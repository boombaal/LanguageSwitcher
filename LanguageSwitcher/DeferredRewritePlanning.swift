import Foundation

/// Одно слово серии `ForeignRunDetector`: что на экране и как те же клавиши читаются в другой раскладке.
struct ForeignRunWord: Equatable {
    var screen: String
    var other: String
    var keyCount: Int
    var sourceID: String
}

/// Подряд идущие слова «не в той раскладке»: чтение тех же клавиш в другой раскладке — точное слово
/// словаря, а на экране (как минимум у двух из них) — не слово текущего языка. Нужна для фраз из одних
/// коротких слов («щк тще ещ иу» = «or not to be», «yj z yt» = «но я не»): по отдельности они
/// `short`/`hold_ru_ctx` и ничего не решают.
struct ForeignRunDetector {
    /// Меньше трёх слов подряд — слишком легко принять сокращение/опечатку за чужую раскладку.
    static let minWords = 3
    /// Пауза между словами, после которой серия считается брошенной (каретка могла уйти).
    static let maxGap: CFTimeInterval = 8

    private(set) var words: [ForeignRunWord] = []
    private var lastAt: CFTimeInterval = 0

    var isEmpty: Bool { words.isEmpty }

    mutating func reset() { words.removeAll() }

    /// Учесть слово на границе. Возвращает серию, когда её пора переписать в `otherLang`.
    /// - Parameter decided: по слову уже принято уверенное решение (замена или `ok_*`) — оно серию обрывает.
    mutating func note(
        screen: String, other: String, curLang: String, otherLang: String, sourceID: String, keyCount: Int,
        decided: Bool, boundaryIsSpace: Bool, now: CFTimeInterval, lex: LexiconStore
    ) -> [ForeignRunWord]? {
        // Только точные попадания в словарь: `score01` для 2–3 букв почти всегда «правдоподобен» как префикс.
        // Слово, которое есть и в словаре текущего языка, серию не рвёт, но и доказательством не считается.
        guard !decided, !screen.isEmpty, DeferredTarget.isInScript(other, lang: otherLang),
              lex.hasNormalizedWord(otherLang, other)
        else { reset(); return nil }
        if let last = words.last, last.sourceID != sourceID || now - lastAt > Self.maxGap { reset() }
        words.append(ForeignRunWord(screen: screen, other: other, keyCount: keyCount, sourceID: sourceID))
        lastAt = now
        let run = words
        // `backspaceN` считает между словами ровно один пробел; после Return/Tab серию не продолжаем.
        if !boundaryIsSpace { reset() }
        // Минимум два слова, которых на экране в словаре текущего языка нет вовсе, и хотя бы одно из 2+ букв:
        // «b c d» → «и с в» — три «слова», но это перечисление, а не фраза.
        let strict = run.filter { !lex.hasNormalizedWord(curLang, $0.screen) }.count
        guard run.count >= Self.minWords, strict >= 2, run.contains(where: { $0.keyCount >= 2 }) else { return nil }
        return run
    }
}

/// Какой текст печатать вместо слова из отложенной очереди, когда язык фразы определился.
enum DeferredTarget {
    /// Слово написано алфавитом `lang` (ru — есть кириллица и нет латиницы, en — наоборот).
    static func isInScript(_ s: String, lang: String) -> Bool {
        let cyr = s.range(of: #"[а-яёА-ЯЁ]"#, options: .regularExpression) != nil
        let lat = s.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
        return lang == "ru" ? (cyr && !lat) : (lat && !cyr)
    }

    private static func isRussian(_ id: String, sources: [KeyboardSourceEntry]) -> Bool {
        id.lowercased().contains("russian") || sources.first { $0.sourceID == id }?.primaryLang == "ru"
    }

    private static func isPlausible(_ s: String, lang: String, lex: LexiconStore) -> Bool {
        WordPlausibility.score01(word: s, lang: lang, lex: lex) >= WordPlausibility.acceptThreshold
    }

    /// Reading of the same keystrokes in `preferLang` — never fall back to on-screen Cyrillic when we asked for English.
    static func text(
        displayed: String, alternate: String, readingsByID: [String: String], currentSourceID: String,
        preferLang: String, sources: [KeyboardSourceEntry], lex: LexiconStore
    ) -> String {
        let want = EnabledKeyboardSourcesRegistry.normalizeLangTag(preferLang)

        for e in sources where EnabledKeyboardSourcesRegistry.normalizeLangTag(e.primaryLang) == want {
            if let r = readingsByID[e.sourceID], !r.isEmpty { return r }
        }
        if want == "en" {
            for e in sources where !isRussian(e.sourceID, sources: sources) {
                if let r = readingsByID[e.sourceID], !r.isEmpty { return r }
            }
        } else if want == "ru" {
            for e in sources where isRussian(e.sourceID, sources: sources) {
                if let r = readingsByID[e.sourceID], !r.isEmpty { return r }
            }
        }

        // Чтения из реестра нет (раскладка не в `sources`): выбираем по алфавиту, а не по `curLang` —
        // иначе для ru уходило латинское чтение клавиш («еще» → «tot»), хотя на экране уже кириллица.
        if want == "ru" || want == "en" {
            for c in [displayed, alternate] where isInScript(c, lang: want) { return c }
        }

        let curLang = sources.first { $0.sourceID == currentSourceID }
            .map { EnabledKeyboardSourcesRegistry.normalizeLangTag($0.primaryLang) } ?? ""
        if !alternate.isEmpty, !want.isEmpty, curLang != want { return alternate }
        if !alternate.isEmpty, isPlausible(alternate, lang: want, lex: lex) { return alternate }
        if !displayed.isEmpty, isPlausible(displayed, lang: want, lex: lex) { return displayed }
        if !alternate.isEmpty { return alternate }
        return displayed
    }
}
