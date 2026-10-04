import XCTest
@testable import LanguageSwitcherCore

/// Решение по одному слову на границе: те же клавиши в двух чтениях (US / RU) + текущая раскладка.
final class LanguageScorerTests: XCTestCase {
    private let lex = TestLexicon.bundled

    override func setUp() {
        super.setUp()
        LanguageContextModel.shared.reset()
    }

    private func code(us: String, ru: String, tisRU: Bool) -> String {
        LanguageScorer.score(wordAsUS: us, wordAsRU: ru, tisIsRussian: tisRU, lex: lex, minLength: 3).reasonCode
    }

    // MARK: Обычный набор в «своей» раскладке не трогаем

    func testRussianWordUnderRussianLayoutIsLeftAlone() {
        XCTAssertEqual(code(us: "ghbdtn", ru: "привет", tisRU: true), "ok_ru")
        XCTAssertEqual(code(us: "rfr", ru: "как", tisRU: true), "ok_ru")
    }

    func testEnglishWordUnderLatinLayoutIsLeftAlone() {
        XCTAssertEqual(code(us: "how", ru: "рщц", tisRU: false), "ok_en")
        XCTAssertEqual(code(us: "file", ru: "ашду", tisRU: false), "ok_en")
    }

    // MARK: Слово в чужой раскладке переключается

    func testEnglishWordTypedUnderRussianLayoutSwitchesToEnglish() {
        let t = LanguageScorer.score(wordAsUS: "file", wordAsRU: "ашду", tisIsRussian: true, lex: lex, minLength: 3)
        XCTAssertEqual(t.reasonCode, "to_en")
        XCTAssertEqual(t.appliedReplacement, "file")
        XCTAssertTrue(t.didSwitchTIS)
    }

    func testRussianWordTypedUnderLatinLayoutSwitchesToRussian() {
        let t = LanguageScorer.score(wordAsUS: "ghbdtn", wordAsRU: "привет", tisIsRussian: false, lex: lex, minLength: 3)
        XCTAssertEqual(t.reasonCode, "to_ru")
        XCTAssertEqual(t.appliedReplacement, "привет")
    }

    // MARK: Регрессия BUGS.md 2026-09-07 — «еще»/«где» считались неоднозначными

    /// «tot» и «ult» — не английские слова, а префиксы (total, ultimate). Раньше этого хватало, чтобы «еще»
    /// и «где» уходили в отложенную очередь и потом переписывались латиницей.
    func testExactRussianWordBeatsMerelyPlausibleLatinReading() {
        XCTAssertFalse(lex.hasNormalizedWord("en", "tot"))
        XCTAssertFalse(lex.hasNormalizedWord("en", "ult"))
        XCTAssertEqual(code(us: "tot", ru: "еще", tisRU: true), "ok_ru")
        XCTAssertEqual(code(us: "ult", ru: "где", tisRU: true), "ok_ru")
    }

    func testExactEnglishWordBeatsMerelyPlausibleCyrillicReading() {
        XCTAssertFalse(lex.hasNormalizedWord("ru", "еру"))
        XCTAssertEqual(code(us: "the", ru: "еру", tisRU: false), "ok_en")
    }

    /// Обратная сторона того же правила: чужое чтение — точное слово, своё — только «похоже». Сразу не
    /// переключаем (3 буквы — мало), но и «своим» не объявляем: слово ждёт следующего в очереди.
    func testExactWordInOtherLayoutStaysAmbiguous() {
        XCTAssertEqual(code(us: "the", ru: "еру", tisRU: true), "ambi2")
        XCTAssertEqual(code(us: "tot", ru: "еще", tisRU: false), "ambi2")
    }

    func testWordsValidInBothLayoutsStayAmbiguous() {
        XCTAssertTrue(lex.hasNormalizedWord("en", "hey"))
        XCTAssertTrue(lex.hasNormalizedWord("ru", "рун"))
        XCTAssertEqual(code(us: "hey", ru: "рун", tisRU: true), "ambi2")
        XCTAssertEqual(code(us: "hey", ru: "рун", tisRU: false), "ambi2")
    }

    // MARK: Короткие слова и удержание RU-контекста

    func testWordsShorterThanMinLengthAreNotJudged() {
        XCTAssertEqual(code(us: "jy", ru: "он", tisRU: true), "short")
        XCTAssertEqual(code(us: "or", ru: "щк", tisRU: true), "short")
    }

    /// «сфт» ни на что русское не похоже: без RU-контекста «can» переключается сразу, после русского слова — ждёт.
    func testShortEnglishReadingRightAfterRussianWordIsHeld() {
        XCTAssertEqual(code(us: "can", ru: "сфт", tisRU: true), "to_en")
        LanguageContextModel.shared.recordCompletedWord(resolvedTag: "ru")
        XCTAssertEqual(code(us: "can", ru: "сфт", tisRU: true), "hold_ru_ctx")
        XCTAssertEqual(code(us: "please", ru: "здуфыу", tisRU: true), "to_en", "длинное слово удержание не касается")
    }

    /// «тще» — префикс «тщетно»: на экране «похоже на ru», поэтому трёхбуквенное «not» ждёт следующего слова.
    func testThreeLetterWordThatLooksRussianWaitsForNextWord() {
        XCTAssertEqual(code(us: "not", ru: "тще", tisRU: true), "ambi2")
        XCTAssertEqual(code(us: "the", ru: "еру", tisRU: true), "ambi2")
    }

    /// От 4 букв точное слово в другой раскладке перевешивает «похожее» на экране — в обе стороны.
    func testExactWordInOtherLayoutWinsFromFourLetters() {
        XCTAssertFalse(lex.hasNormalizedWord("ru", "еруку"))
        let toEn = LanguageScorer.score(wordAsUS: "there", wordAsRU: "еруку", tisIsRussian: true, lex: lex, minLength: 3)
        XCTAssertEqual(toEn.reasonCode, "to_en")
        XCTAssertEqual(toEn.appliedReplacement, "there")
        let toRu = LanguageScorer.score(wordAsUS: "vtyz", wordAsRU: "меня", tisIsRussian: false, lex: lex, minLength: 3)
        XCTAssertEqual(toRu.reasonCode, "to_ru")
        XCTAssertEqual(toRu.appliedReplacement, "меня")
    }

    func testLanguageIntentPerVerdict() {
        func intent(_ us: String, _ ru: String) -> String? {
            LanguageScorer.inferredLanguageIntent(
                LanguageScorer.score(wordAsUS: us, wordAsRU: ru, tisIsRussian: true, lex: lex, minLength: 3), minWord: 3)
        }
        XCTAssertEqual(intent("please", "здуфыу"), "en")
        XCTAssertEqual(intent("ghbdtn", "привет"), "ru")
        XCTAssertNil(intent("to", "ещ"), "короткое слово языка не задаёт")
        XCTAssertNil(intent("hey", "рун"), "неоднозначное — тоже")
    }

    // MARK: Фраза из двух слов

    func testTwoWordEnglishPhraseUnderRussianLayout() {
        let t = LanguageScorer.tryResolveTwoWordPhrase(
            prevDisplayed: "рун", prevUS: "hey", prevRU: "рун", wordAsUS: "how", wordAsRU: "рщц",
            tisIsRussian: true, latSourceId: "com.apple.keylayout.ABC", lex: lex, minLength: 3
        )
        XCTAssertEqual(t?.reasonCode, "phrase_to_en")
        XCTAssertEqual(t?.appliedReplacement, "hey how")
        XCTAssertEqual(t?.switchToSourceID, "com.apple.keylayout.ABC")
    }

    func testTwoRussianWordsAreNotAnEnglishPhrase() {
        XCTAssertNil(LanguageScorer.tryResolveTwoWordPhrase(
            prevDisplayed: "еще", prevUS: "tot", prevRU: "еще", wordAsUS: "djghjcs", wordAsRU: "вопросы",
            tisIsRussian: true, latSourceId: "com.apple.keylayout.ABC", lex: lex, minLength: 3
        ))
    }

    func testPhrasePathOnlyAppliesUnderRussianLayout() {
        XCTAssertNil(LanguageScorer.tryResolveTwoWordPhrase(
            prevDisplayed: "hey", prevUS: "hey", prevRU: "рун", wordAsUS: "how", wordAsRU: "рщц",
            tisIsRussian: false, latSourceId: "com.apple.keylayout.ABC", lex: lex, minLength: 3
        ))
    }

    // MARK: scoreMulti — путь, который включается при двух раскладках в реестре

    func testScoreMultiWithTwoSourcesFillsSwitchTarget() {
        let ru = KeyboardSourceEntry(sourceID: "com.apple.keylayout.RussianWin", primaryLang: "ru", languages: ["ru"], asciiCapable: false)
        let en = KeyboardSourceEntry(sourceID: "com.apple.keylayout.Canadian", primaryLang: "en", languages: ["en"], asciiCapable: true)
        func run(current: KeyboardSourceEntry, us: String, ruText: String) -> DecisionTrace {
            LanguageScorer.scoreMulti(.init(
                currentSourceId: current.sourceID, sources: [en, ru],
                readingsByID: [en.sourceID: us, ru.sourceID: ruText], lex: lex, minLength: 3
            ))
        }
        let toEn = run(current: ru, us: "file", ruText: "ашду")
        XCTAssertEqual(toEn.reasonCode, "to_en")
        XCTAssertEqual(toEn.switchToSourceID, en.sourceID)
        let toRu = run(current: en, us: "ghbdtn", ruText: "привет")
        XCTAssertEqual(toRu.reasonCode, "to_ru")
        XCTAssertEqual(toRu.switchToSourceID, ru.sourceID)
        let stay = run(current: ru, us: "tot", ruText: "еще")
        XCTAssertEqual(stay.reasonCode, "ok_ru")
        XCTAssertNil(stay.switchToSourceID)
    }
}
