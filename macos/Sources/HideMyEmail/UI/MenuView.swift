import AppKit
import HideMyEmailCore
import LayoutSwitcherCore
import SafariServices
import SnowpileCore
import SwiftUI

private enum MenuWorkspace: String, CaseIterable {
    case switcher
    case hideMyEmail
    case duo
    case snow
}

struct MenuView: View {
    let model: AppModel
    let autocomplete: AutocompleteController
    let switcher: SwitcherController
    let duo: DuoFoldController
    @Bindable var duoPrefs: DuoPreferences
    @ObservedObject var snow: SnowpileController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @AppStorage("menu.selectedWorkspace") private var workspace: MenuWorkspace = .switcher
    @AppStorage("settings.selectedTab") private var selectedSettingsTab: String = SettingsTab.general.rawValue
    @State private var query = ""
    @State private var isAccessibilityTrusted = true

    // The menu bar window already sits on Liquid Glass, so its content uses
    // plain sections and keeps glass for controls only.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("", selection: $workspace) {
                Text("Typing").tag(MenuWorkspace.switcher)
                Text("Mail").tag(MenuWorkspace.hideMyEmail)
                Text("Duo").tag(MenuWorkspace.duo)
                Text("Snow").tag(MenuWorkspace.snow)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            switch workspace {
            case .switcher:
                SwitcherMenuModule(switcher: switcher, onDismiss: { dismiss() })
                Divider()
                AutocompleteModule(
                    autocomplete: autocomplete,
                    onOpenAutocompleteSettings: { openAppSettings(tab: .autocomplete) },
                    onDismiss: { dismiss() }
                )
            case .hideMyEmail:
                switch model.state {
                case .unknown:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 120)
                case .signedOut:
                    SignedOutModule(model: model)
                case .signedIn:
                    GeneratorModule(model: model) { text in
                        dismiss()
                        AppDelegate.paste(text, into: model.context)
                    }
                    Divider()
                    addressesModule
                }
            case .duo:
                DuoMenuModule(controller: duo, prefs: duoPrefs, onDismiss: { dismiss() })
            case .snow:
                SnowMenuModule(controller: snow, prefs: snow.preferences, weather: snow.weather)
            }
            if !isAccessibilityTrusted {
                Divider()
                AccessibilityModule()
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 384)
        .task {
            isAccessibilityTrusted = AX.isTrusted
            switcher.refreshSecureInputState()
            if model.state == .signedIn { await model.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isAccessibilityTrusted = AX.isTrusted
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("KeyVeil")
                .font(.system(size: 13, weight: .bold))
            Spacer()
            if workspace == .hideMyEmail && model.isRefreshing {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 4)
    }

    private struct AddressSection: Identifiable {
        let title: String?
        let addresses: [HMEAddress]
        var id: String { title ?? "" }
    }

    private var sections: [AddressSection] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            return [AddressSection(title: nil, addresses: model.addresses.filter {
                $0.label.localizedCaseInsensitiveContains(trimmed) || $0.hme.localizedCaseInsensitiveContains(trimmed)
                    || $0.note.localizedCaseInsensitiveContains(trimmed)
            })]
        }
        guard let site = model.context?.site, !model.siteAddresses.isEmpty else {
            return [AddressSection(title: nil, addresses: model.addresses)]
        }
        let siteIDs = Set(model.siteAddresses.map(\.id))
        return [
            AddressSection(title: site, addresses: model.siteAddresses),
            AddressSection(title: String(localized: "All Addresses"),
                           addresses: model.addresses.filter { !siteIDs.contains($0.id) }),
        ]
    }

    private var addressesModule: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.fill.tertiary, in: .capsule)

            let sections = sections.filter { !$0.addresses.isEmpty }
            if sections.isEmpty {
                Text(query.isEmpty ? "No addresses" : "No results")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                let rows = sections.reduce(0) { $0 + $1.addresses.count }
                let headers = sections.filter { $0.title != nil }.count
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            if let title = section.title {
                                Text(title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .frame(height: 24, alignment: .bottom)
                                    .padding(.bottom, 2)
                            }
                            ForEach(section.addresses) { address in
                                AddressRow(address: address) {
                                    dismiss()
                                    AppDelegate.paste(address.hme, into: model.context)
                                }
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(CGFloat(rows) * 40 + CGFloat(headers) * 26, 300))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if workspace == .hideMyEmail {
                Button { open("manager") } label: {
                    Label("Addresses", systemImage: "list.bullet")
                }
                .help("Addresses")
            }
            Button {
                openAppSettings(tab: defaultSettingsTabForWorkspace)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Label("Quit", systemImage: "power")
            }
            .help("Quit")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }

    private var defaultSettingsTabForWorkspace: SettingsTab {
        switch workspace {
        case .switcher: return .switcher
        case .hideMyEmail: return .mail
        case .duo: return .duo
        case .snow: return .snow
        }
    }

    private func openAppSettings(tab: SettingsTab = .general) {
        selectedSettingsTab = tab.rawValue
        dismiss()
        NSApp.activate()
        openSettings()
    }

    private func open(_ id: String) {
        dismiss()
        NSApp.activate()
        openWindow(id: id)
    }
}

private struct GeneratorModule: View {
    let model: AppModel
    let onPaste: (String) -> Void

    @State private var hme: String?
    @State private var label = ""
    @State private var note = ""
    @State private var reserved: HMEAddress?
    @State private var isWorking = false
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                SymbolBadge(systemName: "envelope.fill", size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hme ?? " ")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .textSelection(.enabled)
                        .redacted(reason: hme == nil ? .placeholder : [])
                        .contentTransition(.opacity)
                    if !model.forwardTo.isEmpty {
                        Text("Forwards to \(model.forwardTo)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    Task { await generate() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, isActive: isWorking && reserved == nil)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("New Address")
                .disabled(isWorking)
            }

            if let reserved, reserved.hme == hme {
                HStack(spacing: 6) {
                    Label("Reserved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.leading, 44)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button {
                        Filler.copy(reserved.hme)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    Button {
                        onPaste(reserved.hme)
                    } label: {
                        Label(model.context.map { "Paste in \($0.appName)" } ?? "Paste", systemImage: "text.insert")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.context == nil)
                }
                .controlSize(.large)
            } else {
                VStack(spacing: 0) {
                    FieldRow(title: "Label", prompt: model.context?.site ?? "Required", text: $label)
                    Divider().padding(.leading, 10)
                    FieldRow(title: "Note", prompt: "Optional", text: $note)
                }
                .background(.fill.tertiary, in: .rect(cornerRadius: 10))

                Button {
                    Task { await reserve() }
                } label: {
                    Text("Use This Address").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(hme == nil || isWorking || resolvedLabel.isEmpty)
            }

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
        .task(id: model.context?.site) {
            label = model.context?.site ?? ""
            if hme == nil { await generate() }
        }
    }

    private var resolvedLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? (model.context?.site ?? "") : trimmed
    }

    private func generate() async {
        isWorking = true
        error = nil
        reserved = nil
        copied = false
        defer { isWorking = false }
        do {
            let next = try await model.generate()
            withAnimation(.smooth) { hme = next }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reserve() async {
        guard let hme else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let address = try await model.reserve(hme, label: resolvedLabel,
                                                  note: note.trimmingCharacters(in: .whitespaces))
            withAnimation(.smooth) { reserved = address }
            note = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct FieldRow: View {
    let title: LocalizedStringKey
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(title)
            TextField(title, text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
    }
}

struct AddressRow: View {
    let address: HMEAddress
    let onPaste: () -> Void
    @State private var isHovered = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            SiteTile(address: address)
            VStack(alignment: .leading, spacing: 1) {
                Text(address.label.isEmpty ? address.hme : address.label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(address.hme)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if !address.isActive {
                Text("Inactive")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
            } else if isHovered {
                HStack(spacing: 2) {
                    Button {
                        Filler.copy(address.hme)
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help("Copy")
                    Button(action: onPaste) {
                        Image(systemName: "text.insert")
                    }
                    .help("Paste")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .background(isHovered ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
        .contentShape(.rect)
        .onHover { hovering in
            isHovered = hovering
            if !hovering { copied = false }
        }
        .contextMenu {
            Button("Copy Address") { Filler.copy(address.hme) }
            Button("Paste", action: onPaste).disabled(!address.isActive)
        }
    }
}

private struct SignedOutModule: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            SymbolBadge(systemName: "envelope.badge.shield.half.filled", size: 56)
            if let browser = model.pendingBrowser {
                HStack(spacing: 8) {
                    if browser.engine == .safari, model.safariExtensionState != .enabled {
                        switch model.safariExtensionState {
                        case .checking:
                            ProgressView().controlSize(.small)
                            Text("Checking Safari…")
                        case .disabled:
                            Text("Safari extension is off")
                        case .unavailable:
                            Text("Safari extension is unavailable")
                        case .enabled:
                            EmptyView()
                        }
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Waiting for iCloud in \(browser.name)…")
                    }
                    Spacer(minLength: 0)
                    Button("Cancel", action: model.cancelSignIn)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                .font(.system(size: 13))
            } else {
                HStack(spacing: 6) {
                    Button {
                        model.signIn(with: BrowserCookies.safari)
                    } label: {
                        Text("Sign In to iCloud").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    Menu {
                        ForEach(BrowserCookies.installed()) { browser in
                            Button(browser.name) { model.signIn(with: browser) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .fixedSize()
                    .help("Sign In with Another Browser")
                }
            }
            if model.safariExtensionState == .disabled || model.safariExtensionState == .unavailable,
               model.pendingBrowser.map({ $0.engine == .safari }) ?? true {
                Button(model.safariExtensionState == .disabled
                       ? "Turn On Safari Extension…" : "Safari Extension Settings…") {
                    Task { try? await SFSafariApplication.showPreferencesForExtension(withIdentifier: BrowserCookies.safariExtensionID) }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

private struct AccessibilityModule: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text("Allow Accessibility for layout switching, email autofill, and autocomplete")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Allow…") {
                AX.requestTrust()
                AX.openAccessibilitySettings()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(.horizontal, 4)
    }
}

private struct AutocompleteModule: View {
    let autocomplete: AutocompleteController
    let onOpenAutocompleteSettings: () -> Void
    let onDismiss: () -> Void

    private var isModelLoaded: Bool {
        if case .ready = autocomplete.engineState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SymbolBadge(systemName: "sparkles", size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Autocomplete & Polish")
                        .font(.system(size: 14, weight: .semibold))
                    Text(statusSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isModelLoaded {
                    Button {
                        autocomplete.unloadModelNow()
                    } label: {
                        Image(systemName: "eject.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                    .help("Unload model from memory")
                }
                Toggle("", isOn: Binding(
                    get: { autocomplete.preferences.isEnabled },
                    set: { autocomplete.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if case .noModel = autocomplete.engineState, autocomplete.preferences.isEnabled || autocomplete.preferences.polishEnabled {
                Button("Choose or Download Model…") {
                    onOpenAutocompleteSettings()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    if autocomplete.preferences.polishEnabled {
                        Button {
                            onDismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                                autocomplete.polishCurrentField()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 11))
                                Text("Polish Text")
                                    .font(.system(size: 11.5, weight: .medium))
                                if let badge = autocomplete.preferences.polishShortcut.badge {
                                    Text(badge)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(autocomplete.isPolishing)
                    }

                    if autocomplete.preferences.isEnabled,
                       let bundleID = autocomplete.lastExternalBundleID,
                       let appName = autocomplete.lastExternalAppName {
                        let paused = autocomplete.isAppExcluded(bundleID)
                        Button {
                            autocomplete.toggleExcluded(bundleID: bundleID)
                        } label: {
                            Image(systemName: paused ? "play.fill" : "pause.fill")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help(paused
                              ? String(localized: "Resume in \(appName)")
                              : String(localized: "Pause in \(appName)"))

                        if !paused && autocomplete.preferences.personalizationStrength != .off {
                            let learningPaused = autocomplete.isLearningExcluded(bundleID)
                            Button {
                                autocomplete.toggleLearningExcluded(bundleID: bundleID)
                            } label: {
                                Image(systemName: learningPaused ? "eye.slash.fill" : "brain")
                                    .font(.system(size: 10))
                                    .foregroundStyle(learningPaused ? .orange : .primary)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .help(learningPaused
                                  ? String(localized: "Resume learning in \(appName)")
                                  : String(localized: "Don't learn in \(appName)"))
                        }
                    }
                }

                if autocomplete.preferences.polishEnabled {
                    @Bindable var autoPrefs = autocomplete.preferences
                    HStack(spacing: 8) {
                        Text("Auto-Fix Caps, Commas & Typos")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Toggle("", isOn: $autoPrefs.autoPolishEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var statusColor: Color {
        if autocomplete.isSecureInputActive { return .orange }
        switch autocomplete.engineState {
        case .disabled: return .secondary
        case .noModel: return .orange
        case .idle: return .secondary
        case .loading: return .accentColor
        case .ready: return .green
        case .error: return .red
        }
    }

    private var statusSubtitle: String {
        if autocomplete.isSecureInputActive && autocomplete.preferences.isEnabled {
            return String(localized: "Paused (Secure Input)")
        }
        switch autocomplete.engineState {
        case .disabled:
            return String(localized: "Off")
        case .noModel:
            return String(localized: "No local GGUF model found")
        case .idle(let name):
            return String(localized: "\(name) · Unloaded (0 MB)")
        case .loading(let name):
            return String(localized: "Loading \(name)…")
        case .ready(let name, let usingGPU):
            let hw = usingGPU ? "GPU" : "CPU"
            if let mb = autocomplete.loadedMemoryMB {
                return "\(name) · ~\(mb) MB · \(hw)"
            }
            return "\(name) · \(hw)"
        case .error(let message):
            return message
        }
    }
}
