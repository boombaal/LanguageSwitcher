import XCTest
@testable import LanguageSwitcherCore

/// Что печатать вместо слова из отложенной очереди (BUGS.md 2026-09-07: «еще» → «tot»).
final class DeferredTargetTests: XCTestCase {
    private let lex = TestLexicon.bundled
    private let ru = KeyboardSourceEntry(sourceID: "com.apple.keylayout.RussianWin", primaryLang: "ru", languages: ["ru"], asciiCapable: false)
    private let en = KeyboardSourceEntry(sourceID: "com.apple.keylayout.Canadian", primaryLang: "en", languages: ["en"], asciiCapable: true)

    func testScriptCheck() {
        XCTAssertTrue(DeferredTarget.isInScript("еще", lang: "ru"))
        XCTAssertTrue(DeferredTarget.isInScript("Ёж", lang: "ru"))
        XCTAssertFalse(DeferredTarget.isInScript("tot", lang: "ru"))
        XCTAssertTrue(DeferredTarget.isInScript("tot", lang: "en"))
        XCTAssertFalse(DeferredTarget.isInScript("tоt", lang: "en"), "кириллическая «о» внутри латиницы")
        XCTAssertFalse(DeferredTarget.isInScript("", lang: "en"))
        XCTAssertFalse(DeferredTarget.isInScript("123", lang: "ru"))
    }

    /// Ровно сценарий бага: в реестре только латинская раскладка, слово набрано под RussianWin.
    func testRussianTargetNeverReturnsLatinWhenRegistryLacksRussianLayout() {
        let text = DeferredTarget.text(
            displayed: "еще", alternate: "tot", readingsByID: [en.sourceID: "tot"],
            currentSourceID: ru.sourceID, preferLang: "ru", sources: [en], lex: lex
        )
        XCTAssertEqual(text, "еще")
    }

    func testEmptyRegistryFallsBackToScript() {
        XCTAssertEqual(DeferredTarget.text(
            displayed: "где", alternate: "ult", readingsByID: [:],
            currentSourceID: ru.sourceID, preferLang: "ru", sources: [], lex: lex
        ), "где")
        XCTAssertEqual(DeferredTarget.text(
            displayed: "рун", alternate: "hey", readingsByID: [:],
            currentSourceID: ru.sourceID, preferLang: "en", sources: [], lex: lex
        ), "hey")
    }

    func testReadingFromRegistryWinsWhenAvailable() {
        let readings = [en.sourceID: "hey", ru.sourceID: "рун"]
        XCTAssertEqual(DeferredTarget.text(
            displayed: "рун", alternate: "hey", readingsByID: readings,
            currentSourceID: ru.sourceID, preferLang: "en", sources: [en, ru], lex: lex
        ), "hey")
        XCTAssertEqual(DeferredTarget.text(
            displayed: "рун", alternate: "hey", readingsByID: readings,
            currentSourceID: ru.sourceID, preferLang: "ru", sources: [en, ru], lex: lex
        ), "рун")
    }

    func testWordTypedUnderLatinLayoutResolvedToRussian() {
        XCTAssertEqual(DeferredTarget.text(
            displayed: "tot", alternate: "еще", readingsByID: [en.sourceID: "tot"],
            currentSourceID: en.sourceID, preferLang: "ru", sources: [en], lex: lex
        ), "еще")
    }

    /// Раскладка опознаётся как русская и по имени, и по языку из реестра.
    func testRussianLayoutRecognisedByLanguageTag() {
        let odd = KeyboardSourceEntry(sourceID: "org.example.custom-cyr", primaryLang: "ru", languages: ["ru"], asciiCapable: false)
        XCTAssertEqual(DeferredTarget.text(
            displayed: "tot", alternate: "", readingsByID: [odd.sourceID: "еще", en.sourceID: "tot"],
            currentSourceID: en.sourceID, preferLang: "ru", sources: [en, odd], lex: lex
        ), "еще")
    }
}
