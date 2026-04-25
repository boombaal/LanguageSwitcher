import Foundation

struct PlausibilityKeyMeta { var isBackspace: Bool = false }

enum WordPlausibility {
    static let incrementalSwitchMargin: Double = 0.08
    static let relativeDropForSignal: Double = 0.28
    static let fuzzyWeightStreaming: Double = 1.2
    static let fuzzyWeightWord: Double = 1.0
    static let acceptThreshold: Double = 0.45
    static let binaryAmbiguityMargin: Double = 0.04

    private static let ctx = LanguageContextModel.shared

    static func score01(word: String, lang: String, lex: LexiconStore) -> Double {
        rawWordScore(word: word, lang: lang, lex: lex, stream: false, meta: nil)
    }

    static func streaming01(text: String, lang: String, lex: LexiconStore, meta: PlausibilityKeyMeta? = nil) -> Double {
        rawWordScore(word: text, lang: lang, lex: lex, stream: true, meta: meta)
    }

    static func disambiguationWord01(_ word: String, lang: String, lex: LexiconStore) -> Double {
        min(1, score01(word: word, lang: lang, lex: lex) + 0.45 * ctx.totalAmbiguityPrior(for: lang))
    }

    private static func rawWordScore(word: String, lang: String, lex: LexiconStore, stream: Bool, meta: PlausibilityKeyMeta?) -> Double {
        if word.isEmpty { return 0 }
        let tag = EnabledKeyboardSourcesRegistry.normalizeLangTag(lang)
        if lex.hasNormalizedWord(tag, word) { return 1 }
        var p = prefixLex01(word, lang: tag, lex: lex)
        let fW: Double = stream ? fuzzyWeightStreaming : fuzzyWeightWord
        var f = FuzzyLexiconMatch.plausibility01(word: word, langTag: tag) * fW * 0.35
        if stream, meta?.isBackspace == true { f *= 0.9 }
        var raw = p + f
        raw += ScriptHeuristics.clusterFit(text: word, lang: tag)
        raw -= ScriptHeuristics.clusterPenalty(text: word, lang: tag)
        let sm = 0.55 * ctx.contextRecencyBoost(for: tag) + 0.35 * ctx.personalStyleBoost(for: tag) + 0.45 * ctx.systemUIScoreBoost(for: tag)
        raw += sm
        if p < 0.045 {
            let deg = ctx.ngramDegradedPlaus01(for: tag) + 0.12 * ctx.bigramConditional01(for: tag)
            raw = max(raw, deg * 0.9 + p * 0.5)
        }
        if stream { raw = min(1, raw + ctx.consumePausePlausibilityBoost()) }
        return min(1, max(0, raw))
    }

    private static func prefixLex01(_ s: String, lang tag: String, lex: LexiconStore) -> Double {
        let scale = max(0.1, LexiconStore.prefixScoreUpperBound)
        return min(1, lex.prefixLexiconScore(lang: tag, prefix: s) / scale)
    }
}
