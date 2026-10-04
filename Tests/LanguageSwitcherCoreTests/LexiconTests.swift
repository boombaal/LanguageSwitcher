import XCTest
@testable import LanguageSwitcherCore

final class LexiconTests: XCTestCase {
    private let lex = TestLexicon.bundled

    // MARK: Чистка списков

    func testSanitizerDropsNonWordsAndJunkShortEntries() {
        let ru = LexiconStore.sanitized(["еще", "ещ", "шт", "#1042", "abc", "я", "по-русски", "ёж", "ещё", "-а"], lang: "ru")
        XCTAssertEqual(ru, ["еще", "я", "по-русски", "ёж", "ещё"])
        let en = LexiconStore.sanitized(["the", "ir", "ti", "z", "a", "to", "don't", "e-mail", "x1", "привет", "'s"], lang: "en")
        XCTAssertEqual(en, ["the", "a", "to", "don't", "e-mail"])
    }

    func testSanitizerLeavesOtherLanguagesAlone() {
        let he: Set<String> = ["של", "x", "#"]
        XCTAssertEqual(LexiconStore.sanitized(he, lang: "he"), he)
    }

    func testShortWordWhitelistIsNormalisedAndShort() {
        for (lang, words) in LexiconStore.shortWordWhitelist {
            for w in words {
                XCTAssertLessThanOrEqual(w.count, 2, "\(lang): «\(w)»")
                XCTAssertEqual(w, w.lowercased().replacingOccurrences(of: "ё", with: "е"), "\(lang): «\(w)» должно быть в нормальной форме")
            }
        }
    }

    // MARK: Словари из репозитория

    func testBundledListsLoadAtFullSize() {
        XCTAssertGreaterThan(lex.words(for: "en").count, 9_000)
        XCTAssertGreaterThan(lex.words(for: "ru").count, 80_000)
    }

    func testJunkTwoLetterEntriesAreGone() {
        for w in ["ещ", "шт", "цу", "ше", "щк", "иу", "аа", "бб"] { XCTAssertFalse(lex.hasNormalizedWord("ru", w), "ru «\(w)»") }
        for w in ["ir", "ti", "ns", "z", "b", "aa", "yj", "yt"] { XCTAssertFalse(lex.hasNormalizedWord("en", w), "en «\(w)»") }
    }

    func testRealShortWordsSurvive() {
        for w in ["я", "и", "в", "не", "но", "он", "ты", "мы", "да", "то", "бы", "же", "её"] { XCTAssertTrue(lex.hasNormalizedWord("ru", w), "ru «\(w)»") }
        for w in ["a", "i", "to", "be", "or", "of", "in", "is", "it", "we", "my", "no", "ok"] { XCTAssertTrue(lex.hasNormalizedWord("en", w), "en «\(w)»") }
    }

    /// Частотный список лемм не содержал самых обычных форм — они дописаны в конец ru.txt.
    func testCommonRussianFormsArePresent() {
        let forms = """
        меня тебя ему мной нами моя мои твоя наша своя эти какая какие были буду будет будут хочу хочет можешь \
        знаю знает делаю сказал думаю видел всех всем вся одна еще ещё где как что это привет спасибо
        """.split(separator: " ").map(String.init)
        for w in forms { XCTAssertTrue(lex.hasNormalizedWord("ru", w), "ru «\(w)»") }
    }

    func testCommonEnglishWordsArePresent() {
        for w in ["the", "and", "not", "how", "are", "you", "can", "please", "file", "code", "hey", "there", "same"] {
            XCTAssertTrue(lex.hasNormalizedWord("en", w), "en «\(w)»")
        }
    }

    func testLookupIsCaseAndYoInsensitive() {
        XCTAssertTrue(lex.hasNormalizedWord("ru", "Ещё"))
        XCTAssertTrue(lex.hasNormalizedWord("ru", "ЕЩЕ"))
        XCTAssertTrue(lex.hasNormalizedWord("en", "The"))
        XCTAssertTrue(lex.hasNormalizedWord("en-US", "the"))
        XCTAssertFalse(lex.hasNormalizedWord("en", ""))
    }

    // MARK: Правдоподобие

    func testExactWordScoresOneAndGibberishScoresBelowThreshold() {
        LanguageContextModel.shared.reset()
        XCTAssertEqual(WordPlausibility.score01(word: "привет", lang: "ru", lex: lex), 1)
        XCTAssertEqual(WordPlausibility.score01(word: "file", lang: "en", lex: lex), 1)
        XCTAssertLessThan(WordPlausibility.score01(word: "рщц", lang: "ru", lex: lex), WordPlausibility.acceptThreshold)
        XCTAssertLessThan(WordPlausibility.score01(word: "ghbdtn", lang: "en", lex: lex), WordPlausibility.acceptThreshold)
    }

    func testInflectedRussianFormIsPlausibleViaMorphology() {
        LanguageContextModel.shared.reset()
        XCTAssertGreaterThanOrEqual(WordPlausibility.score01(word: "указывается", lang: "ru", lex: lex), WordPlausibility.acceptThreshold)
        XCTAssertGreaterThanOrEqual(WordPlausibility.score01(word: "сегменты", lang: "ru", lex: lex), WordPlausibility.acceptThreshold)
    }

    func testPrefixScoreGrowsWithRealPrefixAndIsZeroForNonsense() {
        let small = LexiconStore(words: ["en": ["total", "totally", "ultimate"]])
        XCTAssertGreaterThan(small.prefixScore01(lang: "en", prefix: "tot"), 0)
        XCTAssertEqual(small.prefixLexiconScore(lang: "en", prefix: "qzx"), 0)
        XCTAssertFalse(small.hasPrefixMatch(lang: "en", prefix: "qzx"))
        XCTAssertTrue(small.hasPrefixMatch(lang: "en", prefix: "ult"))
        XCTAssertFalse(small.hasNormalizedWord("en", "tot"))
    }
}
