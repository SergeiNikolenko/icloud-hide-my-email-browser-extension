import Foundation
import LayoutSwitcherCore
import Observation

enum ManualSwitchTrigger: String, CaseIterable, Identifiable {
    case both = "both"
    case option = "option"
    case doubleShift = "doubleShift"
    case disabled = "disabled"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return String(localized: "Option or Double Shift")
        case .option: return String(localized: "Option")
        case .doubleShift: return String(localized: "Double Shift")
        case .disabled: return String(localized: "Off")
        }
    }
}

enum PastePlainTextShortcut: String, CaseIterable, Identifiable {
    case cmdShiftV = "cmdShiftV"
    case cmdV = "cmdV"
    case cmdOptionShiftV = "cmdOptionShiftV"
    case off = "off"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cmdShiftV: return "⌘⇧V"
        case .cmdV: return String(localized: "⌘V (Always Plain Text)")
        case .cmdOptionShiftV: return "⌘⌥⇧V"
        case .off: return String(localized: "Off")
        }
    }

    var shortBadge: String {
        switch self {
        case .cmdShiftV, .off: return "⌘⇧V"
        case .cmdV: return "⌘V"
        case .cmdOptionShiftV: return "⌘⌥⇧V"
        }
    }
}

@MainActor
@Observable
final class SwitcherPreferences {
    static let shared = SwitcherPreferences()

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.isEnabled) }
    }

    var midWordSwitchEnabled: Bool {
        didSet { defaults.set(midWordSwitchEnabled, forKey: Key.midWordSwitchEnabled) }
    }

    var doubleCapsFixEnabled: Bool {
        didSet { defaults.set(doubleCapsFixEnabled, forKey: Key.doubleCapsFixEnabled) }
    }

    var autocorrectEnabled: Bool {
        didSet { defaults.set(autocorrectEnabled, forKey: Key.autocorrectEnabled) }
    }

    var yofikatorEnabled: Bool {
        didSet { defaults.set(yofikatorEnabled, forKey: Key.yofikatorEnabled) }
    }

    var manualTrigger: ManualSwitchTrigger {
        didSet { defaults.set(manualTrigger.rawValue, forKey: Key.manualTrigger) }
    }

    var singleShiftEnabled: Bool {
        didSet { defaults.set(singleShiftEnabled, forKey: Key.singleShiftEnabled) }
    }

    var splitShiftToggleEnabled: Bool {
        didSet { defaults.set(splitShiftToggleEnabled, forKey: Key.splitShiftToggleEnabled) }
    }

    var pastePlainTextEnabled: Bool {
        didSet {
            defaults.set(pastePlainTextEnabled, forKey: Key.pastePlainTextEnabled)
            if !pastePlainTextEnabled && pastePlainTextShortcut != .off {
                pastePlainTextShortcut = .off
            } else if pastePlainTextEnabled && pastePlainTextShortcut == .off {
                pastePlainTextShortcut = .cmdShiftV
            }
        }
    }

    var pastePlainTextShortcut: PastePlainTextShortcut {
        didSet {
            defaults.set(pastePlainTextShortcut.rawValue, forKey: Key.pastePlainTextShortcut)
            let shouldEnable = (pastePlainTextShortcut != .off)
            if pastePlainTextEnabled != shouldEnable {
                pastePlainTextEnabled = shouldEnable
            }
        }
    }

    var switchToEnglishInTerminals: Bool {
        didSet { defaults.set(switchToEnglishInTerminals, forKey: Key.switchToEnglishInTerminals) }
    }

    var useBuiltInAppExceptions: Bool {
        didSet { defaults.set(useBuiltInAppExceptions, forKey: Key.useBuiltInAppExceptions) }
    }

    var soundFeedbackEnabled: Bool {
        didSet { defaults.set(soundFeedbackEnabled, forKey: Key.soundFeedbackEnabled) }
    }

    var soundName: String {
        didSet { defaults.set(soundName, forKey: Key.soundName) }
    }

    static let availableSounds = ["Tink", "Pop", "Glass", "Submarine", "Frog", "Morse", "Purr"]

    var autoLearnRevertedWords: Bool {
        didSet { defaults.set(autoLearnRevertedWords, forKey: Key.autoLearnRevertedWords) }
    }

    var showLayoutInMenuBar: Bool {
        didSet { defaults.set(showLayoutInMenuBar, forKey: Key.showLayoutInMenuBar) }
    }

    var excludedAppBundleIDs: Set<String> {
        didSet { defaults.set(Array(excludedAppBundleIDs).sorted(), forKey: Key.excludedAppBundleIDs) }
    }

    var wordExceptions: [String] {
        didSet { defaults.set(wordExceptions, forKey: Key.wordExceptions) }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Key {
        static let isEnabled = "switcher.isEnabled"
        static let midWordSwitchEnabled = "switcher.midWordSwitchEnabled"
        static let doubleCapsFixEnabled = "switcher.doubleCapsFixEnabled"
        static let autocorrectEnabled = "switcher.autocorrectEnabled"
        static let yofikatorEnabled = "switcher.yofikatorEnabled"
        static let manualTrigger = "switcher.manualTrigger"
        static let singleShiftEnabled = "switcher.singleShiftEnabled"
        static let splitShiftToggleEnabled = "switcher.splitShiftToggleEnabled"
        static let pastePlainTextEnabled = "switcher.pastePlainTextEnabled"
        static let pastePlainTextShortcut = "switcher.pastePlainTextShortcut"
        static let switchToEnglishInTerminals = "switcher.switchToEnglishInTerminals"
        static let useBuiltInAppExceptions = "switcher.useBuiltInAppExceptions"
        static let soundFeedbackEnabled = "switcher.soundFeedbackEnabled"
        static let soundName = "switcher.soundName"
        static let autoLearnRevertedWords = "switcher.autoLearnRevertedWords"
        static let showLayoutInMenuBar = "switcher.showLayoutInMenuBar"
        static let excludedAppBundleIDs = "switcher.excludedAppBundleIDs"
        static let wordExceptions = "switcher.wordExceptions"
        static let migratedFromCarambaV1 = "switcher.migratedFromCarambaV1"
    }

    private init() {
        isEnabled = defaults.object(forKey: Key.isEnabled) as? Bool ?? true
        midWordSwitchEnabled = defaults.object(forKey: Key.midWordSwitchEnabled) as? Bool ?? true
        doubleCapsFixEnabled = defaults.object(forKey: Key.doubleCapsFixEnabled) as? Bool ?? true
        autocorrectEnabled = defaults.object(forKey: Key.autocorrectEnabled) as? Bool ?? true
        yofikatorEnabled = defaults.object(forKey: Key.yofikatorEnabled) as? Bool ?? true
        manualTrigger = defaults.string(forKey: Key.manualTrigger)
            .flatMap(ManualSwitchTrigger.init(rawValue:)) ?? .both
        singleShiftEnabled = defaults.object(forKey: Key.singleShiftEnabled) as? Bool ?? false
        splitShiftToggleEnabled = defaults.object(forKey: Key.splitShiftToggleEnabled) as? Bool ?? true
        let storedShortcut = defaults.string(forKey: Key.pastePlainTextShortcut)
            .flatMap(PastePlainTextShortcut.init(rawValue:))
        let storedPasteEnabled = defaults.object(forKey: Key.pastePlainTextEnabled) as? Bool ?? true
        pastePlainTextShortcut = storedShortcut ?? (storedPasteEnabled ? .cmdShiftV : .off)
        pastePlainTextEnabled = storedShortcut.map { $0 != .off } ?? storedPasteEnabled
        switchToEnglishInTerminals = defaults.object(forKey: Key.switchToEnglishInTerminals) as? Bool ?? true
        useBuiltInAppExceptions = defaults.object(forKey: Key.useBuiltInAppExceptions) as? Bool ?? true
        soundFeedbackEnabled = defaults.object(forKey: Key.soundFeedbackEnabled) as? Bool ?? false
        soundName = defaults.string(forKey: Key.soundName) ?? "Tink"
        // Default false: reverting a word still protects it for the current session via
        // SwitcherPipeline.sessionExceptions without permanently polluting wordExceptions
        // with accidental typos.
        autoLearnRevertedWords = defaults.object(forKey: Key.autoLearnRevertedWords) as? Bool ?? false
        showLayoutInMenuBar = defaults.object(forKey: Key.showLayoutInMenuBar) as? Bool ?? true
        excludedAppBundleIDs = Set(defaults.stringArray(forKey: Key.excludedAppBundleIDs) ?? [])
        wordExceptions = defaults.stringArray(forKey: Key.wordExceptions) ?? []

        migrateFromCarambaIfNeeded()
    }

    /// Automatically imports user settings & exceptions from Caramba Switcher Pro on first run.
    func migrateFromCarambaIfNeeded() {
        guard !defaults.bool(forKey: Key.migratedFromCarambaV1) else { return }
        let summary = CarambaImporter.importAll()
        // Only lock in the migration flag if Caramba files were actually readable
        // (macOS TCC can block direct container reads when launched without app-data access).
        if summary.sourcePath != nil || summary.plistPath != nil {
            defaults.set(true, forKey: Key.migratedFromCarambaV1)
            applyImportedCaramba(summary)
        }
    }

    func applyImportedCaramba(_ summary: CarambaImportSummary) {
        for word in summary.words {
            addWordException(word)
        }
        if !summary.appBundleIDs.isEmpty {
            excludedAppBundleIDs.formUnion(summary.appBundleIDs)
        }
        if let s = summary.settings {
            if let v = s.autoEnabled { isEnabled = v }
            if let v = s.autocorrectOn { autocorrectEnabled = v }
            if let v = s.yofikatorOn { yofikatorEnabled = v }
            if let v = s.singleShiftEnabled { singleShiftEnabled = v }
            if let v = s.splitShiftEnabled { splitShiftToggleEnabled = v }
            if let v = s.soundsEnabled { soundFeedbackEnabled = v }
            if let altOn = s.altEnabled {
                // In Caramba, alt-enabled selects Option (leaving Single Shift with 0ms latency)
                // instead of Double Shift.
                manualTrigger = altOn ? .option : .doubleShift
            }
            if let shortcut = s.pastePlainTextShortcut {
                pastePlainTextShortcut = shortcut
            }
        }
    }

    func addWordException(_ word: String) {
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, !wordExceptions.contains(normalized) else { return }
        wordExceptions = (wordExceptions + [normalized]).sorted()
    }

    func removeWordException(_ word: String) {
        wordExceptions.removeAll { $0 == word }
    }

    func clearAllWordExceptions() {
        wordExceptions = []
    }

    func pipelineConfiguration() -> SwitcherConfiguration {
        SwitcherConfiguration(
            autoSwitchEnabled: isEnabled,
            midWordSwitchEnabled: midWordSwitchEnabled,
            doubleCapsFixEnabled: doubleCapsFixEnabled,
            autocorrectEnabled: autocorrectEnabled,
            yofikatorEnabled: yofikatorEnabled,
            userWordExceptions: Set(wordExceptions)
        )
    }
}

