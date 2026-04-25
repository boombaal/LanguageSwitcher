import Foundation

/// Скоринг **пары** слов: Σ word + transition. Раздельно амбивалентные «рун» / «рщц» вместе могут дать сильный en («hey how») и слабый ru.
enum PhraseLevelScoring {
    private static let wWord1: Double = 0.40
    private static let wWord2: Double = 0.40
    private static let wTrans: Double = 0.20

    /// 0…1: phraseScore = w1*score(w1) + w2*score(w2) + wTrans*transition
    static func pairPhrasePlaus01(p1: String, p2: String, lang: String, lex: LexiconStore) -> Double {
        let t = EnabledKeyboardSourcesRegistry.normalizeLangTag(lang)
        guard t == "en" || t == "ru" else { return 0.45 }
        let s1 = WordPlausibility.score01(word: p1, lang: t, lex: lex)
        let s2 = WordPlausibility.score01(word: p2, lang: t, lex: lex)
        let tr: Double
        if t == "en" { tr = transitionEn01(p1, p2) } else { tr = transitionRu01(p1, p2) }
        return min(1, max(0, wWord1 * s1 + wWord2 * s2 + wTrans * tr))
    }

    // MARK: - EN: «how» после «hey» и др. — высоко; нейтрально — средне.

    private static let goodEnPairs: Set<String> = [
        "hey|how", "how|are", "are|you", "you|doing", "what|is", "how|is", "how|do", "i|am", "i|m",
        "do|you", "can|i", "thank|you", "can|we", "are|we", "it|is", "is|it", "to|be", "not|a",
    ]

    private static func key(_ a: String, _ b: String) -> String {
        let u = a.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        let v = b.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        return u + "|" + v
    }

    private static func transitionEn01(_ p: String, _ n: String) -> Double {
        if p.isEmpty || n.isEmpty { return 0.38 }
        if goodEnPairs.contains(key(p, n)) { return 0.94 }
        return 0.50
    }

    // MARK: - RU: сочетания вроде «рун»+«рщц» (мискорд под en-фразу) — низко.

    private static let ruJunkDigraphs: Set<String> = [
        "нр", "рщ", "рц", "щц", "цф", "нщ", "дл", "гв", "рш", "шп",
    ]

    private static func transitionRu01(_ p: String, _ n: String) -> Double {
        if p.isEmpty || n.isEmpty { return 0.40 }
        let la = p.last, fb = n.first
        if let a = la, let b = fb {
            let e = String([a, b])
            if ruJunkDigraphs.contains(e) { return 0.11 }
        }
        if n.hasPrefix("рщ") || n.hasPrefix("рц") { return 0.14 }
        if p.hasSuffix("н"), n.hasPrefix("р") { return 0.16 }
        return 0.48
    }
}
