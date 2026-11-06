import AppKit
import ApplicationServices
import HideMyEmailCore

enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String, as type: T.Type = T.self) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Chromium and Electron build their web accessibility tree only when an
    /// assistive client asks for it.
    static func enableWebAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        element(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
    }

    static func descriptor(_ element: AXUIElement) -> FieldDescriptor {
        let titleElement = Self.element(element, kAXTitleUIElementAttribute)
        return FieldDescriptor(
            role: attribute(element, kAXRoleAttribute) ?? "",
            subrole: attribute(element, kAXSubroleAttribute),
            roleDescription: attribute(element, kAXRoleDescriptionAttribute),
            identifier: attribute(element, "AXDOMIdentifier") ?? attribute(element, kAXIdentifierAttribute),
            title: attribute(element, kAXTitleAttribute),
            placeholder: attribute(element, kAXPlaceholderValueAttribute),
            label: titleElement.flatMap { attribute($0, kAXValueAttribute) } ?? attribute(element, kAXDescriptionAttribute),
            help: attribute(element, kAXHelpAttribute),
            value: attribute(element, kAXValueAttribute)
        )
    }

    static func webArea(containing element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<64 {
            guard let node = current else { return nil }
            if attribute(node, kAXRoleAttribute, as: String.self) == "AXWebArea" { return node }
            current = Self.element(node, kAXParentAttribute)
        }
        return nil
    }

    /// The URL of the web page that contains an element, if any.
    static func pageURL(containing element: AXUIElement) -> URL? {
        guard let node = webArea(containing: element) else { return nil }
        if let url: URL = attribute(node, kAXURLAttribute) { return url }
        return attribute(node, kAXURLAttribute, as: String.self).flatMap(URL.init(string:))
    }

    /// The title of the page that contains an element, or else of its window.
    static func pageTitle(containing element: AXUIElement, pid: pid_t) -> String? {
        let titles = [
            webArea(containing: element).flatMap { attribute($0, kAXTitleAttribute, as: String.self) },
            Self.element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
                .flatMap { attribute($0, kAXTitleAttribute, as: String.self) },
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return titles.isEmpty ? nil : titles.joined(separator: " ")
    }

    /// The URL of the frontmost page in an app's focused window.
    static func frontPageURL(pid: pid_t) -> URL? {
        if let focused = focusedElement(pid: pid), let url = pageURL(containing: focused) { return url }
        guard let window = element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) else { return nil }
        if let document: String = attribute(window, kAXDocumentAttribute), let url = URL(string: document),
           url.scheme?.hasPrefix("http") == true {
            return url
        }
        return findWebArea(in: window, depth: 0).flatMap { node in
            attribute(node, kAXURLAttribute, as: URL.self)
        }
    }

    private static func findWebArea(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 12 else { return nil }
        if attribute(element, kAXRoleAttribute, as: String.self) == "AXWebArea" { return element }
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        for child in children.prefix(40) {
            if let found = findWebArea(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The element's frame in AppKit screen coordinates (bottom-left origin).
    static func frame(_ element: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0, let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: position.x, y: primary.frame.maxY - position.y - size.height,
                      width: size.width, height: size.height)
    }
}

enum Filler {
    /// Types into the focused field by pasting, which every app and web page
    /// treats as user input, then restores the previous clipboard.
    @MainActor
    static func insert(_ text: String, replacing element: AXUIElement? = nil) {
        if let element {
            // Select the current contents so the paste replaces them.
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if let value: String = AX.attribute(element, kAXValueAttribute), !value.isEmpty {
                var range = CFRange(location: 0, length: (value as NSString).length)
                if let axRange = AXValueCreate(.cfRange, &range) {
                    AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
                }
            }
        }

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
                result[type] = item.data(forType: type)
            }
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyV: CGKeyCode = 9
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            pasteboard.clearContents()
            let items = saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
