import AppKit
import HideMyEmailCore
import SwiftUI

@main
struct HideMyEmailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: .shared)
        } label: {
            Image(systemName: "envelope.badge.shield.half.filled")
        }
        .menuBarExtraStyle(.window)

        Window("Addresses", id: "manager") {
            ManagerView(model: .shared)
        }
        .defaultSize(width: 1080, height: 600)

        Settings {
            SettingsView(model: .shared, settings: .shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await AppModel.shared.bootstrap() }
        FieldWatcher.shared.start()
        HotKey.shared.register(Preferences.shared.shortcut) { Self.createFromShortcut() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppModel.shared.handleWake() }
        }
        if !AX.isTrusted {
            AX.requestTrust()
        }
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
