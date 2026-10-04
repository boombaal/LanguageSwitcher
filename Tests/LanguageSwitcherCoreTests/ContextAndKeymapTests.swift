import XCTest
@testable import LanguageSwitcherCore

final class LanguageContextModelTests: XCTestCase {
    private let ctx = LanguageContextModel.shared

    override func setUp() {
        super.setUp()
        ctx.reset()
    }

    func testResetClearsEverything() {
        ctx.recordCompletedWord(resolvedTag: "ru")
        ctx.reset()
        XCTAssertTrue(ctx.recentWordTagsSnapshot.isEmpty)
        XCTAssertFalse(ctx.shouldHoldRuTisVsShortEnReading(englishWordLength: 3))
        XCTAssertNil(ctx.last5BinaryMajority())
    }

    func testHoldOnlyRightAfterRussianWordAndOnlyForShortReadings() {
        XCTAssertFalse(ctx.shouldHoldRuTisVsShortEnReading(englishWordLength: 3))
        ctx.recordCompletedWord(resolvedTag: "ru")
        XCTAssertTrue(ctx.shouldHoldRuTisVsShortEnReading(englishWordLength: 3))
        XCTAssertFalse(ctx.shouldHoldRuTisVsShortEnReading(englishWordLength: 4))
        XCTAssertFalse(ctx.shouldHoldRuTisVsShortEnReading(englishWordLength: 0))
        ctx.recordCompletedWord(resolvedTag: "en")
        XCTAssertFalse(ctx.shouldHoldRuTisVsShortEnReading(englishWordLength: 3))
    }

    func testRollbackUndoesExactlyOneRecordedWord() {
        ctx.recordCompletedWord(resolvedTag: "ru")
        ctx.recordCompletedWord(resolvedTag: "en")
        ctx.rollbackLastCompletedWord()
        XCTAssertEqual(ctx.recentWordTagsSnapshot, ["ru"])
        ctx.rollbackLastCompletedWord()
        XCTAssertEqual(ctx.recentWordTagsSnapshot, ["ru"], "снимок одноразовый")
    }

    func testUnknownTagsAreIgnoredAndWindowIsBounded() {
        ctx.recordCompletedWord(resolvedTag: "he")
        ctx.recordCompletedWord(resolvedTag: nil)
        ctx.recordCompletedWord(resolvedTag: "")
        XCTAssertTrue(ctx.recentWordTagsSnapshot.isEmpty)
        for _ in 0..<20 { ctx.recordCompletedWord(resolvedTag: "en-US") }
        XCTAssertEqual(ctx.recentWordTagsSnapshot, Array(repeating: "en", count: 8))
        XCTAssertEqual(ctx.last5BinaryMajority(), "en")
    }

    func testRecencyBoostFavoursRecentLanguage() {
        ctx.recordCompletedWord(resolvedTag: "ru")
        ctx.recordCompletedWord(resolvedTag: "ru")
        XCTAssertGreaterThan(ctx.contextRecencyBoost(for: "ru"), ctx.contextRecencyBoost(for: "en"))
        XCTAssertEqual(ctx.contextRecencyBoost(for: "he"), 0)
    }
}

final class KeymapTests: XCTestCase {
    /// Виртуальные коды клавиш ANSI: g h b d t n → «привет».
    private let ghbdtn: [(key: UInt16, shift: Bool)] = [(5, false), (4, false), (11, false), (2, false), (17, false), (45, false)]

    func testSameKeysReadInBothLayouts() {
        XCTAssertEqual(Keymap.string(from: ghbdtn, as: .usQWERTY), "ghbdtn")
        XCTAssertEqual(Keymap.string(from: ghbdtn, as: .ruJcuken), "привет")
    }

    func testWordBufferTracksStrokes() {
        var b = WordBuffer()
        XCTAssertTrue(b.isEmpty)
        for s in ghbdtn { b.append(key: s.key, shift: s.shift) }
        XCTAssertEqual(b.stringAsUS(), "ghbdtn")
        XCTAssertEqual(b.stringAsRU(), "привет")
        b.popLast()
        XCTAssertEqual(b.stringAsRU(), "приве")
        b.clear()
        XCTAssertTrue(b.isEmpty)
        b.popLast()
        XCTAssertTrue(b.isEmpty)
    }

    func testLangTagNormalisation() {
        XCTAssertEqual(EnabledKeyboardSourcesRegistry.normalizeLangTag("en-US"), "en")
        XCTAssertEqual(EnabledKeyboardSourcesRegistry.normalizeLangTag(" RU "), "ru")
        XCTAssertEqual(EnabledKeyboardSourcesRegistry.normalizeLangTag(""), "")
    }

    /// Регрессия: с выдуманным ключом фильтра TIS молча отдавал пустой список, и реестр жил на одной раскладке.
    func testRegistryQueryReturnsEveryEnabledLayout() throws {
        let reg = EnabledKeyboardSourcesRegistry.shared
        reg.refreshFromSystem()
        let ids = reg.enabledSources.map(\.sourceID)
        try XCTSkipIf(ids.isEmpty, "нет доступа к TIS (headless)")
        XCTAssertTrue(ids.contains(reg.liveCurrentInputSourceID()), "текущая раскладка должна быть в реестре: \(ids)")
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
