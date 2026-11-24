import AppKit
import ApplicationServices
import AutocompleteCore
import Carbon.HIToolbox
import CoreText
import Foundation
import OSLog

struct FieldTypography {
    let font: NSFont
    let foregroundColor: NSColor?
    let backgroundColor: NSColor?
    let isDarkBackground: Bool
    let lineLeftX: CGFloat?
    let lineStepHeight: CGFloat?
    let fieldVisibleFrame: CGRect?
    let hasSameLineSuffix: Bool

    static var fallback: FieldTypography {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return FieldTypography(
            font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            foregroundColor: nil,
            backgroundColor: nil,
            isDarkBackground: isDark,
            lineLeftX: nil,
            lineStepHeight: nil,
            fieldVisibleFrame: nil,
            hasSameLineSuffix: false
        )
    }
}

struct FocusedTextSnapshot {
    let element: AXUIElement
    let bundleID: String
    let appName: String
    let windowTitle: String?
    let prefix: String
    let suffix: String
    let caretLocationUTF16: Int
    let selectionLengthUTF16: Int
    let caretScreenRect: CGRect
    let typography: FieldTypography
}

@MainActor
enum TextContextReader {
    private static let logger = Logger(subsystem: "com.nikolenko.HideMyEmail", category: "Autocomplete")
    private static var didRegisterExtraFonts = false
    private static var cachedScreenContextKey: String?
    private static var cachedScreenContextDate: Date = .distantPast
    private static var cachedScreenContextValue: (pageURL: String?, screenContext: String?) = (nil, nil)

    static func invalidateScreenContextCache() {
        cachedScreenContextKey = nil
        cachedScreenContextDate = .distantPast
    }

    /// Reads visible nearby text from the focused window (e.g. recent chat messages above the
    /// input box in Codex/Telegram/Slack/Mail, document headings, or active browser page text & URL)
    /// using bounded reverse-DFS Accessibility traversal (~15-30ms, cached for 2.5s, secret-scrubbed).
    static func readScreenContext(for snapshot: FocusedTextSnapshot) -> (pageURL: String?, screenContext: String?) {
        let cacheKey = "\(snapshot.bundleID)|\(snapshot.windowTitle ?? "")"
        let now = Date()
        if cachedScreenContextKey == cacheKey, now.timeIntervalSince(cachedScreenContextDate) < 2.5 {
            return cachedScreenContextValue
        }

        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == snapshot.bundleID else {
            return (nil, nil)
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AX.setTimeout(appElement, seconds: 0.15)
        let focusedWindow = AX.element(appElement, kAXFocusedWindowAttribute)
            ?? AX.element(appElement, kAXMainWindowAttribute)

        // Walk up from focused input to find the nearest enclosing AXWebArea (browsers & Electron apps).
        var webArea: AXUIElement?
        var walker: AXUIElement? = snapshot.element
        for _ in 0..<18 {
            guard let current = walker else { break }
            let role = AX.attribute(current, kAXRoleAttribute, as: String.self) ?? ""
            if role == "AXWebArea" {
                webArea = current
                break
            }
            walker = AX.element(current, kAXParentAttribute)
        }

        // Extract HTTP(S) page URL if available.
        var pageURL: String?
        if let wa = webArea {
            pageURL = extractHTTPURL(from: wa, attr: "AXURL")
        }
        if pageURL == nil, let win = focusedWindow {
            pageURL = extractHTTPURL(from: win, attr: kAXDocumentAttribute)
        }

        guard let root = webArea ?? focusedWindow else {
            let result: (String?, String?) = (pageURL, nil)
            cachedScreenContextKey = cacheKey
            cachedScreenContextDate = now
            cachedScreenContextValue = result
            return result
        }

        let windowAXRect = focusedWindow.flatMap { rawAXRect($0) }
        let fieldAXRect = rawAXRect(snapshot.element)

        // Skip left sidebar column in multi-pane apps (Codex, Telegram, Mail, Slack, Notion).
        let minAllowedX: CGFloat? = {
            guard let f = fieldAXRect, let w = windowAXRect, (f.minX - w.minX) > 180 else { return nil }
            return f.minX - 48
        }()
        // Read strictly above the composer box so footer controls ("Full access", model picker) never pollute context.
        let maxAllowedY: CGFloat? = fieldAXRect.map { $0.minY - 4 }

        let deadline = CFAbsoluteTimeGetCurrent() + 0.080
        var stack: [AXUIElement] = [root]
        var visited = 0
        let maxNodes = 520
        var fragments: [(y: CGFloat, x: CGFloat, text: String)] = []

        let skipRoles: Set<String> = [
            "AXSecureTextField", "AXMenuBar", "AXToolbar", "AXScrollBar",
            "AXTabGroup", "AXMenu", "AXPopover", "AXSheet"
        ]

        let prefixTail = String(snapshot.prefix.suffix(80)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        while let cur = stack.popLast(), visited < maxNodes {
            if visited % 24 == 0 && CFAbsoluteTimeGetCurrent() > deadline {
                break
            }
            visited += 1
            if CFEqual(cur, snapshot.element) { continue }

            let role = AX.attribute(cur, kAXRoleAttribute, as: String.self) ?? ""
            if skipRoles.contains(role) { continue }

            if role == "AXStaticText" || role == "AXHeading" || role == "AXTextArea" {
                let rawText = AX.attribute(cur, kAXValueAttribute, as: String.self)
                    ?? AX.attribute(cur, kAXTitleAttribute, as: String.self)
                if let text = rawText?.trimmingCharacters(in: .whitespacesAndNewlines),
                   text.count >= 3,
                   !text.contains("\u{FFFC}") {
                    if let rect = rawAXRect(cur), rect.width >= 4, rect.height >= 4 {
                        if let w = windowAXRect {
                            let visibleInWindow = rect.maxX > w.minX + 4 && rect.minX < w.maxX - 4
                                && rect.maxY > w.minY + 4 && rect.minY < w.maxY - 4
                            if !visibleInWindow { continue }
                        }
                        if let minX = minAllowedX, rect.maxX < minX { continue }
                        if let maxY = maxAllowedY, rect.minY > maxY { continue }

                        let bounded = text.count > 260 ? String(text.suffix(260)) : text
                        let lower = bounded.lowercased()
                        if !prefixTail.isEmpty && (lower == prefixTail || prefixTail.contains(lower)) {
                            continue
                        }
                        fragments.append((rect.minY, rect.minX, bounded))
                    }
                }
                continue
            }

            if let children = AX.attribute(cur, kAXChildrenAttribute, as: [AXUIElement].self), !children.isEmpty {
                // Push in forward order so popLast() explores bottom/right-most nodes first (newest chat messages).
                let cap = min(children.count, 80)
                let startIdx = children.count - cap
                for i in startIdx..<children.count {
                    stack.append(children[i])
                }
            }
        }

        // Reconstruct reading order: group fragments on the same visual line (~7pt vertical bucket) left-to-right.
        fragments.sort { a, b in
            let bucketA = Int((a.y / 7.0).rounded())
            let bucketB = Int((b.y / 7.0).rounded())
            if bucketA != bucketB { return bucketA < bucketB }
            return a.x < b.x
        }

        var lines: [String] = []
        var currentBucket: Int?
        var currentLineParts: [String] = []

        func flushLine() {
            guard !currentLineParts.isEmpty else { return }
            let joined = currentLineParts.joined(separator: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            currentLineParts = []
            guard joined.count >= 6 else { return }
            guard !TypingHistoryStore.containsSensitiveData(joined) else { return }
            if lines.last != joined {
                lines.append(joined)
            }
        }

        for item in fragments {
            let bucket = Int((item.y / 7.0).rounded())
            if currentBucket != bucket {
                flushLine()
                currentBucket = bucket
            }
            currentLineParts.append(item.text)
        }
        flushLine()

        let merged = lines.joined(separator: "\n")
        let screenContext: String? = merged.isEmpty ? nil : String(merged.suffix(PromptBuilder.maxScreenContextChars))
        let result = (pageURL, screenContext)
        cachedScreenContextKey = cacheKey
        cachedScreenContextDate = now
        cachedScreenContextValue = result
        return result
    }

    private static func rawAXRect(_ element: AXUIElement) -> CGRect? {
        var posRaw: AnyObject?
        var sizeRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRaw) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRaw) == .success,
              let posRaw, let sizeRaw,
              CFGetTypeID(posRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else {
            return nil
        }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(posRaw as! AXValue, .cgPoint, &pt),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &sz),
              pt.x.isFinite && pt.y.isFinite && sz.width.isFinite && sz.height.isFinite else {
            return nil
        }
        return CGRect(origin: pt, size: sz)
    }

    private static func extractHTTPURL(from element: AXUIElement, attr: String) -> String? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &raw) == .success, let raw else {
            return nil
        }
        let str: String?
        if let url = raw as? URL {
            str = url.absoluteString
        } else if let s = raw as? String {
            str = s
        } else {
            str = nil
        }
        guard let str, str.hasPrefix("http://") || str.hasPrefix("https://") else { return nil }
        return str
    }

    private static let monospaceBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "com.barebones.bbedit",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
    ]

    static var isSecureEventInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    /// Registers common web/editor fonts (Inter, Roboto, Open Sans, JetBrains Mono, etc.)
    /// into our process read-only if Cotypist is installed locally, so AX font lookups
    /// in browsers and Electron apps match 1-to-1 without bloating KeyVeil.app.
    static func registerBundledWebFontsIfAvailable() {
        guard !didRegisterExtraFonts else { return }
        didRegisterExtraFonts = true

        let candidateDirs = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Cotypist.app/Contents/Resources/Fonts", isDirectory: true),
        ].compactMap { $0 }

        let fm = FileManager.default
        for dir in candidateDirs where fm.fileExists(atPath: dir.path) {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in items where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    static func readFocusedContext() -> FocusedTextSnapshot? {
        guard AX.isTrusted else { return nil }
        registerBundledWebFontsIfAvailable()

        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else {
            return nil
        }

        let pid = app.processIdentifier
        AX.enableWebAccessibility(pid: pid)

        guard let focused = AX.focusedElement(pid: pid) else { return nil }
        AX.setTimeout(focused, seconds: 0.2)

        let role = AX.attribute(focused, kAXRoleAttribute, as: String.self) ?? ""
        let subrole = AX.attribute(focused, kAXSubroleAttribute, as: String.self) ?? ""

        // Strictly never touch password or secure input fields.
        if subrole == "AXSecureTextField" || role == "AXSecureTextField" || subrole.localizedCaseInsensitiveContains("secure") {
            return nil
        }

        let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXWebArea"]
        if !editableRoles.contains(role) {
            let isEditableAttr: Bool = AX.attribute(focused, "AXEditable", as: Bool.self) ?? false
            let hasRange = selectedTextRange(of: focused) != nil
            guard isEditableAttr || hasRange else { return nil }
        }

        guard let range = selectedTextRange(of: focused) else { return nil }
        let caret = max(0, range.location)
        let selectionLen = max(0, range.length)

        // Read bounded text around the caret without copying megabytes from huge documents.
        let (prefix, suffix) = readBoundedText(of: focused, caret: caret, selectionLength: selectionLen)
        guard !prefix.isEmpty || !suffix.isEmpty else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        AX.setTimeout(appElement, seconds: 0.2)
        let focusedWindow = AX.element(appElement, kAXFocusedWindowAttribute)
        let windowFrame = focusedWindow.flatMap { AX.frame($0) }
        let windowTitle = focusedWindow.flatMap { AX.attribute($0, kAXTitleAttribute, as: String.self) }
        let elementFrame = AX.frame(focused)

        guard let rawCaretRect = computeCaretScreenRect(
            element: focused,
            caret: caret,
            selectionLength: selectionLen,
            prefix: prefix,
            elementFrame: elementFrame
        ) else {
            return nil
        }

        let typography = readTypography(
            element: focused,
            caret: caret,
            prefix: prefix,
            suffix: suffix,
            caretRect: rawCaretRect,
            elementFrame: elementFrame,
            windowFrame: windowFrame,
            bundleID: bundleID
        )

        let caretRect = repairCaretRectIfNeeded(
            rawCaretRect,
            element: focused,
            prefix: prefix,
            selectionLength: selectionLen,
            typography: typography,
            elementFrame: elementFrame
        )

        return FocusedTextSnapshot(
            element: focused,
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            windowTitle: windowTitle,
            prefix: prefix,
            suffix: suffix,
            caretLocationUTF16: caret,
            selectionLengthUTF16: selectionLen,
            caretScreenRect: caretRect,
            typography: typography
        )
    }

    /// Lightweight live caret query used to re-sync ghost text position after type-through
    /// or word-by-word acceptance (handles line wraps and Chromium subpixel kerning).
    static func readLiveCaretRect() -> CGRect? {
        guard AX.isTrusted,
              let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              let focused = AX.focusedElement(pid: app.processIdentifier),
              let range = selectedTextRange(of: focused) else {
            return nil
        }
        AX.setTimeout(focused, seconds: 0.15)
        let caret = max(0, range.location)
        let selLen = max(0, range.length)
        let (prefix, suffix) = readBoundedText(of: focused, caret: caret, selectionLength: selLen)
        let elementFrame = AX.frame(focused)
        guard let rawCaret = computeCaretScreenRect(
            element: focused,
            caret: caret,
            selectionLength: selLen,
            prefix: prefix,
            elementFrame: elementFrame
        ) else {
            return nil
        }
        let typography = readTypography(
            element: focused,
            caret: caret,
            prefix: prefix,
            suffix: suffix,
            caretRect: rawCaret,
            elementFrame: elementFrame,
            windowFrame: nil,
            bundleID: bundleID
        )
        return repairCaretRectIfNeeded(
            rawCaret,
            element: focused,
            prefix: prefix,
            selectionLength: selLen,
            typography: typography,
            elementFrame: elementFrame
        )
    }

    static func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// Public helper for computing screen-space bounds of an arbitrary UTF-16 range
    /// (used for inline autocorrect strikethrough over the exact misspelled word).
    static func screenBounds(of element: AXUIElement, location: Int, length: Int) -> CGRect? {
        guard location >= 0, length >= 0 else { return nil }
        return boundsForRange(element, location: location, length: length)
    }

    /// Computes screen-space bounds of a word immediately before the caret, working in both
    /// native AppKit editors (AXBoundsForRange) and Electron/Chromium/WebKit editors (AXTextMarkerRange).
    static func screenBoundsOfWordBeforeCaret(
        of element: AXUIElement,
        caretUTF16: Int,
        replaceLengthUTF16: Int,
        wordUTF16Length: Int
    ) -> CGRect? {
        let wordStart = max(0, caretUTF16 - replaceLengthUTF16)
        if let rect = boundsForRange(element, location: wordStart, length: wordUTF16Length),
           rect.width > 1 {
            return rect
        }

        // Chromium / Electron / WebKit fallback via AXTextMarker stepping.
        guard let selMR = selectedTextMarkerRange(of: element) else { return nil }
        let trailingChars = max(0, replaceLengthUTF16 - wordUTF16Length)
        guard wordUTF16Length > 0, wordUTF16Length <= 64, trailingChars <= 4 else { return nil }

        var wordEndMarker = AXTextMarkerRangeCopyStartMarker(selMR)
        for _ in 0..<trailingChars {
            guard let prev = previousTextMarker(of: element, from: wordEndMarker) else { return nil }
            wordEndMarker = prev
        }
        var wordStartMarker = wordEndMarker
        for _ in 0..<wordUTF16Length {
            guard let prev = previousTextMarker(of: element, from: wordStartMarker) else { return nil }
            wordStartMarker = prev
        }

        let wordRange = AXTextMarkerRangeCreate(kCFAllocatorDefault, wordStartMarker, wordEndMarker)
        guard let rect = boundsForTextMarkerRange(element, markerRange: wordRange),
              rect.width > 1 else {
            return nil
        }
        return rect
    }

    private static func readBoundedText(of element: AXUIElement, caret: Int, selectionLength: Int) -> (String, String) {
        let prefixWindow = 2000
        let suffixWindow = 240

        // Prefer AXStringForRange on large documents to avoid fetching megabytes of AXValue.
        if let totalChars: Int = AX.attribute(element, kAXNumberOfCharactersAttribute, as: Int.self), totalChars > 4000 {
            let pStart = max(0, caret - prefixWindow)
            let pLen = max(0, min(caret, totalChars) - pStart)
            let sStart = min(totalChars, caret + selectionLength)
            let sLen = max(0, min(totalChars - sStart, suffixWindow))
            let prefix = stringForRange(element, location: pStart, length: pLen) ?? ""
            let suffix = stringForRange(element, location: sStart, length: sLen) ?? ""
            return (prefix, suffix)
        }

        guard let value: String = AX.attribute(element, kAXValueAttribute, as: String.self) else {
            return ("", "")
        }
        let ns = value as NSString
        let total = ns.length
        let clampedCaret = min(max(0, caret), total)
        let pStart = max(0, clampedCaret - prefixWindow)
        let prefix = ns.substring(with: NSRange(location: pStart, length: clampedCaret - pStart))

        let sStart = min(total, clampedCaret + selectionLength)
        let sLen = max(0, min(total - sStart, suffixWindow))
        let suffix = ns.substring(with: NSRange(location: sStart, length: sLen))
        return (prefix, suffix)
    }

    private static func stringForRange(_ element: AXUIElement, location: Int, length: Int) -> String? {
        guard length > 0 else { return "" }
        var cfRange = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &result
        ) == .success else { return nil }
        return result as? String
    }

    /// Converts AX top-left coordinates to Cocoa bottom-left screen coordinates.
    private static func axToCocoaRect(_ axRect: CGRect) -> CGRect {
        let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        let primaryHeight = primaryScreen?.frame.height ?? NSScreen.main?.frame.height ?? 900
        return CGRect(
            x: axRect.origin.x,
            y: primaryHeight - axRect.origin.y - axRect.size.height,
            width: axRect.size.width,
            height: axRect.size.height
        )
    }

    private static func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var cfRange = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var raw: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &raw
        ) == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(raw as! AXValue, .cgRect, &rect) else { return nil }
        guard rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite else {
            return nil
        }
        guard rect.height > 4 && rect.height < 140 else { return nil }
        return axToCocoaRect(rect)
    }

    // MARK: - AXTextMarker Helpers (Chromium / Electron / ProseMirror / WebKit)

    private static func selectedTextMarkerRange(of element: AXUIElement) -> AXTextMarkerRange? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else {
            return nil
        }
        return (raw as! AXTextMarkerRange)
    }

    private static func previousTextMarker(of element: AXUIElement, from marker: AXTextMarker) -> AXTextMarker? {
        var raw: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXPreviousTextMarkerForTextMarker" as CFString,
            marker,
            &raw
        ) == .success, let raw, CFGetTypeID(raw) == AXTextMarkerGetTypeID() else {
            return nil
        }
        return (raw as! AXTextMarker)
    }

    private static func lineTextMarkerRange(of element: AXUIElement, for marker: AXTextMarker) -> AXTextMarkerRange? {
        var raw: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXLineTextMarkerRangeForTextMarker" as CFString,
            marker,
            &raw
        ) == .success, let raw, CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else {
            return nil
        }
        return (raw as! AXTextMarkerRange)
    }

    private static func leftLineTextMarkerRange(of element: AXUIElement, for marker: AXTextMarker) -> AXTextMarkerRange? {
        var raw: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXLeftLineTextMarkerRangeForTextMarker" as CFString,
            marker,
            &raw
        ) == .success, let raw, CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else {
            return nil
        }
        return (raw as! AXTextMarkerRange)
    }

    private static func stringForTextMarkerRange(_ element: AXUIElement, markerRange: AXTextMarkerRange) -> String? {
        var raw: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXStringForTextMarkerRange" as CFString,
            markerRange,
            &raw
        ) == .success else {
            return nil
        }
        return raw as? String
    }

    private static func boundsForTextMarkerRange(_ element: AXUIElement, markerRange: AXTextMarkerRange) -> CGRect? {
        var raw: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXBoundsForTextMarkerRange" as CFString,
            markerRange,
            &raw
        ) == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(raw as! AXValue, .cgRect, &rect) else { return nil }
        guard rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite else {
            return nil
        }
        guard rect.height > 4 && rect.height < 140 else { return nil }
        return axToCocoaRect(rect)
    }

    private static func uiElementForTextMarker(_ element: AXUIElement, marker: AXTextMarker) -> AXUIElement? {
        var raw: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXUIElementForTextMarker" as CFString,
            marker,
            &raw
        ) == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        return (raw as! AXUIElement)
    }

    private static func isRectPlausiblyInside(_ rect: CGRect, elementFrame: CGRect?) -> Bool {
        guard let elementFrame, elementFrame.width > 4, elementFrame.height > 4 else { return true }
        let expanded = elementFrame.insetBy(dx: -32, dy: -32)
        return expanded.contains(CGPoint(x: rect.minX, y: rect.midY))
            || expanded.contains(CGPoint(x: rect.maxX, y: rect.midY))
    }

    private static func computeCaretScreenRect(
        element: AXUIElement,
        caret: Int,
        selectionLength: Int,
        prefix: String,
        elementFrame: CGRect?
    ) -> CGRect? {
        let lastChar = prefix.last
        let currentLineHasText: Bool = {
            guard !prefix.isEmpty, lastChar != "\n", lastChar != "\r" else { return false }
            return true
        }()

        // 1. Native AppKit NSTextView / TextEdit / Notes / Mail / Telegram:
        //    Preceding character bounds anchored to its right edge.
        if caret > 0, currentLineHasText,
           let prevRect = boundsForRange(element, location: caret - 1, length: 1),
           prevRect.origin != .zero,
           prevRect.width > 0 && prevRect.width < 120,
           isRectPlausiblyInside(prevRect, elementFrame: elementFrame) {
            return CGRect(x: prevRect.maxX, y: prevRect.minY, width: 2, height: prevRect.height)
        }

        // 2. Chromium / Electron / ProseMirror / WebKit (Codex, Claude, Slack, Notion, Chrome, Safari):
        //    AXSelectedTextMarkerRange + AXBoundsForTextMarkerRange gives the exact caret rect even
        //    when AXBoundsForRange returns (0, 0, 0, 0).
        if let selMR = selectedTextMarkerRange(of: element) {
            let startMarker = AXTextMarkerRangeCopyStartMarker(selMR)
            let leftLineMR = leftLineTextMarkerRange(of: element, for: startMarker)
            let leftLineStr = leftLineMR.flatMap { stringForTextMarkerRange(element, markerRange: $0) }
            let leftLineIsValidInPrefix: Bool = {
                guard let s = leftLineStr, !s.isEmpty, !s.contains("\n"), !s.contains("\u{FFFC}") else {
                    return false
                }
                if prefix.hasSuffix(s) { return true }
                let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
                let trimmedLeft = s.trimmingCharacters(in: .whitespaces)
                return !trimmedLeft.isEmpty && trimmedPrefix.hasSuffix(trimmedLeft)
            }()

            // 2a. Collapsed caret bounds directly from AXSelectedTextMarkerRange.
            //     Reject full-line/placeholder boxes (width > 12).
            if selectionLength == 0,
               let selRect = boundsForTextMarkerRange(element, markerRange: selMR),
               selRect.width <= 12,
               isRectPlausiblyInside(selRect, elementFrame: elementFrame) {
                // Guard against a Chromium edge case where a collapsed marker jumps to the far left
                // edge of the field even though the CURRENT visual line already has typed text.
                // (On a real soft wrap to column 0 of line 2, `leftLineIsValidInPrefix` is false.)
                let suspiciousLeftEdge = leftLineIsValidInPrefix
                    && elementFrame.map { abs(selRect.minX - $0.minX) < 1.5 } == true
                if !suspiciousLeftEdge {
                    return CGRect(x: selRect.maxX, y: selRect.minY, width: max(2, selRect.width), height: selRect.height)
                }
            }

            // 2b. Single preceding character via AXPreviousTextMarkerForTextMarker.
            if currentLineHasText,
               let prevMarker = previousTextMarker(of: element, from: startMarker) {
                let prevRange = AXTextMarkerRangeCreate(kCFAllocatorDefault, prevMarker, startMarker)
                let prevStr = stringForTextMarkerRange(element, markerRange: prevRange)
                if let prevStr, prevStr.count == 1,
                   prevStr != "\u{FFFC}", prevStr != "\n", prevStr != "\r",
                   let prevRect = boundsForTextMarkerRange(element, markerRange: prevRange),
                   prevRect.width > 0 && prevRect.width < 100 && prevRect.height <= 64,
                   isRectPlausiblyInside(prevRect, elementFrame: elementFrame) {
                    return CGRect(x: prevRect.maxX, y: prevRect.minY, width: 2, height: prevRect.height)
                }
            }

            // 2c. Text from line start to caret via AXLeftLineTextMarkerRangeForTextMarker
            //     (rescues trailing-space cases in Chromium contenteditable without leaking outside DOM).
            if currentLineHasText,
               leftLineIsValidInPrefix,
               let leftLineMR,
               let leftRect = boundsForTextMarkerRange(element, markerRange: leftLineMR),
               leftRect.width > 1 && leftRect.height <= 48,
               isRectPlausiblyInside(leftRect, elementFrame: elementFrame) {
                let isFullContainer = elementFrame.map { leftRect.width >= $0.width - 2 } ?? false
                if !isFullContainer {
                    return CGRect(x: leftRect.maxX, y: leftRect.minY, width: 2, height: leftRect.height)
                }
            }
        }

        // 3. Native zero-width AXBoundsForRange at caret (e.g., start of line).
        if let zeroRect = boundsForRange(element, location: caret, length: 0),
           zeroRect.origin != .zero,
           zeroRect.width <= 12,
           isRectPlausiblyInside(zeroRect, elementFrame: elementFrame) {
            return CGRect(x: zeroRect.maxX, y: zeroRect.minY, width: max(2, zeroRect.width), height: zeroRect.height)
        }

        // Never fall back to element origin or mouse cursor — showing inline ghost text without
        // true caret coordinates causes overlap over typed text.
        return nil
    }

    /// Inspects child `<p>` (`AXGroup`) and `AXStaticText` nodes inside a Chromium/Electron
    /// ProseMirror `AXTextArea` to obtain ground-truth CSS line coordinates in Cocoa screen space.
    private static func readChildParagraphLineGeometry(
        of element: AXUIElement,
        currentParagraph: String
    ) -> (paragraphRect: CGRect?, staticTextRect: CGRect?) {
        let trimmedTarget = currentParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else { return (nil, nil) }
        guard let children = AX.attribute(element, kAXChildrenAttribute, as: [AXUIElement].self),
              !children.isEmpty else {
            return (nil, nil)
        }

        // Check up to the last 24 child blocks in reverse order so long composers stay fast.
        for child in children.suffix(24).reversed() {
            let role = AX.attribute(child, kAXRoleAttribute, as: String.self) ?? ""
            if role == "AXStaticText" {
                let val = (AX.attribute(child, kAXValueAttribute, as: String.self) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty && (val == trimmedTarget || val.hasSuffix(trimmedTarget) || trimmedTarget.hasSuffix(val)) {
                    let rect = AX.frame(child)
                    return (rect, rect)
                }
                continue
            }

            guard role == "AXGroup" else { continue }
            guard let grandChildren = AX.attribute(child, kAXChildrenAttribute, as: [AXUIElement].self),
                  !grandChildren.isEmpty else {
                continue
            }

            // Collect leaf AXStaticText nodes inside this paragraph group.
            var matchedStaticRect: CGRect?
            var matchedAny = false
            for g in grandChildren.suffix(16).reversed() {
                let gRole = AX.attribute(g, kAXRoleAttribute, as: String.self) ?? ""
                if gRole == "AXStaticText" {
                    let val = (AX.attribute(g, kAXValueAttribute, as: String.self) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !val.isEmpty && (val == trimmedTarget || val.hasSuffix(trimmedTarget) || trimmedTarget.hasSuffix(val)) {
                        matchedAny = true
                        if val == trimmedTarget {
                            matchedStaticRect = AX.frame(g)
                        }
                        break
                    }
                } else if gRole == "AXGroup",
                          let deep = AX.attribute(g, kAXChildrenAttribute, as: [AXUIElement].self) {
                    for d in deep.suffix(8).reversed() {
                        if AX.attribute(d, kAXRoleAttribute, as: String.self) == "AXStaticText" {
                            let val = (AX.attribute(d, kAXValueAttribute, as: String.self) ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !val.isEmpty && (val == trimmedTarget || val.hasSuffix(trimmedTarget) || trimmedTarget.hasSuffix(val)) {
                                matchedAny = true
                                if val == trimmedTarget {
                                    matchedStaticRect = AX.frame(d)
                                }
                                break
                            }
                        }
                    }
                    if matchedAny { break }
                }
            }

            if matchedAny {
                return (AX.frame(child), matchedStaticRect)
            }
        }

        return (nil, nil)
    }

    /// Validates any AX-reported caret rect against the actual rendered width and vertical
    /// bounds of the current line, repairing Chromium/Electron ProseMirror glitches where
    /// AXBoundsForTextMarkerRange snaps near the left edge or drifts vertically onto padding.
    private static func repairCaretRectIfNeeded(
        _ rawCaret: CGRect,
        element: AXUIElement,
        prefix: String,
        selectionLength: Int,
        typography: FieldTypography,
        elementFrame: CGRect?
    ) -> CGRect {
        guard selectionLength == 0 else { return rawCaret }

        // Extract text on the current paragraph before the caret.
        let currentParagraph: String = {
            if let nl = prefix.lastIndex(where: { $0 == "\n" || $0 == "\r" }) {
                return String(prefix[prefix.index(after: nl)...])
            }
            return prefix
        }()
        guard !currentParagraph.isEmpty else { return rawCaret }

        // Check Chromium AXLeftLineTextMarkerRangeForTextMarker when available (handles wrapped lines too).
        var leftLineStr: String?
        var leftLineRect: CGRect?
        if let selMR = selectedTextMarkerRange(of: element) {
            let startMarker = AXTextMarkerRangeCopyStartMarker(selMR)
            if let leftMR = leftLineTextMarkerRange(of: element, for: startMarker),
               let s = stringForTextMarkerRange(element, markerRange: leftMR),
               !s.isEmpty, !s.contains("\n"), !s.contains("\u{FFFC}") {
                let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
                let trimmedLeft = s.trimmingCharacters(in: .whitespaces)
                if prefix.hasSuffix(s) || (!trimmedLeft.isEmpty && trimmedPrefix.hasSuffix(trimmedLeft)) {
                    leftLineStr = s
                    leftLineRect = boundsForTextMarkerRange(element, markerRange: leftMR)
                }
            }
        }

        let font = typography.font
        let naturalLineHeight = max(14, ceil(font.ascender - font.descender + font.leading))
        let childGeo = readChildParagraphLineGeometry(of: element, currentParagraph: currentParagraph)

        let fieldWidth = (typography.fieldVisibleFrame ?? elementFrame)?.width
        let activeLineText = leftLineStr ?? currentParagraph
        let expectedWidth = GhostOverlayPanel.advanceWidth(of: activeLineText, font: font)
        let isSingleVisualLine = (leftLineStr != nil) || (fieldWidth.map { expectedWidth < $0 - 16 } ?? true)

        let anchorLeftX: CGFloat = childGeo.staticTextRect?.minX
            ?? childGeo.paragraphRect?.minX
            ?? typography.lineLeftX
            ?? elementFrame?.minX
            ?? rawCaret.minX

        var repaired = rawCaret
        var didRepair = false

        // 1. Horizontal overlap guard: reject broken AX rects that land left of the actual typed text.
        if isSingleVisualLine && expectedWidth >= 20 {
            let minPlausibleX = anchorLeftX + expectedWidth * 0.68
            if repaired.minX < minPlausibleX {
                if let sr = childGeo.staticTextRect,
                   sr.height <= naturalLineHeight * 1.85,
                   sr.maxX >= minPlausibleX {
                    repaired = CGRect(x: sr.maxX, y: sr.minY, width: 2, height: sr.height)
                    didRepair = true
                } else if let lr = leftLineRect,
                          lr.height <= naturalLineHeight * 1.85,
                          lr.maxX >= minPlausibleX,
                          (fieldWidth.map { lr.width < $0 - 4 } ?? true) {
                    repaired = CGRect(x: lr.maxX, y: lr.minY, width: 2, height: lr.height)
                    didRepair = true
                } else {
                    let anchorY = childGeo.paragraphRect?.minY ?? repaired.minY
                    let anchorH = childGeo.paragraphRect.map { min($0.height, naturalLineHeight + 6) } ?? min(repaired.height, naturalLineHeight + 6)
                    repaired = CGRect(x: anchorLeftX + expectedWidth, y: anchorY, width: 2, height: anchorH)
                    didRepair = true
                }
            }
        }

        // 2. Vertical drift guard: lock onto the single-line `<p>` / `AXStaticText` box when
        //    Chromium reports an oversized container height or vertically offset rect.
        if let lineBox = (childGeo.staticTextRect ?? childGeo.paragraphRect),
           lineBox.height >= 12 && lineBox.height <= naturalLineHeight * 1.75 {
            let tooTall = repaired.height > lineBox.height * 1.35
            let driftedY = abs(repaired.midY - lineBox.midY) > 2.5
            if tooTall || driftedY {
                repaired.origin.y = lineBox.minY
                repaired.size.height = lineBox.height
                didRepair = true
            }
        }

        if didRepair {
            Self.logger.info(
                "Repaired caret rect from (\(Int(rawCaret.minX)),\(Int(rawCaret.minY)),h=\(Int(rawCaret.height))) to (\(Int(repaired.minX)),\(Int(repaired.minY)),h=\(Int(repaired.height))) expectedW=\(Int(expectedWidth))"
            )
        }

        return repaired
    }

    // MARK: - Typography & Line Geometry (1-to-1 with Cotypist's AX font/color/line reading)

    private static func readTypography(
        element: AXUIElement,
        caret: Int,
        prefix: String,
        suffix: String,
        caretRect: CGRect,
        elementFrame: CGRect?,
        windowFrame: CGRect?,
        bundleID: String
    ) -> FieldTypography {
        let sameLineSuffix = suffix.prefix { $0 != "\n" && $0 != "\r" }
        let hasSameLineSuffix = sameLineSuffix.contains(where: { !$0.isWhitespace })

        // Visible field bounds clamped to the focused window.
        var visibleField = elementFrame
        if let f = visibleField, let w = windowFrame {
            let clipped = f.intersection(w)
            if !clipped.isNull && clipped.width > 20 && clipped.height > 10 {
                visibleField = clipped
            }
        }

        // Determine the exact left edge of the current line and CSS/editor line step height.
        let lineGeo = readCurrentLineGeometry(
            element: element,
            caret: caret,
            caretRect: caretRect,
            fieldFrame: visibleField
        )

        // Read attributed string around the caret for exact font & foreground/background colors.
        let attrSample = readAttributedSample(element: element, caret: caret)
        let matchedFont = attrSample.font ?? inferredFallbackFont(caretHeight: caretRect.height, bundleID: bundleID)
        let fgColor = attrSample.foregroundColor
        let bgColor = attrSample.backgroundColor
        let isDark = detectDarkBackground(bgColor: bgColor, fgColor: fgColor)

        return FieldTypography(
            font: matchedFont,
            foregroundColor: fgColor,
            backgroundColor: bgColor,
            isDarkBackground: isDark,
            lineLeftX: lineGeo.leftX,
            lineStepHeight: lineGeo.lineStepHeight,
            fieldVisibleFrame: visibleField,
            hasSameLineSuffix: hasSameLineSuffix
        )
    }

    private static func readCurrentLineGeometry(
        element: AXUIElement,
        caret: Int,
        caretRect: CGRect,
        fieldFrame: CGRect?
    ) -> (leftX: CGFloat?, lineStepHeight: CGFloat?) {
        var resolvedLeftX: CGFloat?
        var resolvedLineStep: CGFloat?

        // 1. Chromium / Electron / WebKit: AXLineTextMarkerRangeForTextMarker gives exact visual line bounds
        //    and AXUIElementForTextMarker's parent paragraph (<p> AXGroup) reveals CSS line-height.
        if let selMR = selectedTextMarkerRange(of: element) {
            let startMarker = AXTextMarkerRangeCopyStartMarker(selMR)
            if let lineMR = lineTextMarkerRange(of: element, for: startMarker),
               let lineStr = stringForTextMarkerRange(element, markerRange: lineMR),
               !lineStr.contains("\u{FFFC}"),
               let lineBounds = boundsForTextMarkerRange(element, markerRange: lineMR),
               lineBounds.height <= max(caretRect.height * 2.2, 48),
               lineBounds.minX <= caretRect.minX + 2 {
                resolvedLeftX = lineBounds.minX
                if lineBounds.height > caretRect.height && lineBounds.height <= caretRect.height * 1.8 {
                    resolvedLineStep = lineBounds.height
                }
            }

            if resolvedLineStep == nil,
               let markerEl = uiElementForTextMarker(element, marker: startMarker),
               let parentEl = AX.element(markerEl, kAXParentAttribute),
               AX.attribute(parentEl, kAXRoleAttribute, as: String.self) == "AXGroup",
               let parentFrame = AX.frame(parentEl),
               parentFrame.height >= caretRect.height && parentFrame.height <= caretRect.height * 1.75 {
                resolvedLineStep = parentFrame.height
                if resolvedLeftX == nil && parentFrame.minX <= caretRect.minX + 2 {
                    resolvedLeftX = parentFrame.minX
                }
            }
        }

        // 2. Native AppKit editors: AXLineForIndex + AXRangeForLine + AXBoundsForRange.
        if resolvedLeftX == nil {
            let probeIndex = max(0, caret > 0 ? caret - 1 : 0)
            var lineNumberRef: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXLineForIndexParameterizedAttribute as CFString,
                NSNumber(value: probeIndex),
                &lineNumberRef
            ) == .success, let lineNum = lineNumberRef as? Int {
                var lineRangeRef: AnyObject?
                if AXUIElementCopyParameterizedAttributeValue(
                    element,
                    kAXRangeForLineParameterizedAttribute as CFString,
                    NSNumber(value: lineNum),
                    &lineRangeRef
                ) == .success, let lineRangeRef, CFGetTypeID(lineRangeRef) == AXValueGetTypeID() {
                    var lineRange = CFRange()
                    if AXValueGetValue(lineRangeRef as! AXValue, .cfRange, &lineRange),
                       lineRange.length > 0,
                       let firstCharRect = boundsForRange(element, location: lineRange.location, length: 1),
                       firstCharRect.minX <= caretRect.minX + 2 {
                        resolvedLeftX = firstCharRect.minX
                    }
                }
            }
        }

        // 3. Fallback to field left edge (without adding artificial inset that misaligns Electron inputs).
        if resolvedLeftX == nil, let f = fieldFrame, f.minX <= caretRect.minX + 2 {
            resolvedLeftX = f.minX
        }

        return (resolvedLeftX, resolvedLineStep)
    }

    private static func readAttributedSample(
        element: AXUIElement,
        caret: Int
    ) -> (font: NSFont?, foregroundColor: NSColor?, backgroundColor: NSColor?) {
        // 1. Prefer AXAttributedStringForTextMarkerRange on the character(s) before the caret
        //    in Chromium/Electron/WebKit (step back up to 2 markers in case the caret follows a space).
        if let selMR = selectedTextMarkerRange(of: element) {
            var endMarker = AXTextMarkerRangeCopyStartMarker(selMR)
            for _ in 0..<2 {
                guard let prevMarker = previousTextMarker(of: element, from: endMarker) else { break }
                let prevRange = AXTextMarkerRangeCreate(kCFAllocatorDefault, prevMarker, endMarker)
                var raw: AnyObject?
                if AXUIElementCopyParameterizedAttributeValue(
                    element,
                    "AXAttributedStringForTextMarkerRange" as CFString,
                    prevRange,
                    &raw
                ) == .success, let attrStr = raw as? NSAttributedString, attrStr.length > 0,
                   !attrStr.string.contains("\u{FFFC}") {
                    let parsed = parseAttributedString(attrStr, at: attrStr.length - 1)
                    if parsed.font != nil || parsed.foregroundColor != nil {
                        return parsed
                    }
                }
                endMarker = prevMarker
            }
        }

        // 2. Native AppKit / standard AXAttributedStringForRange.
        let probeLoc = caret > 0 ? caret - 1 : 0
        var cfRange = CFRange(location: probeLoc, length: 1)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else {
            return (nil, nil, nil)
        }
        var raw: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXAttributedStringForRangeParameterizedAttribute as CFString,
            axRange,
            &raw
        ) == .success, let attrStr = raw as? NSAttributedString, attrStr.length > 0 else {
            return (nil, nil, nil)
        }
        return parseAttributedString(attrStr, at: 0)
    }

    private static func parseAttributedString(
        _ attrStr: NSAttributedString,
        at index: Int
    ) -> (font: NSFont?, foregroundColor: NSColor?, backgroundColor: NSColor?) {
        let clamped = min(max(0, index), attrStr.length - 1)
        let attrs = attrStr.attributes(at: clamped, effectiveRange: nil)

        let axFontKey = kAXFontTextAttribute.takeUnretainedValue() as String
        let axFgKey = kAXForegroundColorTextAttribute.takeUnretainedValue() as String
        let axBgKey = kAXBackgroundColorTextAttribute.takeUnretainedValue() as String

        var resolvedFont: NSFont?
        if let fontDict = attrs[NSAttributedString.Key(axFontKey)] as? [String: Any] {
            resolvedFont = resolveFont(from: fontDict)
        } else if let directFont = attrs[.font] as? NSFont {
            resolvedFont = directFont
        }

        let fg = parseAXColor(attrs[NSAttributedString.Key(axFgKey)])
            ?? (attrs[.foregroundColor] as? NSColor)
        let bg = parseAXColor(attrs[NSAttributedString.Key(axBgKey)])
            ?? (attrs[.backgroundColor] as? NSColor)

        return (resolvedFont, fg, bg)
    }

    private static func resolveFont(from dict: [String: Any]) -> NSFont? {
        let sizeKey = kAXFontSizeKey.takeUnretainedValue() as String
        let nameKey = kAXFontNameKey.takeUnretainedValue() as String
        let familyKey = kAXFontFamilyKey.takeUnretainedValue() as String

        let rawSize = (dict[sizeKey] as? NSNumber)?.doubleValue
            ?? (dict["AXFontSize"] as? NSNumber)?.doubleValue
            ?? Double(NSFont.systemFontSize)
        let size = CGFloat(min(max(rawSize, 9), 48))

        let fontName = (dict[nameKey] as? String)
            ?? (dict["AXFontName"] as? String)
        let familyName = (dict[familyKey] as? String)
            ?? (dict["AXFontFamily"] as? String)

        // 1. Direct PostScript / system font name match.
        if let fontName, !fontName.isEmpty {
            if fontName.hasPrefix(".AppleSystemUIFont") || fontName.hasPrefix(".SFNS") {
                return systemFontMatching(descriptorName: fontName, size: size)
            }
            if let exact = NSFont(name: fontName, size: size) {
                return exact
            }
        }

        // 2. Family name match (also handles CSS stacks like "Inter, -apple-system, sans-serif").
        if let familyName, !familyName.isEmpty {
            let candidates = familyName
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))) }
                .filter { !$0.isEmpty }
            for fam in candidates {
                let lower = fam.lowercased()
                if lower == "-apple-system" || lower == "system-ui" || lower == "blinkmacsystemfont" || lower == "sf pro text" || lower == "sf pro" {
                    return NSFont.systemFont(ofSize: size)
                }
                if lower == "monospace" || lower == "ui-monospace" || lower == "sf mono" {
                    return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                }
                if let matched = NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: size) {
                    return matched
                }
                if let direct = NSFont(name: fam, size: size) {
                    return direct
                }
            }
        }

        return NSFont.systemFont(ofSize: size)
    }

    private static func systemFontMatching(descriptorName: String, size: CGFloat) -> NSFont {
        let lower = descriptorName.lowercased()
        let weight: NSFont.Weight
        if lower.contains("bold") {
            weight = .bold
        } else if lower.contains("semibold") || lower.contains("demibold") {
            weight = .semibold
        } else if lower.contains("medium") {
            weight = .medium
        } else if lower.contains("light") {
            weight = .light
        } else {
            weight = .regular
        }
        if lower.contains("mono") {
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if lower.contains("italic") || lower.contains("oblique") {
            return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        }
        return base
    }

    private static func inferredFallbackFont(caretHeight: CGFloat, bundleID: String) -> NSFont {
        // Typical line height is ~1.22–1.35× font size; 0.78× matches TextEdit/Notes/Chrome well.
        let estimated = (caretHeight * 0.78).rounded()
        let size = min(max(estimated, 11), 32)
        if monospaceBundleIDs.contains(bundleID) {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return NSFont.systemFont(ofSize: size)
    }

    private static func parseAXColor(_ value: Any?) -> NSColor? {
        guard let value else { return nil }
        if let nsColor = value as? NSColor {
            return nsColor
        }
        let cfObj = value as CFTypeRef
        if CFGetTypeID(cfObj) == CGColor.typeID {
            let cgColor = cfObj as! CGColor
            return NSColor(cgColor: cgColor)
        }
        return nil
    }

    private static func detectDarkBackground(bgColor: NSColor?, fgColor: NSColor?) -> Bool {
        if let bg = bgColor?.usingColorSpace(.sRGB), bg.alphaComponent > 0.3 {
            let lum = 0.2126 * bg.redComponent + 0.7152 * bg.greenComponent + 0.0722 * bg.blueComponent
            return lum < 0.5
        }
        if let fg = fgColor?.usingColorSpace(.sRGB), fg.alphaComponent > 0.3 {
            let lum = 0.2126 * fg.redComponent + 0.7152 * fg.greenComponent + 0.0722 * fg.blueComponent
            return lum > 0.55
        }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
