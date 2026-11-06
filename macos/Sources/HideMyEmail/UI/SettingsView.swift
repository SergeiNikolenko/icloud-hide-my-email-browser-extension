import AppKit
import HideMyEmailCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @Bindable var settings: Preferences

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings(settings: settings)
            }
            Tab("Account", systemImage: "person.crop.circle") {
                AccountSettings(model: model)
            }
            Tab("Apps", systemImage: "square.grid.2x2") {
                AppsSettings(settings: settings)
            }
        }
        .frame(width: 500, height: 380)
    }
}

private struct GeneralSettings: View {
    @Bindable var settings: Preferences
    @State private var launchesAtLogin = LaunchAtLogin.isEnabled
    @State private var isTrusted = AX.isTrusted

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: $launchesAtLogin)
                    .onChange(of: launchesAtLogin) { _, enabled in LaunchAtLogin.set(enabled) }
                Picker("Create and Fill Shortcut", selection: $settings.shortcut) {
                    ForEach(Shortcut.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.shortcut) { _, shortcut in
                    HotKey.shared.register(shortcut) { AppDelegate.createFromShortcut() }
                }
                Toggle("Suggest Addresses in Email Fields", isOn: $settings.showsSuggestions)
            }
            Section {
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
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isTrusted = AX.isTrusted
            if isTrusted { FieldWatcher.shared.restart() }
        }
    }
}

private struct AccountSettings: View {
    let model: AppModel
    @State private var forwardTo = ""

    var body: some View {
        Form {
            Section {
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
            }
            Section {
                if model.state == .signedIn {
                    LabeledContent("Addresses", value: "\(model.addresses.count)")
                    Button("Sign Out", role: .destructive, action: model.signOut)
                } else {
                    Button("Sign In…") { model.signIn(with: BrowserCookies.safari) }
                }
            }
            if let error = model.lastError {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            forwardTo = model.forwardTo
            if model.state == .signedIn, model.forwardToOptions.isEmpty { await model.refresh() }
            forwardTo = model.forwardTo
        }
    }
}

private struct AppsSettings: View {
    @Bindable var settings: Preferences
    @State private var selection: String?

    private var running: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { !settings.excludedBundleIDs.contains($0.bundleIdentifier ?? "") }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Form {
            Section("No Suggestions In") {
                List(selection: $selection) {
                    ForEach(settings.excludedBundleIDs.sorted(), id: \.self) { bundleID in
                        HStack(spacing: 8) {
                            AppIcon(bundleID: bundleID)
                            Text(AppIcon.name(for: bundleID))
                        }
                        .tag(bundleID)
                    }
                }
                .frame(minHeight: 150)
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
        .onChange(of: settings.excludedBundleIDs) { _, _ in FieldWatcher.shared.restart() }
    }
}

private struct AppIcon: View {
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
