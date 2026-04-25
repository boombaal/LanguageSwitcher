import Foundation

/// Penalizes unlikely letter sequences for a target language (lightweight, no full phonology).
enum ScriptHeuristics {
    /// Subtract from 0…1 plausibility scale (negative harm = bad for this language).
    static func clusterPenalty(text raw: String, lang: String) -> Double {
        let t = EnabledKeyboardSourcesRegistry.normalizeLangTag(lang)
        let s = raw.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        guard s.count >= 2 else { return 0 }
        if t == "en" { return enPenalty(s) }
        if t == "ru" { return ruPenalty(s) }
        return 0
    }

    /// 0…1 bonus when clusters fit the expected script.
    static func clusterFit(text: String, lang: String) -> Double {
        let t = EnabledKeyboardSourcesRegistry.normalizeLangTag(lang)
        if t == "en" { return isLatinString(text) && !hasCyrillic(text) ? 0.04 : 0 }
        if t == "ru" { return hasCyrillic(text) && !hasLatin(text) ? 0.04 : 0 }
        return 0
    }

    private static func isLatinString(_ s: String) -> Bool { s.range(of: #"[a-zA-Z]"#, options: .regularExpression) != nil }
    private static func hasCyrillic(_ s: String) -> Bool { s.range(of: #"[а-яёА-ЯЁ]"#, options: .regularExpression) != nil }
    private static func hasLatin(_ s: String) -> Bool { s.range(of: #"[a-zA-Z]"#, options: .regularExpression) != nil }

    private static let enCons = "bcdfghjklmnpqrstvwxz"

    // Long Latin consonant runs / wrong script.
    private static func enPenalty(_ s: String) -> Double {
        if hasCyrillic(s) { return 0.12 }
        var harm = 0.0
        let low = s.lowercased()
        if maxConsonantRun(low, alphabet: enCons) >= 5 { harm += 0.07 }
        if low.range(of: #"q[^u]"#, options: .regularExpression) != nil { harm += 0.05 }
        return min(0.2, harm)
    }

    private static func maxConsonantRun(_ s: String, alphabet: String) -> Int {
        var m = 0, cur = 0
        for ch in s {
            if alphabet.contains(ch) { cur += 1; m = max(m, cur) } else { cur = 0 }
        }
        return m
    }

    private static func ruPenalty(_ s: String) -> Double {
        if s.range(of: #"[a-zA-Z]{3,}"#, options: .regularExpression) != nil { return 0.1 }
        return 0
    }
}
