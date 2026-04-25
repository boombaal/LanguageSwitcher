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
    /// Сколько полных границ слов прошло **после** того, как в `pending` попало ambi-слово (лог, опцион.)
    private var wordBoundariesAfterAmbiPending: Int = 0
    /// Слова между ambi-сегмент(ами) и **текущим** (разрешающим) словом, пока нет `languageHint` / до deferred.
    /// Иначе при «рун»+пробел+`hey`+проб+`how`+… срабатывал `stale_pending_dropped` — «рун» оставался, дальше путалась вставка («рунhey»).
    private var deferredInterstitialWords: [PendingAmbiguousWord] = []
    private let maxDeferredInterstitialWords = 40
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
    /// После пошаговой смены TIS — гистерезис (см. `incrementalLayoutCooldown`).
    private var lastIncrementalLayoutSwitch: CFTimeInterval = 0
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
        /// Нажатия в этом «слове»; для `backspaceN` надёжнее, чем `displayed` (нет двойного учёта с текущим буфером).
        var keyStrokes: [(UInt16, Bool)]
    }

    private static func deferredKeyCount(_ p: PendingAmbiguousWord) -> Int {
        if !p.keyStrokes.isEmpty { return p.keyStrokes.count }
        return p.displayed.count
    }

    private func clearPending() {
        pendingAmbiguous.removeAll()
        wordBoundariesAfterAmbiPending = 0
        deferredInterstitialWords.removeAll(keepingCapacity: false)
    }

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

    /// «По буквам»: RU- и EN-чтения одних клавиш, накопленные prefix+ngram+контекст, без late fuzzy; префикс = проекция в другой скрипт.
    private func tryIncrementalLayoutSwitchAfterKeystroke(capsLock: Bool) {
        guard AppSettings.shared.incrementalLayoutSwitchEnabled else { return }
        let minLen = AppSettings.shared.incrementalPrefixMinLength
        guard !buffer.isEmpty else { return }
        registry.syncCurrentInputSourceFromSystem()
        let curId = registry.currentInputSourceID
        let srcs = registry.enabledSources
        guard srcs.count >= 2,
              let ruEntry = srcs.first(where: { registry.isRussianSourceID($0.sourceID) }),
              let latEntry = srcs.first(where: { !registry.isRussianSourceID($0.sourceID) }) else { return }

        let n = buffer.keyStrokes.count
        let ctx = LanguageContextModel.shared
        var accEN = 0.0
        var accRU = 0.0
        for len in 1...n {
            let strokes = Array(buffer.keyStrokes.prefix(len))
            let read = buildReadings(strokes: strokes, capsLock: capsLock)
            let rE = read[latEntry.sourceID] ?? ""
            let rR = read[ruEntry.sourceID] ?? ""
            accEN += WordPlausibility.incrementalPlaus01(prefix: rE, lang: "en", lex: lex) + 0.035 * ctx.incrementalLangBias(for: "en")
            accRU += WordPlausibility.incrementalPlaus01(prefix: rR, lang: "ru", lex: lex) + 0.035 * ctx.incrementalLangBias(for: "ru")
        }

        let readFull = buildReadings(strokes: buffer.keyStrokes, capsLock: capsLock)
        let rENFull = readFull[latEntry.sourceID] ?? ""
        let rRUFull = readFull[ruEntry.sourceID] ?? ""
        let conf = 1.0 - exp(-0.2 * Double(n))
        let now = CFAbsoluteTimeGetCurrent()
        let cool = AppSettings.shared.incrementalLayoutCooldown
        let curIsRU = registry.isRussianSourceID(curId)
        if now - lastIncrementalLayoutSwitch < cool {
            if curIsRU { accEN -= 0.1 } else { accRU -= 0.1 }
        }

        if AppSettings.shared.incrementalScoringDebug {
            let d = accRU - accEN
            let th = WordPlausibility.incrementalSumDiffThreshold(keyStrokes: n)
            var dec: String
            if max(rENFull.count, rRUFull.count) < minLen { dec = "короткий" }
            else if conf < AppSettings.shared.incrementalMinConfidence { dec = "low_conf" }
            else if (curIsRU && accEN - accRU > th) || (!curIsRU && accRU - accEN > th) { dec = "switch?" }
            else { dec = "pending" }
            let line = "typed en:«\(rENFull)» ru:«\(rRUFull)» | accEN \(String(format: "%.2f", accEN)) accRU \(String(format: "%.2f", accRU)) Δ(ru-en) \(String(format: "%.2f", d)) th \(String(format: "%.2f", th)) conf \(String(format: "%.2f", conf)) — \(dec)"
            LaunchLog.append("Inc: \(line)")
        }

        guard max(rENFull.count, rRUFull.count) >= minLen else { return }
        guard conf >= AppSettings.shared.incrementalMinConfidence else { return }
        let th = WordPlausibility.incrementalSumDiffThreshold(keyStrokes: n)
        var target: KeyboardSourceEntry?
        if curIsRU, accEN - accRU > th { target = latEntry }
        else if !curIsRU, accRU - accEN > th { target = ruEntry }
        guard let e = target, e.sourceID != curId else { return }
        let live = registry.liveCurrentInputSourceID()
        guard live == curId || live == e.sourceID else { return }
        var altL = registry.langTag(forSourceID: e.sourceID).map { EnabledKeyboardSourcesRegistry.normalizeLangTag($0) } ?? ""
        if altL.isEmpty { altL = registry.isRussianSourceID(e.sourceID) ? "ru" : "en" }
        lastIncrementalLayoutSwitch = now
        pushLayoutUndo(before: live)
        _ = input.selectSource(id: e.sourceID)
        LaunchLog.append("EventTap: инкрем. \(curIsRU ? "RU" : "EN") → \(altL) accEN=\(String(format: "%.2f", accEN)) accRU=\(String(format: "%.2f", accRU)) th=\(String(format: "%.2f", th)) «en:\(rENFull)» / «ru:\(rRUFull)»")
    }

    private static func isWordPlausibleForLang(_ s: String, lang: String, lex: LexiconStore) -> Bool {
        WordPlausibility.score01(word: s, lang: lang, lex: lex) >= WordPlausibility.acceptThreshold
    }

    /// Отлож. вставка: текст текущего слова в целевом языке (те же клавиши, что `readings` на границе), а не `asCurrentScript` из трейса.
    private static func currentWordTextForDeferred(
        preferLang: String,
        readings: [String: String],
        currentId: String,
        t: DecisionTrace,
        sources: [KeyboardSourceEntry]
    ) -> String {
        let want = EnabledKeyboardSourcesRegistry.normalizeLangTag(preferLang)
        let reg = EnabledKeyboardSourcesRegistry.shared
        if want == "en" {
            for e in sources where !reg.isRussianSourceID(e.sourceID) {
                if let s = readings[e.sourceID], !s.isEmpty { return s }
            }
        } else if want == "ru" {
            for e in sources where reg.isRussianSourceID(e.sourceID) {
                if let s = readings[e.sourceID], !s.isEmpty { return s }
            }
        }
        return stringForScoredCurrent(readings: readings, currentId: currentId, t: t)
    }

    /// После `hold_ru_ctx` `inferredLanguageIntent` = ru — тогда отлож. вставка даёт кир+кириллицу (рун+рщц) вместо en-фразы. Override → en, если и ambi-сегм., и текущее en-чтение уверенны.
    private static func deferredEnOverrideWhenHoldRuCtx(
        pending: [PendingAmbiguousWord],
        readings: [String: String],
        t: DecisionTrace,
        sources: [KeyboardSourceEntry],
        lex: LexiconStore
    ) -> String? {
        let reg = EnabledKeyboardSourcesRegistry.shared
        guard t.reasonCode == "hold_ru_ctx", !pending.isEmpty else { return nil }
        var enCurrent = t.asAlternateScript
        for e in sources where !reg.isRussianSourceID(e.sourceID) {
            if let s = readings[e.sourceID], !s.isEmpty { enCurrent = s; break }
        }
        let enC = enCurrent.lowercased()
        guard !enC.isEmpty,
              enC.rangeOfCharacter(from: .letters) != nil,
              isWordPlausibleForLang(enC, lang: "en", lex: lex) else { return nil }
        for p in pending {
            let alt = p.alternateScript
            if alt.isEmpty { continue }
            if alt.range(of: #"^[A-Za-z\-']{2,}$"#, options: .regularExpression) == nil { continue }
            if isWordPlausibleForLang(alt.lowercased(), lang: "en", lex: lex) { return "en" }
        }
        return nil
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

    /// «hey how» и т.п. — вся строка A–Z, без смешения: один select + type, без лишних TIS/пробел между сегм.
    private static func isLatinLetterOrSpaceOnly(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.range(of: #"^[A-Za-z ]+$"#, options: .regularExpression) != nil
    }

    /// Отлож. вставка: если в `enabledSources` только RU, `TIS` для Latin через реестр не выбрать — берём U.S. из `TISCreateASCIICapableInputSourceList` + `usID` для `SyntheticKeyboard.type`.
    private static func typeDeferredLatinWithResolvedUS(
        _ allText: String,
        input: InputSourceManager
    ) {
        let r = input.resolve()
        let st = input.selectUS()
        if st != 0 {
            LaunchLog.append("EventTap: deferred selectUS status=\(st) usID=\(r.usID) usFound=\(r.usFound)")
        }
        Thread.sleep(forTimeInterval: 0.012)
        SyntheticKeyboard.type(allText, layoutSourceID: r.usID)
        LaunchLog.append("EventTap: deferred (US resolve) type «\(allText)» usID=\(r.usID)")
    }

    /// Симметрично `typeDeferredLatinWithResolvedUS`: в short list нет RU, `TIS` для кириллицы берём из `TISCreateASCIICapableList` + `ruID`.
    private static func typeDeferredCyrillicResolvingRU(
        _ allText: String,
        input: InputSourceManager
    ) {
        let r = input.resolve()
        let st = input.selectRussian()
        if st != 0 {
            LaunchLog.append("EventTap: deferred selectRussian status=\(st) ruID=\(r.ruID) ruFound=\(r.ruFound)")
        }
        Thread.sleep(forTimeInterval: 0.012)
        SyntheticKeyboard.type(allText, layoutSourceID: r.ruID)
        LaunchLog.append("EventTap: deferred (RU resolve) type «\(allText)» ruID=\(r.ruID)")
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
        // Только HID autorepeat (удержание клавиши). Не использовать NSEvent.isARepeat: иначе второе
        // отдельное нажатие той же клавиши (напр. ...инг|g| + |g|hbdtn=привет) может не попасть в буфер.
        if e.isKeyAutorepeat { return Unmanaged.passUnretained(e) }
        if let n = NSEvent(cgEvent: e) {
            return onKeyDown(n: n, cg: e)
        }
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
                tryIncrementalLayoutSwitchAfterKeystroke(capsLock: n.modifierFlags.contains(.capsLock))
            }
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
            tryIncrementalLayoutSwitchAfterKeystroke(capsLock: n.modifierFlags.contains(.capsLock))
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
                tryIncrementalLayoutSwitchAfterKeystroke(capsLock: f.contains(.capsLock))
            }
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
            tryIncrementalLayoutSwitchAfterKeystroke(capsLock: f.contains(.capsLock))
            return Unmanaged.passUnretained(cg)
        }
        buffer.clear(); clearPending(); lastKeyDownTime = 0
        return Unmanaged.passUnretained(cg)
    }

    private func buildReadings(capsLock: Bool) -> [String: String] {
        buildReadings(strokes: buffer.keyStrokes, capsLock: capsLock)
    }

    private func buildReadings(strokes: [(UInt16, Bool)], capsLock: Bool) -> [String: String] {
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
        if !pendingAmbiguous.isEmpty {
            wordBoundariesAfterAmbiPending += 1
        }
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
        if srcs.count >= 2,
           let ruEnt = srcs.first(where: { registry.isRussianSourceID($0.sourceID) }),
           let latEnt = srcs.first(where: { $0.sourceID != ruEnt.sourceID }),
           pendingAmbiguous.count == 1, let p0 = pendingAmbiguous.first,
           let tPhrase = LanguageScorer.tryResolveTwoWordPhrase(
            prevDisplayed: p0.displayed,
            prevUS: p0.readingsByID[latEnt.sourceID] ?? p0.alternateScript,
            prevRU: p0.readingsByID[ruEnt.sourceID] ?? p0.displayed,
            wordAsUS: wus, wordAsRU: wru, tisIsRussian: tisRU, latSourceId: latEnt.sourceID, lex: lex, minLength: minL
           ) {
            var m = tPhrase
            m.currentSourceID = curId
            t = m
            LaunchLog.append("EventTap: phrase_to_en — «\(m.appliedReplacement ?? "")»")
        } else if srcs.count >= 2 {
            t = LanguageScorer.scoreMulti(.init(currentSourceId: curId, sources: srcs, readingsByID: readings, lex: lex, minLength: minL))
        } else {
            t = LanguageScorer.score(wordAsUS: wus, wordAsRU: wru, tisIsRussian: tisRU, lex: lex, minLength: minL)
        }
        if t.reasonCode == "ambi" || t.reasonCode == "ambi2" {
            if pendingAmbiguous.count < maxPendingAmbiguous {
                wordBoundariesAfterAmbiPending = 0
                deferredInterstitialWords.removeAll(keepingCapacity: false)
                pendingAmbiguous.append(PendingAmbiguousWord(
                    readingsByID: readings, currentSourceID: curId, displayed: t.asCurrentScript, alternateScript: t.asAlternateScript,
                    keyStrokes: lastWordSnapshot.map(\.strokes) ?? []
                ))
            }
            DispatchQueue.main.async { self.traceHandler(t) }
            return Unmanaged.passUnretained(cg)
        }
        if let rec = LanguageScorer.contextTagToRecord(t) {
            LanguageContextModel.shared.recordCompletedWord(resolvedTag: rec)
        }
        var pCopy = pendingAmbiguous
        var languageHint = LanguageScorer.inferredLanguageIntent(t, minWord: minL)
        if t.reasonCode == "hold_ru_ctx" {
            if Self.deferredEnOverrideWhenHoldRuCtx(pending: pCopy, readings: readings, t: t, sources: srcs, lex: lex) != nil {
                languageHint = "en"
                LaunchLog.append("EventTap: hold_ru_ctx → deferred en (ambi+текущее en-чтение)")
            } else {
                // Иначе «ru» из intent даёт мусор «рун+рщц»; отлож. вставку не делаем.
                languageHint = nil
            }
        }
        if !pCopy.isEmpty, deferredInterstitialWords.count > maxDeferredInterstitialWords {
            let d = DecisionTrace(
                asCurrentScript: t.asCurrentScript, asAlternateScript: t.asAlternateScript, tisWasRussian: tisRU,
                aInEn: t.aInEn, aInRu: t.aInRu, bInEn: t.bInEn, bInRu: t.bInRu, appliedReplacement: nil, didSwitchTIS: false,
                reasonCode: "stale_pending_dropped", reasonHuman: "Отлож. сегм. сброшены: слишком длинный хвост после ambi (длинная фраза) — backspace+вставка небезопасны.",
                switchToSourceID: nil, lexHitsSummary: t.lexHitsSummary, currentSourceID: curId
            )
            clearPending()
            pCopy = []
            DispatchQueue.main.async { self.traceHandler(d) }
        }
        if !pCopy.isEmpty, let preferLang = languageHint, t.reasonCode != "phrase_to_en" {
            // Без «раскладка уже en — не трогать» здесь: при to_en+U.S. очищали pending без
            // отложенной переписи; сегмент ambi2 (другой скрипт) оставался, дальше backspace+пусто.
            let prefixSeg = pCopy + deferredInterstitialWords
            let parts = prefixSeg.map { Self.targetForPending($0, preferLang: preferLang, lex: lex) }
            let currentPart = Self.currentWordTextForDeferred(
                preferLang: preferLang, readings: readings, currentId: curId, t: t, sources: srcs
            )
            let wordPieces = (parts + [currentPart]).filter { !$0.isEmpty }
            let allText = wordPieces.joined(separator: " ")
            let curDisp = Self.displayCurrentWord(readings: readings, currentId: curId)
            // Стираем по числу **нажатий** (и пробелов), а не по `displayed`+`curDisp`: иначе одна
            // и та же «полоса» (ambi-сегм. + «текущее») считалась дважды → backspace > текста, стирался весь абзац.
            let currentKeyCount = lastWordSnapshot.map { $0.strokes.count } ?? max(wus.count, wru.count, curDisp.count)
            let backspaceN = prefixSeg.reduce(0) { $0 + Self.deferredKeyCount($1) } + currentKeyCount + prefixSeg.count
            if allText.isEmpty, backspaceN > 0 {
                clearPending()
                LaunchLog.append("EventTap: deferred skipped (пустой allText) backspaceN=\(backspaceN)")
                return Unmanaged.passUnretained(cg)
            }
            var targetSid = Self.sourceId(forLang: preferLang) ?? curId
            let preferNTag = EnabledKeyboardSourcesRegistry.normalizeLangTag(preferLang)
            if preferNTag == "ru", !EnabledKeyboardSourcesRegistry.shared.isRussianSourceID(targetSid) {
                targetSid = self.input.resolve().ruID
                LaunchLog.append("EventTap: deferred targetSid — RU via resolve: \(targetSid) (тек. TIS/список без ru — иначе кирилл. печать с ABC даёт 0 букв)")
            }
            let boundaryVK = cg.vKey
            let nPrefixSegm = pCopy.count + deferredInterstitialWords.count
            let dRetro = DecisionTrace(
                asCurrentScript: t.asCurrentScript, asAlternateScript: t.asAlternateScript, tisWasRussian: tisRU,
                aInEn: t.aInEn, aInRu: t.aInRu, bInEn: t.bInEn, bInRu: t.bInRu,
                appliedReplacement: nil, didSwitchTIS: true,
                reasonCode: "deferred_resolved",
                reasonHuman: "Отложенно (только план, до CGEvent): \(nPrefixSegm) сегм. (ambi+хвост) → \(preferLang) по «\(t.asCurrentScript)» — вставка «\(allText)». Реальное применение: строка с reason **deferred_applied**; подробности — LanguageSwitcher/launch.log (дом. каталог / App Support).",
                switchToSourceID: targetSid, lexHitsSummary: t.lexHitsSummary, currentSourceID: curId
            )
            clearPending()
            DispatchQueue.main.async { self.traceHandler(t) }
            DispatchQueue.main.async { self.traceHandler(dRetro) }
            LaunchLog.append("EventTap: deferred \(nPrefixSegm) сегм. (ambi+межслов.) → \(preferLang) + «\(t.asCurrentScript)» backspaces=\(backspaceN) insertPlan=«\(allText)»")
            let preferN = EnabledKeyboardSourcesRegistry.normalizeLangTag(preferLang)
            runSyntheticOnTapThread {
                self.runWithTapSuspendedForSynthetic {
                    let beforeLayout = EnabledKeyboardSourcesRegistry.shared.liveCurrentInputSourceID()
                    SyntheticKeyboard.backspaces(backspaceN)
                    Thread.sleep(forTimeInterval: 0.012)
                    if targetSid != beforeLayout {
                        self.pushLayoutUndo(before: beforeLayout)
                    }
                    let reg = EnabledKeyboardSourcesRegistry.shared
                    let list = reg.enabledSources
                    if let ruSid = list.first(where: { reg.isRussianSourceID($0.sourceID) })?.sourceID,
                       let latSid = list.first(where: { !reg.isRussianSourceID($0.sourceID) })?.sourceID {
                        if preferN == "en", Self.isLatinLetterOrSpaceOnly(allText) {
                            _ = self.input.selectSource(id: latSid)
                            Thread.sleep(forTimeInterval: 0.01)
                            SyntheticKeyboard.type(allText, layoutSourceID: latSid)
                            LaunchLog.append("EventTap: deferred (fast) type «\(allText)» sid=\(latSid)")
                        } else {
                            var firstPiece = true
                            for piece in wordPieces where !piece.isEmpty {
                                if !firstPiece { SyntheticKeyboard.postSpace() }
                                firstPiece = false
                                let sid = Self.layoutSourceID(forScriptSegment: piece, ruId: ruSid, latId: latSid)
                                _ = self.input.selectSource(id: sid)
                                Thread.sleep(forTimeInterval: 0.006)
                                SyntheticKeyboard.type(piece, layoutSourceID: sid)
                            }
                        }
                        _ = self.input.selectSource(id: targetSid)
                    } else {
                        if preferN == "en", Self.isLatinLetterOrSpaceOnly(allText) {
                            Self.typeDeferredLatinWithResolvedUS(allText, input: self.input)
                        } else if preferN == "ru" {
                            // Не `selectSource(targetSid)+type(…, targetSid)`: при одной лат. раскл. в enabled `targetSid`=ABC → кирилл. в map нет, ввод пустой.
                            Self.typeDeferredCyrillicResolvingRU(allText, input: self.input)
                        } else {
                            _ = self.input.selectSource(id: targetSid)
                            Thread.sleep(forTimeInterval: 0.01)
                            SyntheticKeyboard.type(allText, layoutSourceID: targetSid)
                        }
                        _ = self.input.selectSource(id: targetSid)
                    }
                    SyntheticKeyboard.postBoundaryCorresponding(toVirtualKey: boundaryVK)
                    let liveAfter = EnabledKeyboardSourcesRegistry.shared.liveCurrentInputSourceID()
                    LaunchLog.append("EventTap: deferred HID end backspaceN=\(backspaceN) typedLen=\(allText.count) afterSid=\(liveAfter)")
                    let dApplied = DecisionTrace(
                        asCurrentScript: allText, asAlternateScript: "", tisWasRussian: preferN == "ru",
                        aInEn: preferN == "en", aInRu: preferN == "ru", bInEn: false, bInRu: false,
                        appliedReplacement: nil, didSwitchTIS: false,
                        reasonCode: "deferred_applied",
                        reasonHuman: "Отлож. вставка: сгенерированы и отправлены HID-события (backspace×\(backspaceN), ввод длины \(allText.count)). Текст в поле всё ещё «старый»? Часто: фокус в другом окне, IME/веб, или права/очередь событий — см. launch log (строка `deferred HID end`).",
                        switchToSourceID: targetSid, lexHitsSummary: t.lexHitsSummary, currentSourceID: liveAfter
                    )
                    DispatchQueue.main.async { self.traceHandler(dApplied) }
                }
            }
            return nil
        }
        if !pCopy.isEmpty, languageHint == nil {
            if t.reasonCode != "ambi" && t.reasonCode != "ambi2", hasAnyReading, !t.asCurrentScript.isEmpty {
                let w = PendingAmbiguousWord(
                    readingsByID: readings, currentSourceID: curId,
                    displayed: t.asCurrentScript, alternateScript: t.asAlternateScript,
                    keyStrokes: lastWordSnapshot.map(\.strokes) ?? []
                )
                deferredInterstitialWords.append(w)
                LaunchLog.append("EventTap: deferred interstitial +«\(w.displayed)» (n=\(deferredInterstitialWords.count))")
            }
            DispatchQueue.main.async { self.traceHandler(t) }
            return Unmanaged.passUnretained(cg)
        }
        let skipSameLang = Self.shouldSkipSwitchBecauseCurrentMatchesTarget(curId: curId, readings: readings, t: t)
        let traceForUI = skipSameLang ? t.skippingBecauseCurrentLayoutMatchesTarget() : t
        DispatchQueue.main.async { self.traceHandler(traceForUI) }
        if let g = t.appliedReplacement, t.didSwitchTIS, !g.isEmpty, !skipSameLang {
            let aScreen = Self.displayCurrentWord(readings: readings, currentId: curId)
            // `phrase_to_en`: в поле «рун рщц» — backspace по двум сегм.; иначе одно слово; после инкрем. TIS см. t.asCurrentScript.
            let deleteCount: Int
            if t.reasonCode == "phrase_to_en", let p0 = pendingAmbiguous.first {
                deleteCount = p0.displayed.count + 1 + wru.count
                clearPending()
            } else {
                deleteCount = max(t.asCurrentScript.count, aScreen.count)
            }
            let targetSid = t.switchToSourceID ?? Self.inferBinaryTargetId(from: t)
            let boundaryVK = cg.vKey
            let retypeNeeded = t.reasonCode == "phrase_to_en" || !Self.isSameLexicalForm(g, t.asCurrentScript)
            runSyntheticOnTapThread {
                self.runWithTapSuspendedForSynthetic {
                    let beforeLayout = EnabledKeyboardSourcesRegistry.shared.liveCurrentInputSourceID()
                    if retypeNeeded {
                        SyntheticKeyboard.backspaces(deleteCount)
                    }
                    // to_en / phrase_to_en: `selectSource(sid)` из short list даёт -1, если U.S. нет в кэше — TIS
                    // оставалась RU, ветка `else if to_en` не вызывалась. Сначала U.S. через `selectUS` (resolve+TIS).
                    if t.reasonCode == "to_en" {
                        let r = self.input.resolve()
                        if beforeLayout != r.usID {
                            self.pushLayoutUndo(before: beforeLayout)
                        }
                        _ = self.input.selectUS()
                    } else if t.reasonCode == "phrase_to_en" {
                        let r = self.input.resolve()
                        if (targetSid.map { $0 != beforeLayout } ?? true) && beforeLayout != r.usID {
                            self.pushLayoutUndo(before: beforeLayout)
                        }
                        if let s = targetSid, !EnabledKeyboardSourcesRegistry.shared.isRussianSourceID(s) {
                            let st = self.input.selectSource(id: s)
                            if st != 0 { _ = self.input.selectUS() }
                        } else {
                            _ = self.input.selectUS()
                        }
                    } else if let sid = targetSid {
                        if sid != beforeLayout {
                            self.pushLayoutUndo(before: beforeLayout)
                        }
                        _ = self.input.selectSource(id: sid)
                    } else if t.reasonCode == "to_ru" {
                        if let ru = Self.sourceId(forLang: "ru"), ru != beforeLayout {
                            self.pushLayoutUndo(before: beforeLayout)
                        }
                        _ = self.input.selectRussian()
                    }
                    if retypeNeeded {
                        var typeSid = targetSid
                            ?? (t.reasonCode == "to_ru" ? Self.sourceId(forLang: "ru") : Self.sourceId(forLang: "en"))
                            ?? EnabledKeyboardSourcesRegistry.shared.liveCurrentInputSourceID() // to_en, phrase_to_en → en
                        if t.reasonCode == "to_en" || t.reasonCode == "phrase_to_en" {
                            let r = self.input.resolve()
                            if Self.isLatinLetterOrSpaceOnly(g), EnabledKeyboardSourcesRegistry.shared.isRussianSourceID(typeSid) {
                                typeSid = r.usID
                            }
                        }
                        // Дать TIS/фокусу проглотить смену раскладки до HID-символов, иначе буквы могут пойти в старой раскладке.
                        Thread.sleep(forTimeInterval: 0.006)
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
        case "to_en", "phrase_to_en":
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
        if t.reasonCode == "phrase_to_en" { return "en" }
        if t.reasonCode.hasPrefix("to_") {
            let tail = String(t.reasonCode.dropFirst(3))
            if !tail.isEmpty { return EnabledKeyboardSourcesRegistry.normalizeLangTag(tail) }
        }
        return nil
    }

    /// Do not re-type / «skip» only when экранный текст уже совпадает с подстановкой **и** TIS у цели.
    /// Не сравнивать `rep` с `readings[curId]`: при инкрем. смене TIS U.S. там уже «make», в поле остаётся «ьфлу»; эталон — `t.asCurrentScript` (как в LanguageScorer).
    private static func shouldSkipSwitchBecauseCurrentMatchesTarget(curId: String, readings _: [String: String], t: DecisionTrace) -> Bool {
        guard t.didSwitchTIS, let rep = t.appliedReplacement, !rep.isEmpty else { return false }
        if !isSameLexicalForm(rep, t.asCurrentScript) { return false }
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
