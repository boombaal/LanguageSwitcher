import AppKit
import Foundation

/// Maps key strokes to strings per TIS source id. Uses bundle [`Keymap`](LanguageSwitcher/Keymap.swift) for US/RU physical layouts; other sources fall back to US unless ID suggests Russian.
/// (Full `UCKeyTranslate` per `kTISPropertyUnicodeKeyLayoutData` can be layered in later for arbitrary scripts.)
final class KeyStrokesTranslator {
    static let shared = KeyStrokesTranslator()

    private let cacheLock = NSLock()
    private var reverseMapBySourceID: [String: [Character: (vk: UInt16, shift: Bool)]] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            forName: .keyboardSourcesRegistryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearCaches()
        }
    }

    func clearCaches() {
        cacheLock.lock()
        reverseMapBySourceID.removeAll()
        cacheLock.unlock()
    }

    func string(from strokes: [(key: UInt16, shift: Bool)], sourceID: String, capsLock: Bool) -> String {
        _ = capsLock
        let script = scriptForSourceID(sourceID)
        return Keymap.string(from: strokes, as: script)
    }

    func reverseCharMap(for sourceID: String) -> [Character: (vk: UInt16, shift: Bool)] {
        cacheLock.lock()
        if let m = reverseMapBySourceID[sourceID] {
            cacheLock.unlock()
            return m
        }
        cacheLock.unlock()
        let script = scriptForSourceID(sourceID)
        let m = Keymap.reverseLookupTable(for: script).mapValues { ($0.key, $0.shift) }
        cacheLock.lock()
        reverseMapBySourceID[sourceID] = m
        cacheLock.unlock()
        return m
    }

    private func scriptForSourceID(_ sourceID: String) -> KeyboardScript {
        EnabledKeyboardSourcesRegistry.shared.isRussianSourceID(sourceID) ? .ruJcuken : .usQWERTY
    }
}
