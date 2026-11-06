import Carbon.HIToolbox

enum Shortcut: String, CaseIterable, Identifiable {
    case controlOptionE
    case optionCommandE
    case shiftCommandE
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controlOptionE: "⌃⌥E"
        case .optionCommandE: "⌥⌘E"
        case .shiftCommandE: "⇧⌘E"
        case .off: String(localized: "None")
        }
    }

    fileprivate var carbon: (key: UInt32, modifiers: UInt32)? {
        let e = UInt32(kVK_ANSI_E)
        switch self {
        case .controlOptionE: return (e, UInt32(controlKey | optionKey))
        case .optionCommandE: return (e, UInt32(optionKey | cmdKey))
        case .shiftCommandE: return (e, UInt32(shiftKey | cmdKey))
        case .off: return nil
        }
    }
}

/// A system-wide shortcut through the Carbon hot key API, which needs no
/// input monitoring permission.
@MainActor
final class HotKey {
    static let shared = HotKey()

    private var reference: EventHotKeyRef?
    private var handlerInstalled = false
    private var action: (() -> Void)?

    func register(_ shortcut: Shortcut, action: @escaping () -> Void) {
        self.action = action
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        guard let carbon = shortcut.carbon else { return }

        if !handlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { HotKey.shared.action?() }
                return noErr
            }, 1, &eventType, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x484D_4531), id: 1)
        RegisterEventHotKey(carbon.key, carbon.modifiers, id, GetApplicationEventTarget(), 0, &reference)
    }
}
