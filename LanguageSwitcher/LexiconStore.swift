import Foundation

/// Thread-safe word sets keyed by normalized language tag (`en`, `ru`, …).
final class LexiconStore {
    static let shared = LexiconStore()

    private let lock = NSLock()
    private var byLang: [String: Set<String>] = [:]
    /// Sorted word list per lang for prefix lookup and prefix scoring.
    private var sortedWordsByLang: [String: [String]] = [:]
    private var prefixTrieByLang: [String: LexiconPrefixTrie] = [:]
    /// Tuning: normalize `prefixLexiconScore` to ~0…1 in `WordPlausibility`.
    static var prefixScoreUpperBound: Double = 9.0

    static func termPrefixScore(p: String, w: String, local: Int) -> Double {
        let pl = p.count, wl = max(w.count, 1)
        let rankTerm = log(1.0 + 1.0 / Double(1 + local)) * 2.0
        let cover = Double(pl) * (Double(pl) / Double(wl))
        let headInWord = 1.0 + 0.25 * (1.0 - min(1, Double(pl) / Double(wl)))
        var headKeys: Double = 0
        for j in 0..<pl {
            headKeys += pow(0.91, Double(j))
        }
        if pl > 0 { headKeys /= Double(pl) }
        return rankTerm * cover * headInWord * (0.65 + 0.35 * headKeys)
    }

    /// Backward-compatible accessors (EN/RU bundles).
    var english: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return byLang["en"] ?? []
    }

    var russian: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return byLang["ru"] ?? []
    }

    init() { reloadFromBundleAndCache() }

    /// `~/Library/Application Support/LanguageSwitcher/Lexicon/user-<lang>.txt` — редактируемые слова (не затираются манифестом).
    static func userLexiconURL(for lang: String) -> URL {
        let k = EnabledKeyboardSourcesRegistry.normalizeLangTag(lang)
        return LexiconDownloadService.appSupportLexiconDir.appendingPathComponent("user-\(k).txt")
    }

    func reloadFromBundleAndCache() {
        var next: [String: Set<String>] = [:]
        next["en"] = Self.mergedLang(cached: LexiconDownloadService.cacheFileURL(for: "en"), bundled: Self.bundleURL(lang: "en"), fallback: Self.fallbackEN)
            .union(Self.loadSet(from: Self.userLexiconURL(for: "en")) ?? [])
        next["ru"] = Self.mergedLang(cached: LexiconDownloadService.cacheFileURL(for: "ru"), bundled: Self.bundleURL(lang: "ru"), fallback: Self.fallbackRU)
            .union(Self.loadSet(from: Self.userLexiconURL(for: "ru")) ?? [])
        for lang in LexiconDownloadService.cachedLangFiles() where lang != "en" && lang != "ru" {
            let k = EnabledKeyboardSourcesRegistry.normalizeLangTag(lang)
            let cached = LexiconDownloadService.cacheFileURL(for: lang).flatMap { Self.loadSet(from: $0) } ?? []
            let user = Self.loadSet(from: Self.userLexiconURL(for: k)) ?? []
            let merged = cached.union(user)
            if !merged.isEmpty { next[k] = merged }
        }
        if let names = try? FileManager.default.contentsOfDirectory(at: LexiconDownloadService.appSupportLexiconDir, includingPropertiesForKeys: nil) {
            for u in names where u.lastPathComponent.hasPrefix("user-") && u.pathExtension == "txt" {
                let base = u.deletingPathExtension().lastPathComponent.dropFirst("user-".count)
                let k = EnabledKeyboardSourcesRegistry.normalizeLangTag(String(base))
                guard !k.isEmpty, k != "en", k != "ru", next[k] == nil,
                      let user = Self.loadSet(from: u), !user.isEmpty else { continue }
                next[k] = user
            }
        }
        let sorted = next.mapValues { Array($0).sorted() }
        var tries: [String: LexiconPrefixTrie] = [:]
        for (k, words) in sorted {
            if !words.isEmpty { tries[k] = Self.buildPrefixTrie(from: words) }
        }
        lock.lock()
        byLang = next
        sortedWordsByLang = sorted
        prefixTrieByLang = tries
        lock.unlock()
    }

    private static func buildPrefixTrie(from words: [String]) -> LexiconPrefixTrie {
        let t = LexiconPrefixTrie()
        for (wi, w) in words.enumerated() {
            for L in 1...w.count {
                let p = String(w.prefix(L))
                guard let (lo, _) = prefixWordRangeStatic(sorted: words, p: p) else { continue }
                let local = wi - lo
                let s = termPrefixScore(p: p, w: w, local: local)
                t.insert(path: p, score: s)
            }
        }
        return t
    }

    private static func prefixWordRangeStatic(sorted: [String], p: String) -> (Int, Int)? {
        var lo0 = 0, hi0 = sorted.count
        while lo0 < hi0 {
            let mid = (lo0 + hi0) / 2
            if sorted[mid] < p { lo0 = mid + 1 } else { hi0 = mid }
        }
        guard lo0 < sorted.count, sorted[lo0].hasPrefix(p) else { return nil }
        var a = lo0, b = sorted.count
        while a < b {
            let mid = (a + b) / 2
            if sorted[mid].hasPrefix(p) { a = mid + 1 } else { b = mid }
        }
        return (lo0, b)
    }

    /// Existence of exact normalized form in the store.
    func hasNormalizedWord(_ tag: String, _ raw: String) -> Bool {
        let k = EnabledKeyboardSourcesRegistry.normalizeLangTag(tag)
        let t = Self.normalizeKey(tag, raw)
        guard !t.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        return (byLang[k] ?? []).contains(t)
    }

    private static func normalizeKey(_ tag: String, _ raw: String) -> String {
        let k = EnabledKeyboardSourcesRegistry.normalizeLangTag(tag)
        if k == "ru" { return raw.lowercased().replacingOccurrences(of: "ё", with: "е") }
        return raw.lowercased()
    }

    /// Legacy boolean; `prefixLexiconScore > 0` is the score-based version.
    func hasPrefixMatch(lang: String, prefix raw: String) -> Bool {
        prefixLexiconScore(lang: lang, prefix: raw) > 0.001
    }

    /// Language-model–lite: rank among prefix-matching words, length and «head of word» weighting. 0 = no prefix.
    func prefixLexiconScore(lang: String, prefix: String) -> Double {
        let tag = EnabledKeyboardSourcesRegistry.normalizeLangTag(lang)
        let p: String
        if tag == "ru" {
            p = prefix.lowercased().replacingOccurrences(of: "ё", with: "е")
        } else {
            p = prefix.lowercased()
        }
        guard !p.isEmpty else { return 0 }
        lock.lock()
        let trie = prefixTrieByLang[tag]
        let sorted = sortedWordsByLang[tag] ?? []
        lock.unlock()
        if let tr = trie {
            let v = tr.maxScore(prefix: p)
            if v > 0.0001 { return v }
        }
        guard !sorted.isEmpty else { return 0 }
        guard let (lo, hi) = prefixWordRange(sorted: sorted, p: p) else { return 0 }
        var best: Double = 0
        let cap = min(hi, lo + 220)
        for idx in lo..<cap {
            let w = sorted[idx]
            guard w.hasPrefix(p) else { break }
            let local = idx - lo
            let s = Self.termPrefixScore(p: p, w: w, local: local)
            if s > best { best = s }
        }
        return best
    }

    /// First/last+1 index in `sorted` of words with prefix `p` (sorted is ASCIIbetical, normalized).
    private func prefixWordRange(sorted: [String], p: String) -> (Int, Int)? {
        var lo0 = 0, hi0 = sorted.count
        while lo0 < hi0 {
            let mid = (lo0 + hi0) / 2
            if sorted[mid] < p { lo0 = mid + 1 } else { hi0 = mid }
        }
        guard lo0 < sorted.count, sorted[lo0].hasPrefix(p) else { return nil }
        var a = lo0, b = sorted.count
        while a < b {
            let mid = (a + b) / 2
            if sorted[mid].hasPrefix(p) { a = mid + 1 } else { b = mid }
        }
        return (lo0, b)
    }

    func words(for lang: String) -> Set<String> {
        let k = EnabledKeyboardSourcesRegistry.normalizeLangTag(lang)
        lock.lock(); defer { lock.unlock() }
        return byLang[k] ?? []
    }

    /// Snapshot for scoring: langTag -> set (only langs that have data).
    func snapshot() -> [String: Set<String>] {
        lock.lock(); defer { lock.unlock() }
        return byLang
    }

    func mergeWords(for lang: String, set: Set<String>) {
        let k = EnabledKeyboardSourcesRegistry.normalizeLangTag(lang)
        guard !k.isEmpty else { return }
        lock.lock()
        var cur = byLang[k] ?? []
        cur.formUnion(set)
        byLang[k] = cur
        let arr = Array(cur).sorted()
        sortedWordsByLang[k] = arr
        prefixTrieByLang[k] = Self.buildPrefixTrie(from: arr)
        lock.unlock()
    }

    /// Raw text of the user lexicon file (one word per line).
    func userLexiconRawText(for lang: String) -> String {
        let u = Self.userLexiconURL(for: lang)
        guard FileManager.default.fileExists(atPath: u.path),
              let t = try? String(contentsOf: u, encoding: .utf8) else { return "" }
        return t
    }

    /// Replace user lexicon from editor text; reloads the store.
    func saveUserLexiconFromEditor(lang: String, text: String) throws {
        let k = EnabledKeyboardSourcesRegistry.normalizeLangTag(lang)
        guard !k.isEmpty else { throw NSError(domain: "LexiconStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Пустой язык"]) }
        var set = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let t = Self.normalizeLexeme(String(line))
            if !t.isEmpty { set.insert(t) }
        }
        try Self.writeUserLexiconFile(lang: k, words: set)
        reloadFromBundleAndCache()
        NotificationCenter.default.post(name: .lexiconStoreDidReload, object: nil)
    }

    /// Append normalized words to the user file and reload.
    func appendUserWords(lang: String, words: Set<String>) {
        let k = EnabledKeyboardSourcesRegistry.normalizeLangTag(lang)
        guard !k.isEmpty else { return }
        var cur = Self.loadSet(from: Self.userLexiconURL(for: k)) ?? []
        for w in words {
            let t = Self.normalizeLexeme(w)
            if !t.isEmpty { cur.insert(t) }
        }
        try? Self.writeUserLexiconFile(lang: k, words: cur)
        reloadFromBundleAndCache()
        NotificationCenter.default.post(name: .lexiconStoreDidReload, object: nil)
    }

    private static func normalizeLexeme(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.replacingOccurrences(of: "ё", with: "е")
    }

    private static func writeUserLexiconFile(lang: String, words: Set<String>) throws {
        let u = userLexiconURL(for: lang)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = words.sorted().joined(separator: "\n") + (words.isEmpty ? "" : "\n")
        try text.write(to: u, atomically: true, encoding: .utf8)
    }

    private static func mergedLang(cached: URL?, bundled: URL?, fallback: [String]) -> Set<String> {
        let c = loadSet(from: cached)
        let b = loadSet(from: bundled)
        switch (c, b) {
        case let (x?, y?): return x.union(y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        case (nil, nil): return Set(fallback)
        }
    }

    private static func bundleURL(lang: String) -> URL? {
        Bundle.main.url(forResource: lang, withExtension: "txt", subdirectory: "Lexicon")
            ?? Bundle.main.url(forResource: lang, withExtension: "txt")
    }

    private static func loadSet(from u: URL?) -> Set<String>? {
        guard let u, let t = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        return Set(
            t.split { $0.isNewline || $0 == " " || $0 == "\t" }
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    private static let fallbackEN: [String] = [
        "the", "a", "to", "and", "of", "in", "is", "it", "you", "for", "that", "on", "with", "are", "be", "an", "as", "at", "this", "or", "from", "hello", "test", "world", "name", "what", "where", "when", "here", "there", "one", "two", "read", "write", "press", "open", "close", "app", "macos", "swift", "code"
    ]
    private static let fallbackRU: [String] = [
        "и", "в", "не", "что", "как", "с", "по", "на", "к", "из", "о", "за", "у", "от", "а", "это", "так", "же", "там", "все", "она", "он", "для", "который", "привет", "тест", "слово", "здравствуйте", "как", "тут", "тоже", "только", "еще", "когда", "уже", "сейчас", "можно", "было", "стать", "программа", "текст", "русский", "английский"
    ]
}
