import Foundation
import XCTest
@testable import LanguageSwitcherCore

enum TestLexicon {
    private static let lexiconDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("LanguageSwitcher/Lexicon", isDirectory: true)

    static func rawWords(_ lang: String) -> Set<String> {
        let url = lexiconDir.appendingPathComponent("\(lang).txt")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return Set(text.split(whereSeparator: \.isNewline).map { $0.lowercased() })
    }

    /// Словари из репозитория — те же, что попадают в .app. Строится один раз на весь прогон (trie на 100k слов).
    static let bundled = LexiconStore(words: [
        "en": LexiconStore.sanitized(rawWords("en"), lang: "en"),
        "ru": LexiconStore.sanitized(rawWords("ru"), lang: "ru"),
    ])
}
