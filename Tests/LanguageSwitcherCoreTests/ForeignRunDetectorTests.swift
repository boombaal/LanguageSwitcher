import XCTest
@testable import LanguageSwitcherCore

/// Серия коротких слов «не в той раскладке» (BUGS.md 2026-10-04).
final class ForeignRunDetectorTests: XCTestCase {
    private let lex = TestLexicon.bundled
    private let ruSid = "com.apple.keylayout.RussianWin"
    private let enSid = "com.apple.keylayout.Canadian"

    /// Слова под RU-раскладкой: (на экране, латинское чтение).
    private func feedRU(
        _ d: inout ForeignRunDetector, _ screen: String, _ other: String,
        decided: Bool = false, space: Bool = true, at now: CFTimeInterval = 0, sid: String? = nil
    ) -> [ForeignRunWord]? {
        d.note(screen: screen, other: other, curLang: "ru", otherLang: "en", sourceID: sid ?? ruSid,
               keyCount: screen.count, decided: decided, boundaryIsSpace: space, now: now, lex: lex)
    }

    private func feedEN(_ d: inout ForeignRunDetector, _ screen: String, _ other: String) -> [ForeignRunWord]? {
        d.note(screen: screen, other: other, curLang: "en", otherLang: "ru", sourceID: enSid,
               keyCount: screen.count, decided: false, boundaryIsSpace: true, now: 0, lex: lex)
    }

    func testOrNotToFiresOnThirdWord() {
        var d = ForeignRunDetector()
        XCTAssertNil(feedRU(&d, "щк", "or"))
        XCTAssertNil(feedRU(&d, "тще", "not"))
        let run = feedRU(&d, "ещ", "to")
        XCTAssertEqual(run?.map(\.other), ["or", "not", "to"])
        XCTAssertEqual(run?.map(\.screen), ["щк", "тще", "ещ"])
    }

    func testReverseDirectionRussianUnderLatinLayout() {
        var d = ForeignRunDetector()
        XCTAssertNil(feedEN(&d, "yj", "но"))
        XCTAssertNil(feedEN(&d, "z", "я"))
        XCTAssertEqual(feedEN(&d, "yt", "не")?.map(\.other), ["но", "я", "не"])
    }

    func testTwoWordsAreNotEnough() {
        var d = ForeignRunDetector()
        XCTAssertNil(feedRU(&d, "щк", "or"))
        XCTAssertNil(feedRU(&d, "тще", "not"))
        XCTAssertEqual(d.words.count, 2)
    }

    func testNormalRussianTextNeverStartsARun() {
        var d = ForeignRunDetector()
        for (screen, other) in [("но", "yj"), ("я", "z"), ("не", "yt"), ("как", "rfr"), ("он", "jy")] {
            XCTAssertNil(feedRU(&d, screen, other))
            XCTAssertTrue(d.isEmpty, "«\(screen)»: латинское чтение «\(other)» не слово — серии быть не должно")
        }
    }

    /// «и с в» под RU читаются как «b c d», но это не слова-en и на экране настоящие русские слова.
    func testSingleLetterEnumerationDoesNotFire() {
        var d = ForeignRunDetector()
        XCTAssertNil(feedRU(&d, "ф", "a"))
        XCTAssertNil(feedRU(&d, "ш", "i"))
        XCTAssertNil(feedRU(&d, "ф", "a"), "все слова по одной букве — не фраза")
    }

    func testWordValidInBothLanguagesKeepsRunButIsNotEvidence() {
        var d = ForeignRunDetector()
        // «он»/«jy» рвёт серию (чтение не слово), «рун»/«hey» — нет, но строгих слов должно быть два.
        XCTAssertNil(feedRU(&d, "рун", "hey"))
        XCTAssertNil(feedRU(&d, "щк", "or"))
        XCTAssertNil(feedRU(&d, "рун", "hey"), "только одно слово, которого нет в ru")
        XCTAssertEqual(feedRU(&d, "ещ", "to")?.count, 4)
    }

    func testConfidentDecisionBreaksRun() {
        var d = ForeignRunDetector()
        XCTAssertNil(feedRU(&d, "щк", "or"))
        XCTAssertNil(feedRU(&d, "тще", "not"))
        XCTAssertNil(feedRU(&d, "ещ", "to", decided: true))
        XCTAssertTrue(d.isEmpty)
    }

    func testPauseLongerThanMaxGapRestartsRun() {
        var d = ForeignRunDetector()
        XCTAssertNil(feedRU(&d, "щк", "or", at: 0))
        XCTAssertNil(feedRU(&d, "тще", "not", at: 1))
        XCTAssertNil(feedRU(&d, "ещ", "to", at: 1 + ForeignRunDetector.maxGap + 0.5))
        XCTAssertEqual(d.words.map(\.other), ["to"])
    }

    func testLayoutChangeRestartsRun() {
        var d = ForeignRunDetector()
        XCTAssertNil(feedRU(&d, "щк", "or"))
        XCTAssertNil(feedRU(&d, "тще", "not"))
        XCTAssertNil(feedRU(&d, "ещ", "to", sid: "com.apple.keylayout.Russian"))
        XCTAssertEqual(d.words.count, 1)
    }

    /// Третье слово, закрытое Return, серию завершает; после перевода строки она не продолжается.
    func testNonSpaceBoundaryFiresButDoesNotContinue() {
        var d = ForeignRunDetector()
        XCTAssertNil(feedRU(&d, "щк", "or"))
        XCTAssertNil(feedRU(&d, "тще", "not", space: false))
        XCTAssertTrue(d.isEmpty)
        XCTAssertNil(feedRU(&d, "щк", "or"))
        XCTAssertNil(feedRU(&d, "тще", "not"))
        XCTAssertEqual(feedRU(&d, "ещ", "to", space: false)?.count, 3)
        XCTAssertTrue(d.isEmpty)
    }

    func testBackspaceCountMatchesKeysPlusSingleSpaces() {
        var d = ForeignRunDetector()
        _ = feedRU(&d, "щк", "or")
        _ = feedRU(&d, "тще", "not")
        let run = feedRU(&d, "ещ", "to")!
        XCTAssertEqual(run.reduce(0) { $0 + $1.keyCount } + run.count - 1, "щк тще ещ".count)
    }
}
