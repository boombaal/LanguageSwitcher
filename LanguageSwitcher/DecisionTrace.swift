import Foundation

struct DecisionTrace: CustomStringConvertible, Identifiable {
    var id: UUID
    var date: Date
    /// String from keys as current TIS; second line is alternate script (binary) or first alternate (N-way).
    var asCurrentScript: String
    var asAlternateScript: String
    var tisWasRussian: Bool
    var aInEn: Bool
    var aInRu: Bool
    var bInEn: Bool
    var bInRu: Bool
    var appliedReplacement: String?
    var didSwitchTIS: Bool
    var reasonCode: String
    var reasonHuman: String
    /// When switching in N-way mode, destination TIS id (nil = derive from `to_ru` / `to_en`).
    var switchToSourceID: String?
    /// Compact debug: which langs hit for current vs alternate strings.
    var lexHitsSummary: String
    var currentSourceID: String

    var description: String { reasonHuman }

    init(
        asCurrentScript: String, asAlternateScript: String, tisWasRussian: Bool,
        aInEn: Bool, aInRu: Bool, bInEn: Bool, bInRu: Bool,
        appliedReplacement: String?, didSwitchTIS: Bool,
        reasonCode: String, reasonHuman: String,
        switchToSourceID: String? = nil,
        lexHitsSummary: String = "",
        currentSourceID: String = ""
    ) {
        self.id = UUID()
        self.date = Date()
        self.asCurrentScript = asCurrentScript
        self.asAlternateScript = asAlternateScript
        self.tisWasRussian = tisWasRussian
        self.aInEn = aInEn
        self.aInRu = aInRu
        self.bInEn = bInEn
        self.bInRu = bInRu
        self.appliedReplacement = appliedReplacement
        self.didSwitchTIS = didSwitchTIS
        self.reasonCode = reasonCode
        self.reasonHuman = reasonHuman
        self.switchToSourceID = switchToSourceID
        self.lexHitsSummary = lexHitsSummary
        self.currentSourceID = currentSourceID
    }

    /// Same lexical context, but no TIS/replacement: current system layout already matches the inferred language.
    func skippingBecauseCurrentLayoutMatchesTarget() -> DecisionTrace {
        DecisionTrace(
            asCurrentScript: asCurrentScript,
            asAlternateScript: asAlternateScript,
            tisWasRussian: tisWasRussian,
            aInEn: aInEn, aInRu: aInRu, bInEn: bInEn, bInRu: bInRu,
            appliedReplacement: nil,
            didSwitchTIS: false,
            reasonCode: "skip_same_lang",
            reasonHuman: "Раскладка в системе уже соответствует определённому языку — замена и смена TIS не выполняются.",
            switchToSourceID: nil,
            lexHitsSummary: lexHitsSummary,
            currentSourceID: currentSourceID
        )
    }
}

// MARK: - LanguageScorer

enum LanguageScorer {
    /// Preferred language tag from a confident trace (`en`, `ru`, …). `nil` if no signal.
    static func inferredLanguageIntent(_ t: DecisionTrace, minWord: Int) -> String? {
        let n = t.asCurrentScript
        // Длина minWord в скоринге (например 4) не должна глушить намерение для ok_:
        // иначе «how»+pending остаётся без deferred, pending залипает (ниже languageHint==nil).
        let lenOk = n.count >= max(2, minWord)
        if t.reasonCode.hasPrefix("ok_") {
            let tag = String(t.reasonCode.dropFirst(3))
            let allowOkTag = n.count >= 2 || lenOk
            if allowOkTag {
                if tag == "en", t.aInEn { return "en" }
                if tag == "ru", t.aInRu { return "ru" }
                if !tag.isEmpty { return tag }
            }
        }
        switch t.reasonCode {
        case "to_en": return "en"
        case "to_ru": return "ru"
        case "hold_ru_ctx": return "ru"
        case "phrase_to_en": return "en"
        default:
            if t.reasonCode.hasPrefix("to_") { return String(t.reasonCode.dropFirst(3)) }
            return nil
        }
    }

    static func contextTagToRecord(_ t: DecisionTrace) -> String? {
        inferredLanguageIntent(t, minWord: 1)
    }

    private static func inLex(_ s: String, lang: String, lex: LexiconStore) -> Bool {
        WordPlausibility.score01(word: s, lang: lang, lex: lex) >= WordPlausibility.acceptThreshold
    }

    struct MultiScoreInput {
        var currentSourceId: String
        var sources: [KeyboardSourceEntry]
        var readingsByID: [String: String]
        var lex: LexiconStore
        var minLength: Int
    }

    static func scoreMulti(_ ctx: MultiScoreInput) -> DecisionTrace {
        let curId = ctx.currentSourceId
        let srcs = ctx.sources
        if srcs.count == 2, let ru = srcs.first(where: { EnabledKeyboardSourcesRegistry.shared.isRussianSourceID($0.sourceID) }),
           let lat = srcs.first(where: { $0.sourceID != ru.sourceID }) {
            let wru = ctx.readingsByID[ru.sourceID] ?? ""
            let wus = ctx.readingsByID[lat.sourceID] ?? ""
            let tisRU = (curId == ru.sourceID)
            var t = score(wordAsUS: wus, wordAsRU: wru, tisIsRussian: tisRU, lex: ctx.lex, minLength: ctx.minLength)
            t.currentSourceID = curId
            t.switchToSourceID = inferSwitchId(from: t, ruId: ru.sourceID, latId: lat.sourceID)
            t.lexHitsSummary = "2-way"
            return t
        }
        return scoreNWay(ctx)
    }

    private static func inferSwitchId(from t: DecisionTrace, ruId: String, latId: String) -> String? {
        switch t.reasonCode {
        case "to_ru": return ruId
        case "to_en", "phrase_to_en": return latId
        default: return nil
        }
    }

    private static func scoreNWay(_ ctx: MultiScoreInput) -> DecisionTrace {
        let curId = ctx.currentSourceId
        guard let cur = ctx.sources.first(where: { $0.sourceID == curId }) else {
            return DecisionTrace(
                asCurrentScript: "", asAlternateScript: "", tisWasRussian: false,
                aInEn: false, aInRu: false, bInEn: false, bInRu: false,
                appliedReplacement: nil, didSwitchTIS: false,
                reasonCode: "no_current", reasonHuman: "Текущая раскладка не в списке включённых.",
                switchToSourceID: nil, lexHitsSummary: "", currentSourceID: curId
            )
        }
        let a = ctx.readingsByID[curId] ?? ""
        let others = ctx.sources.filter { $0.sourceID != curId }
        let alt = others.first
        let b = alt.flatMap { ctx.readingsByID[$0.sourceID] } ?? ""
        let tisRU = EnabledKeyboardSourcesRegistry.shared.isRussianSourceID(curId)
        let curLang = cur.primaryLang
        let aInCurr = inLex(a, lang: curLang, lex: ctx.lex)
        var hits: [(KeyboardSourceEntry, Bool)] = []
        for o in others {
            hits.append((o, inLex(ctx.readingsByID[o.sourceID] ?? "", lang: o.primaryLang, lex: ctx.lex)))
        }
        let inLexOthers = hits.filter(\.1).map(\.0)
        let aEn = (curLang == "en") && aInCurr
        let aRu = (curLang == "ru") && aInCurr
        let altLang = alt?.primaryLang ?? ""
        let bEn = (altLang == "en") && inLex(b, lang: "en", lex: ctx.lex)
        let bRu = (altLang == "ru") && inLex(b, lang: "ru", lex: ctx.lex)
        let summary = hits.map { "\($0.0.primaryLang):\($0.1)" }.joined(separator: ",")

        if a.count < ctx.minLength, (ctx.readingsByID[others.first?.sourceID ?? ""] ?? "").count < ctx.minLength {
            return DecisionTrace(
                asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisRU,
                aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu,
                appliedReplacement: nil, didSwitchTIS: false,
                reasonCode: "short", reasonHuman: "Слово короче minLength (\(ctx.minLength)): «\(a)»",
                switchToSourceID: nil, lexHitsSummary: summary, currentSourceID: curId
            )
        }
        if a.isEmpty {
            return DecisionTrace(
                asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisRU,
                aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu,
                appliedReplacement: nil, didSwitchTIS: false,
                reasonCode: "empty", reasonHuman: "Пустое «слово» — нет букв.",
                switchToSourceID: nil, lexHitsSummary: summary, currentSourceID: curId
            )
        }

        if aInCurr && inLexOthers.count > 1 {
            return DecisionTrace(
                asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisRU,
                aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu,
                appliedReplacement: nil, didSwitchTIS: false,
                reasonCode: "ambi2", reasonHuman: "N-way: несколько других чтений в словаре — не трогаем: «\(a)»",
                switchToSourceID: nil, lexHitsSummary: summary, currentSourceID: curId
            )
        }
        if aInCurr && inLexOthers.count == 1, let o = inLexOthers.first {
            let ta = EnabledKeyboardSourcesRegistry.normalizeLangTag(cur.primaryLang)
            let tb = EnabledKeyboardSourcesRegistry.normalizeLangTag(o.primaryLang)
            let otext = ctx.readingsByID[o.sourceID] ?? ""
            let sa = WordPlausibility.disambiguationWord01(a, lang: ta, lex: ctx.lex)
            let sb = WordPlausibility.disambiguationWord01(otext, lang: tb, lex: ctx.lex)
            if sa - sb > WordPlausibility.binaryAmbiguityMargin {
                let code = "ok_\(ta)"
                return DecisionTrace(
                    asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisRU,
                    aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu,
                    appliedReplacement: nil, didSwitchTIS: false,
                    reasonCode: code, reasonHuman: "N-way: остаёмся на текущем (\(ta)) — контекст: «\(a)» (σ \(String(format: "%.2f", sa)) vs \(String(format: "%.2f", sb)))",
                    switchToSourceID: nil, lexHitsSummary: summary, currentSourceID: curId
                )
            }
            if sb - sa > WordPlausibility.binaryAmbiguityMargin, ta != tb, !otext.isEmpty {
                let code = "to_\(tb)"
                return DecisionTrace(
                    asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisRU,
                    aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu,
                    appliedReplacement: otext, didSwitchTIS: true,
                    reasonCode: code, reasonHuman: "N-way: смена по контексту — «\(otext)» (σ \(String(format: "%.2f", sb)) > \(String(format: "%.2f", sa)))",
                    switchToSourceID: o.sourceID, lexHitsSummary: summary, currentSourceID: curId
                )
            }
            if sb - sa > WordPlausibility.binaryAmbiguityMargin, ta == tb, !otext.isEmpty {
                return DecisionTrace(
                    asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisRU,
                    aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu,
                    appliedReplacement: nil, didSwitchTIS: false,
                    reasonCode: "skip_same_lang", reasonHuman: "N-way: контекст в пользу другой раскладки того же языка — без TIS: «\(a)»",
                    switchToSourceID: nil, lexHitsSummary: summary, currentSourceID: curId
                )
            }
            return DecisionTrace(
                asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisRU,
                aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu,
                appliedReplacement: nil, didSwitchTIS: false,
                reasonCode: "ambi2", reasonHuman: "N-way: два чтения близки — «\(a)»",
                switchToSourceID: nil, lexHitsSummary: summary, currentSourceID: curId
            )
        }
        if aInCurr && inLexOthers.isEmpty {
            let code = "ok_\(curLang)"
            return DecisionTrace(
                asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisRU,
                aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu,
                appliedReplacement: nil, didSwitchTIS: false,
                reasonCode: code, reasonHuman: "Похоже на \(curLang): «\(a)»",
                switchToSourceID: nil, lexHitsSummary: summary, currentSourceID: curId
            )
        }
        if inLexOthers.count == 1, let only = inLexOthers.first, let rep = ctx.readingsByID[only.sourceID] {
            let onlyLang = EnabledKeyboardSourcesRegistry.normalizeLangTag(only.primaryLang)
            let curLangNorm = EnabledKeyboardSourcesRegistry.normalizeLangTag(cur.primaryLang)
            if !onlyLang.isEmpty, onlyLang == curLangNorm {
                return DecisionTrace(
                    asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisRU,
                    aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu,
                    appliedReplacement: nil, didSwitchTIS: false,
                    reasonCode: "skip_same_lang",
                    reasonHuman: "N-way: словарь указывает на другую раскладку того же языка (\(only.primaryLang)), в системе он уже выбран — без смены.",
                    switchToSourceID: nil, lexHitsSummary: summary, currentSourceID: curId
                )
            }
            let code = "to_\(only.primaryLang)"
            return DecisionTrace(
                asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisRU,
                aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu,
                appliedReplacement: rep, didSwitchTIS: true,
                reasonCode: code, reasonHuman: "N-way: смена на \(only.primaryLang) — «\(rep)»",
                switchToSourceID: only.sourceID, lexHitsSummary: summary, currentSourceID: curId
            )
        }
        if inLexOthers.count > 1 {
            return DecisionTrace(
                asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisRU,
                aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu,
                appliedReplacement: nil, didSwitchTIS: false,
                reasonCode: "ambi", reasonHuman: "N-way: несколько раскладок подходят под словари — не трогаем.",
                switchToSourceID: nil, lexHitsSummary: summary, currentSourceID: curId
            )
        }
        return DecisionTrace(
            asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisRU,
            aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu,
            appliedReplacement: nil, didSwitchTIS: false,
            reasonCode: "no_match", reasonHuman: "N-way: нет совпадения. \(summary)",
            switchToSourceID: nil, lexHitsSummary: summary, currentSourceID: curId
        )
    }

    private static func inEN(_ s: String, lex: LexiconStore) -> Bool {
        WordPlausibility.score01(word: s, lang: "en", lex: lex) >= WordPlausibility.acceptThreshold
    }
    private static func inRU(_ s: String, lex: LexiconStore) -> Bool {
        WordPlausibility.score01(word: s, lang: "ru", lex: lex) >= WordPlausibility.acceptThreshold
    }

    /// Два слова подряд (pending ambi + текущее): phrase en vs ru; иначе `nil` — обычный score по текущему слову.
    static func tryResolveTwoWordPhrase(
        prevDisplayed: String,
        prevUS: String,
        prevRU: String,
        wordAsUS: String,
        wordAsRU: String,
        tisIsRussian: Bool,
        latSourceId: String,
        lex: LexiconStore,
        minLength: Int
    ) -> DecisionTrace? {
        guard tisIsRussian else { return nil }
        guard prevDisplayed.count >= minLength, wordAsRU.count >= minLength, prevUS.count >= minLength, wordAsUS.count >= minLength else { return nil }
        let sE = PhraseLevelScoring.pairPhrasePlaus01(p1: prevUS, p2: wordAsUS, lang: "en", lex: lex)
        let sR = PhraseLevelScoring.pairPhrasePlaus01(p1: prevRU, p2: wordAsRU, lang: "ru", lex: lex)
        let margin: Double = 0.10
        guard sE - sR > margin, sE >= 0.48 else { return nil }
        let a = wordAsRU
        let b = wordAsUS
        let aEn = inEN(a, lex: lex)
        let aRu = inRU(a, lex: lex)
        let bEn = inEN(b, lex: lex)
        let bRu = inRU(b, lex: lex)
        let rep = prevUS + " " + wordAsUS
        let h = "Фраза (2 слова): en \(String(format: "%.2f", sE)) > ru \(String(format: "%.2f", sR)) — U.S.: «\(rep)» вместо «\(prevRU) \(wordAsRU)»"
        return DecisionTrace(
            asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisIsRussian,
            aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu,
            appliedReplacement: rep, didSwitchTIS: true,
            reasonCode: "phrase_to_en", reasonHuman: h,
            switchToSourceID: latSourceId, lexHitsSummary: "phrase E=\(String(format: "%.2f", sE)) R=\(String(format: "%.2f", sR))", currentSourceID: ""
        )
    }

    static func score(
        wordAsUS: String,
        wordAsRU: String,
        tisIsRussian: Bool,
        lex: LexiconStore,
        minLength: Int
    ) -> DecisionTrace {
        let a = tisIsRussian ? wordAsRU : wordAsUS
        let b = tisIsRussian ? wordAsUS : wordAsRU
        let aEn = inEN(a, lex: lex)
        let aRu = inRU(a, lex: lex)
        let bEn = inEN(b, lex: lex)
        let bRu = inRU(b, lex: lex)
        if a.count < minLength, b.count < minLength {
            return .init(
                asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisIsRussian,
                aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu, appliedReplacement: nil, didSwitchTIS: false,
                reasonCode: "short", reasonHuman: "Слово короче minLength (\(minLength)): «\(a)»"
            )
        }
        if a.isEmpty {
            return .init(
                asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisIsRussian,
                aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu, appliedReplacement: nil, didSwitchTIS: false,
                reasonCode: "empty", reasonHuman: "Пустое «слово» — нет букв."
            )
        }
        if tisIsRussian {
            if aRu && bEn {
                let sru = WordPlausibility.disambiguationWord01(a, lang: "ru", lex: lex)
                let sen = WordPlausibility.disambiguationWord01(b, lang: "en", lex: lex)
                if sen - sru > WordPlausibility.binaryAmbiguityMargin {
                    return .init(
                        asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisIsRussian,
                        aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu, appliedReplacement: b, didSwitchTIS: true,
                        reasonCode: "to_en", reasonHuman: "Амбивалент: по контексту/UI сильнее en — смена: «\(b)» (ru:\(String(format: "%.2f", sru)) en:\(String(format: "%.2f", sen)))"
                    )
                }
                if sru - sen > WordPlausibility.binaryAmbiguityMargin {
                    return .init(
                        asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisIsRussian,
                        aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu, appliedReplacement: nil, didSwitchTIS: false,
                        reasonCode: "ok_ru", reasonHuman: "Амбивалент: по контексту сильнее ru: «\(a)» (ru:\(String(format: "%.2f", sru)) en:\(String(format: "%.2f", sen)))"
                    )
                }
                return noSwitch(a, b, aEn, aRu, bEn, bRu, tisIsRussian, "ambi2", "Оба варианта (RU+EN) близки — не трогаем: «\(a)» / «\(b)»")
            }
            if aRu && !bEn {
                return .init(
                    asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisIsRussian,
                    aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu, appliedReplacement: nil, didSwitchTIS: false,
                    reasonCode: "ok_ru", reasonHuman: "Похоже на RU, латинский вариант не en — трогать нельзя: «\(a)»"
                )
            }
            if !aRu && bEn && aEn { return noSwitch(a, b, aEn, aRu, bEn, bRu, tisIsRussian, "ambi", "EN и RU варианты в словаре — не трогаем: «\(a)»/«\(b)»") }
            if !aRu && bEn {
                if LanguageContextModel.shared.shouldHoldRuTisVsShortEnReading(englishWordLength: b.count) {
                    return noSwitch(
                        a, b, aEn, aRu, bEn, bRu, tisIsRussian, "hold_ru_ctx",
                        "Продолжение RU-фразы: короткое en-чтение «\(b)» (на экране «\(a)») — не смена на U.S. (возм. неверные клавиши в RU-раскладке)."
                    )
                }
                return .init(
                    asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisIsRussian,
                    aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu, appliedReplacement: b, didSwitchTIS: true,
                    reasonCode: "to_en", reasonHuman: "Набрали в RU, но RU-варианта нет в ru, en-вариант en — смена на U.S.: «\(b)»"
                )
            }
        } else {
            if aEn && bRu {
                let sen = WordPlausibility.disambiguationWord01(a, lang: "en", lex: lex)
                let sru = WordPlausibility.disambiguationWord01(b, lang: "ru", lex: lex)
                if sru - sen > WordPlausibility.binaryAmbiguityMargin {
                    return .init(
                        asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisIsRussian,
                        aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu, appliedReplacement: b, didSwitchTIS: true,
                        reasonCode: "to_ru", reasonHuman: "Амбивалент: по контексту сильнее ru — смена: «\(b)» (en:\(String(format: "%.2f", sen)) ru:\(String(format: "%.2f", sru)))"
                    )
                }
                if sen - sru > WordPlausibility.binaryAmbiguityMargin {
                    return .init(
                        asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisIsRussian,
                        aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu, appliedReplacement: nil, didSwitchTIS: false,
                        reasonCode: "ok_en", reasonHuman: "Амбивалент: по контексту сильнее en: «\(a)» (en:\(String(format: "%.2f", sen)) ru:\(String(format: "%.2f", sru)))"
                    )
                }
                return noSwitch(a, b, aEn, aRu, bEn, bRu, tisIsRussian, "ambi2", "Оба варианта (EN+RU) близки — не трогаем: «\(a)» / «\(b)»")
            }
            if aEn && !bRu {
                return .init(
                    asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisIsRussian,
                    aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu, appliedReplacement: nil, didSwitchTIS: false,
                    reasonCode: "ok_en", reasonHuman: "Похоже на en, кириллица не ru — трогать нельзя: «\(a)»"
                )
            }
            if !aEn && bRu && aRu { return noSwitch(a, b, aEn, aRu, bEn, bRu, tisIsRussian, "ambi", "EN и RU варианты в словаре — не трогаем: «\(a)»/«\(b)»") }
            if !aEn && bRu {
                return .init(
                    asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisIsRussian,
                    aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu, appliedReplacement: b, didSwitchTIS: true,
                    reasonCode: "to_ru", reasonHuman: "Набрали в U.S., но en нет, ru вариант в ru — смена на Русскую: «\(b)»"
                )
            }
        }
        return .init(
            asCurrentScript: a, asAlternateScript: b, tisWasRussian: tisIsRussian,
            aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu, appliedReplacement: nil, didSwitchTIS: false,
            reasonCode: "no_match", reasonHuman: "Словарь+эвристика: замена не сработала («\(a)» / «\(b)»)."
        )
    }

    private static func noSwitch(
        _ a: String, _ b: String, _ aEn: Bool, _ aRu: Bool, _ bEn: Bool, _ bRu: Bool, _ tis: Bool, _ c: String, _ h: String
    ) -> DecisionTrace {
        .init(
            asCurrentScript: a, asAlternateScript: b, tisWasRussian: tis, aInEn: aEn, aInRu: aRu, bInEn: bEn, bInRu: bRu,
            appliedReplacement: nil, didSwitchTIS: false, reasonCode: c, reasonHuman: h
        )
    }
}
