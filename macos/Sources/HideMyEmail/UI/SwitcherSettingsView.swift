import AppKit
import LayoutSwitcherCore
import SwiftUI
import UniformTypeIdentifiers

struct LayoutSwitcherSettings: View {
    let switcher: SwitcherController
    @Bindable var prefs: SwitcherPreferences

    @State private var testerInput = "ghbdtn"
    @State private var testerLang: SwitcherLanguage = .english
    @State private var showDiagnostics = false
    @State private var newWord = ""
    @State private var selectedWord: String?
    @State private var selectedApp: String?
    @State private var importMessage: String?

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { !prefs.excludedAppBundleIDs.contains($0.bundleIdentifier ?? "") }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Form {
            Section("Automatic Switching") {
                Toggle("Enable Automatic Layout Switching", isOn: $prefs.isEnabled)
                Toggle("Switch Mid-Word While Typing", isOn: $prefs.midWordSwitchEnabled)
                    .disabled(!prefs.isEnabled)
                Toggle("Fix Double-Caps (ПРивет → Привет)", isOn: $prefs.doubleCapsFixEnabled)
                Toggle("Mistype Autocorrect", isOn: $prefs.autocorrectEnabled)
                Toggle("Yofikator (е → ё)", isOn: $prefs.yofikatorEnabled)
            }

            Section("Shortcuts & Gestures") {
                Picker("Switch Typed Word or Selection", selection: $prefs.manualTrigger) {
                    ForEach(ManualSwitchTrigger.allCases) { trigger in
                        Text(trigger.title).tag(trigger)
                    }
                }
                Toggle("Single Shift — Change Active Layout", isOn: $prefs.singleShiftEnabled)
                Toggle("Left Shift + Right Shift — Toggle Autoswitching", isOn: $prefs.splitShiftToggleEnabled)
                Picker("Paste Without Formatting Shortcut", selection: $prefs.pastePlainTextShortcut) {
                    ForEach(PastePlainTextShortcut.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
            }

            Section("Behavior") {
                Toggle("Switch to English in Terminals (Terminal, iTerm, Alacritty…)", isOn: $prefs.switchToEnglishInTerminals)
                Toggle("Remember Manually Reverted Words as Exceptions", isOn: $prefs.autoLearnRevertedWords)
                Toggle("Sound Feedback on Switch", isOn: $prefs.soundFeedbackEnabled)
                if prefs.soundFeedbackEnabled {
                    Picker("Switch Sound", selection: $prefs.soundName) {
                        ForEach(SwitcherPreferences.availableSounds, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .onChange(of: prefs.soundName) { _, newName in
                        if let sound = NSSound(named: NSSound.Name(newName)) {
                            sound.volume = 0.25
                            sound.play()
                        }
                    }
                }
                Toggle("Show Active Layout in Menu Bar", isOn: $prefs.showLayoutInMenuBar)
            }

            Section("Word Exceptions") {
                HStack(spacing: 8) {
                    TextField("Word to never auto-switch or autocorrect", text: $newWord)
                        .onSubmit(addWord)
                    Button("Add", action: addWord)
                        .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if prefs.wordExceptions.isEmpty {
                    Text("No custom word exceptions yet.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    List(prefs.wordExceptions, id: \.self, selection: $selectedWord) { word in
                        Text(word)
                    }
                    .frame(height: 96)

                    HStack {
                        if prefs.wordExceptions.count > 1 {
                            Button("Clear All", role: .destructive) {
                                prefs.clearAllWordExceptions()
                                self.selectedWord = nil
                            }
                            .controlSize(.small)
                        }
                        Spacer()
                        Button("Remove Selected", role: .destructive) {
                            if let selectedWord {
                                prefs.removeWordException(selectedWord)
                                self.selectedWord = nil
                            }
                        }
                        .disabled(selectedWord == nil)
                        .controlSize(.small)
                    }
                }
            }

            Section("App Exceptions") {
                Toggle("Use Built-In Caramba App Exceptions (486 rules: 1Password, games, IDEs…)", isOn: $prefs.useBuiltInAppExceptions)

                if !prefs.excludedAppBundleIDs.isEmpty {
                    List(prefs.excludedAppBundleIDs.sorted(), id: \.self, selection: $selectedApp) { id in
                        HStack(spacing: 8) {
                            AppIcon(bundleID: id)
                            Text(AppIcon.name(for: id))
                        }
                    }
                    .frame(height: 96)
                }

                HStack(spacing: 8) {
                    Menu {
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                                if let id = app.bundleIdentifier {
                                    prefs.excludedAppBundleIDs.insert(id)
                                }
                            }
                        }
                        if !runningApps.isEmpty {
                            Divider()
                        }
                        Button("Choose App…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.application]
                            panel.allowsMultipleSelection = false
                            panel.canChooseDirectories = false
                            panel.directoryURL = URL(fileURLWithPath: "/Applications")
                            panel.begin { response in
                                guard response == .OK,
                                      let url = panel.url,
                                      let bundle = Bundle(url: url),
                                      let bid = bundle.bundleIdentifier else { return }
                                Task { @MainActor in
                                    prefs.excludedAppBundleIDs.insert(bid)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Button {
                        if let selectedApp {
                            prefs.excludedAppBundleIDs.remove(selectedApp)
                            self.selectedApp = nil
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedApp == nil)
                    Spacer()

                    Button("Import from Caramba…") {
                        let result = switcher.importFromCaramba()
                        if result.sourcePath == nil && result.plistPath == nil {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent("Library/Containers/tech.caramba.switcher/Data/Library/Application Support/Caramba Switcher Pro")
                            panel.message = String(localized: "Select Caramba.sqlite to import saved word and app exceptions.")
                            panel.begin { response in
                                Task { @MainActor in
                                    if response == .OK, let url = panel.url {
                                        let picked = switcher.importFromCaramba(explicitPath: url.path)
                                        importMessage = String(localized: "Imported \(picked.words.count) words, \(picked.appBundleIDs.count) apps, and Caramba settings.")
                                    } else {
                                        importMessage = String(localized: "Caramba Switcher database was not found.")
                                    }
                                }
                            }
                        } else {
                            importMessage = String(localized: "Imported \(result.words.count) words, \(result.appBundleIDs.count) apps, and Caramba settings.")
                        }
                    }
                    .controlSize(.small)
                }
                .buttonStyle(.borderless)

                if let importMessage {
                    Text(importMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                DisclosureGroup("Live Engine Tester & Status", isExpanded: $showDiagnostics) {
                    HStack(spacing: 8) {
                        Picker("Typed in", selection: $testerLang) {
                            Text("English (EN)").tag(SwitcherLanguage.english)
                            Text("Russian (RU)").tag(SwitcherLanguage.russian)
                        }
                        .labelsHidden()
                        .frame(width: 120)

                        TextField("Enter word (e.g. ghbdtn, руддщ, tkrf, ПРивет, teh)", text: $testerInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    let trimmed = testerInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, let diag = switcher.diagnoseTestInput(trimmed, language: testerLang) {
                        LabeledContent("Result") {
                            HStack(spacing: 6) {
                                Text(diag.finalOutput)
                                    .font(.body.weight(.semibold))
                                    .textSelection(.enabled)
                                Text(diag.finalLanguage.shortLabel)
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.fill.tertiary, in: .capsule)
                            }
                        }
                        if let kbm = diag.kbm {
                            LabeledContent("KBM Scores") {
                                Text("RU: \(formatScore(kbm.ruScore)) · EN: \(formatScore(kbm.enScore))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if diag.skippedByFilter {
                            LabeledContent("Filter") {
                                Text("Protected token (password / URL / camelCase / exception)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    LabeledContent("Language Model") {
                        Text(switcher.isModelLoaded ? "Logos \(switcher.modelVersion) (88k KBM · 72k rules)" : "Not Loaded")
                            .foregroundStyle(switcher.isModelLoaded ? Color.secondary : Color.red)
                    }
                    LabeledContent("Keyboard Hook") {
                        if switcher.isEventTapActive {
                            Text("Active").foregroundStyle(.green)
                        } else {
                            Button("Restart Hook") { switcher.restartEventTap() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addWord() {
        prefs.addWordException(newWord)
        newWord = ""
    }

    private func formatScore(_ score: KbmCandidateScore) -> String {
        switch score {
        case .none: return "none"
        case .weighted(let w): return "\(w)"
        case .knownWord: return "known"
        case .collision: return "collision"
        }
    }
}

