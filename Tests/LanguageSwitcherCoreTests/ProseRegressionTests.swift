import XCTest
@testable import LanguageSwitcherCore

/// Связный текст слово за словом — так, как его видит `handleBoundary`: контекст копится от слова к слову.
/// Главное требование к переключателю: обычный набор в правильной раскладке он не трогает.
final class ProseRegressionTests: XCTestCase {
    private let lex = TestLexicon.bundled

    private let russian = """
    я еще не видел такого поведения и не знаю где искать причину но думаю что дело в словаре \
    сегодня мы посмотрим на лог и попробуем понять почему слово пропадает а на его месте остается пробел \
    если раскладка указывается правильно то текст должен оставаться как есть и ничего не стирается \
    у меня остался один вопрос как нам это проверить когда приложение работает в фоне \
    можешь показать какие еще сегменты нужно отображать в этом окне спасибо за помощь
    """

    private let english = """
    there was a problem with the keyboard layout and we could not find the reason for a long time \
    please check the file and tell me where the same code is used in the project settings \
    how are you doing today can we try to write this function again and run it with the new batch \
    this is not the best way to get the position of the button but it works for the first version
    """

    private struct Outcome { var word: String; var code: String; var replacement: String? }

    /// Набрать `text` клавишами раскладки `typedIn`, когда в системе выбрана раскладка `tisRU`.
    private func run(_ text: String, typedIn: KeyboardScript, tisRU: Bool) -> [Outcome] {
        LanguageContextModel.shared.reset()
        return text.split(separator: " ").compactMap { w in
            guard let keys = Keymap.keySequence(for: String(w), script: typedIn) else { return nil }
            let t = LanguageScorer.score(
                wordAsUS: Keymap.string(from: keys, as: .usQWERTY), wordAsRU: Keymap.string(from: keys, as: .ruJcuken),
                tisIsRussian: tisRU, lex: lex, minLength: 3
            )
            // Как в `handleBoundary`: удержание и неоднозначность в контекст не записываются.
            if !["hold_ru_ctx", "ambi", "ambi2"].contains(t.reasonCode), let tag = LanguageScorer.contextTagToRecord(t) {
                LanguageContextModel.shared.recordCompletedWord(resolvedTag: tag)
            }
            return Outcome(word: String(w), code: t.reasonCode, replacement: t.appliedReplacement)
        }
    }

    func testRussianProseUnderRussianLayoutIsNeverRewritten() {
        let out = run(russian, typedIn: .ruJcuken, tisRU: true)
        XCTAssertGreaterThan(out.count, 60)
        let switched = out.filter { $0.replacement != nil }
        XCTAssertTrue(switched.isEmpty, "переключило: \(switched.map { "\($0.word)→\($0.replacement!)" })")
        // Неоднозначные слова уходят в отложенную очередь — их должно быть исчезающе мало.
        let queued = out.filter { $0.code.hasPrefix("ambi") || $0.code == "hold_ru_ctx" }
        XCTAssertTrue(queued.isEmpty, "в очередь: \(queued.map { "\($0.word):\($0.code)" })")
    }

    func testEnglishProseUnderLatinLayoutIsNeverRewritten() {
        let out = run(english, typedIn: .usQWERTY, tisRU: false)
        XCTAssertGreaterThan(out.count, 60)
        let switched = out.filter { $0.replacement != nil }
        XCTAssertTrue(switched.isEmpty, "переключило: \(switched.map { "\($0.word)→\($0.replacement!)" })")
        let queued = out.filter { $0.code.hasPrefix("ambi") }
        XCTAssertTrue(queued.isEmpty, "в очередь: \(queued.map { "\($0.word):\($0.code)" })")
    }

    /// Английский текст, набранный под русской раскладкой: каждое слово от 4 букв должно переключаться само.
    func testEnglishTypedUnderRussianLayoutIsRecognised() {
        let out = run(english, typedIn: .usQWERTY, tisRU: true)
        let long = out.filter { $0.word.count >= 4 }
        let missed = long.filter { $0.replacement != $0.word }
        XCTAssertTrue(missed.isEmpty, "не распознано: \(missed.map { "\($0.word):\($0.code)" })")
        XCTAssertFalse(out.contains { $0.code == "ok_ru" }, "принято за русское: \(out.filter { $0.code == "ok_ru" }.map(\.word))")
    }

    /// Русский текст под латинской раскладкой: слова от 3 букв (без б/ю/ж/э/х/ъ — это знаки препинания в US).
    func testRussianTypedUnderLatinLayoutIsRecognised() {
        let out = run(russian, typedIn: .ruJcuken, tisRU: false)
        let judged = out.filter { $0.word.count >= 3 && $0.word.rangeOfCharacter(from: CharacterSet(charactersIn: "бюжэхъё")) == nil }
        XCTAssertGreaterThan(judged.count, 30)
        // Трёхбуквенное слово, чьё латинское чтение похоже на английское («еще» = «tot»), ждёт следующего
        // слова в очереди — это допустимо; всё остальное должно переключаться сразу.
        let missed = judged.filter { $0.replacement != $0.word && !($0.word.count == 3 && $0.code == "ambi2") }
        XCTAssertTrue(missed.isEmpty, "не распознано: \(missed.map { "\($0.word):\($0.code)" })")
        let waiting = judged.filter { $0.code == "ambi2" }
        XCTAssertLessThanOrEqual(waiting.count, 3, "в очередь: \(waiting.map(\.word))")
    }
}
