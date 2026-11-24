import AppKit
import AutocompleteCore
import HideMyEmailCore
import LayoutSwitcherCore
import SnowpileCore
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable {
    case general
    case switcher
    case autocomplete
    case mail
    case duo
    case snow
}

struct SettingsView: View {
    let model: AppModel
    @Bindable var settings: Preferences
    let autocomplete: AutocompleteController
    let switcher: SwitcherController
    @Bindable var switcherPrefs: SwitcherPreferences
    let duo: DuoFoldController
    @Bindable var duoPrefs: DuoPreferences
    @ObservedObject var snow: SnowpileController
    @AppStorage("settings.selectedTab") private var selectedTabRaw: String = SettingsTab.general.rawValue

    private var selectedTab: Binding<SettingsTab> {
        Binding(
            get: { SettingsTab(rawValue: selectedTabRaw) ?? .general },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    var body: some View {
        TabView(selection: selectedTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettings(switcher: switcher, duo: duo)
            }
            Tab("Switcher", systemImage: "keyboard", value: SettingsTab.switcher) {
                LayoutSwitcherSettings(switcher: switcher, prefs: switcherPrefs)
            }
            Tab("Autocomplete", systemImage: "sparkles", value: SettingsTab.autocomplete) {
                AutocompleteSettings(autocomplete: autocomplete)
            }
            Tab("Mail", systemImage: "envelope.badge.shield.half.filled", value: SettingsTab.mail) {
                HideMyEmailSettings(model: model, settings: settings)
            }
            Tab("Mac Duo", systemImage: "laptopcomputer", value: SettingsTab.duo) {
                DuoSettingsView(controller: duo, prefs: duoPrefs)
            }
            Tab("Snow", systemImage: "snowflake", value: SettingsTab.snow) {
                SnowSettingsView(controller: snow, prefs: snow.preferences, weather: snow.weather)
            }
        }
        .frame(width: 660, height: 550)
    }
}

private struct GeneralSettings: View {
    let switcher: SwitcherController
    let duo: DuoFoldController
    @State private var launchesAtLogin = LaunchAtLogin.isEnabled
    @State private var isTrusted = AX.isTrusted

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open at Login", isOn: $launchesAtLogin)
                    .onChange(of: launchesAtLogin) { _, enabled in LaunchAtLogin.set(enabled) }
            }

            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if isTrusted {
                        Text("Allowed").foregroundStyle(.green)
                    } else {
                        Button("Allow…") {
                            AX.requestTrust()
                            AX.openAccessibilitySettings()
                        }
                    }
                }
                LabeledContent("Screen Recording") {
                    if duo.screenRecordingGranted {
                        Text("Allowed").foregroundStyle(.green)
                    } else {
                        Button("Allow…") {
                            DuoScreenRecordingPermission.request()
                            DuoScreenRecordingPermission.openSettings()
                        }
                    }
                }
            }

            Section("About") {
                LabeledContent("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")") {
                    Button("Check for Updates…") { Updates.controller.checkForUpdates(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            isTrusted = AX.isTrusted
            duo.refreshPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isTrusted = AX.isTrusted
            duo.refreshPermission()
            if isTrusted {
                FieldWatcher.shared.restart()
                AutocompleteController.shared.restartIfTrusted()
                switcher.restartEventTap()
            }
        }
    }
}

private struct HideMyEmailSettings: View {
    let model: AppModel
    @Bindable var settings: Preferences
    @State private var forwardTo = ""
    @State private var selection: String?

    private var running: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { !settings.excludedBundleIDs.contains($0.bundleIdentifier ?? "") }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Form {
            Section("iCloud Account") {
                Picker("iCloud", selection: Binding(get: { model.region }, set: { region in
                    guard region != model.region else { return }
                    model.signOut()
                    model.region = region
                    Task { await model.bootstrap() }
                })) {
                    Text("iCloud").tag(ICloudRegion.global)
                    Text("iCloud China").tag(ICloudRegion.china)
                }
                if model.state == .signedIn, !model.forwardToOptions.isEmpty {
                    Picker("Forward To", selection: $forwardTo) {
                        ForEach(model.forwardToOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: forwardTo) { _, email in
                        guard !email.isEmpty, email != model.forwardTo else { return }
                        Task { await model.setForwardTo(email) }
                    }
                }
                if model.state == .signedIn {
                    LabeledContent("Addresses", value: "\(model.addresses.count)")
                    Button("Sign Out", role: .destructive, action: model.signOut)
                } else {
                    Button("Sign In…") { model.signIn(with: BrowserCookies.safari) }
                }
                if let error = model.lastError {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section("Autofill Behavior") {
                Picker("Create and Fill Shortcut", selection: $settings.shortcut) {
                    ForEach(Shortcut.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.shortcut) { _, shortcut in
                    HotKey.shared.register(shortcut) { AppDelegate.createFromShortcut() }
                }
                Toggle("Suggest Addresses in Email Fields", isOn: $settings.showsSuggestions)
            }

            Section("No Suggestions In") {
                if settings.excludedBundleIDs.isEmpty {
                    Text("No excluded apps.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    List(selection: $selection) {
                        ForEach(settings.excludedBundleIDs.sorted(), id: \.self) { bundleID in
                            HStack(spacing: 8) {
                                AppIcon(bundleID: bundleID)
                                Text(AppIcon.name(for: bundleID))
                            }
                            .tag(bundleID)
                        }
                    }
                    .frame(minHeight: 96, maxHeight: 140)
                }
                HStack {
                    Menu {
                        ForEach(running, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                                if let id = app.bundleIdentifier { settings.excludedBundleIDs.insert(id) }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Button {
                        if let selection { settings.excludedBundleIDs.remove(selection) }
                        selection = nil
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selection == nil)
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .task {
            forwardTo = model.forwardTo
            if model.state == .signedIn, model.forwardToOptions.isEmpty { await model.refresh() }
            forwardTo = model.forwardTo
        }
        .onChange(of: settings.excludedBundleIDs) { _, _ in FieldWatcher.shared.restart() }
    }
}

private struct AutocompleteSettings: View {
    let autocomplete: AutocompleteController
    @State private var selection: String?
    @State private var learningSelection: String?
    @State private var selectedPerAppBundleID: String = ""
    @State private var showAdvancedPrompts = false
    @State private var showLoraSection = false
    @State private var showLearningExclusions = false
    @State private var exportStatusMessage: String?

    private var prefs: AutocompletePreferences { autocomplete.preferences }

    private var isModelLoaded: Bool {
        if case .ready = autocomplete.engineState { return true }
        return false
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { !prefs.excludedBundleIDs.contains($0.bundleIdentifier ?? "") }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private var runningLearningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { !prefs.learningExcludedBundleIDs.contains($0.bundleIdentifier ?? "") }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private var perAppCandidates: [(bundleID: String, name: String)] {
        var map: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
                map[id] = app.localizedName ?? id
            }
        }
        if let lastID = autocomplete.lastExternalBundleID {
            map[lastID] = autocomplete.lastExternalAppName ?? AppIcon.name(for: lastID)
        }
        for id in prefs.perAppPrompts.keys {
            map[id] = map[id] ?? AppIcon.name(for: id)
        }
        return map.map { ($0.key, $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var missingCuratedDownloads: [DownloadableModel] {
        let installedFilenames = Set(autocomplete.availableModels.map { $0.filename.lowercased() })
        return ModelCatalog.curatedDownloads.filter { !installedFilenames.contains($0.filename.lowercased()) }
    }

    var body: some View {
        @Bindable var prefs = autocomplete.preferences
        Form {
            Section {
                Toggle("Enable Inline Autocomplete", isOn: Binding(
                    get: { prefs.isEnabled },
                    set: { autocomplete.setEnabled($0) }
                ))
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        statusBadge
                        if isModelLoaded {
                            Button("Unload Now") {
                                autocomplete.unloadModelNow()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                Picker("Auto-Unload When Idle", selection: $prefs.idleUnloadDelay) {
                    ForEach(IdleUnloadDelay.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            }

            Section("Text Polish (Wispr Style)") {
                Toggle("Enable Text Polish (Typos, Grammar & Commas)", isOn: $prefs.polishEnabled)
                Toggle("Auto-Fix Past Text on Pause (Caps, Commas & Typos)", isOn: $prefs.autoPolishEnabled)
                    .disabled(!prefs.polishEnabled)
                if prefs.polishEnabled && prefs.autoPolishEnabled {
                    HStack {
                        Text("Auto-Fix Pause")
                        Slider(
                            value: Binding(
                                get: { Double(prefs.autoPolishDelayMs) },
                                set: { prefs.autoPolishDelayMs = Int($0.rounded()) }
                            ),
                            in: 800...2500,
                            step: 100
                        )
                        Text(String(format: "%.1f s", Double(prefs.autoPolishDelayMs) / 1000.0))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }
                Picker("Polish Shortcut", selection: $prefs.polishShortcut) {
                    ForEach(PolishShortcut.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!prefs.polishEnabled)
                Picker("Polish Style", selection: $prefs.polishStyle) {
                    ForEach(TextPolishStyle.allCases) { Text($0.displayTitle).tag($0) }
                }
                .disabled(!prefs.polishEnabled)
                Text("Automatically fixes past text on a brief pause (or anytime via shortcut): typos, wrong layout (lbrndrf → диктовка), capitalization, and commas. Skips code editors and terminals. Press ⌘Z to undo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local Model (< 1 GB RAM)") {
                if autocomplete.availableModels.isEmpty {
                    Text("No local GGUF models detected yet. Download one below or choose a local .gguf file.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Active Model", selection: Binding(
                        get: { autocomplete.selectedModel?.id ?? "" },
                        set: { newID in
                            if let model = autocomplete.availableModels.first(where: { $0.id == newID }) {
                                autocomplete.selectModel(model)
                            }
                        }
                    )) {
                        ForEach(autocomplete.availableModels) { model in
                            Text(modelLabel(model)).tag(model.id)
                        }
                    }
                }

                HStack {
                    Button("Add GGUF File…") { pickCustomModel() }
                    Button("Open Folder") { autocomplete.openModelsFolder() }
                    Button("Refresh") { autocomplete.refreshModels() }
                    Spacer()
                    Button("Preview Overlay") { autocomplete.showDemoPreview() }
                }

                DisclosureGroup("LoRA Fine-Tune Adapter (.gguf)", isExpanded: $showLoraSection) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            if let path = prefs.loraAdapterPath {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text("No LoRA adapter selected")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Choose LoRA…") { pickLoraAdapter() }
                                .controlSize(.small)
                            if prefs.loraAdapterPath != nil {
                                Button("Clear") { autocomplete.clearLoraAdapter() }
                                    .controlSize(.small)
                            }
                        }
                        if prefs.loraAdapterPath != nil {
                            HStack {
                                Text("Adapter Strength")
                                Slider(value: $prefs.loraScale, in: 0.1...1.5, step: 0.1)
                                Text(String(format: "%.1f×", prefs.loraScale))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                        Text("Load a custom GGUF LoRA adapter trained on your exported writing data to fine-tune the active model locally.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                if !missingCuratedDownloads.isEmpty {
                    ForEach(missingCuratedDownloads) { preset in
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(preset.name) (\(preset.approxSizeLabel))")
                                    .font(.callout.weight(.medium))
                                Text(preset.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if autocomplete.downloadingModelID == preset.id {
                                ProgressView(value: autocomplete.downloadProgress)
                                    .frame(width: 72)
                                Button("Cancel") { autocomplete.cancelDownload() }
                                    .controlSize(.small)
                            } else {
                                Button("Download") { autocomplete.downloadModel(preset) }
                                    .disabled(autocomplete.downloadingModelID != nil)
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                if let error = autocomplete.lastDownloadError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Shortcuts & Behavior") {
                Picker("Trigger Mode", selection: $prefs.triggerMode) {
                    ForEach(TriggerMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Manual Invoke Shortcut", selection: $prefs.invokeShortcut) {
                    ForEach(InvokeShortcut.allCases) { Text($0.title).tag($0) }
                }
                Picker("Accept Suggestion", selection: $prefs.acceptShortcut) {
                    ForEach(AcceptShortcut.allCases) { Text($0.title).tag($0) }
                }
                Picker("Accept Next Word", selection: $prefs.acceptWordShortcut) {
                    ForEach(AcceptWordShortcut.allCases) { Text($0.title).tag($0) }
                }
                Picker("Max Completion Length", selection: $prefs.maxCompletionLength) {
                    ForEach(CompletionLengthPreset.allCases) { Text($0.displayTitle).tag($0) }
                }
                Picker("Word Alternatives (Synonyms)", selection: $prefs.synonymsShortcut) {
                    ForEach(SynonymsShortcut.allCases) { Text($0.title).tag($0) }
                }
                Picker("Escape Key", selection: $prefs.escapeBehavior) {
                    ForEach(EscapeBehavior.allCases) { Text($0.title).tag($0) }
                }
                Picker("Trailing Punctuation", selection: $prefs.trailingPunctuationMode) {
                    ForEach(TrailingPunctuationMode.allCases) { Text($0.displayTitle).tag($0) }
                }
                Toggle("Allow Mid-Line Suggestions", isOn: $prefs.allowMidLine)
                Toggle("Emoji Shortcodes (:fire:)", isOn: $prefs.emojiSuggestions)
                if prefs.emojiSuggestions {
                    Picker("Emoji Skin Tone", selection: $prefs.emojiSkinTone) {
                        ForEach(EmojiSkinTone.allCases) { Text($0.displayTitle).tag($0) }
                    }
                }
                Toggle("Gentle Autocorrect", isOn: $prefs.autocorrectEnabled)
                Toggle("Use Screen Context (Active Window)", isOn: $prefs.useScreenContext)
                Toggle("Use Clipboard Context", isOn: $prefs.useClipboardContext)
                Toggle("Show Shortcut Hint Inline", isOn: $prefs.showShortcutHints)
                HStack {
                    Text("Trigger Delay")
                    Slider(
                        value: Binding(
                            get: { Double(prefs.debounceMilliseconds) },
                            set: { prefs.debounceMilliseconds = Int($0.rounded()) }
                        ),
                        in: 100...600,
                        step: 20
                    )
                    .disabled(prefs.triggerMode == .onShortcutOnly)
                    Text("\(prefs.debounceMilliseconds) ms")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }

            Section("Learning, Personalization & Statistics") {
                HStack {
                    Text("Personalization Strength")
                    Slider(
                        value: Binding(
                            get: { prefs.personalizationStrength.sliderIndex },
                            set: { prefs.personalizationStrength = PersonalizationStrength.from(sliderIndex: $0) }
                        ),
                        in: 0...3,
                        step: 1
                    )
                    Text(prefs.personalizationStrength.displayTitle)
                        .foregroundStyle(.secondary)
                        .frame(width: 66, alignment: .trailing)
                }
                Toggle("Learn From All Typing (Local Only)", isOn: $prefs.recordAllTyping)
                    .disabled(prefs.personalizationStrength == .off)
                Toggle("Personalize Word Choice", isOn: $prefs.personalizeWordChoice)
                    .disabled(prefs.personalizationStrength == .off)

                VStack(alignment: .leading, spacing: 3) {
                    let stats = autocomplete.completionStats
                    Text("Accepted: \(stats.completionsAccepted) · Saved: \(stats.wordsAccepted) words (\(stats.charactersSaved) chars)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text("Writing samples: \(autocomplete.recordedStyleSampleCount) · Learned words: \(autocomplete.learnedWordCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack(spacing: 8) {
                    Button("Export Training Data…") { exportTrainingJSONL() }
                        .controlSize(.small)
                        .disabled(autocomplete.recordedStyleSampleCount == 0)
                    Button("Import from Cotypist") {
                        exportStatusMessage = autocomplete.importFromCotypist()
                    }
                    .controlSize(.small)
                    Spacer()
                    Button("Clear History", role: .destructive) {
                        autocomplete.clearTypingHistory()
                    }
                    .controlSize(.small)
                    .disabled(autocomplete.recordedStyleSampleCount == 0 && autocomplete.learnedWordCount == 0)
                }

                if let status = exportStatusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Custom AI Instructions", isExpanded: $showAdvancedPrompts) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: $prefs.userPrompt)
                            .font(.callout)
                            .frame(minHeight: 54, maxHeight: 84)
                        HStack {
                            Text("Applies across all apps. Imported from Cotypist when available.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset Default") {
                                prefs.userPrompt = ModelCatalog.defaultUserPrompt
                            }
                            .controlSize(.small)
                        }
                    }

                    if !perAppCandidates.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("Per-App Instructions", selection: $selectedPerAppBundleID) {
                                Text("Select an app…").tag("")
                                ForEach(perAppCandidates, id: \.bundleID) { item in
                                    let hasCustom = !(prefs.perAppPrompts[item.bundleID] ?? "").isEmpty
                                    Text(hasCustom ? "\(item.name) •" : item.name).tag(item.bundleID)
                                }
                            }
                            if !selectedPerAppBundleID.isEmpty {
                                TextEditor(text: Binding(
                                    get: { prefs.promptForApp(selectedPerAppBundleID) },
                                    set: { prefs.setPrompt($0, forApp: selectedPerAppBundleID) }
                                ))
                                .font(.callout)
                                .frame(minHeight: 44, maxHeight: 72)
                            }
                        }
                    }
                }

                DisclosureGroup("Do Not Learn In Apps (\(prefs.learningExcludedBundleIDs.count))", isExpanded: $showLearningExclusions) {
                    VStack(alignment: .leading, spacing: 6) {
                        if prefs.learningExcludedBundleIDs.isEmpty {
                            Text("No learning-excluded apps. Autocomplete still works in excluded learning apps, but typing there is never recorded.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            List(selection: $learningSelection) {
                                ForEach(prefs.learningExcludedBundleIDs.sorted(), id: \.self) { bundleID in
                                    HStack(spacing: 8) {
                                        AppIcon(bundleID: bundleID)
                                        Text(AppIcon.name(for: bundleID))
                                    }
                                    .tag(bundleID)
                                }
                            }
                            .frame(minHeight: 72, maxHeight: 110)
                        }
                        HStack {
                            Menu {
                                ForEach(runningLearningApps, id: \.processIdentifier) { app in
                                    Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                                        if let id = app.bundleIdentifier { prefs.learningExcludedBundleIDs.insert(id) }
                                    }
                                }
                            } label: {
                                Image(systemName: "plus")
                            }
                            .menuIndicator(.hidden)
                            .fixedSize()
                            Button {
                                if let learningSelection { prefs.learningExcludedBundleIDs.remove(learningSelection) }
                                learningSelection = nil
                            } label: {
                                Image(systemName: "minus")
                            }
                            .disabled(learningSelection == nil)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.top, 4)
                }
            }

            Section("No Autocomplete In") {
                List(selection: $selection) {
                    ForEach(prefs.excludedBundleIDs.sorted(), id: \.self) { bundleID in
                        HStack(spacing: 8) {
                            AppIcon(bundleID: bundleID)
                            Text(AppIcon.name(for: bundleID))
                        }
                        .tag(bundleID)
                    }
                }
                .frame(minHeight: 96, maxHeight: 130)
                HStack {
                    Menu {
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                                if let id = app.bundleIdentifier { prefs.excludedBundleIDs.insert(id) }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Button {
                        if let selection { prefs.excludedBundleIDs.remove(selection) }
                        selection = nil
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selection == nil)
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .onAppear { autocomplete.refreshModels() }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch autocomplete.engineState {
        case .disabled:
            Text("Off").foregroundStyle(.secondary)
        case .noModel:
            Text("No Model").foregroundStyle(.orange)
        case .idle(let name):
            Text("\(name) · Unloaded (0 MB)").foregroundStyle(.secondary)
        case .loading(let name):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading \(name)…").foregroundStyle(.secondary)
            }
        case .ready(let name, let usingGPU):
            let hw = usingGPU ? "Metal GPU" : "CPU"
            let mem = autocomplete.loadedMemoryMB.map { "~\($0) MB · " } ?? ""
            let lora = autocomplete.isLoraActive ? " · LoRA" : ""
            Text("\(name) · \(mem)\(hw)\(lora)")
                .foregroundStyle(.green)
        case .error(let message):
            Text(message).foregroundStyle(.red).lineLimit(2)
        }
    }

    private func modelLabel(_ model: LocalModel) -> String {
        let sourceTag: String
        switch model.source {
        case .cotypistModels: sourceTag = "Cotypist"
        case .appModels: sourceTag = String(localized: "Local")
        case .custom: sourceTag = String(localized: "Custom")
        }
        return "\(model.name) — \(model.formattedSize) (\(sourceTag))"
    }

    private func pickCustomModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Add Model")
        if panel.runModal() == .OK, let url = panel.url {
            autocomplete.addCustomModel(url: url)
        }
    }

    private func pickLoraAdapter() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Select LoRA")
        if panel.runModal() == .OK, let url = panel.url {
            autocomplete.selectLoraAdapter(url: url)
        }
    }

    private func exportTrainingJSONL() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .plainText]
        panel.nameFieldStringValue = "keyveil-writing-style.jsonl"
        panel.prompt = String(localized: "Export")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let count = try autocomplete.exportTrainingData(to: url)
                exportStatusMessage = String(localized: "Exported \(count) samples to \(url.lastPathComponent)")
            } catch {
                exportStatusMessage = error.localizedDescription
            }
        }
    }
}

struct AppIcon: View {
    let bundleID: String

    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(for bundleID: String) -> String {
        url(for: bundleID).map { FileManager.default.displayName(atPath: $0.path) }?
            .replacingOccurrences(of: ".app", with: "") ?? bundleID
    }

    var body: some View {
        Group {
            if let url = Self.url(for: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                Image(systemName: "app")
            }
        }
        .frame(width: 20, height: 20)
    }
}
