import AppKit
import CoreGraphics
import ApplicationServices
import CoreFoundation

private let kKeycodeField: CGEventField = .keyboardEventKeycode
private let kEventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
private let kBackspace: UInt16 = 0x33
private let kSpace: UInt16 = 0x31
private let kReturn: UInt16 = 0x24
private let kTab: UInt16 = 0x30
private let kEscape: UInt16 = 0x35
private let kVK_Control: UInt16 = 0x3B
private let kVK_RightControl: UInt16 = 0x3E

/// Global CGEvent hook; requires Input Monitoring (and usually Accessibility) in System Settings.
final class EventTapController: NSObject {
    var buffer = WordBuffer()
    var mach: CFMachPort?
    var traceHandler: (DecisionTrace) -> Void
    var lex: LexiconStore
    let input = InputSourceManager.shared
    private let translator = KeyStrokesTranslator.shared
    private let registry = EnabledKeyboardSourcesRegistry.shared

    @objc private var isRunning = false
    var loopSource: CFRunLoopSource?
    private(set) var failedToCreateTap: Bool = false
    private(set) var tapFailureUserMessage: String?
    private var didLogFirstKey = false
    private var pendingAmbiguous: [PendingAmbiguousWord] = []
    private let maxPendingAmbiguous = 32
    private var ignoreTapKeyDownForOurSynthetic = false
    private let ignoreTapLock = NSLock()
    private var layoutUndoStack: [String] = []
    private let layoutUndoMax = 32
    private var lastControlTapTime: CFTimeInterval = 0
    private var controlTapCount = 0
    private let controlDoubleTapWindow: CFTimeInterval = 0.45
    private var lastCapsLockState = false
    private var lastWordSnapshot: (strokes: [(UInt16, Bool)], capsLock: Bool)?
    /// macOS шлёт Control чаще через `flagsChanged`, а не `keyDown`.
    private var controlModifierWasDown = false
    /// Streaming plausibility для пошаговой смены раскладки (сравнение с прошлым нажатием).
    private var lastIncrementalPlaus: (cur: Double, bestAlt: Double, curId: String)?
    private var lastIncrementalStrokeCount: Int = 0
    private var lastKeyDownTime: CFTimeInterval = 0

    init(lex: LexiconStore, onTrace: @escaping (DecisionTrace) -> Void) {
        self.lex = lex
        self.traceHandler = onTrace
        super.init()
        NotificationCenter.default.addObserver(
            forName: .lexiconStoreDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.lex = LexiconStore.shared
        }
    }

    func start() {
        guard !isRunning else { return }
        failedToCreateTap = false
        tapFailureUserMessage = nil
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: kEventMask,
            callback: { proxy, t, e, u in
                EventTapController.cb(proxy, t, e, u)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            failedToCreateTap = true
            tapFailureUserMessage = "• Клавиатурный тап: НЕ СОЗДАН (CGEvent.tapCreate=nil) — без **Input Monitoring** тап nil. См. ниже «TCC и подпись»."
            LaunchLog.append("EventTap: tapCreate FAILED (nil) — нет Input Monitoring / перезапустите .app")
            return
        }
        _ = kKeycodeField
        self.mach = port
        CGEvent.tapEnable(tap: port, enable: true)
        guard let sl = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            failedToCreateTap = true
            CGEvent.tapEnable(tap: port, enable: false)
            self.mach = nil
            tapFailureUserMessage = "• Тап создан, но CFMachPortCreateRunLoopSource=nil — колбэк **никогда** не вызовется (внутренняя ошибка; см. ~/LanguageSwitcher-launch.log)."
            LaunchLog.append("EventTap: CRITICAL CFMachPortCreateRunLoopSource=nil — run loop not fed, no key events")
            return
        }
        loopSource = sl
        CFRunLoopAddSource(CFRunLoopGetMain(), sl, .commonModes)
        isRunning = true
        LaunchLog.append("EventTap: created + run loop; keyDown + flagsChanged (Control)")
    }

    func stop() {
        if let p = mach { CGEvent.tapEnable(tap: p, enable: false) }
        if let s = loopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes)
        }
        loopSource = nil
        mach = nil
        isRunning = false
    }

    private struct PendingAmbiguousWord {
        var readingsByID: [String: String]
        var currentSourceID: String
        /// As on screen at boundary (`asCurrentScript`).
        var displayed: String
        /// Other reading for the same keys (`asAlternateScript`), e.g. «hey» when screen shows «рун».
        var alternateScript: String
    }

    private func clearPending() { pendingAmbiguous.removeAll() }

    private func pushLayoutUndo(before previousId: String) {
        guard !previousId.isEmpty else { return }
        layoutUndoStack.append(previousId)
        if layoutUndoStack.count > layoutUndoMax {
            layoutUndoStack.removeFirst(layoutUndoStack.count - layoutUndoMax)
        }
    }

    /// Двойной Ctrl: переписать слово в «другой» скрипт (RU↔латиница) и добавить новую форму в user-словарь.
    private func registerControlDoubleTapManualSwap() {
        let t = CFAbsoluteTimeGetCurrent()
        if t - lastControlTapTime > controlDoubleTapWindow { controlTapCount = 0 }
        controlTapCount += 1
        lastControlTapTime = t
        guard controlTapCount >= 2 else { return }
        controlTapCount = 0
        performDoubleCtrlScriptSwapAndLearn()
    }

    private func performDoubleCtrlScriptSwapAndLearn() {
        registry.syncCurrentInputSourceFromSystem()
        let caps: Bool
        let strokes: [(UInt16, Bool)]
        if !buffer.isEmpty {
            strokes = buffer.keyStrokes
            caps = lastCapsLockState
        } else if let snap = lastWordSnapshot {
            strokes = snap.strokes
            caps = snap.capsLock
        } else {
            LaunchLog.append("EventTap: двойной Ctrl — нет слова (наберите слово или только что нажмите пробел после него)")
            return
        }
        guard !strokes.isEmpty else { return }

        let srcs = registry.enabledSources
        guard let ruEntry = srcs.first(where: { registry.isRussianSourceID($0.sourceID) }),
              let latEntry = srcs.first(where: { !registry.isRussianSourceID($0.sourceID) }) else {
            LaunchLog.append("EventTap: двойной Ctrl — в системе нужны и русская, и латинская раскладка")
            return
        }

        var readings: [String: String] = [:]
        for e in srcs {
            readings[e.sourceID] = translator.string(from: strokes, sourceID: e.sourceID, capsLock: caps)
        }
        let curId = registry.liveCurrentInputSourceID()
        let curIsRu = registry.isRussianSourceID(curId)
        let targetEntry = curIsRu ? latEntry : ruEntry
        let curText = readings[curId] ?? ""
        let newText = readings[targetEntry.sourceID] ?? ""
        guard !curText.isEmpty else { return }
        guard !newText.isEmpty, newText != curText else {
            LaunchLog.append("EventTap: двойной Ctrl — нет альтернативного прочтения для этих клавиш")
            return
        }

        var targetLang = EnabledKeyboardSourcesRegistry.normalizeLangTag(targetEntry.primaryLang)
        if targetLang.isEmpty { targetLang = registry.isRussianSourceID(targetEntry.sourceID) ? "ru" : "en" }

        runSyntheticOnTapThread {
            self.runWithTapSuspendedForSynthetic {
                SyntheticKeyboard.backspaces(curText.count)
                _ = self.input.selectSource(id: targetEntry.sourceID)
                SyntheticKeyboard.type(newText, layoutSourceID: targetEntry.sourceID)
            }
        }
        LexiconStore.shared.appendUserWords(lang: targetLang, words: [newText])
        buffer.clear()
        LaunchLog.append("EventTap: двойной Ctrl — «\(curText)» → «\(newText)» (+user \(targetLang))")
    }

    /// Left/right Control alone (двойной Ctrl — ручная смена скрипта слова).
    private static func isBareControlKey(kc: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard kc == kVK_Control || kc == kVK_RightControl else { return false }
        if flags.contains(.command) || flags.contains(.option) || flags.contains(.function) || flags.contains(.shift) {
            return false
        }
        return true
    }

    /// Control на macOS чаще приходит как `flagsChanged` с keycode 59/62, а не `keyDown`.
    private func handleControlFlagsChanged(_ e: CGEvent) {
        let kc = UInt16(truncatingIfNeeded: e.getIntegerValueField(kKeycodeField))
        guard kc == kVK_Control || kc == kVK_RightControl else { return }
        let f = e.nsModifierFlags
        let nowCtrl = f.contains(.control)
        let leading = nowCtrl && !controlModifierWasDown
        controlModifierWasDown = nowCtrl
        guard leading, !e.isKeyAutorepeat else { return }
        guard Self.isBareControlKey(kc: kc, flags: f) else { return }
        registerControlDoubleTapManualSwap()
    }

    /// Раскладка для набора сегмента: кириллица → RU source, иначе → латиница.
    private static func layoutSourceID(forScriptSegment text: String, ruId: String, latId: String) -> String {
        if text.range(of: #"[а-яёА-ЯЁ]"#, options: .regularExpression) != nil {
            return ruId
        }
        return latId
    }

    private func tryIncrementalLayoutSwitchAfterKeystroke(capsLock: Bool, meta: PlausibilityKeyMeta? = nil) {
        guard AppSettings.shared.incrementalLayoutSwitchEnabled else { return }
        let minLen = AppSettings.shared.incrementalPrefixMinLength
        guard !buffer.isEmpty else { return }
        let strokeN = buffer.keyStrokes.count
        if strokeN < lastIncrementalStrokeCount { lastIncrementalPlaus = nil }
        lastIncrementalStrokeCount = strokeN

        registry.syncCurrentInputSourceFromSystem()
        let curId = registry.currentInputSourceID
        let readings = buildReadings(capsLock: capsLock)
        let srcs = registry.enabledSources
        guard srcs.count >= 2 else { return }

        var curLang = registry.langTag(forSourceID: curId).map { EnabledKeyboardSourcesRegistry.normalizeLangTag($0) } ?? ""
        if curLang.isEmpty {
            curLang = registry.isRussianSourceID(curId) ? "ru" : "en"
        }
        let curText = readings[curId] ?? ""
        let curP = WordPlausibility.streaming01(text: curText, lang: curLang, lex: lex, meta: meta)

        var bestAltP: Double = 0
        var bestEntry: KeyboardSourceEntry?
        var bestText: String?

        let curIsRu = registry.isRussianSourceID(curId)
        for e in srcs where e.sourceID != curId {
            if registry.isRussianSourceID(e.sourceID) == curIsRu {
                continue
            }
            var lang = EnabledKeyboardSourcesRegistry.normalizeLangTag(e.primaryLang)
            if lang.isEmpty {
                lang = registry.isRussianSourceID(e.sourceID) ? "ru" : "en"
            }
            let text = readings[e.sourceID] ?? ""
            guard text != curText else { continue }
            guard text.count >= minLen else { continue }
            let pAlt = WordPlausibility.streaming01(text: text, lang: lang, lex: lex, meta: meta)
            if pAlt > bestAltP {
                bestAltP = pAlt
                bestEntry = e
                bestText = text
            }
        }

        let margin = WordPlausibility.incrementalSwitchMargin
        if curText.count >= minLen, curP + margin >= bestAltP {
            lastIncrementalPlaus = (curP, bestAltP, curId)
            return
        }

        var shouldSwitch = false
        if let t = bestText, t.count >= minLen, bestAltP > curP + margin { shouldSwitch = true }
        if !shouldSwitch, let _ = bestEntry, let last = lastIncrementalPlaus, last.curId == curId, curP < last.cur {
            let rel = last.cur > 0.04 ? (last.cur - curP) / last.cur : 0
            if rel >= WordPlausibility.relativeDropForSignal, bestAltP + 0.02 >= curP, (bestText?.count ?? 0) >= minLen {
                shouldSwitch = true
            }
        }

        if !shouldSwitch {
            lastIncrementalPlaus = (curP, bestAltP, curId)
            return
        }
        guard let e = bestEntry, let altStr = bestText, altStr.count >= minLen else {
            lastIncrementalPlaus = (curP, bestAltP, curId)
            return
        }
        let live = registry.liveCurrentInputSourceID()
        guard live == curId || live == e.sourceID else { return }
        var altL = registry.langTag(forSourceID: e.sourceID).map { EnabledKeyboardSourcesRegistry.normalizeLangTag($0) } ?? ""
        if altL.isEmpty { altL = registry.isRussianSourceID(e.sourceID) ? "ru" : "en" }
        lastIncrementalPlaus = nil
        pushLayoutUndo(before: live)
        _ = input.selectSource(id: e.sourceID)
        LaunchLog.append("EventTap: score префикс cur=\(String(format: "%.2f", curP)) → alt=\(String(format: "%.2f", bestAltP)) «\(altStr)» (\(altL) \(e.sourceID))")
    }

    private static func isWordPlausibleForLang(_ s: String, lang: String, lex: LexiconStore) -> Bool {
        WordPlausibility.score01(word: s, lang: lang, lex: lex) >= WordPlausibility.acceptThreshold
    }

    /// Reading of the same keystrokes in `preferLang`, for deferred replacement — never fall back to on-screen Cyrillic when we asked for English.
    private static func targetForPending(_ p: PendingAmbiguousWord, preferLang: String, lex: LexiconStore) -> String {
        let reg = EnabledKeyboardSourcesRegistry.shared
        let want = EnabledKeyboardSourcesRegistry.normalizeLangTag(preferLang)
        let srcs = reg.enabledSources

        for e in srcs where EnabledKeyboardSourcesRegistry.normalizeLangTag(e.primaryLang) == want {
            if let r = p.readingsByID[e.sourceID], !r.isEmpty { return r }
        }
        if want == "en" {
            for e in srcs where !reg.isRussianSourceID(e.sourceID) {
                if let r = p.readingsByID[e.sourceID], !r.isEmpty { return r }
            }
        } else if want == "ru" {
            for e in srcs where reg.isRussianSourceID(e.sourceID) {
                if let r = p.readingsByID[e.sourceID], !r.isEmpty { return r }
            }
        }

        let curLang = reg.langTag(forSourceID: p.currentSourceID).map { EnabledKeyboardSourcesRegistry.normalizeLangTag($0) } ?? ""
        if !p.alternateScript.isEmpty, !want.isEmpty, curLang != want {
            return p.alternateScript
        }
        if !p.alternateScript.isEmpty, isWordPlausibleForLang(p.alternateScript, lang: want, lex: lex) {
            return p.alternateScript
        }
        if !p.displayed.isEmpty, isWordPlausibleForLang(p.displayed, lang: want, lex: lex) {
            return p.displayed
        }
        if !p.alternateScript.isEmpty { return p.alternateScript }
        return p.displayed
    }

    private static func displayCurrentWord(readings: [String: String], currentId: String) -> String {
        readings[currentId] ?? ""
    }

    /// Compare on-screen word vs replacement for skipping redundant re-type (avoids «Ho» + «House» glitches).
    private static func isSameLexicalForm(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().replacingOccurrences(of: "ё", with: "е")
        let y = b.lowercased().replacingOccurrences(of: "ё", with: "е")
        return x == y
    }

    private static func stringForScoredCurrent(readings: [String: String], currentId: String, t: DecisionTrace) -> String {
        if let g = t.appliedReplacement, !g.isEmpty, t.reasonCode.hasPrefix("to_") { return g }
        if t.reasonCode.hasPrefix("ok_") { return t.asCurrentScript }
        return t.asCurrentScript.isEmpty ? (readings[currentId] ?? "") : t.asCurrentScript
    }

    private func runWithTapSuspendedForSynthetic(perform work: () -> Void) {
        ignoreTapLock.lock()
        ignoreTapKeyDownForOurSynthetic = true
        ignoreTapLock.unlock()
        if let t = mach { CGEvent.tapEnable(tap: t, enable: false) }
        defer {
            if let t = mach { CGEvent.tapEnable(tap: t, enable: true) }
            ignoreTapLock.lock()
            ignoreTapKeyDownForOurSynthetic = false
            ignoreTapLock.unlock()
        }
        work()
    }

    /// Synthetic replace must run before the next key event is delivered; `main.async` races and causes «Wareho»+«Warehouse».
    private func runSyntheticOnTapThread(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private static func cb(_ proxy: CGEventTapProxy, _ type: CGEventType, _ e: CGEvent, _ u: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
        Unmanaged<EventTapController>.fromOpaque(u!).takeUnretainedValue().onEvent(type, e)
    }

    private func onEvent(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown || type == .flagsChanged {
            ignoreTapLock.lock()
            let skip = ignoreTapKeyDownForOurSynthetic
            ignoreTapLock.unlock()
            if skip { return Unmanaged.passUnretained(e) }
        }
        if type == .tapDisabledByTimeout, let m = mach {
            CGEvent.tapEnable(tap: m, enable: true)
            LaunchLog.append("EventTap: tap re-enabled (was tapDisabledByTimeout)")
        }
        if type == .tapDisabledByUserInput, let m = mach {
            CGEvent.tapEnable(tap: m, enable: true)
            LaunchLog.append("EventTap: tap re-enabled (was tapDisabledByUserInput — часто: Control перехват)")
        }
        if type == .flagsChanged {
            handleControlFlagsChanged(e)
            return Unmanaged.passUnretained(e)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(e) }
        if !didLogFirstKey {
            didLogFirstKey = true
            let kc = e.getIntegerValueField(kKeycodeField)
            LaunchLog.append("EventTap: first keyDown (HID доходит) keycode=\(kc) autoSwitch=\(AppSettings.shared.isAutoSwitchEnabled)")
        }
        if !AppSettings.shared.isAutoSwitchEnabled { return Unmanaged.passUnretained(e) }
        if let n = NSEvent(cgEvent: e) {
            if n.isARepeat { return Unmanaged.passUnretained(e) }
            return onKeyDown(n: n, cg: e)
        }
        if e.isKeyAutorepeat { return Unmanaged.passUnretained(e) }
        return onKeyDown(cg: e)
    }

    private func onKeyDown(n: NSEvent, cg: CGEvent) -> Unmanaged<CGEvent>? {
        let kc = n.keyCode
        let noTextMods: NSEvent.ModifierFlags = [.command, .control, .option, .function]
        if !n.modifierFlags.isDisjoint(with: noTextMods) { buffer.clear(); clearPending(); lastKeyDownTime = 0; return Unmanaged.passUnretained(cg) }
        if kc == kBackspace {
            buffer.popLast()
            lastKeyDownTime = CFAbsoluteTimeGetCurrent()
            if !buffer.isEmpty {
                tryIncrementalLayoutSwitchAfterKeystroke(capsLock: n.modifierFlags.contains(.capsLock), meta: PlausibilityKeyMeta(isBackspace: true))
            } else { lastIncrementalPlaus = nil; lastIncrementalStrokeCount = 0 }
            return Unmanaged.passUnretained(cg)
        }
        if kc == kEscape { buffer.clear(); clearPending(); lastKeyDownTime = 0; return Unmanaged.passUnretained(cg) }
        if Self.isWordBoundaryKeycode(kc) { return handleBoundary(cg: cg, n: n) }
        if Self.isWordChar(n: n, keyCode: kc, shift: n.modifierFlags.contains(.shift), caps: n.modifierFlags.contains(.capsLock)) {
            lastCapsLockState = n.modifierFlags.contains(.capsLock)
            let now = CFAbsoluteTimeGetCurrent()
            if !buffer.isEmpty, lastKeyDownTime > 0 { LanguageContextModel.shared.registerInterKeyGap(now - lastKeyDownTime) }
            lastKeyDownTime = now
            buffer.append(key: kc, shift: n.modifierFlags.contains(.shift))
            tryIncrementalLayoutSwitchAfterKeystroke(capsLock: n.modifierFlags.contains(.capsLock), meta: nil)
            return Unmanaged.passUnretained(cg)
        }
        buffer.clear(); clearPending(); lastKeyDownTime = 0
        return Unmanaged.passUnretained(cg)
    }

    private func onKeyDown(cg: CGEvent) -> Unmanaged<CGEvent>? {
        let f = cg.nsModifierFlags
        let kc = cg.vKey
        let noTextMods: NSEvent.ModifierFlags = [.command, .control, .option, .function]
        if !f.isDisjoint(with: noTextMods) { buffer.clear(); clearPending(); lastKeyDownTime = 0; return Unmanaged.passUnretained(cg) }
        if kc == kBackspace {
            buffer.popLast()
            lastKeyDownTime = CFAbsoluteTimeGetCurrent()
            if !buffer.isEmpty {
                tryIncrementalLayoutSwitchAfterKeystroke(capsLock: f.contains(.capsLock), meta: PlausibilityKeyMeta(isBackspace: true))
            } else { lastIncrementalPlaus = nil; lastIncrementalStrokeCount = 0 }
            return Unmanaged.passUnretained(cg)
        }
        if kc == kEscape { buffer.clear(); clearPending(); lastKeyDownTime = 0; return Unmanaged.passUnretained(cg) }
        if Self.isWordBoundaryKeycode(kc) { return handleBoundary(cg: cg, n: nil) }
        if Self.isWordChar(n: nil, keyCode: kc, shift: f.contains(.shift), caps: f.contains(.capsLock)) {
            lastCapsLockState = f.contains(.capsLock)
            let now = CFAbsoluteTimeGetCurrent()
            if !buffer.isEmpty, lastKeyDownTime > 0 { LanguageContextModel.shared.registerInterKeyGap(now - lastKeyDownTime) }
            lastKeyDownTime = now
            buffer.append(key: kc, shift: f.contains(.shift))
            tryIncrementalLayoutSwitchAfterKeystroke(capsLock: f.contains(.capsLock), meta: nil)
            return Unmanaged.passUnretained(cg)
        }
        buffer.clear(); clearPending(); lastKeyDownTime = 0
        return Unmanaged.passUnretained(cg)
    }

    private func buildReadings(capsLock: Bool) -> [String: String] {
        let strokes = buffer.keyStrokes
        var m: [String: String] = [:]
        for e in registry.enabledSources {
            m[e.sourceID] = translator.string(from: strokes, sourceID: e.sourceID, capsLock: capsLock)
        }
        return m
    }

    private func handleBoundary(cg: CGEvent, n: NSEvent?) -> Unmanaged<CGEvent>? {
        registry.syncCurrentInputSourceFromSystem()
        let caps = n?.modifierFlags.contains(.capsLock) ?? cg.nsModifierFlags.contains(.capsLock)
        let readings = buildReadings(capsLock: caps)
        let curId = registry.currentInputSourceID
        let wus = buffer.stringAsUS()
        let wru = buffer.stringAsRU()
        let tisRU = input.isCurrentlyRussian()
        let hasAnyReading = readings.values.contains { !$0.isEmpty }
        if !buffer.isEmpty, hasAnyReading {
            lastWordSnapshot = (strokes: buffer.keyStrokes, capsLock: caps)
        }
        buffer.clear()
        lastKeyDownTime = 0
        let minL = AppSettings.shared.minWordLength
        let disp = Self.displayCurrentWord(readings: readings, currentId: curId)
        if !hasAnyReading, wus.isEmpty, wru.isEmpty {
            clearPending()
            let d = DecisionTrace(
                asCurrentScript: "", asAlternateScript: "", tisWasRussian: tisRU, aInEn: false, aInRu: false, bInEn: false, bInRu: false, appliedReplacement: nil, didSwitchTIS: false,
                reasonCode: "empty", reasonHuman: "Граница, но в буфере нет букв.",
                switchToSourceID: nil, lexHitsSummary: "", currentSourceID: curId
            )
            DispatchQueue.main.async { self.traceHandler(d) }
            return Unmanaged.passUnretained(cg)
        }
        let srcs = registry.enabledSources
        let t: DecisionTrace
        if srcs.count >= 2 {
            t = LanguageScorer.scoreMulti(.init(currentSourceId: curId, sources: srcs, readingsByID: readings, lex: lex, minLength: minL))
        } else {
            t = LanguageScorer.score(wordAsUS: wus, wordAsRU: wru, tisIsRussian: tisRU, lex: lex, minLength: minL)
        }
        if t.reasonCode == "ambi" || t.reasonCode == "ambi2" {
            if pendingAmbiguous.count < maxPendingAmbiguous {
                pendingAmbiguous.append(PendingAmbiguousWord(
                    readingsByID: readings, currentSourceID: curId, displayed: t.asCurrentScript, alternateScript: t.asAlternateScript
                ))
            }
            DispatchQueue.main.async { self.traceHandler(t) }
            return Unmanaged.passUnretained(cg)
        }
        if let rec = LanguageScorer.contextTagToRecord(t) {
            LanguageContextModel.shared.recordCompletedWord(resolvedTag: rec)
        }
        let pCopy = pendingAmbiguous
        let languageHint = LanguageScorer.inferredLanguageIntent(t, minWord: minL)
        if !pCopy.isEmpty, let preferLang = languageHint {
            let want = EnabledKeyboardSourcesRegistry.normalizeLangTag(preferLang)
            if let have = Self.normalizedPrimaryLang(forSourceID: curId), have == want {
                clearPending()
                let d = DecisionTrace(
                    asCurrentScript: t.asCurrentScript, asAlternateScript: t.asAlternateScript, tisWasRussian: tisRU,
                    aInEn: t.aInEn, aInRu: t.aInRu, bInEn: t.bInEn, bInRu: t.bInRu,
                    appliedReplacement: nil, didSwitchTIS: false,
                    reasonCode: "skip_same_lang",
                    reasonHuman: "Системная раскладка уже \(preferLang) — отложенная вставка не выполняется.",
                    switchToSourceID: nil, lexHitsSummary: t.lexHitsSummary, currentSourceID: curId
                )
                DispatchQueue.main.async { self.traceHandler(d) }
                return Unmanaged.passUnretained(cg)
            }
            let parts = pCopy.map { Self.targetForPending($0, preferLang: preferLang, lex: lex) }
            let currentPart = Self.stringForScoredCurrent(readings: readings, currentId: curId, t: t)
            let allText = (parts + [currentPart]).joined(separator: " ")
            let curDisp = Self.displayCurrentWord(readings: readings, currentId: curId)
            let backspaceN = pCopy.reduce(0) { $0 + $1.displayed.count } + curDisp.count + (pCopy.isEmpty ? 0 : pCopy.count)
            let targetSid = Self.sourceId(forLang: preferLang) ?? curId
            let boundaryVK = cg.vKey
            let dRetro = DecisionTrace(
                asCurrentScript: t.asCurrentScript, asAlternateScript: t.asAlternateScript, tisWasRussian: tisRU,
                aInEn: t.aInEn, aInRu: t.aInRu, bInEn: t.bInEn, bInRu: t.bInRu,
                appliedReplacement: nil, didSwitchTIS: true,
                reasonCode: "deferred_resolved",
                reasonHuman: "Отложенно: \(pCopy.count) сегм. → \(preferLang) (по «\(t.asCurrentScript)»), вставка «\(allText)»",
                switchToSourceID: targetSid, lexHitsSummary: t.lexHitsSummary, currentSourceID: curId
            )
            clearPending()
            DispatchQueue.main.async { self.traceHandler(t) }
            DispatchQueue.main.async { self.traceHandler(dRetro) }
            LaunchLog.append("EventTap: deferred \(pCopy.count) → \(preferLang) + «\(t.asCurrentScript)» backspaces=\(backspaceN)")
            let wordPieces = parts + [currentPart]
            runSyntheticOnTapThread {
                self.runWithTapSuspendedForSynthetic {
                    let beforeLayout = EnabledKeyboardSourcesRegistry.shared.liveCurrentInputSourceID()
                    SyntheticKeyboard.backspaces(backspaceN)
                    if targetSid != beforeLayout {
                        self.pushLayoutUndo(before: beforeLayout)
                    }
                    let reg = EnabledKeyboardSourcesRegistry.shared
                    let list = reg.enabledSources
                    if let ruSid = list.first(where: { reg.isRussianSourceID($0.sourceID) })?.sourceID,
                       let latSid = list.first(where: { !reg.isRussianSourceID($0.sourceID) })?.sourceID {
                        var firstPiece = true
                        for piece in wordPieces where !piece.isEmpty {
                            if !firstPiece { SyntheticKeyboard.postSpace() }
                            firstPiece = false
                            let sid = Self.layoutSourceID(forScriptSegment: piece, ruId: ruSid, latId: latSid)
                            _ = self.input.selectSource(id: sid)
                            SyntheticKeyboard.type(piece, layoutSourceID: sid)
                        }
                        _ = self.input.selectSource(id: targetSid)
                    } else {
                        _ = self.input.selectSource(id: targetSid)
                        SyntheticKeyboard.type(allText, layoutSourceID: targetSid)
                    }
                    SyntheticKeyboard.postBoundaryCorresponding(toVirtualKey: boundaryVK)
                }
            }
            return nil
        }
        if !pCopy.isEmpty, languageHint == nil {
            DispatchQueue.main.async { self.traceHandler(t) }
            return Unmanaged.passUnretained(cg)
        }
        let skipSameLang = Self.shouldSkipSwitchBecauseCurrentMatchesTarget(curId: curId, t: t)
        let traceForUI = skipSameLang ? t.skippingBecauseCurrentLayoutMatchesTarget() : t
        DispatchQueue.main.async { self.traceHandler(traceForUI) }
        if let g = t.appliedReplacement, t.didSwitchTIS, !g.isEmpty, !skipSameLang {
            let aScreen = Self.displayCurrentWord(readings: readings, currentId: curId)
            let deleteCount = max(t.asCurrentScript.count, aScreen.count)
            let targetSid = t.switchToSourceID ?? Self.inferBinaryTargetId(from: t)
            let boundaryVK = cg.vKey
            let retypeNeeded = !Self.isSameLexicalForm(g, aScreen)
            runSyntheticOnTapThread {
                self.runWithTapSuspendedForSynthetic {
                    let beforeLayout = EnabledKeyboardSourcesRegistry.shared.liveCurrentInputSourceID()
                    if retypeNeeded {
                        SyntheticKeyboard.backspaces(deleteCount)
                    }
                    if let sid = targetSid {
                        if sid != beforeLayout {
                            self.pushLayoutUndo(before: beforeLayout)
                        }
                        _ = self.input.selectSource(id: sid)
                    } else if t.reasonCode == "to_ru" {
                        if let ru = Self.sourceId(forLang: "ru"), ru != beforeLayout {
                            self.pushLayoutUndo(before: beforeLayout)
                        }
                        _ = self.input.selectRussian()
                    } else if t.reasonCode == "to_en" {
                        if let en = Self.sourceId(forLang: "en"), en != beforeLayout {
                            self.pushLayoutUndo(before: beforeLayout)
                        }
                        _ = self.input.selectUS()
                    }
                    if retypeNeeded {
                        let typeSid = targetSid ?? (t.reasonCode == "to_ru" ? Self.sourceId(forLang: "ru") : Self.sourceId(forLang: "en")) ?? EnabledKeyboardSourcesRegistry.shared.liveCurrentInputSourceID()
                        SyntheticKeyboard.type(g, layoutSourceID: typeSid)
                    }
                    SyntheticKeyboard.postBoundaryCorresponding(toVirtualKey: boundaryVK)
                }
            }
            return nil
        }
        return Unmanaged.passUnretained(cg)
    }

    private static func inferBinaryTargetId(from t: DecisionTrace) -> String? {
        let e = EnabledKeyboardSourcesRegistry.shared.enabledSources
        switch t.reasonCode {
        case "to_ru":
            return e.first { $0.sourceID.lowercased().contains("russian") || $0.primaryLang == "ru" }?.sourceID
        case "to_en":
            return e.first { !$0.sourceID.lowercased().contains("russian") }?.sourceID
        default: return nil
        }
    }

    private static func normalizedPrimaryLang(forSourceID id: String) -> String? {
        guard let t = EnabledKeyboardSourcesRegistry.shared.langTag(forSourceID: id), !t.isEmpty else { return nil }
        return EnabledKeyboardSourcesRegistry.normalizeLangTag(t)
    }

    private static func resolvedTargetLanguageTag(from t: DecisionTrace) -> String? {
        if let sid = t.switchToSourceID, !sid.isEmpty, let l = normalizedPrimaryLang(forSourceID: sid) { return l }
        if let inferred = inferBinaryTargetId(from: t), !inferred.isEmpty, let l = normalizedPrimaryLang(forSourceID: inferred) { return l }
        if t.reasonCode.hasPrefix("to_") {
            let tail = String(t.reasonCode.dropFirst(3))
            if !tail.isEmpty { return EnabledKeyboardSourcesRegistry.normalizeLangTag(tail) }
        }
        return nil
    }

    /// User already has the target language selected in TIS — do not replace text or switch again.
    private static func shouldSkipSwitchBecauseCurrentMatchesTarget(curId: String, t: DecisionTrace) -> Bool {
        guard t.didSwitchTIS, let rep = t.appliedReplacement, !rep.isEmpty else { return false }
        if let sid = t.switchToSourceID, !sid.isEmpty, sid == curId { return true }
        if let inferred = inferBinaryTargetId(from: t), !inferred.isEmpty, inferred == curId { return true }
        guard let want = resolvedTargetLanguageTag(from: t) else { return false }
        guard let have = normalizedPrimaryLang(forSourceID: curId) else { return false }
        return want == have
    }

    private static func sourceId(forLang tag: String) -> String? {
        EnabledKeyboardSourcesRegistry.shared.enabledSources.first { $0.primaryLang == tag }?.sourceID
    }

    private static func isWordBoundaryKeycode(_ kc: UInt16) -> Bool { [kSpace, kReturn, kTab].contains(kc) }

    private static func boundaryString(for kc: UInt16) -> String {
        switch kc {
        case kSpace: return " "
        case kReturn: return "\r"
        case kTab: return "\t"
        default: return " "
        }
    }

    private static func isWordChar(n: NSEvent?, keyCode: UInt16, shift: Bool, caps: Bool) -> Bool {
        if isWordCharKeymap(keyCode: keyCode, shift: shift) { return true }
        if let n, let s = n.characters?.first {
            if s.isLetter || s.isNumber { return true }
            if "-_'".contains(s) { return true }
        }
        let cur = EnabledKeyboardSourcesRegistry.shared.currentInputSourceID
        if !cur.isEmpty {
            let ch = KeyStrokesTranslator.shared.string(from: [(keyCode, shift)], sourceID: cur, capsLock: caps)
            if let c = ch.first, c.isLetter || c.isNumber { return true }
            if ch.rangeOfCharacter(from: .letters) != nil { return true }
        }
        return false
    }

    private static func isWordCharKeymap(keyCode: UInt16, shift: Bool) -> Bool {
        for script in [KeyboardScript.usQWERTY, KeyboardScript.ruJcuken] {
            guard let pair = Keymap.charPair(key: keyCode, shift: shift, script: script) else { continue }
            guard let c = pair.first else { continue }
            if c.isLetter || c.isNumber { return true }
            if script == .usQWERTY, "-_'".contains(c) { return true }
        }
        return false
    }
}
