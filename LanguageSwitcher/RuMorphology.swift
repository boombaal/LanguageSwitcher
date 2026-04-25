import Foundation

/// Грубый stem для RU: снятие флексий + усечение — чтобы «порядке» вело к пути в словаре к «порядок»/префиксам, без внешней морфологии.
enum RuMorphology {
    /// Суффиксы (сначала длинные); одно снятие на вариант.
    private static let stripSuffixes: [String] = {
        var seen = Set<String>()
        var out: [String] = []
        // Длинные, затем короткие; без дубликатов
        for s in [
            "ыми", "ями", "ами", "ими", "ого", "его", "ему", "ому", "ах", "ях", "ыми", "ыми", "ыми", "ися", "ыми",
            "ой", "ей", "ый", "ий", "ая", "яя", "ое", "ее", "ие", "ые", "ую", "юю", "ыми", "ыми", "ыми", "уми", "о",
            "ам", "ям", "ем", "ом", "им", "ах", "ях", "ов", "ев", "ься", "ся", "сь",
            "ют", "ят", "ат", "ет", "ит", "ут", "от", "ть", "ешь", "ишь", "щий", "вши", "ал", "ил", "ла", "ло", "ли", "л",
            "ой", "ей", "ка", "ки", "ку", "ке", "ок", "ек", "он", "н",
            "и", "ы", "а", "я", "у", "ю", "е", "о", "ь", "ы"
        ] {
            if seen.insert(s).inserted { out.append(s) }
        }
        return out.sorted { $0.count > $1.count }
    }()

    static func normalized(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    /// Поверхностные варианты для `hasWord` / prefixScore (оригинал + снятие + 1–2 буквы с конца, не короче minLength).
    static func searchCandidates(_ word: String, minLength: Int = 3) -> [String] {
        let t = normalized(word)
        guard t.count >= minLength else { return [t] }
        var seen = Set<String>()
        var out: [String] = []
        func add(_ s: String) {
            if s.count >= minLength, seen.insert(s).inserted { out.append(s) }
        }
        add(t)
        for suf in stripSuffixes where suf.count < t.count {
            if t.hasSuffix(suf) {
                add(String(t.dropLast(suf.count)))
            }
        }
        for x in out {
            if x.count > minLength + 1 {
                add(String(x.dropLast()))
            }
            if x.count > minLength + 2 {
                add(String(x.dropLast(2)))
            }
        }
        return out
    }
}
