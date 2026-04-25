import AppKit
import Foundation

enum FuzzyLexiconMatch {
    /// 0…1, for merging with `prefixLexiconScore`. Weaker than a lexicon hit; 0 if fuzzy disabled / too short.
    static func plausibility01(word: String, langTag: String) -> Double {
        guard AppSettings.shared.fuzzySpellEnabled else { return 0 }
        let minC = max(2, AppSettings.shared.fuzzyMinWordLength - 1)
        guard word.count >= minC else { return 0 }
        let L = EnabledKeyboardSourcesRegistry.normalizeLangTag(langTag)
        let language = (L == "ru") ? "ru" : "en"
        return spellOK(word, langCode: language) ? 0.75 : 0
    }

    static func fuzzySpellAccepts(word: String, langTag: String) -> Bool {
        guard AppSettings.shared.fuzzySpellEnabled else { return false }
        guard word.count >= AppSettings.shared.fuzzyMinWordLength else { return false }
        let L = EnabledKeyboardSourcesRegistry.normalizeLangTag(langTag)
        let language = (L == "ru") ? "ru" : "en"
        return spellOK(word, langCode: language)
    }

    private static func spellOK(_ word: String, langCode: String) -> Bool {
        guard !word.isEmpty else { return false }
        let sc = NSSpellChecker.shared
        var wordCount = 0
        let r = sc.checkSpelling(
            of: word,
            startingAt: 0,
            language: langCode,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: &wordCount
        )
        return r.location == NSNotFound
    }
}
