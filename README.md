# LanguageSwitcher

macOS menubar app that watches what you type, scores **English vs Russian** (and N keyboard layouts) using local word lists, and can **switch the system input source** or **rewrite a word** when the “wrong” layout fits the dictionary better. Keycode sequences are re-interpreted through **US QWERTY ↔ Russian JCUKEN** (and other enabled layouts) when auto-correction runs.

**Repository:** [github.com/boombaal/LanguageSwitcher](https://github.com/boombaal/LanguageSwitcher)

## Requirements

- macOS **13.0+**
- Xcode 15+ (Swift 5) to build from source
- **Input Monitoring** (and usually **Accessibility**) enabled for the app in **System Settings → Privacy & Security**

## Features

- **Auto-switch** on word boundaries (space, return, tab): compares readings of the same key sequence in each enabled layout, scores with lexicon + optional **NSSpellChecker** (“fuzzy”) pass.
- **Score-based plausibility** (not just yes/no): prefix strength, fuzzy merge, **script heuristics** (clusters, script mismatch).
- **Incremental layout switch** while typing: streaming scores; optional sharp-drop detection and **keyboard projection** (current vs alternate layout reading).
- **Ambiguity resolution** when two languages both look valid: **context** (last words), **UI locale**, **per-user** bigram-style statistics persisted in `UserDefaults`.
- **Prefix trie** for fast O(|prefix|) lookup with fallback to binary search; degraded **n-gram** signal when the prefix is unknown.
- **Double Ctrl**: swap RU↔Latin for the current word and append the new form to the user lexicon.
- **Decision log** in the app UI for debugging scoring decisions.

## Build

```bash
cd /path/to/LanguageSwitcher
xcodebuild -project LanguageSwitcher.xcodeproj -scheme LanguageSwitcher -configuration Debug \
  -derivedDataPath ./build/DerivedData build
```

The built app:

`build/DerivedData/Build/Products/Debug/LanguageSwitcher.app`

Open it:

```bash
open "build/DerivedData/Build/Products/Debug/LanguageSwitcher.app"
```

**Bundle ID:** `com.languageswitcher.app`  
`LSUIElement` in `Info.plist` controls whether the app appears in the Dock (handy to toggle while debugging).

## Dictionaries

Bundled `en` / `ru` word lists; optional downloads via manifest under Application Support. User-editable `user-<lang>.txt` files are merged in and not overwritten by manifest updates.

## Permissions

- **Input Monitoring** — required to create a `CGEvent` tap; without it, the app cannot see keystrokes.
- **Accessibility** — used to drive synthetic keyboard events when replacing text or switching TIS; prompts are triggered from the app on first run.

## License

No license file is included in this repository yet; add one if you open-source under specific terms.
