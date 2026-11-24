import AutocompleteCore
import Carbon.HIToolbox
import Foundation
import Observation

enum AcceptShortcut: String, CaseIterable, Identifiable {
    case tab
    case optionTab
    case shiftTab
    case controlSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tab: "Tab ⇥"
        case .optionTab: "⌥Tab"
        case .shiftTab: "⇧Tab"
        case .controlSpace: "⌃Space"
        }
    }

    var badge: String {
        switch self {
        case .tab: "⇥"
        case .optionTab: "⌥⇥"
        case .shiftTab: "⇧⇥"
        case .controlSpace: "⌃␣"
        }
    }

    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let relevant = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        switch self {
        case .tab:
            return keyCode == Int64(kVK_Tab) && relevant.isEmpty
        case .optionTab:
            return keyCode == Int64(kVK_Tab) && relevant == .maskAlternate
        case .shiftTab:
            return keyCode == Int64(kVK_Tab) && relevant == .maskShift
        case .controlSpace:
            return keyCode == Int64(kVK_Space) && relevant == .maskControl
        }
    }
}

enum AcceptWordShortcut: String, CaseIterable, Identifiable {
    case optionRight
    case optionTab
    case shiftTab
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionRight: "⌥→"
        case .optionTab: "⌥Tab"
        case .shiftTab: "⇧Tab"
        case .off: String(localized: "Off")
        }
    }

    var badge: String? {
        switch self {
        case .optionRight: "⌥→"
        case .optionTab: "⌥⇥"
        case .shiftTab: "⇧⇥"
        case .off: nil
        }
    }

    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let relevant = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        switch self {
        case .optionRight:
            return keyCode == Int64(kVK_RightArrow) && relevant == .maskAlternate
        case .optionTab:
            return keyCode == Int64(kVK_Tab) && relevant == .maskAlternate
        case .shiftTab:
            return keyCode == Int64(kVK_Tab) && relevant == .maskShift
        case .off:
            return false
        }
    }
}

extension TrailingPunctuationMode {
    var displayTitle: String {
        switch self {
        case .neither: return String(localized: "Never")
        case .fullCompletionsOnly: return String(localized: "Only with full completion")
        case .both: return String(localized: "With both shortcuts")
        }
    }
}

extension PersonalizationStrength {
    var displayTitle: String {
        switch self {
        case .off: return String(localized: "Off")
        case .gentle: return String(localized: "Gentle")
        case .balanced: return String(localized: "Balanced")
        case .strong: return String(localized: "Strong")
        }
    }
}

enum PolishShortcut: String, CaseIterable, Identifiable {
    case optionShiftP
    case controlOptionP
    case controlOptionSpace
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionShiftP: "⌥⇧P"
        case .controlOptionP: "⌃⌥P"
        case .controlOptionSpace: "⌃⌥Space"
        case .off: String(localized: "Off")
        }
    }

    var badge: String? {
        switch self {
        case .optionShiftP: "⌥⇧P"
        case .controlOptionP: "⌃⌥P"
        case .controlOptionSpace: "⌃⌥␣"
        case .off: nil
        }
    }

    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let relevant = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        switch self {
        case .optionShiftP:
            return keyCode == Int64(kVK_ANSI_P) && relevant == [.maskAlternate, .maskShift]
        case .controlOptionP:
            return keyCode == Int64(kVK_ANSI_P) && relevant == [.maskControl, .maskAlternate]
        case .controlOptionSpace:
            return keyCode == Int64(kVK_Space) && relevant == [.maskControl, .maskAlternate]
        case .off:
            return false
        }
    }
}

enum IdleUnloadDelay: Int, CaseIterable, Identifiable {
    case thirtySeconds = 30
    case fortyFiveSeconds = 45
    case twoMinutes = 120
    case fiveMinutes = 300

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .thirtySeconds: return String(localized: "30 seconds")
        case .fortyFiveSeconds: return String(localized: "45 seconds")
        case .twoMinutes: return String(localized: "2 minutes")
        case .fiveMinutes: return String(localized: "5 minutes")
        }
    }
}

enum TriggerMode: String, CaseIterable, Identifiable {
    case afterPause
    case onShortcutOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .afterPause: return String(localized: "After a short pause")
        case .onShortcutOnly: return String(localized: "Only on shortcut")
        }
    }
}

enum InvokeShortcut: String, CaseIterable, Identifiable {
    case optionSpace
    case controlSpace
    case optionShiftSpace
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionSpace: "⌥Space"
        case .controlSpace: "⌃Space"
        case .optionShiftSpace: "⌥⇧Space"
        case .off: String(localized: "Off")
        }
    }

    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let relevant = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        switch self {
        case .optionSpace:
            return keyCode == Int64(kVK_Space) && relevant == .maskAlternate
        case .controlSpace:
            return keyCode == Int64(kVK_Space) && relevant == .maskControl
        case .optionShiftSpace:
            return keyCode == Int64(kVK_Space) && relevant == [.maskAlternate, .maskShift]
        case .off:
            return false
        }
    }
}

enum EscapeBehavior: String, CaseIterable, Identifiable {
    case dismissAndPause
    case dismiss
    case passThrough

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dismissAndPause: return String(localized: "Dismiss & pause 5s")
        case .dismiss: return String(localized: "Dismiss once")
        case .passThrough: return String(localized: "Pass Escape to app")
        }
    }
}

enum SynonymsShortcut: String, CaseIterable, Identifiable {
    case optionShiftS
    case controlOptionS
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionShiftS: "⌥⇧S"
        case .controlOptionS: "⌃⌥S"
        case .off: String(localized: "Off")
        }
    }

    var badge: String? {
        switch self {
        case .optionShiftS: "⌥⇧S"
        case .controlOptionS: "⌃⌥S"
        case .off: nil
        }
    }

    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let relevant = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        switch self {
        case .optionShiftS:
            return keyCode == Int64(kVK_ANSI_S) && relevant == [.maskAlternate, .maskShift]
        case .controlOptionS:
            return keyCode == Int64(kVK_ANSI_S) && relevant == [.maskControl, .maskAlternate]
        case .off:
            return false
        }
    }
}

extension CompletionLengthPreset {
    var displayTitle: String {
        switch self {
        case .currentWord: return String(localized: "Current word only")
        case .short: return String(localized: "Short (phrase)")
        case .medium: return String(localized: "Medium (sentence)")
        case .long: return String(localized: "Long (1–2 sentences)")
        }
    }
}

extension EmojiSkinTone {
    var displayTitle: String {
        switch self {
        case .none: return String(localized: "Default (Yellow)")
        case .light: return String(localized: "Light 🏻")
        case .mediumLight: return String(localized: "Medium-Light 🏼")
        case .medium: return String(localized: "Medium 🏽")
        case .mediumDark: return String(localized: "Medium-Dark 🏾")
        case .dark: return String(localized: "Dark 🏿")
        }
    }
}

extension TextPolishStyle {
    var displayTitle: String {
        switch self {
        case .clean: return String(localized: "Clean & Natural")
        case .agents: return String(localized: "Clear for Chats & Agents")
        case .formal: return String(localized: "Polite & Formal")
        }
    }
}

@MainActor
@Observable
final class AutocompletePreferences {
    static let shared = AutocompletePreferences()

    static let defaultExcludedBundleIDs: Set<String> = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.1password.1password",
        "com.bitwarden.desktop",
    ]

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: "autocomplete.enabled") }
    }

    var selectedModelPath: String? {
        didSet { defaults.set(selectedModelPath, forKey: "autocomplete.selectedModelPath") }
    }

    var customModelPaths: [String] {
        didSet { defaults.set(customModelPaths, forKey: "autocomplete.customModelPaths") }
    }

    var userPrompt: String {
        didSet { defaults.set(userPrompt, forKey: "autocomplete.userPrompt") }
    }

    var perAppPrompts: [String: String] {
        didSet { defaults.set(perAppPrompts, forKey: "autocomplete.perAppPrompts") }
    }

    var personalizationStrength: PersonalizationStrength {
        didSet { defaults.set(personalizationStrength.rawValue, forKey: "autocomplete.personalizationStrength") }
    }

    var recordAllTyping: Bool {
        didSet { defaults.set(recordAllTyping, forKey: "autocomplete.recordAllTyping") }
    }

    var trailingPunctuationMode: TrailingPunctuationMode {
        didSet { defaults.set(trailingPunctuationMode.rawValue, forKey: "autocomplete.trailingPunctuationMode") }
    }

    /// Off by default (matching Cotypist's `AccessoryButtonsViewController_enabled = 0`).
    var showShortcutHints: Bool {
        didSet { defaults.set(showShortcutHints, forKey: "autocomplete.showShortcutHints") }
    }

    var acceptShortcut: AcceptShortcut {
        didSet { defaults.set(acceptShortcut.rawValue, forKey: "autocomplete.acceptShortcut") }
    }

    var acceptWordShortcut: AcceptWordShortcut {
        didSet { defaults.set(acceptWordShortcut.rawValue, forKey: "autocomplete.acceptWordShortcut") }
    }

    var allowMidLine: Bool {
        didSet { defaults.set(allowMidLine, forKey: "autocomplete.allowMidLine") }
    }

    var emojiSuggestions: Bool {
        didSet { defaults.set(emojiSuggestions, forKey: "autocomplete.emojiSuggestions") }
    }

    var autocorrectEnabled: Bool {
        didSet { defaults.set(autocorrectEnabled, forKey: "autocomplete.autocorrectEnabled") }
    }

    var useClipboardContext: Bool {
        didSet { defaults.set(useClipboardContext, forKey: "autocomplete.useClipboardContext") }
    }

    var useScreenContext: Bool {
        didSet { defaults.set(useScreenContext, forKey: "autocomplete.useScreenContext") }
    }

    var debounceMilliseconds: Int {
        didSet { defaults.set(debounceMilliseconds, forKey: "autocomplete.debounceMs") }
    }

    var idleUnloadDelay: IdleUnloadDelay {
        didSet { defaults.set(idleUnloadDelay.rawValue, forKey: "autocomplete.idleUnloadSeconds") }
    }

    var polishEnabled: Bool {
        didSet { defaults.set(polishEnabled, forKey: "autocomplete.polishEnabled") }
    }

    var autoPolishEnabled: Bool {
        didSet { defaults.set(autoPolishEnabled, forKey: "autocomplete.autoPolishEnabled") }
    }

    var autoPolishDelayMs: Int {
        didSet { defaults.set(autoPolishDelayMs, forKey: "autocomplete.autoPolishDelayMs") }
    }

    var polishShortcut: PolishShortcut {
        didSet { defaults.set(polishShortcut.rawValue, forKey: "autocomplete.polishShortcut") }
    }

    var polishStyle: TextPolishStyle {
        didSet { defaults.set(polishStyle.rawValue, forKey: "autocomplete.polishStyle") }
    }

    var excludedBundleIDs: Set<String> {
        didSet { defaults.set(Array(excludedBundleIDs), forKey: "autocomplete.excludedBundleIDs") }
    }

    var triggerMode: TriggerMode {
        didSet { defaults.set(triggerMode.rawValue, forKey: "autocomplete.triggerMode") }
    }

    var invokeShortcut: InvokeShortcut {
        didSet { defaults.set(invokeShortcut.rawValue, forKey: "autocomplete.invokeShortcut") }
    }

    var escapeBehavior: EscapeBehavior {
        didSet { defaults.set(escapeBehavior.rawValue, forKey: "autocomplete.escapeBehavior") }
    }

    var synonymsShortcut: SynonymsShortcut {
        didSet { defaults.set(synonymsShortcut.rawValue, forKey: "autocomplete.synonymsShortcut") }
    }

    var maxCompletionLength: CompletionLengthPreset {
        didSet { defaults.set(maxCompletionLength.rawValue, forKey: "autocomplete.maxCompletionLength") }
    }

    var personalizeWordChoice: Bool {
        didSet { defaults.set(personalizeWordChoice, forKey: "autocomplete.personalizeWordChoice") }
    }

    var learningExcludedBundleIDs: Set<String> {
        didSet { defaults.set(Array(learningExcludedBundleIDs), forKey: "autocomplete.learningExcludedBundleIDs") }
    }

    var emojiSkinTone: EmojiSkinTone {
        didSet { defaults.set(emojiSkinTone.rawValue, forKey: "autocomplete.emojiSkinTone") }
    }

    var loraAdapterPath: String? {
        didSet { defaults.set(loraAdapterPath, forKey: "autocomplete.loraAdapterPath") }
    }

    var loraScale: Double {
        didSet { defaults.set(loraScale, forKey: "autocomplete.loraScale") }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        isEnabled = defaults.object(forKey: "autocomplete.enabled") as? Bool ?? true
        selectedModelPath = defaults.string(forKey: "autocomplete.selectedModelPath")
        customModelPaths = defaults.stringArray(forKey: "autocomplete.customModelPaths") ?? []
        if let savedPrompt = defaults.string(forKey: "autocomplete.userPrompt") {
            userPrompt = savedPrompt
        } else {
            let imported = ModelCatalog.importedCotypistUserPrompt() ?? ModelCatalog.defaultUserPrompt
            userPrompt = imported
            defaults.set(imported, forKey: "autocomplete.userPrompt")
        }
        perAppPrompts = defaults.dictionary(forKey: "autocomplete.perAppPrompts") as? [String: String] ?? [:]
        personalizationStrength = defaults.string(forKey: "autocomplete.personalizationStrength")
            .flatMap(PersonalizationStrength.init(rawValue:)) ?? .balanced
        recordAllTyping = defaults.object(forKey: "autocomplete.recordAllTyping") as? Bool ?? true
        trailingPunctuationMode = defaults.string(forKey: "autocomplete.trailingPunctuationMode")
            .flatMap(TrailingPunctuationMode.init(rawValue:)) ?? .fullCompletionsOnly
        showShortcutHints = defaults.object(forKey: "autocomplete.showShortcutHints") as? Bool ?? false
        acceptShortcut = defaults.string(forKey: "autocomplete.acceptShortcut")
            .flatMap(AcceptShortcut.init(rawValue:)) ?? .tab
        acceptWordShortcut = defaults.string(forKey: "autocomplete.acceptWordShortcut")
            .flatMap(AcceptWordShortcut.init(rawValue:)) ?? .optionRight
        allowMidLine = defaults.object(forKey: "autocomplete.allowMidLine") as? Bool ?? true
        emojiSuggestions = defaults.object(forKey: "autocomplete.emojiSuggestions") as? Bool ?? true
        autocorrectEnabled = defaults.object(forKey: "autocomplete.autocorrectEnabled") as? Bool ?? true
        useClipboardContext = defaults.object(forKey: "autocomplete.useClipboardContext") as? Bool ?? false
        useScreenContext = defaults.object(forKey: "autocomplete.useScreenContext") as? Bool ?? true
        let storedDebounce = defaults.integer(forKey: "autocomplete.debounceMs")
        debounceMilliseconds = storedDebounce >= 80 ? storedDebounce : 220
        idleUnloadDelay = IdleUnloadDelay(rawValue: defaults.integer(forKey: "autocomplete.idleUnloadSeconds")) ?? .fortyFiveSeconds
        polishEnabled = defaults.object(forKey: "autocomplete.polishEnabled") as? Bool ?? true
        autoPolishEnabled = defaults.object(forKey: "autocomplete.autoPolishEnabled") as? Bool ?? true
        let storedAutoPolishDelay = defaults.integer(forKey: "autocomplete.autoPolishDelayMs")
        autoPolishDelayMs = storedAutoPolishDelay >= 600 ? storedAutoPolishDelay : 1300
        polishShortcut = defaults.string(forKey: "autocomplete.polishShortcut")
            .flatMap(PolishShortcut.init(rawValue:)) ?? .optionShiftP
        polishStyle = defaults.string(forKey: "autocomplete.polishStyle")
            .flatMap(TextPolishStyle.init(rawValue:)) ?? .agents
        excludedBundleIDs = (defaults.array(forKey: "autocomplete.excludedBundleIDs") as? [String]).map(Set.init)
            ?? Self.defaultExcludedBundleIDs
        triggerMode = defaults.string(forKey: "autocomplete.triggerMode")
            .flatMap(TriggerMode.init(rawValue:)) ?? .afterPause
        invokeShortcut = defaults.string(forKey: "autocomplete.invokeShortcut")
            .flatMap(InvokeShortcut.init(rawValue:)) ?? .optionSpace
        escapeBehavior = defaults.string(forKey: "autocomplete.escapeBehavior")
            .flatMap(EscapeBehavior.init(rawValue:)) ?? .dismissAndPause
        synonymsShortcut = defaults.string(forKey: "autocomplete.synonymsShortcut")
            .flatMap(SynonymsShortcut.init(rawValue:)) ?? .optionShiftS
        maxCompletionLength = defaults.string(forKey: "autocomplete.maxCompletionLength")
            .flatMap(CompletionLengthPreset.init(rawValue:)) ?? .medium
        personalizeWordChoice = defaults.object(forKey: "autocomplete.personalizeWordChoice") as? Bool ?? true
        learningExcludedBundleIDs = (defaults.array(forKey: "autocomplete.learningExcludedBundleIDs") as? [String]).map(Set.init) ?? []
        emojiSkinTone = defaults.string(forKey: "autocomplete.emojiSkinTone")
            .flatMap(EmojiSkinTone.init(rawValue:)) ?? .none
        loraAdapterPath = defaults.string(forKey: "autocomplete.loraAdapterPath")
        let storedScale = defaults.object(forKey: "autocomplete.loraScale") as? Double
        loraScale = storedScale ?? 1.0
    }

    func promptForApp(_ bundleID: String?) -> String {
        guard let bundleID else { return "" }
        return perAppPrompts[bundleID] ?? ""
    }

    func setPrompt(_ text: String, forApp bundleID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = perAppPrompts
        if trimmed.isEmpty {
            updated.removeValue(forKey: bundleID)
        } else {
            updated[bundleID] = trimmed
        }
        perAppPrompts = updated
    }
}
