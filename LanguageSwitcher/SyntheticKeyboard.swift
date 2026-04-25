import AppKit
import CoreGraphics
import CoreFoundation

/// Posts HID key events. Requires Accessibility to affect other applications reliably.
enum SyntheticKeyboard {

    private static let kBackspace: CGKeyCode = 0x33 // 51
    private static let kSpace: CGKeyCode = 0x31
    private static let kReturn: CGKeyCode = 0x24
    private static let kTab: CGKeyCode = 0x30

    private static func postKey(_ v: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: v, keyDown: down) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private static func click(_ v: CGKeyCode, _ shift: Bool) {
        var f: CGEventFlags = []
        if shift { f = .maskShift }
        postKey(v, down: true, flags: f)
        postKey(v, down: false, flags: f)
    }

    static func backspaces(_ n: Int) {
        for _ in 0..<n { click(kBackspace, false) }
    }

    static func type(_ text: String, script: KeyboardScript) {
        for ch in text {
            switch ch {
            case " ": postSpace()
            case "\n", "\r": postReturn()
            case "\t": postTab()
            default:
                guard let (k, sh) = Keymap.firstKeycode(for: ch, in: script) else { continue }
                click(k, sh)
            }
        }
    }

    /// Types using Unicode layout reverse map for the given TIS source id (falls back to Keymap US/RU).
    static func type(_ text: String, layoutSourceID: String) {
        let map = KeyStrokesTranslator.shared.reverseCharMap(for: layoutSourceID)
        for ch in text {
            switch ch {
            case " ": postSpace()
            case "\n", "\r": postReturn()
            case "\t": postTab()
            default:
                guard let (k, sh) = map[ch].map({ ($0.vk, $0.shift) }) ?? fallbackKeymapChar(ch, sourceID: layoutSourceID) else { continue }
                click(k, sh)
            }
        }
    }

    private static func fallbackKeymapChar(_ ch: Character, sourceID: String) -> (CGKeyCode, Bool)? {
        let ru = EnabledKeyboardSourcesRegistry.shared.isRussianSourceID(sourceID)
        let sc: KeyboardScript = ru ? .ruJcuken : .usQWERTY
        return Keymap.firstKeycode(for: ch, in: sc).map { (CGKeyCode($0.key), $0.shift) }
    }

    /// Reliable boundary delivery after synthetic word (Space / Return / Tab).
    static func postBoundaryCorresponding(toVirtualKey vKey: UInt16) {
        switch vKey {
        case 0x31: postSpace()
        case 0x24: postReturn()
        case 0x30: postTab()
        default: break
        }
    }

    static func postSpace() { click(kSpace, false) }
    static func postReturn() { click(kReturn, false) }
    static func postTab() { click(kTab, false) }

    static func rePostKeyPress(cloning n: NSEvent, characters: String) {
        rePostKeyPress(keyCode: n.keyCode, modifierFlags: n.modifierFlags, characters: characters)
    }

    static func rePostKeyPress(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, characters: String) {
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(
                with: t, location: .zero,
                modifierFlags: modifierFlags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            )?.cgEvent { e.post(tap: .cghidEventTap) }
        }
    }
}
