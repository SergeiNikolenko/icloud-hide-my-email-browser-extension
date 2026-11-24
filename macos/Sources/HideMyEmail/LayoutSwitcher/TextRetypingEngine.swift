import AppKit
import ApplicationServices
import Carbon
import Foundation
import LayoutSwitcherCore

/// Performs tagged synthetic retyping, selection conversion, and plain-text paste
/// using Caramba's exact inter-step timings and minimal diff backspacing.
enum TextRetypingEngine {
    /// Unique tag attached to all synthetic CGEvents so our event tap ignores its own output.
    static let syntheticEventTag: Int64 = 0x4B56_5357 // "KVSW"

    static func performRetype(
        action: SwitcherAction,
        feats: FeatsConfig,
        specialBrowser: Bool,
        layoutMap: KeyboardLayoutMap,
        targetLanguage: SwitcherLanguage,
        switchLayout: @escaping @Sendable (SwitcherLanguage) -> Void
    ) {
        let source = CGEventSource(stateID: .privateState)

        // 1. Switch system keyboard layout first (matching Caramba's order:
        //    layout activation -> delayBetweenLayoutActivationAndBackspaces -> backspaces -> delay -> retype).
        if let newLang = action.targetLanguage {
            switchLayout(newLang)
            let activationDelay = max(feats.delayBetweenLayoutActivationAndBackspacesMs, specialBrowser ? 30 : 25)
            Thread.sleep(forTimeInterval: Double(activationDelay) / 1000.0)
        }

        // 2. If we're in a browser URL bar with highlighted inline autocomplete, clear the selected
        //    suggestion first so backspaces only erase the characters we typed.
        let extraClear = specialBrowser && hasTrailingAutocompleteSelection() ? 1 : 0
        let totalBackspaces = action.backspaces + extraClear

        if totalBackspaces > 0 {
            for _ in 0..<totalBackspaces {
                postVirtualKey(CGKeyCode(kVK_Delete), flags: [], source: source)
                Thread.sleep(forTimeInterval: 0.002)
            }
            let retypeDelay = max(feats.delayBetweenBackspacesAndRetypingMs, specialBrowser ? 30 : 25)
            Thread.sleep(forTimeInterval: Double(retypeDelay) / 1000.0)
        }

        // 3. Inject replacement text using target virtual keyCode + explicit Unicode payload.
        let activeLang = action.targetLanguage ?? targetLanguage
        for ch in action.textToType {
            postCharacter(ch, language: activeLang, layoutMap: layoutMap, source: source)
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    static func postVirtualKey(_ keyCode: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        // Match Caramba Switcher Pro (0x10025a4a8): apply modifier flags only on keyDown,
        // keep keyUp clean, and post at cgSessionEventTap so HID modifier bounce (e.g. physical
        // Option release) can never turn Delete into Option+Delete or interfere with shortcuts.
        down.flags = flags
        up.flags = []
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    static func postCharacter(
        _ ch: Character,
        language: SwitcherLanguage,
        layoutMap: KeyboardLayoutMap,
        source: CGEventSource?
    ) {
        if ch == "\n" || ch == "\r" {
            postVirtualKey(CGKeyCode(kVK_Return), flags: [], source: source)
            return
        }
        if ch == "\t" {
            postVirtualKey(CGKeyCode(kVK_Tab), flags: [], source: source)
            return
        }
        if ch == " " {
            postVirtualKey(CGKeyCode(kVK_Space), flags: [], source: source)
            return
        }

        let mapped = layoutMap.keyStroke(for: ch, in: language)
        let keyCode = CGKeyCode(mapped?.keyCode ?? 0)
        let eventFlags: CGEventFlags = (mapped?.shifted == true) ? .maskShift : []
        var utf16 = Array(String(ch).utf16)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = eventFlags
        up.flags = []
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// Reads currently selected text via Accessibility (fast, zero-clipboard read when exposed).
    @MainActor
    static func readSelectedText() -> String? {
        if AX.isTrusted,
           let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let focused = AX.focusedElement(pid: pid) {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value) == .success,
               let selected = value as? String,
               !selected.isEmpty {
                return selected
            }
        }
        return nil
    }

    /// Captures selected text via tagged Cmd+C on cgSessionEventTap, polling changeCount up to
    /// 220ms (fast ~15ms in native apps, full Caramba 200ms reliability in Electron/browsers).
    static func readSelectedTextViaClipboard() -> (text: String, savedPasteboard: [[NSPasteboard.PasteboardType: Data]])? {
        let saved = snapshotPasteboard()
        let beforeCount = DispatchQueue.main.sync { NSPasteboard.general.changeCount }

        let source = CGEventSource(stateID: .privateState)
        postVirtualKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand, source: source)

        // Poll in 10ms increments up to 220ms (Caramba waits a flat 200ms).
        var changed = false
        for _ in 0..<22 {
            Thread.sleep(forTimeInterval: 0.010)
            let nowCount = DispatchQueue.main.sync { NSPasteboard.general.changeCount }
            if nowCount != beforeCount {
                changed = true
                break
            }
        }
        guard changed else { return nil }

        // Brief settle so apps writing multiple pasteboard representations finish populating .string.
        Thread.sleep(forTimeInterval: 0.005)
        let text: String? = DispatchQueue.main.sync {
            NSPasteboard.general.string(forType: .string)
        }
        guard let text, !text.isEmpty else {
            restorePasteboard(saved)
            return nil
        }
        return (text, saved)
    }

    /// Replaces the currently selected text via tagged Cmd+V (matching Caramba 0x10025935c:
    /// avoids AXUIElementSetAttributeValue which silently fails in Electron/Chromium/WebKit editors)
    /// and always restores the user's original pasteboard after 200ms.
    static func replaceSelectedText(
        with replacement: String,
        savedPasteboard: [[NSPasteboard.PasteboardType: Data]]?
    ) {
        let snapshot = savedPasteboard ?? snapshotPasteboard()
        DispatchQueue.main.sync {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(replacement, forType: .string)
        }
        Thread.sleep(forTimeInterval: 0.010)
        let source = CGEventSource(stateID: .privateState)
        postVirtualKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand, source: source)
        Thread.sleep(forTimeInterval: 0.200)
        restorePasteboard(snapshot)
    }

    /// Deletes a just-pasted single-line conversion and pastes the reverted string back,
    /// enabling clean back-and-forth Option toggling after a selection conversion.
    static func replaceTrailingTextViaClipboard(
        backspaceCount: Int,
        replacement: String
    ) {
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<max(0, backspaceCount) {
            postVirtualKey(CGKeyCode(kVK_Delete), flags: [], source: source)
            Thread.sleep(forTimeInterval: 0.002)
        }
        if backspaceCount > 0 {
            Thread.sleep(forTimeInterval: 0.025)
        }
        replaceSelectedText(with: replacement, savedPasteboard: nil)
    }

    /// Pastes clipboard contents as plain unformatted text (Cmd+Shift+V feature from Caramba).
    static func pasteWithoutFormatting() {
        let plain: String? = DispatchQueue.main.sync {
            NSPasteboard.general.string(forType: .string)
        }
        guard let plain, !plain.isEmpty else { return }

        let snapshot = snapshotPasteboard()
        DispatchQueue.main.sync {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(plain, forType: .string)
        }
        Thread.sleep(forTimeInterval: 0.010)
        let source = CGEventSource(stateID: .privateState)
        postVirtualKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand, source: source)
        Thread.sleep(forTimeInterval: 0.200)
        restorePasteboard(snapshot)
    }

    private static func hasTrailingAutocompleteSelection() -> Bool {
        DispatchQueue.main.sync {
            guard AX.isTrusted,
                  let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let focused = AX.focusedElement(pid: pid) else {
                return false
            }
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""
            guard role == "AXTextField" || role == "AXComboBox" else { return false }

            var selectedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
               let sel = selectedRef as? String, !sel.isEmpty {
                return true
            }
            return false
        }
    }

    static func snapshotPasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        DispatchQueue.main.sync {
            let pb = NSPasteboard.general
            return (pb.pasteboardItems ?? []).map { item in
                var entry: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        entry[type] = data
                    }
                }
                return entry
            }
        }
    }

    static func restorePasteboard(_ snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        DispatchQueue.main.sync {
            let pb = NSPasteboard.general
            pb.clearContents()
            guard !snapshot.isEmpty else { return }
            let items: [NSPasteboardItem] = snapshot.map { entry in
                let item = NSPasteboardItem()
                for (type, data) in entry {
                    item.setData(data, forType: type)
                }
                return item
            }
            pb.writeObjects(items)
        }
    }
}

