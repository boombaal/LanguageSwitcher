import AppKit
import CoreGraphics

/// Physical key → string for US and Russian (ЙЦУКЕН) on standard Apple layouts, same as macOS TIS.
enum KeyboardScript {
    case usQWERTY
    case ruJcuken
}

struct Keymap {

    typealias ChPair = (normal: String, shift: String)

    /// (normal, shift) for each kVK, both layouts.
    private static let table: [UInt16: (us: ChPair, ru: ChPair)] = {
        var m: [UInt16: (us: ChPair, ru: ChPair)] = [
            0:  (("a", "A"), ("ф", "Ф")),
            1:  (("s", "S"), ("ы", "Ы")),
            2:  (("d", "D"), ("в", "В")),
            3:  (("f", "F"), ("а", "А")),
            4:  (("h", "H"), ("р", "Р")),
            5:  (("g", "G"), ("п", "П")),
            6:  (("z", "Z"), ("я", "Я")),
            7:  (("x", "X"), ("ч", "Ч")),
            8:  (("c", "C"), ("с", "С")),
            9:  (("v", "V"), ("м", "М")),
            11: (("b", "B"), ("и", "И")),
            12: (("q", "Q"), ("й", "Й")),
            13: (("w", "W"), ("ц", "Ц")),
            14: (("e", "E"), ("у", "У")),
            15: (("r", "R"), ("к", "К")),
            16: (("y", "Y"), ("н", "Н")),
            17: (("t", "T"), ("е", "Е")),
            0x1F: (("o", "O"), ("щ", "Щ")),
            0x20: (("u", "U"), ("г", "Г")),
            0x21: (("[", "{"), ("х", "Х")),
            0x1E: (("]", "}"), ("ъ", "Ъ")),
            0x22: (("i", "I"), ("ш", "Ш")),
            0x23: (("p", "P"), ("з", "З")),
            0x25: (("l", "L"), ("д", "Д")),
            0x26: (("j", "J"), ("о", "О")),
            0x27: (("'", "\""), ("э", "Э")),
            0x28: (("k", "K"), ("л", "Л")),
            0x29: ((";", ":"), ("ж", "Ж")),
            0x2A: (("\\", "|"), ("/", "?")),
            0x2B: ((",", "<"), ("б", "Б")),
            0x2C: (("/", "?"), (".", ",")),
            0x2D: (("n", "N"), ("т", "Т")),
            0x2E: (("m", "M"), ("ь", "Ь")),
            0x2F: ((".", ">"), ("ю", "Ю")),
        ]
        // Digits
        m[0x12] = (("1", "!"), ("1", "!"))
        m[0x13] = (("2", "@"), ("2", "\""))
        m[0x14] = (("3", "#"), ("3", "№"))
        m[0x15] = (("4", "$"), ("4", "%"))
        m[0x16] = (("6", "^"), ("6", ":"))
        m[0x17] = (("5", "%"), ("5", ":"))
        m[0x18] = (("=", "+"), ("=", "+"))
        m[0x19] = (("9", "("), ("9", "("))
        m[0x1A] = (("7", "&"), ("7", "."))
        m[0x1B] = (("-", "_"), ("-", "_"))
        m[0x1C] = (("8", "*"), ("8", ","))
        m[0x1D] = (("0", ")"), ("0", ")"))
        m[0x32] = (("`", "~"), ("ё", "Ё"))
        return m
    }()

    static func charPair(key: UInt16, shift: Bool, script: KeyboardScript) -> String? {
        guard let p = table[key] else { return nil }
        let c = (script == .usQWERTY) ? p.us : p.ru
        return shift ? c.shift : c.normal
    }

    static func string(from keys: [(key: UInt16, shift: Bool)], as script: KeyboardScript) -> String {
        var s = ""
        for e in keys {
            if let ch = charPair(key: e.key, shift: e.shift, script: script) { s += ch }
        }
        return s
    }

    static func firstKeycode(for s: String, in script: KeyboardScript) -> (key: UInt16, shift: Bool)? {
        for (k, p) in table {
            let a = (script == .usQWERTY) ? p.us : p.ru
            if a.normal == s { return (k, false) }
            if a.shift == s { return (k, true) }
        }
        return nil
    }

    static func firstKeycode(for ch: Character, in script: KeyboardScript) -> (key: UInt16, shift: Bool)? {
        firstKeycode(for: String(ch), in: script)
    }

    static func keySequence(for text: String, script: KeyboardScript) -> [(key: UInt16, shift: Bool)]? {
        var out: [(UInt16, Bool)] = []
        for ch in text {
            if let t = firstKeycode(for: ch, in: script) {
                out.append(t)
            } else { return nil }
        }
        return out
    }

    /// First mapping per character (for synthetic typing / reverse lookup).
    static func reverseLookupTable(for script: KeyboardScript) -> [Character: (key: UInt16, shift: Bool)] {
        var m: [Character: (UInt16, Bool)] = [:]
        for vk: UInt16 in 0..<128 {
            for sh in [false, true] {
                guard let pair = charPair(key: vk, shift: sh, script: script), let c = pair.first else { continue }
                if c.isLetter || c.isNumber || "-_'".contains(c) {
                    if m[c] == nil { m[c] = (vk, sh) }
                }
            }
        }
        return m
    }
}
