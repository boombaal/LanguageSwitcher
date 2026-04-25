import Foundation

/// Recent-word buffer, user LM counters, and bigrams for n-gram / ambiguity fallbacks.
@objcMembers
final class LanguageContextModel: NSObject {
    static let shared = LanguageContextModel()

    private let lock = NSLock()
    private var recentTags: [String] = [] // "en" | "ru" | "other" — last completed words
    private var enTotal: Int = 0
    private var ruTotal: Int = 0
    private var bEnEn: Int = 0, bEnRu: Int = 0, bRuEn: Int = 0, bRuRu: Int = 0
    private var lastCompletedTag: String?
    private let maxRecent = 8
    private var pausePlausibilityPending = false

    private let kR = "ctxRecent", kEn = "ctxEnC", kRu = "ctxRuC", kB = "ctxBig"

    override private init() {
        super.init()
        load()
    }

    var recentWordTagsSnapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return recentTags
    }

    // MARK: - System / UI

    /// Primary UI locale mapped to en / ru (else "other" with small weight).
    func systemTagBinary() -> String {
        let s = NSLocale.current.language.languageCode?.identifier
            ?? Locale.preferredLanguages.first.map { String($0.prefix(2)).lowercased() }
            ?? "en"
        if s == "ru" { return "ru" }
        if s == "en" { return "en" }
        return "en"
    }

    func systemUIScoreBoost(for tag: String) -> Double {
        let t = EnabledKeyboardSourcesRegistry.normalizeLangTag(tag)
        let g = systemTagBinary()
        if t == g { return 0.06 }
        if g == "en", t == "ru" { return 0 }
        if g == "ru", t == "en" { return 0 }
        return 0.02
    }

    // MARK: - Context window (1…3 last words)

    /// 0…~0.15: higher if `tag` matches last 1…3 word languages.
    func contextRecencyBoost(for tag: String) -> Double {
        let t = EnabledKeyboardSourcesRegistry.normalizeLangTag(tag)
        if t != "en", t != "ru" { return 0 }
        lock.lock(); defer { lock.unlock() }
        var s = 0.0
        let w: [Double] = [0.10, 0.07, 0.04]
        let n = min(3, recentTags.count)
        for i in 0..<n {
            let idx = recentTags.count - 1 - i
            if recentTags[idx] == t { s += w[i] }
        }
        return min(0.16, s)
    }

    /// P(tag | last completed) from bigram counts + smoothing.
    func bigramConditional01(for tag: String) -> Double {
        let t = EnabledKeyboardSourcesRegistry.normalizeLangTag(tag)
        guard t == "en" || t == "ru" else { return 0.25 }
        lock.lock()
        let prev = lastCompletedTag
        let enE = bEnEn, enR = bEnRu, ruE = bRuEn, ruR = bRuRu
        lock.unlock()
        guard let p = prev, p == "en" || p == "ru" else { return 0.35 }
        let num: Int, den: Int
        if p == "en" {
            num = t == "en" ? enE : enR
            den = enE + enR
        } else {
            num = t == "en" ? ruE : ruR
            den = ruE + ruR
        }
        if den < 1 { return 0.4 }
        return Double(num + 1) / Double(den + 2)
    }

    /// Degraded mode: when the lexicon prefix has no mass, n-gram + personal as soft signal (0…~0.2).
    func ngramDegradedPlaus01(for tag: String) -> Double {
        min(0.2, 0.55 * bigramConditional01(for: tag) * 0.4 + 0.45 * personalStyleBoost(for: tag) * 2)
    }

    // MARK: - Personal LM

    /// 0…~0.1 from running en/ru counts.
    func personalStyleBoost(for tag: String) -> Double {
        let t = EnabledKeyboardSourcesRegistry.normalizeLangTag(tag)
        guard t == "en" || t == "ru" else { return 0.02 }
        lock.lock(); defer { lock.unlock() }
        let tot = enTotal + ruTotal
        guard tot > 0 else { return 0.03 }
        let pEn = Double(enTotal) / Double(tot)
        let pRu = Double(ruTotal) / Double(tot)
        if t == "en" { return min(0.1, 0.05 + pEn * 0.08) }
        return min(0.1, 0.05 + pRu * 0.08)
    }

    /// Combined: UI + recency + personal (for one candidate language).
    func totalAmbiguityPrior(for tag: String) -> Double {
        contextRecencyBoost(for: tag) + systemUIScoreBoost(for: tag) + personalStyleBoost(for: tag)
    }

    // MARK: - Recording

    /// Call at word boundary when a language is known from trace.
    func recordCompletedWord(resolvedTag: String?) {
        guard let t0 = resolvedTag, !t0.isEmpty else { return }
        let tag = EnabledKeyboardSourcesRegistry.normalizeLangTag(t0)
        guard tag == "en" || tag == "ru" else { return }
        let bin = tag
        lock.lock()
        if let p = lastCompletedTag, p == "en" || p == "ru" {
            if p == "en" {
                if bin == "en" { bEnEn += 1 } else { bEnRu += 1 }
            } else {
                if bin == "en" { bRuEn += 1 } else { bRuRu += 1 }
            }
        }
        lastCompletedTag = bin
        if bin == "en" { enTotal += 1 } else { ruTotal += 1 }
        recentTags.append(bin)
        if recentTags.count > maxRecent { recentTags.removeFirst(recentTags.count - maxRecent) }
        lock.unlock()
        save()
    }

    /// Last 5 "binary" (en/ru) words as frequency hint — same as `personalStyleBoost` + optional bump.
    func last5BinaryMajority() -> String? {
        lock.lock(); defer { lock.unlock() }
        let f = recentTags.filter { $0 == "en" || $0 == "ru" }
        guard !f.isEmpty else { return nil }
        var e = 0, r = 0
        for t in f.suffix(5) { if t == "en" { e += 1 } else { r += 1 } }
        if e == r { return nil }
        return e > r ? "en" : "ru"
    }

    // MARK: - Edits (backspace) / pause

    /// Call before handling a new character with `now - lastKeyDown` for pause-aware n-gram / boundary weight.
    func registerInterKeyGap(_ seconds: TimeInterval) {
        pausePlausibilityPending = seconds > 0.55
    }

    /// One-shot: extra plausibility after a long typing pause.
    func consumePausePlausibilityBoost() -> Double {
        if pausePlausibilityPending {
            pausePlausibilityPending = false
            return 0.04
        }
        return 0
    }

    // MARK: - Persistence

    private func load() {
        let d = UserDefaults.standard
        if let r = d.array(forKey: kR) as? [String] { recentTags = r.compactMap { s in
            s == "en" || s == "ru" ? s : nil
        } }
        enTotal = d.integer(forKey: kEn)
        ruTotal = d.integer(forKey: kRu)
        if let a = d.array(forKey: kB) as? [Int], a.count >= 4 {
            bEnEn = a[0]; bEnRu = a[1]; bRuEn = a[2]; bRuRu = a[3]
        }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(recentTags, forKey: kR)
        d.set(enTotal, forKey: kEn)
        d.set(ruTotal, forKey: kRu)
        lock.lock()
        let pack = [bEnEn, bEnRu, bRuEn, bRuRu]
        lock.unlock()
        d.set(pack, forKey: kB)
    }
}
