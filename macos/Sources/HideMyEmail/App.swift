import AppKit
import HideMyEmailCore
import LayoutSwitcherCore
import SnowpileCore
import Sparkle
import SwiftUI

@main
struct KeyVeilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var switcher = SwitcherController.shared
    @State private var switcherPrefs = SwitcherPreferences.shared
    @State private var duo = DuoFoldController.shared
    @State private var duoPrefs = DuoPreferences.shared
    @StateObject private var snow = SnowpileController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: .shared, autocomplete: .shared, switcher: switcher, duo: duo, duoPrefs: duoPrefs, snow: snow)
        } label: {
            MenuBarLabelView(switcher: switcher, prefs: switcherPrefs, duo: duo, duoPrefs: duoPrefs)
        }
        .menuBarExtraStyle(.window)

        Window("Addresses", id: "manager") {
            ManagerView(model: .shared)
        }
        .defaultSize(width: 1080, height: 600)
        .defaultLaunchBehavior(Demo.isEnabled ? .presented : .automatic)

        Settings {
            SettingsView(model: .shared, settings: .shared, autocomplete: .shared, switcher: switcher, switcherPrefs: switcherPrefs, duo: duo, duoPrefs: duoPrefs, snow: snow)
        }
    }
}

private struct MenuBarLabelView: View {
    let switcher: SwitcherController
    let prefs: SwitcherPreferences
    let duo: DuoFoldController
    let duoPrefs: DuoPreferences

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .symbolRenderingMode(.hierarchical)
            if prefs.showLayoutInMenuBar {
                Text(switcher.currentLanguage.shortLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .opacity(prefs.isEnabled ? 1.0 : 0.45)
            }
            if duoPrefs.showsAngleInMenuBar && duo.sensorAvailable {
                Text(String(format: "%.0f°", duo.angle))
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                    .opacity(duoPrefs.isEnabled ? 0.85 : 0.4)
            }
        }
    }

    private var iconName: String {
        if switcher.isSecureInputActive {
            return "lock.shield"
        }
        if !prefs.isEnabled {
            return "keyboard"
        }
        return "keyboard.badge.ellipsis"
    }
}

/// Sparkle checks the feed daily and installs updates in the background.
@MainActor
enum Updates {
    static let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                         userDriverDelegate: nil)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Updates.controller
        if Demo.isEnabled {
            AppModel.shared.startDemo()
            Demo.showPanels()
        } else {
            Task { await AppModel.shared.bootstrap() }
            FieldWatcher.shared.start()
            AutocompleteController.shared.start()
            SwitcherController.shared.start()
            DuoFoldController.shared.start()
            SnowpileController.shared.start()
        }
        HotKey.shared.register(Preferences.shared.shortcut) { Self.createFromShortcut() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppModel.shared.handleWake()
                AutocompleteController.shared.restartIfTrusted()
                SwitcherController.shared.restartEventTap()
                SnowpileController.shared.didWake()
            }
        }
        if !AX.isTrusted {
            AX.requestTrust()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DuoFoldController.shared.stop()
        SnowpileController.shared.stop()
        AutocompleteController.shared.shutdownForTermination()
    }

    /// Creates an address for the site in the frontmost app and types it into
    /// the focused field, or copies it when nothing editable has focus.
    static func createFromShortcut() {
        let model = AppModel.shared
        guard model.state == .signedIn else {
            Toast.show(String(localized: "Sign in to iCloud first"), symbol: "exclamationmark.circle.fill", tint: .orange)
            return
        }
        SuggestionPanel.shared.hide()
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focused = AX.isTrusted ? pid.flatMap(AX.focusedElement(pid:)) : nil
        let isEditable = focused.map { element in
            let field = AX.descriptor(element)
            return ["AXTextField", "AXTextArea", "AXComboBox"].contains(field.role) && field.subrole != "AXSecureTextField"
        } ?? false
        if let pid, let url = AX.frontPageURL(pid: pid) {
            model.context?.site = Sites.registrableDomain(of: url)
        }

        Task {
            do {
                let address = try await model.createForCurrentSite()
                if isEditable {
                    Filler.insert(address.hme, replacing: focused)
                    Toast.show(address.hme)
                } else {
                    Filler.copy(address.hme)
                    Toast.show(String(localized: "Copied \(address.hme)"), symbol: "doc.on.doc.fill", tint: .accentColor)
                }
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", tint: .red)
            }
        }
    }

    /// Returns to the app the user came from and types the address there.
    static func paste(_ text: String, into context: BrowsingContext?) {
        guard let context, let app = NSRunningApplication(processIdentifier: context.pid) else {
            Filler.copy(text)
            return
        }
        app.activate()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            Filler.insert(text)
        }
    }
}
