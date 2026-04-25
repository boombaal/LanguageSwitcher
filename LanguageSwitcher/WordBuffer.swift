import AppKit
import CoreGraphics

struct WordKeyStroke {
    var key: UInt16
    var shift: Bool
}

struct WordBuffer {
    var strokes: [WordKeyStroke] = []
    /// HID keycode + shift for translators.
    var keyStrokes: [(key: UInt16, shift: Bool)] { strokes.map { ($0.key, $0.shift) } }
    mutating func append(key: UInt16, shift: Bool) { strokes.append(WordKeyStroke(key: key, shift: shift)) }
    mutating func clear() { strokes = [] }
    mutating func popLast() { if !strokes.isEmpty { strokes.removeLast() } }
    var isEmpty: Bool { strokes.isEmpty }
    func stringAsUS() -> String { Keymap.string(from: strokes.map { (key: $0.key, shift: $0.shift) }, as: .usQWERTY) }
    func stringAsRU() -> String { Keymap.string(from: strokes.map { (key: $0.key, shift: $0.shift) }, as: .ruJcuken) }
    var lengthInChars: Int { max(stringAsUS().count, stringAsRU().count) } // for same key seq should match
}
