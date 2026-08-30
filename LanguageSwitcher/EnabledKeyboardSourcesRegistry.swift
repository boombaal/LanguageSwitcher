import AppKit
import Carbon
import CoreFoundation
import Foundation

/// One user-selectable keyboard input source (TIS).
struct KeyboardSourceEntry: Equatable, Hashable {
    /// `kTISPropertyInputSourceID`
    var sourceID: String
    /// Normalized BCP-47 prefix, e.g. `en`, `ru`, `he`
    var primaryLang: String
    /// Raw `kTISPropertyInputSourceLanguages`
    var languages: [String]
    /// From `kTISPropertyInputSourceASCIICapable`
    var asciiCapable: Bool
}

/// Snapshot of enabled keyboard layouts + current TIS; refreshes on launch and on TIS notifications.
final class EnabledKeyboardSourcesRegistry {
    static let shared = EnabledKeyboardSourcesRegistry()

    private let lock = NSLock()
    private var entries: [KeyboardSourceEntry] = []
    private var currentSourceID: String = ""
    private var notificationObserver: Any?

    private init() {}

    /// Ordered list (stable order from TIS).
    var enabledSources: [KeyboardSourceEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    var currentInputSourceID: String {
        lock.lock()
        defer { lock.unlock() }
        return currentSourceID
    }

    /// Distinct primary language tags present in enabled sources (for lexicon download).
    var enabledLangTags: [String] {
        let langs = enabledSources.map(\.primaryLang)
        var seen = Set<String>()
        var out: [String] = []
        for l in langs where !l.isEmpty {
            if seen.insert(l).inserted { out.append(l) }
        }
        return out
    }

    func langTag(forSourceID id: String) -> String? {
        enabledSources.first { $0.sourceID == id }?.primaryLang
    }

    func isRussianSourceID(_ id: String) -> Bool {
        id.lowercased().contains("russian") || langTag(forSourceID: id) == "ru"
    }

    func refreshFromSystem() {
        let list = Self.querySelectableKeyboardSources()
        let cur = Self.currentKeyboardSourceID()
        lock.lock()
        if !list.isEmpty {
            entries = list
        } else {
            // TIS нередко кратковременно отдаёт пустой список при смене раскладки; не затираем кэш.
            if entries.isEmpty, let u = TISCreateASCIICapableInputSourceList() {
                let fallback = u.takeRetainedValue() as! [TISInputSource]
                let mapped = Self.entriesFromTISList(fallback)
                if !mapped.isEmpty { entries = mapped }
            }
        }
        currentSourceID = cur
        let n = entries.count
        lock.unlock()
        LaunchLog.append("KeyboardRegistry: \(n) sources (TIS list query \(list.count)), current=\(cur)")
    }

    private static func entriesFromTISList(_ arr: [TISInputSource]) -> [KeyboardSourceEntry] {
        arr.map { s in
            let langs = stringArrayProperty(s, kTISPropertyInputSourceLanguages)
            let primary = normalizeLangTag(langs.first ?? "")
            return KeyboardSourceEntry(
                sourceID: id(s), primaryLang: primary, languages: langs,
                asciiCapable: boolProperty(s, kPropAsciiCapable)
            )
        }
    }

    /// Updates only `currentInputSourceID` from `TISCopyCurrentKeyboardInputSource` (cheap).
    /// Call on word boundary: the distributed notification refreshes the cache asynchronously, so it can lag behind the real TIS by one run-loop turn.
    func syncCurrentInputSourceFromSystem() {
        let cur = Self.currentKeyboardSourceID()
        lock.lock()
        currentSourceID = cur
        lock.unlock()
    }

    /// Live id without relying on the last notification-driven refresh.
    func liveCurrentInputSourceID() -> String { Self.currentKeyboardSourceID() }

    func startMonitoring() {
        refreshFromSystem()
        if notificationObserver != nil { return }
        let center = CFNotificationCenterGetDistributedCenter()
        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<EnabledKeyboardSourcesRegistry>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    me.refreshFromSystem()
                    NotificationCenter.default.post(name: .keyboardSourcesRegistryDidChange, object: me)
                }
            },
            kTISNotifySelectedKeyboardInputSourceChanged, nil, .deliverImmediately
        )
        notificationObserver = true
        LaunchLog.append("KeyboardRegistry: observing kTISNotifySelectedKeyboardInputSourceChanged")
    }

    func stopMonitoring() {
        guard notificationObserver != nil else { return }
        let tisName = CFNotificationName(rawValue: kTISNotifySelectedKeyboardInputSourceChanged)
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            tisName,
            nil
        )
        notificationObserver = nil
    }

    /// Resolve `TISInputSource` for `sourceID` from a fresh selectable list (not retained long-term).
    func tisInputSource(for sourceID: String) -> TISInputSource? {
        for s in Self.querySelectableKeyboardSourcesRaw() {
            if Self.id(s) == sourceID { return s }
        }
        return nil
    }

    // MARK: - TIS helpers

    private static func id(_ s: TISInputSource) -> String {
        stringProperty(s, kTISPropertyInputSourceID)
    }

    private static func stringProperty(_ s: TISInputSource, _ key: CFString) -> String {
        guard let ptr = TISGetInputSourceProperty(s, key) else { return "" }
        let any = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(ptr)).takeUnretainedValue()
        if let str = any as? String { return str }
        return (any as! CFString) as String
    }

    private static func boolProperty(_ s: TISInputSource, _ key: CFString) -> Bool {
        guard let ptr = TISGetInputSourceProperty(s, key) else { return false }
        let any = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(ptr)).takeUnretainedValue()
        if let b = any as? Bool { return b }
        if CFGetTypeID(any) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((any as! CFBoolean))
        }
        return false
    }

    private static func stringArrayProperty(_ s: TISInputSource, _ key: CFString) -> [String] {
        guard let ptr = TISGetInputSourceProperty(s, key) else { return [] }
        let any = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(ptr)).takeUnretainedValue()
        if let a = any as? [String] { return a }
        if let nsa = any as? NSArray { return nsa.compactMap { $0 as? String } }
        return []
    }

    private static func currentKeyboardSourceID() -> String {
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "" }
        return id(cur)
    }

    /// Property keys as documented for `TISCreateInputSourceList` (Swift may not expose all `kTIS*` constants).
    private static let kPropIsSelect = "TISInputSourceIsSelect" as CFString
    private static let kPropAsciiCapable = "TISInputSourceASCIICapable" as CFString

    private static func querySelectableKeyboardSourcesRaw() -> [TISInputSource] {
        let dict: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!,
            kPropIsSelect: kCFBooleanTrue!,
        ]
        guard let arr = TISCreateInputSourceList(dict as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return arr
    }

    private static func querySelectableKeyboardSources() -> [KeyboardSourceEntry] {
        querySelectableKeyboardSourcesRaw().map { s in
            let langs = stringArrayProperty(s, kTISPropertyInputSourceLanguages)
            let primary = normalizeLangTag(langs.first ?? "")
            let ascii = boolProperty(s, kPropAsciiCapable)
            return KeyboardSourceEntry(
                sourceID: id(s),
                primaryLang: primary,
                languages: langs,
                asciiCapable: ascii
            )
        }
    }

    /// `en-US` -> `en`, `ru` -> `ru`
    static func normalizeLangTag(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return "" }
        if let dash = t.firstIndex(of: "-") {
            return String(t[..<dash])
        }
        return t
    }
}

extension Notification.Name {
    static let keyboardSourcesRegistryDidChange = Notification.Name("LanguageSwitcher.keyboardSourcesRegistryDidChange")
}
