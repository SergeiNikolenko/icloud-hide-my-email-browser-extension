import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Inserts accepted suggestions or replacements cleanly into the frontmost focused field.
@MainActor
enum TextInserter {
    /// Magic tag attached to synthetic CGEvents so our CGEventTap ignores them reliably.
    static let syntheticMarker: Int64 = 0x484D_4541

    /// True while synthetic events are being posted so our CGEventTap ignores them.
    private(set) static var isSynthesizing = false

    static func insert(_ text: String, deletingBefore deleteCount: Int = 0, completion: (@MainActor () -> Void)? = nil) {
        guard !text.isEmpty || deleteCount > 0 else { return }
        isSynthesizing = true

        // Dispatch outside the synchronous CGEventTap callback so macOS never times out the tap
        // and synthetic characters arrive strictly after the consumed trigger key.
        Task { @MainActor in
            defer {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    isSynthesizing = false
                }
            }

            if deleteCount > 0 {
                sendBackspaces(count: deleteCount)
                try? await Task.sleep(for: .milliseconds(16))
            }

            if !text.isEmpty {
                let hasSurrogates = text.unicodeScalars.contains { $0.value > 0xFFFF }
                if hasSurrogates || text.count > 64 {
                    pastePreservingClipboard(text)
                } else {
                    typeUnicode(text)
                }
            }

            completion?()
        }
    }

    /// Replaces either the active text selection or the entire focused input field
    /// with `text` via Cmd+A (when `selectAll` is true) + clipboard-preserving Cmd+V,
    /// so Cmd+Z in the target app cleanly undoes the polish if desired.
    static func replaceField(with text: String, selectAll: Bool, completion: (@MainActor () -> Void)? = nil) {
        guard !text.isEmpty else { return }
        isSynthesizing = true

        Task { @MainActor in
            defer {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(90))
                    isSynthesizing = false
                }
            }

            if selectAll {
                sendCommandKey(CGKeyCode(kVK_ANSI_A))
                try? await Task.sleep(for: .milliseconds(35))
            }

            pastePreservingClipboard(text)
            completion?()
        }
    }

    private static func sendCommandKey(_ keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        tag(down)
        tag(up)
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func tag(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
    }

    private static func sendBackspaces(count: Int) {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        let code = CGKeyCode(kVK_Delete)
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            down?.flags = []
            up?.flags = []
            tag(down)
            tag(up)
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private static func typeUnicode(_ text: String) {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        let units = Array(text.utf16)
        let chunkSize = 12
        var offset = 0
        while offset < units.count {
            let end = min(offset + chunkSize, units.count)
            var slice = Array(units[offset..<end])
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                down.flags = []
                up.flags = []
                tag(down)
                tag(up)
                down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
                up.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
                down.post(tap: .cgAnnotatedSessionEventTap)
                up.post(tap: .cgAnnotatedSessionEventTap)
            }
            offset = end
        }
    }

    private static func pastePreservingClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedItems: [[(NSPasteboard.PasteboardType, Data)]] = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        }
        let changeCountBefore = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let insertedChangeCount = pasteboard.changeCount

        if let source = CGEventSource(stateID: .privateState) {
            let vKey = CGKeyCode(kVK_ANSI_V)
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            tag(down)
            tag(up)
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }

        // Restore previous clipboard contents once the target app finishes handling Cmd+V.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) {
            guard pasteboard.changeCount == insertedChangeCount else { return }
            pasteboard.clearContents()
            if !savedItems.isEmpty && changeCountBefore != insertedChangeCount {
                let restored = savedItems.map { pairs -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in pairs { item.setData(data, forType: type) }
                    return item
                }
                pasteboard.writeObjects(restored)
            }
        }
    }
}

