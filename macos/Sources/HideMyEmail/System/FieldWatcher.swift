import AppKit
import ApplicationServices
import HideMyEmailCore

/// Follows keyboard focus across apps and offers addresses whenever an email
/// field gets focus, in any browser or app except the excluded ones.
@MainActor
final class FieldWatcher {
    static let shared = FieldWatcher()

    private var observer: AXObserver?
    private var observedPid: pid_t?
    private var evaluation: Task<Void, Never>?
    private let model = AppModel.shared

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self.attach(app) }
        }
        attach(NSWorkspace.shared.frontmostApplication)
    }

    func restart() {
        detach()
        attach(NSWorkspace.shared.frontmostApplication)
    }

    private func attach(_ app: NSRunningApplication?) {
        guard let app, let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { return }
        SuggestionPanel.shared.hide()
        model.context = BrowsingContext(appName: app.localizedName ?? bundleID, pid: app.processIdentifier, site: nil)
        detach()
        guard AX.isTrusted, !Preferences.shared.excludedBundleIDs.contains(bundleID) else { return }

        let pid = app.processIdentifier
        AX.enableWebAccessibility(pid: pid)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, _ in
            MainActor.assumeIsolated { FieldWatcher.shared.scheduleEvaluation() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let appElement = AXUIElementCreateApplication(pid)
        for notification in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
                             kAXMainWindowChangedNotification] {
            AXObserverAddNotification(created, appElement, notification as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        observedPid = pid
        scheduleEvaluation()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPid = nil
    }

    func scheduleEvaluation() {
        evaluation?.cancel()
        evaluation = Task {
            // Focus changes arrive in bursts while pages load.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            evaluate()
        }
    }

    private func evaluate() {
        guard let pid = observedPid else { return }
        let focused = AX.focusedElement(pid: pid)
        let url = focused.flatMap(AX.pageURL(containing:)) ?? AX.frontPageURL(pid: pid)
        model.context?.site = url.flatMap(Sites.registrableDomain(of:))

        guard Preferences.shared.showsSuggestions, model.state == .signedIn, let focused else {
            SuggestionPanel.shared.hide()
            return
        }
        let field = AX.descriptor(focused)
        guard EmailField.isEmailField(field), (field.value ?? "").isEmpty else {
            SuggestionPanel.shared.hide()
            return
        }
        SuggestionPanel.shared.show(for: focused, anchor: anchorFrame(for: focused, pid: pid))
    }

    /// Embedded Electron web views (such as the Codex browser) report their
    /// page at the window's origin, so field frames there are not on screen;
    /// anchor to the pointer, which sits on the field after a click.
    private func anchorFrame(for element: AXUIElement, pid: pid_t) -> CGRect {
        let mouse = NSEvent.mouseLocation
        let pointer = CGRect(x: mouse.x - 12, y: mouse.y - 14, width: 280, height: 28)
        guard let frame = AX.frame(element),
              let window = AX.element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
              let windowFrame = AX.frame(window), windowFrame.insetBy(dx: -4, dy: -4).contains(frame)
        else { return pointer }
        if let webArea = AX.webArea(containing: element), let pageFrame = AX.frame(webArea),
           pageFrame.minX == windowFrame.minX, pageFrame.maxY == windowFrame.maxY, pageFrame.size != windowFrame.size {
            return pointer
        }
        return frame
    }
}
