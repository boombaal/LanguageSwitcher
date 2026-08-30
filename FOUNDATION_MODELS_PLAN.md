# Подключение Apple Foundation Models — оценка и план

Дата: 2026-08-29
Область: `LanguageSwitcher` (macOS, menubar, автопереключение раскладки EN⇄RU)

---

## 1. Краткий вердикт

| Вопрос | Ответ |
|---|---|
| **Возможно технически?** | Да, но только как **асинхронный «арбитр» для неоднозначных случаев**, не как замена основного движка и не в пути посимвольного переключения. |
| **Целесообразно?** | Условно да — при положительном результате быстрого спайка (см. §9). Выигрыш точечный: бакет `ambi`/`ambi2`/`hold_ru_ctx` и фразовый скоринг. Цена — заметная новая поверхность кода и зависимость от macOS 26 + Apple Intelligence. |
| **Рекомендация** | Сначала **time-boxed спайк на 1–2 дня** с замером качества on-device модели на ~100 реальных неоднозначных кейсах RU/EN с контекстом. Go/No-Go — по цифрам. Если Go — выкатывать как **опциональную бета-функцию**, основной движок остаётся baseline и «источником истины» для тестов. |

Ключевые факты об API (проверено, август 2026):

- **Framework:** `FoundationModels` (Swift), доступ к on-device LLM ~3B параметров (Apple Intelligence).
- **Требования:** macOS 26+, Apple silicon, включённый Apple Intelligence. Проверка — `SystemLanguageModel.default.availability`.
- **Русский поддерживается** — добавлен в 3-м поколении моделей (языковая группа с украинским, польским и др.), 15 языков суммарно.
- **Латентность:** ~0.4 с до первого токена на медленном устройстве, ~30 ток/с; `prewarm()` снижает time-to-first-token до ~40 %.
- **Контекст:** фиксированные 4096 токенов (инструкции + промпт + вывод).
- **Стоимость:** ноль (on-device), офлайн, приватно, без сети и без entitlement.
- **Guided generation:** `@Generable`/`@Guide` — вывод констрейнится в типизированный Swift-энум (для нас: `en` / `ru` / `unknown` + `confidence`).
- **Тулчейн:** нужен Xcode 26; в проекте поднять условную сборку (`#if canImport(FoundationModels)` + `if #available(macOS 26, *)`), не трогая базовый deployment target 13.0.

---

## 2. Как приложение принимает решение сейчас

Поток (`EventTapController`):

1. CGEvent-тап ловит `keyDown`, копит нажатия в `WordBuffer` (keycodes + shift).
2. На каждой букве — `tryIncrementalLayoutSwitchAfterKeystroke`: посимвольный префикс-скор EN vs RU, может переключить TIS «на лету».
3. На границе слова (`space`/`return`/`tab`) — `handleBoundary`:
   - строит чтения одних и тех же клавиш во всех раскладках (`buildReadings`);
   - `LanguageScorer.score` / `scoreMulti` / `tryResolveTwoWordPhrase` → `DecisionTrace` с `reasonCode`;
   - при уверенности — backspaces + смена TIS + повторный ввод (в т.ч. **отложенно**: `pendingAmbiguous`, `deferredInterstitialWords`, `deferred_resolved` → `deferred_applied`).

Скоринг (`WordPlausibility` / `PhraseLevelScoring` / `IncrementalNgramScoring` / `LanguageContextModel`):

- exact-hit по словарю (`LexiconStore`, prefix-trie) → 1.0;
- префикс-скор + n-граммы + `ScriptHeuristics` (кластеры/несовместимые пары);
- fuzzy-проход `NSSpellChecker` (опция);
- контекст: последние 8 тегов слов, персональные счётчики en/ru, биграммы (`UserDefaults`), UI-локаль, паузы между клавишами;
- фразовый скоринг пары слов — **захардкоженный набор из ~20 хороших EN-пар и ~10 «мусорных» RU-диграфов**.

**Вывод:** движок детерминированный, покрыт трейсами, быстрый. Слабые места — ровно там, где хорош маленький LLM с контекстом.

---

## 3. Где Foundation Models дают выигрыш (по убыванию ценности)

### 3.1. Разбор неоднозначности на границе слова — **основной кейс**

`reasonCode ∈ {ambi, ambi2, hold_ru_ctx}` и близкие `disambiguationWord01` (разница < `binaryAmbiguityMargin`). Оба чтения — валидные словарные слова (`теми`⇄`ntvb`, `под`⇄`gjl`, `как`⇄`rfr`). Сейчас решает хрупкая смесь эвристик; LLM с 2–5 предыдущими словами контекста определяет намерение заметно точнее.

- Частота: низкая (только «спорные» слова) — вписывается в бюджет латентности.
- Интеграция: LLM выдаёт `languageHint` для «зависшего» `pendingAmbiguous`-сегмента, который **уже существующий** отложенный пайплайн применяет на следующей границе. Новой логики правки текста почти не нужно.

### 3.2. Фразовый скоринг

`PhraseLevelScoring` сейчас — статический список. Замена/дополнение оценкой LLM «насколько это правдоподобное начало фразы на EN vs RU» — прямое улучшение без ручного ведения списков. Тот же асинхронный путь, что и 3.1.

### 3.3. Отложенная многословная коррекция

`deferredInterstitialWords` + `pendingAmbiguous`: когда накопилось несколько спорных сегментов, отдать LLM весь буфер и получить язык намерения для всей цепочки — чище, чем текущее пословное разрешение.

### 3.4. (Опц.) Обогащение `LanguageContextModel`

LLM-оценку можно сложить как ещё один слагаемый прайор в `totalAmbiguityPrior`, не давая ему право вето. Наименее рискованный способ ввести модель в систему.

---

## 4. Где НЕ применять

- **`tryIncrementalLayoutSwitchAfterKeystroke`** (посимвольно) — срабатывает на каждую букву, требования по латентности несовместимы с LLM. Оставить как есть.
- **Синхронно внутри callback тапа** — callback обязан вернуться немедленно, иначе macOS глушит тап (`tapDisabledByTimeout`). `await` в этом пути запрещён.
- **Быстрый путь однозначных слов** (`exact-hit`, явный `to_en`/`to_ru`) — словарь уже даёт 1.0, LLM ничего не добавит, только съест бюджет.
- **Замена `LexiconStore`/`LanguageScorer`** — детерминизм и тестируемость важнее.

---

## 5. Ограничения и риски

| # | Риск | Влияние | Митигация |
|---|---|---|---|
| R1 | **Латентность** ~0.3–0.5 с/запрос; быстрый набор даёт границу слова каждые ~300 мс | Нельзя звать на каждое слово | Жёсткий гейтинг (только `ambi*`), дебаунс, кэш по (readings+контекст), одна параллельная сессия, отмена устаревших `Task`, `prewarm()` на простоях |
| R2 | **Качество на русском** on-device модели неизвестно для нашей задачи | Может свести выигрыш к нулю | **Спайк §9 — блокирующий критерий Go/No-Go** |
| R3 | **Доступность:** только macOS 26+ + Apple silicon + включённый Apple Intelligence; текущий target 13.0 | Функция недоступна значительной части пользователей | Условная компиляция; при `availability != .available` — полный откат на текущий движок; функция строго опциональна |
| R4 | `.unavailable(.modelNotReady)` (модель ещё качается) | Первые запуски без функции | Явный статус в Settings, тихий фолбэк |
| R5 | **Недетерминизм** LLM ломает текущую модель тестирования по `DecisionTrace` | Регрессии сложнее ловить | `temperature: 0` / greedy; LLM — только advisory; отдельные тесты-снапшоты для LLM-пути; основной движок остаётся арбитром в CI |
| R6 | **Guardrails** могут отказать на произвольном фрагменте набранного текста | Пустой ответ | Ловить `LanguageModelSession.GenerationError`, на отказ — фолбэк на эвристику |
| R7 | **Энергопотребление / нагрев** от частого инференса | Батарея, троттлинг | Гейтинг R1 + `if ProcessInfo.thermalState == .serious/.critical { fallback }` |
| R8 | **Тулчейн:** нужен Xcode 26; молодой, меняющийся API (уже были dyld-поломки между бетами) | Стоимость поддержки | Изолировать весь код FM за одним протоколом `DisambiguationAdvisor`; отключаемо флагом сборки |
| R9 | **Приватность восприятия:** отправляем фрагменты набора в модель | На деле on-device, из устройства не уходит | Явно указать в README/Settings, что всё локально; не логировать промпты в `LaunchLog` в релизе |
| R10 | **Гонки правки текста:** пока ждём LLM, пользователь набрал дальше | Порча текста при backspace+ретайп | Применять только через существующий отложенный путь на следующей границе, с проверкой `deferredKeyCount` / `maxDeferredInterstitialWords`; при выходе за окно — отмена |

---

## 6. Архитектура интеграции

Принцип: **LLM — необязательный асинхронный tie-breaker поверх нынешнего пайплайна. Основной движок работает всегда и не ждёт модель.**

```
handleBoundary()
  ├─ LanguageScorer → DecisionTrace                (без изменений, синхронно)
  ├─ reasonCode однозначный?  → применяем как сейчас, LLM не трогаем
  └─ reasonCode ∈ {ambi, ambi2, hold_ru_ctx}?
        ├─ сегмент кладётся в pendingAmbiguous       (как сейчас)
        └─ enqueue async DisambiguationAdvisor.resolve(
               readings, lastWords(3..5), candidates:[en,ru])
             ↳ вне callback, отдельный Task, cancel предыдущего
             ↳ результат {lang, confidence}
                 • confidence ≥ порог → выставить languageHint для pending-сегмента
                 • следующая граница → штатный deferred_resolved → deferred_applied
                 • иначе / отказ / таймаут / thermal → ничего, работает эвристика
```

Новые сущности (весь FM-код изолирован):

- `protocol DisambiguationAdvisor { func resolve(_ ctx: AmbiguityContext) async -> LanguageVerdict? }`
- `HeuristicAdvisor` — обёртка над текущей логикой (fallback, всегда доступна).
- `FoundationModelsAdvisor` (`#if canImport(FoundationModels)`, `@available(macOS 26, *)`):
  - хранит один `LanguageModelSession` с короткими инструкциями;
  - `@Generable struct LanguageVerdict { @Guide(...) let language: Lang; let confidence: Double }` (`enum Lang { case en, ru, unknown }`);
  - `prewarm()` по таймеру простоя;
  - LRU-кэш вердиктов, лимит 1 параллельного запроса, дедлайн ~500 мс.
- `AppSettings`: `foundationModelsAssistEnabled` (по умолчанию `false`), плюс строка статуса доступности в `SettingsUI`.
- Метрика: счётчики «LLM согласился/разошёлся с эвристикой/таймаут» в `DecisionLog` для оценки пользы.

Промпт (эскиз): системная инструкция «Ты определяешь язык, который пользователь СОБИРАЛСЯ набрать. Ответь строго структурой»; вход — `previous words: "…"`, `option EN: "<reading_us>"`, `option RU: "<reading_ru>"`. Вывод — guided `LanguageVerdict`. Держать < ~150 токенов ради латентности.

Что **не** меняется: `EventTapController` callback остаётся синхронным; `SyntheticKeyboard`, отложенный backspace+ретайп, `LexiconStore`.

---

## 7. Более дешёвая альтернатива / промежуточный шаг

`NaturalLanguage` (`NLLanguageRecognizer`, `NLContextualEmbedding`) — доступно уже с macOS 13, без Apple Intelligence, латентность околонулевая:

- `NLLanguageRecognizer.languageHypotheses` на строке «предыдущие слова + кандидат» — дешёвый прайор EN/RU, можно завести **прямо сейчас** как ещё одно слагаемое в `LanguageContextModel.totalAmbiguityPrior`.
- Слаб на одиночных коротких словах и не понимает постановку «одни клавиши — два чтения», поэтому не заменяет п.3.1, но закрывает часть кейсов бесплатно и служит baseline для сравнения со спайком FM.

Рекомендация: сделать этот шаг в любом случае — он маленький и снижает риск R2 (будет с чем сравнивать).

---

## 8. Поэтапный план

### Этап 0 — Спайк (1–2 дня) — **блокирующий**
- Собрать датасет ~100–150 реальных неоднозначных кейсов из `DecisionLog`/`LaunchLog` (readings EN, readings RU, 3–5 предыдущих слов, «правильный» язык вручную).
- Консольная утилита (или отдельная схема) на Xcode 26: гоняет датасет через `LanguageModelSession` + guided `LanguageVerdict`.
- Замерить: accuracy vs текущая эвристика, p50/p95 латентности, долю guardrail-отказов, поведение при `thermalState`.
- **Критерии Go** в §9.

### Этап 1 — Каркас (0.5–1 день)
- `DisambiguationAdvisor` + `HeuristicAdvisor`, вклинить в `handleBoundary` **без FM** (advisor = heuristic), убедиться, что поведение не изменилось, тесты зелёные.
- Добавить `NLLanguageRecognizer`-прайор в `LanguageContextModel` (альтернатива §7).

### Этап 2 — MVP FoundationModelsAdvisor (2–3 дня)
- Условная сборка, availability-гейтинг, сессия + `@Generable`, `prewarm`, кэш, дедлайн, отмена `Task`.
- Подключить к `pendingAmbiguous` → `languageHint` (переиспользовать `deferred_resolved`).
- Флаг `foundationModelsAssistEnabled` (off), статус в Settings, счётчики согласия в `DecisionLog`.

### Этап 3 — Фразовый скоринг через FM (1–2 дня)
- Опционально подменять/дополнять `PhraseLevelScoring.pairPhrasePlaus01` вердиктом LLM на том же асинхронном пути.

### Этап 4 — Бета и калибровка (1–2 дня + сбор данных)
- Дать включить вручную; собрать статистику согласия LLM/эвристики/таймаутов на реальном использовании.
- Настроить пороги confidence и дедлайн.

### Этап 5 — GA-решение
- Если по бете чистый выигрыш и стабильность — оставить опцию, возможно включать по умолчанию при `availability == .available`.
- Иначе — оставить за флагом «эксперимент» или убрать, потеряв только изолированный модуль.

**Итого при положительном спайке:** ~7–11 человеко-дней до беты.

---

## 9. Критерии Go / No-Go после спайка

**Go**, если одновременно:
- Accuracy LLM на неоднозначном датасете **≥ +10 п.п.** к текущей эвристике (и не хуже ни на одном языке отдельно).
- p95 латентности одного вердикта **≤ 500 мс** на целевом железе (M1).
- Guardrail-отказов **< 2 %**, все обрабатываются фолбэком без порчи текста.
- Нет деградации на RU-кейсах относительно эвристики.

**No-Go / отложить**, если: RU-качество на уровне или ниже эвристики (R2), либо латентность p95 > 800 мс, либо API нестабилен в текущем Xcode. Тогда ограничиться шагом §7 (`NaturalLanguage`).

---

## 10. Затрагиваемые файлы

| Файл | Изменение |
|---|---|
| `EventTapController.swift` | Вызов `DisambiguationAdvisor` в `handleBoundary` для `ambi*`; проставление `languageHint` для `pendingAmbiguous` из async-результата |
| `DecisionTrace.swift` (`LanguageScorer`) | Точка, где эвристический вердикт помечается как «неуверенный» и отдаётся advisor'у |
| `PhraseLevelScoring.swift` | (Этап 3) опциональный вызов FM вместо статических наборов |
| `LanguageContextModel.swift` | (§7) слагаемое-прайор от `NLLanguageRecognizer`; счётчики согласия |
| `AppSettings.swift` | `foundationModelsAssistEnabled` + пороги |
| `SettingsUI.swift` | Тумблер + строка статуса доступности Apple Intelligence |
| `DecisionLog.swift` | Метрики «LLM vs эвристика» |
| **Новые:** `DisambiguationAdvisor.swift`, `HeuristicAdvisor.swift`, `FoundationModelsAdvisor.swift` | Изолированный модуль, весь FM-код за `#if canImport(FoundationModels)` |
| `LanguageSwitcher.xcodeproj` | Xcode 26; условная линковка `FoundationModels.framework` (weak) |
| `project.pbxproj` / CI | Тулчейн Xcode 26; отдельная схема для спайк-утилиты |

Entitlements менять не нужно (on-device, без сети). Sandbox уже выключен.

---

## Источники

- [Introducing the Third Generation of Apple's Foundation Models](https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models)
- [Updates to Apple's On-Device and Server Foundation Language Models](https://machinelearning.apple.com/research/apple-foundation-models-2025-updates)
- [Apple Intelligence Foundation Language Models Tech Report 2025](https://machinelearning.apple.com/research/apple-foundation-models-tech-report-2025)
- [Exploring Foundation Models: Supported Languages and Internationalization — Rudrank Riyam](https://rudrank.com/exploring-foundation-models-supported-languages-internationalization)
- [Deep dive into the Foundation Models framework — WWDC25 (Session 301)](https://developer.apple.com/videos/play/wwdc2025/301/)
- [Introduction to Apple's FoundationModels: Limitations, Capabilities, Tools — Natasha The Robot](https://www.natashatherobot.com/p/apple-foundation-models)
- [Foundation Models framework dyld symbol errors after macOS 26 Beta 2 — Apple Developer Forums](https://developer.apple.com/forums/thread/799484)
