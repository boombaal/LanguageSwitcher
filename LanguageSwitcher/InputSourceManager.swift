import AppKit
import Carbon
import Foundation

struct InputSourceIDResult {
    let usABC: TISInputSource?
    let russian: TISInputSource?
    let usID: String
    let ruID: String
    let usFound: Bool
    let ruFound: Bool
}

/// U.S. QWERTY (ABC) vs Russian via TIS.
final class InputSourceManager {
    static let shared = InputSourceManager()
    private init() {}

    var current: TISInputSource? { TISCopyCurrentKeyboardInputSource().map { $0.takeRetainedValue() } }

    private static func id(_ s: TISInputSource) -> String {
        stringProperty(s, kTISPropertyInputSourceID)
    }

    private static func stringProperty(_ s: TISInputSource, _ key: CFString) -> String {
        guard let ptr = TISGetInputSourceProperty(s, key) else { return "" }
        let any = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(ptr)).takeUnretainedValue()
        if let str = any as? String { return str }
        return (any as! CFString) as String
    }

    private static func stringArrayProperty(_ s: TISInputSource, _ key: CFString) -> [String] {
        guard let ptr = TISGetInputSourceProperty(s, key) else { return [] }
        let any = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(ptr)).takeUnretainedValue()
        if let a = any as? [String] { return a }
        if let nsa = any as? NSArray { return nsa.compactMap { $0 as? String } }
        return []
    }

    static func isRussian(_ src: TISInputSource) -> Bool {
        id(src).lowercased().contains("russian")
    }

    static func isLatinUS(_ src: TISInputSource) -> Bool {
        let i = id(src).lowercased()
        if i == "com.apple.keylayout.abc" { return true }
        if i.contains("abc") && !i.contains("russian") { return true }
        let langs = stringArrayProperty(src, kTISPropertyInputSourceLanguages)
        return langs.contains { $0.hasPrefix("en") } && !i.contains("russian")
    }

    private static func listAllKeyboardSources() -> [TISInputSource] {
        guard let u = TISCreateASCIICapableInputSourceList() else { return [] }
        // CFArray of TISInputSource refs; CoreFoundation +1 is consumed by takeRetainedValue.
        return u.takeRetainedValue() as! [TISInputSource]
    }

    /// Primary: `TISCopyInputSourceForLanguage`, then overrides; fall back to scanning ASCII list.
    func resolve() -> InputSourceIDResult {
        let oen = AppSettings.shared.tisOverrideEN
        let oru = AppSettings.shared.tisOverrideRU
        var us: TISInputSource?
        var ru: TISInputSource?
        if let oen, let f = findByID(oen) { us = f }
        if let oru, let f = findByID(oru) { ru = f }
        if us == nil { us = TISCopyInputSourceForLanguage("en" as CFString).map { $0.takeRetainedValue() } }
        if us == nil { us = TISCopyInputSourceForLanguage("en-US" as CFString).map { $0.takeRetainedValue() } }
        if ru == nil { ru = TISCopyInputSourceForLanguage("ru" as CFString).map { $0.takeRetainedValue() } }
        if us == nil || ru == nil {
            for s in Self.listAllKeyboardSources() {
                if us == nil, Self.isLatinUS(s) { us = s }
                if ru == nil, Self.isRussian(s) { ru = s }
            }
        }
        let usID = us.map { Self.id($0) } ?? (oen ?? "com.apple.keylayout.ABC")
        let ruID = ru.map { Self.id($0) } ?? (oru ?? "com.apple.keylayout.Russian")
        return .init(
            usABC: us,
            russian: ru,
            usID: usID,
            ruID: ruID,
            usFound: us != nil,
            ruFound: ru != nil
        )
    }

    private func findByID(_ id: String) -> TISInputSource? {
        for s in Self.listAllKeyboardSources() {
            if Self.id(s) == id { return s }
        }
        return nil
    }

    func isCurrentlyRussian() -> Bool { current.map { InputSourceManager.isRussian($0) } ?? false }

    @discardableResult
    func selectUS() -> OSStatus { select(using: resolve().usABC, fallbackId: resolve().usID) }

    @discardableResult
    func selectRussian() -> OSStatus { select(using: resolve().russian, fallbackId: resolve().ruID) }

    /// Select by bundle / TIS id from the current selectable-keyboard list.
    @discardableResult
    func selectSource(id: String) -> OSStatus {
        if let s = EnabledKeyboardSourcesRegistry.shared.tisInputSource(for: id) {
            return TISSelectInputSource(s)
        }
        return -1
    }

    @discardableResult
    private func select(using src: TISInputSource?, fallbackId: String) -> OSStatus {
        if let s = src, !InputSourceManager.id(s).isEmpty { return TISSelectInputSource(s) }
        if let s = findByID(fallbackId) { return TISSelectInputSource(s) }
        return -1
    }
}
