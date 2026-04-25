import AppKit
import Foundation

@objcMembers
final class AppSettings: NSObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    private let kMinWord = "minWordLength"
    private let kEnabled = "autoSwitchEnabled"
    private let kLogN = "decisionLogSize"
    private let kTisEN = "tisOverrideEN"
    private let kTisRU = "tisOverrideRU"
    private let kManifest = "lexiconManifestURL"
    private let kLexUp = "lexiconCheckUpdates"
    private let kFuzzy = "fuzzySpellEnabled"
    private let kFuzzyMin = "fuzzyMinWordLength"
    private let kIncremental = "incrementalLayoutSwitch"
    private let kIncPrefixMin = "incrementalPrefixMinLength"
    private let kIncCool = "incrementalLayoutCooldownS"
    private let kIncMinConf = "incrementalMinConfidence"
    private let kIncDbg = "incrementalScoringDebug"

    var minWordLength: Int {
        get { min(10, max(1, d.integer(forKey: kMinWord) == 0 ? 2 : d.integer(forKey: kMinWord))) }
        set { d.set(newValue, forKey: kMinWord) }
    }

    var isAutoSwitchEnabled: Bool {
        get { d.object(forKey: kEnabled) as? Bool ?? true }
        set { d.set(newValue, forKey: kEnabled) }
    }

    var decisionLogSize: Int {
        get { min(200, max(5, d.integer(forKey: kLogN) == 0 ? 30 : d.integer(forKey: kLogN))) }
        set { d.set(newValue, forKey: kLogN) }
    }

    var tisOverrideEN: String? {
        get { d.string(forKey: kTisEN) }
        set { d.set(newValue, forKey: kTisEN) }
    }

    var tisOverrideRU: String? {
        get { d.string(forKey: kTisRU) }
        set { d.set(newValue, forKey: kTisRU) }
    }

    var lexiconManifestURL: String? {
        get { d.string(forKey: kManifest) }
        set { d.set(newValue, forKey: kManifest) }
    }

    var lexiconCheckUpdates: Bool {
        get { d.object(forKey: kLexUp) as? Bool ?? false }
        set { d.set(newValue, forKey: kLexUp) }
    }

    /// When exact word list misses, consult NSSpellChecker for en/ru (second pass in scorer).
    var fuzzySpellEnabled: Bool {
        get { d.object(forKey: kFuzzy) as? Bool ?? false }
        set { d.set(newValue, forKey: kFuzzy) }
    }

    var fuzzyMinWordLength: Int {
        get { min(12, max(3, d.integer(forKey: kFuzzyMin) == 0 ? 4 : d.integer(forKey: kFuzzyMin))) }
        set { d.set(newValue, forKey: kFuzzyMin) }
    }

    /// After each letter, switch TIS when another layout’s reading is the first prefix match in its lexicon.
    var incrementalLayoutSwitchEnabled: Bool {
        get { d.object(forKey: kIncremental) as? Bool ?? true }
        set { d.set(newValue, forKey: kIncremental) }
    }

    /// Minimum length of the candidate reading before incremental switch is considered.
    var incrementalPrefixMinLength: Int {
        get { min(12, max(1, d.integer(forKey: kIncPrefixMin) == 0 ? 2 : d.integer(forKey: kIncPrefixMin))) }
        set { d.set(newValue, forKey: kIncPrefixMin) }
    }

    /// Post-switch подавление «дёргать» (сек, 0.15…1.0).
    var incrementalLayoutCooldown: TimeInterval {
        get {
            let v = d.double(forKey: kIncCool)
            if v <= 0 { return 0.42 }
            return min(1.2, max(0.15, v))
        }
        set { d.set(newValue, forKey: kIncCool) }
    }

    /// Порог `confidence` (накопл. 0…1) для пошаговой смены.
    var incrementalMinConfidence: Double {
        get { min(0.95, max(0.04, d.object(forKey: kIncMinConf) as? Double ?? 0.14)) }
        set { d.set(newValue, forKey: kIncMinConf) }
    }

    var incrementalScoringDebug: Bool {
        get { d.object(forKey: kIncDbg) as? Bool ?? false }
        set { d.set(newValue, forKey: kIncDbg) }
    }
}
