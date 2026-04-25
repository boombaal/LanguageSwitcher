import Foundation

/// Ранний сигнал до конца слова: биграммы/триграммы и «невозможные» пары; без словаря, без fuzzy.
enum IncrementalNgramScoring {
    /// 0…1, выше = префикс больше похож на типичное написание в языке.
    static func ngramPlaus01(prefix: String, lang: String) -> Double {
        let t = EnabledKeyboardSourcesRegistry.normalizeLangTag(lang)
        let s = prefix.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        guard s.count >= 1 else { return 0.4 }
        if t == "en" { return en01(s) }
        if t == "ru" { return ru01(s) }
        return 0.5
    }

    private static func en01(_ s: String) -> Double {
        var p = 0.72
        if s.count >= 2, let w = twoSuffix(s) {
            if enBad2.contains(w) { p -= 0.58 }
        }
        if s.count >= 3, let t3 = threeSuffix(s) {
            if enBad3.contains(t3) { p -= 0.32 }
        }
        if s.range(of: #"[0-9]"#, options: .regularExpression) != nil { p += 0.04 }
        if s.range(of: #"[a-z]{2,}"#, options: .regularExpression) == nil, s.count > 0 { p -= 0.1 }
        return min(1, max(0.08, p + tailCharBonus(s, ru: false)))
    }

    private static func ru01(_ s: String) -> Double {
        var p = 0.7
        if s.count >= 2, let w = twoSuffix(s) {
            if ruBad2.contains(w) { p -= 0.62 }
        }
        if s.count >= 3, let t3 = threeSuffix(s) {
            if ruBad3.contains(t3) { p -= 0.35 }
        }
        if s.range(of: #"[0-9]"#, options: .regularExpression) != nil { p += 0.04 }
        if s.range(of: #"[а-яё]{2,}"#, options: .regularExpression) == nil, s.count > 1 { p -= 0.08 }
        return min(1, max(0.08, p + tailCharBonus(s, ru: true)))
    }

    private static func twoSuffix(_ s: String) -> String? {
        let n = s.count
        guard n >= 2 else { return nil }
        let i = s.index(s.endIndex, offsetBy: -2)
        return String(s[i..<s.endIndex])
    }

    private static func threeSuffix(_ s: String) -> String? {
        let n = s.count
        guard n >= 3 else { return nil }
        let i = s.index(s.endIndex, offsetBy: -3)
        return String(s[i..<s.endIndex])
    }

    /// Лёгкий бонус за букву, частую в конце.
    private static func tailCharBonus(_ s: String, ru: Bool) -> Double {
        guard let last = s.last else { return 0 }
        if ru { return "аоиеёуыэюяйь".contains(last) ? 0.04 : 0 }
        if last.isLetter, !"qjxz".contains(last) { return 0.02 }
        return 0
    }

    /// Pairs with «q» кроме «qu» — всегда подозрительны в EN.
    private static let enBad2: Set<String> = [
        "qq", "qz", "qx", "qj", "qk", "qs", "qd", "qc", "qb", "qh", "qf", "qg", "qv",
        "wq", "fq", "jq", "kq", "zq", "cq", "pq", "vq", "mx", "zx", "xz", "xx", "bx",
    ]

    private static let enBad3: Set<String> = Set([
        "qqq", "qwq", "qxq", "qxz", "zqx", "qqj", "xqx",
    ])

    private static let ruBad2: Set<String> = [
        "жы", "шы", "чы", "щы", "ыы", "ьь", "ъъ", "уь", "аь", "оь", "еь", "иь", "оы", "аы", "оэ",
    ]

    private static let ruBad3: Set<String> = Set([
        "ыыы", "ььь", "ъыь",
    ])
}
