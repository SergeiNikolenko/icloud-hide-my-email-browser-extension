import AppKit
import AutocompleteCore
import Foundation

/// Native AppKit inline ghost-text overlay modeled 1-to-1 after Cotypist's `SingleCompletionOverlay`:
/// - Completely transparent, borderless, shadowless, click-through `NSPanel`.
/// - Renders directly in the editor's matched `NSFont`, baseline, line height, and text color
///   using `NSTextStorage` + `NSLayoutManager` + `NSTextContainer` (`lineFragmentPadding = 0`).
/// - Uses `firstLineHeadIndent` so line 1 starts at the exact caret X while wrapped lines align
///   naturally with the paragraph's left margin.
/// - Renders autocorrect inline with Cotypist's exact red strikethrough (`#C74747` / `#E05555`)
///   over the typo word and green correction (`#0A8A30` / `#13AE3E`) right beside it.
/// - Zero material pills, zero borders, zero keycap badges by default.
@MainActor
final class GhostOverlayPanel {
    static let shared = GhostOverlayPanel()

    private var panel: NSPanel?
    private let ghostView = InlineGhostTextView()
    private(set) var isVisible = false

    func show(
        suggestion: ActiveSuggestion,
        at caretRect: CGRect,
        typography: FieldTypography,
        typoWordRect: CGRect? = nil,
        acceptBadge: String? = nil,
        showShortcutHint: Bool = false
    ) {
        let panel = panel ?? makePanel()
        self.panel = panel

        let screen = NSScreen.screens.first(where: { $0.frame.contains(caretRect.origin) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let screenBounds = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let backingScale = screen?.backingScaleFactor ?? 2.0

        switch suggestion.kind {
        case .completion:
            showCompletion(
                text: suggestion.text,
                panel: panel,
                caretRect: caretRect,
                typography: typography,
                screenBounds: screenBounds,
                backingScale: backingScale,
                acceptBadge: showShortcutHint ? acceptBadge : nil
            )

        case .autocorrect(_, let original):
            showAutocorrect(
                replacement: suggestion.text.trimmingCharacters(in: .whitespaces),
                original: original,
                panel: panel,
                caretRect: caretRect,
                typoWordRect: typoWordRect,
                typography: typography,
                screenBounds: screenBounds,
                backingScale: backingScale
            )

        case .emoji:
            showEmoji(
                emoji: suggestion.text,
                panel: panel,
                caretRect: caretRect,
                typography: typography,
                screenBounds: screenBounds,
                backingScale: backingScale
            )
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    /// Exact glyph advance width for zero-latency type-through & word-by-word updates.
    static func advanceWidth(of text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return width.isFinite ? width : CGFloat(text.count) * (font.pointSize * 0.55)
    }

    private static func snapToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let s = max(scale, 1.0)
        return (value * s).rounded() / s
    }

    // MARK: - Completion Layout (1-to-1 Cotypist NSLayoutManager + firstLineHeadIndent)

    private func showCompletion(
        text: String,
        panel: NSPanel,
        caretRect: CGRect,
        typography: FieldTypography,
        screenBounds: CGRect,
        backingScale: CGFloat,
        acceptBadge: String?
    ) {
        let font = typography.font
        let naturalLineHeight = ghostView.defaultLineHeight(for: font)
        let editorBoxHeight = caretRect.height > 4 ? caretRect.height : naturalLineHeight
        let lineStep = typography.lineStepHeight ?? editorBoxHeight
        let lineSpacing: CGFloat = (lineStep > naturalLineHeight && lineStep <= naturalLineHeight * 2.1)
            ? (lineStep - naturalLineHeight)
            : 0

        // Align panel left edge to the paragraph's left margin so wrapped lines stay in the column.
        let clipRight = min(
            (typography.fieldVisibleFrame?.maxX ?? screenBounds.maxX) - 2,
            screenBounds.maxX - 4
        )
        let preferredLeft = typography.lineLeftX ?? caretRect.minX
        let panelLeftX = Self.snapToPixel(
            max(screenBounds.minX + 2, min(preferredLeft, caretRect.minX)),
            scale: backingScale
        )
        let firstLineIndent = max(0, caretRect.minX - panelLeftX)
        let availableWidth = max(max(firstLineIndent + 24, 120), min(clipRight - panelLeftX, 760))

        // Build Cotypist-style attributed string with exact suggestionDefault color & gentle tail fade.
        let baseGhostColor = Self.ghostTextColor(for: typography)
        let attributed = Self.buildCompletionAttributedString(
            text: text,
            font: font,
            baseColor: baseGhostColor,
            firstLineHeadIndent: firstLineIndent,
            lineSpacing: lineSpacing,
            acceptBadge: acceptBadge
        )

        // Compute exact editor baseline from the font's ascender/descender centered inside caretRect.
        // Allow slightly negative half-leading when Chromium reports a tight glyph box (e.g. 16px for 14pt SF Pro)
        // so line 1 never drifts downward relative to the typed text.
        let fontBoxHeight = max(1, font.ascender - font.descender)
        let editorHalfLeading = (editorBoxHeight - fontBoxHeight) / 2
        let editorBaselineY = caretRect.minY + editorHalfLeading + abs(font.descender)
        let estPanelTopY = editorBaselineY + ceil(font.ascender)

        let maxLinesHeight = max(lineStep * 3 + 6, naturalLineHeight * 3 + 6, 56)
        let screenRoomBelow = max(naturalLineHeight + 2, estPanelTopY - (screenBounds.minY + 2))
        var maxHeight = min(maxLinesHeight, screenRoomBelow)
        if let fieldFrame = typography.fieldVisibleFrame {
            let fieldRoomBelow = max(naturalLineHeight + 2, estPanelTopY - fieldFrame.minY + 2)
            maxHeight = min(maxHeight, fieldRoomBelow)
        }

        let metrics = ghostView.configureCompletion(
            attributedString: attributed,
            containerWidth: availableWidth,
            maxHeight: maxHeight,
            naturalLineHeight: naturalLineHeight,
            drawInlineBacking: typography.hasSameLineSuffix,
            backingColor: Self.inlineBackingColor(for: typography)
        )

        // Lock line 1's actual NSLayoutManager baseline directly onto the editor's baseline.
        let panelTopY = Self.snapToPixel(
            min(editorBaselineY + metrics.firstLineBaselineFromTop, screenBounds.maxY),
            scale: backingScale
        )

        let panelHeight = ceil(min(maxHeight + 2, max(metrics.usedSize.height + 2, naturalLineHeight + 2)))
        let panelWidth = ceil(max(availableWidth, firstLineIndent + 32))
        let originY = Self.snapToPixel(panelTopY - panelHeight, scale: backingScale)

        let frame = CGRect(x: panelLeftX, y: originY, width: panelWidth, height: panelHeight)
        panel.setFrame(frame, display: true)
        ghostView.frame = CGRect(origin: .zero, size: frame.size)
        ghostView.needsDisplay = true
    }

    // MARK: - Inline Autocorrect Layout (1-to-1 Cotypist red strikethrough + green fix)

    private func showAutocorrect(
        replacement: String,
        original: String,
        panel: NSPanel,
        caretRect: CGRect,
        typoWordRect: CGRect?,
        typography: FieldTypography,
        screenBounds: CGRect,
        backingScale: CGFloat
    ) {
        let font = typography.font
        let naturalLineHeight = ghostView.defaultLineHeight(for: font)
        let editorLineHeight = caretRect.height > 4 ? caretRect.height : naturalLineHeight

        let fixAttr = NSAttributedString(string: replacement, attributes: [
            .font: font,
            .foregroundColor: Self.autocorrectGreen(isDark: typography.isDarkBackground),
        ])
        let fixSize = fixAttr.size()
        let fixPadX: CGFloat = 4
        let gap: CGFloat = 5

        let hasTypoRect = typoWordRect != nil && (typoWordRect?.width ?? 0) > 2
        let strikeScreenRect = typoWordRect ?? .zero
        let panelLeftX = hasTypoRect ? (strikeScreenRect.minX - 2) : (caretRect.minX + 2)
        let correctionStartX = hasTypoRect
            ? max(strikeScreenRect.maxX + gap, caretRect.minX + 2)
            : (caretRect.minX + 2)

        let totalWidth = ceil((correctionStartX - panelLeftX) + fixSize.width + fixPadX * 2 + 4)
        let panelHeight = ceil(max(editorLineHeight, naturalLineHeight) + 4)

        let halfLeading = max(0, (editorLineHeight - naturalLineHeight) / 2)
        let panelTopY = Self.snapToPixel(caretRect.minY + halfLeading + naturalLineHeight + 2, scale: backingScale)
        let originX = Self.snapToPixel(
            min(max(panelLeftX, screenBounds.minX + 4), screenBounds.maxX - totalWidth - 4),
            scale: backingScale
        )
        let originY = Self.snapToPixel(
            min(max(panelTopY - panelHeight, screenBounds.minY + 2), screenBounds.maxY - panelHeight - 2),
            scale: backingScale
        )

        let frame = CGRect(x: originX, y: originY, width: totalWidth, height: panelHeight)

        // Convert strike rect into the flipped view's local coordinates.
        let localStrikeRect: CGRect?
        if hasTypoRect {
            let localX = strikeScreenRect.minX - frame.minX
            let localY = frame.maxY - strikeScreenRect.maxY
            localStrikeRect = CGRect(x: localX, y: localY, width: strikeScreenRect.width, height: strikeScreenRect.height)
        } else {
            localStrikeRect = nil
        }

        let localCorrectionOrigin = CGPoint(
            x: correctionStartX - frame.minX,
            y: max(1, (panelHeight - naturalLineHeight) / 2)
        )

        ghostView.configureAutocorrect(
            strikeRect: localStrikeRect,
            correctionString: fixAttr,
            correctionOrigin: localCorrectionOrigin,
            font: font,
            strikeColor: Self.autocorrectRed(isDark: typography.isDarkBackground),
            backingColor: Self.inlineBackingColor(for: typography)
        )

        panel.setFrame(frame, display: true)
        ghostView.frame = CGRect(origin: .zero, size: frame.size)
        ghostView.needsDisplay = true
    }

    // MARK: - Inline Emoji Layout

    private func showEmoji(
        emoji: String,
        panel: NSPanel,
        caretRect: CGRect,
        typography: FieldTypography,
        screenBounds: CGRect,
        backingScale: CGFloat
    ) {
        let font = typography.font
        let naturalLineHeight = ghostView.defaultLineHeight(for: font)
        let editorLineHeight = caretRect.height > 4 ? caretRect.height : naturalLineHeight

        let attr = NSAttributedString(string: emoji, attributes: [
            .font: font,
            .foregroundColor: Self.ghostTextColor(for: typography),
        ])
        let size = attr.size()
        let padX: CGFloat = 4
        let panelWidth = ceil(size.width + padX * 2 + 2)
        let panelHeight = ceil(max(editorLineHeight, naturalLineHeight) + 2)

        let halfLeading = max(0, (editorLineHeight - naturalLineHeight) / 2)
        let panelTopY = Self.snapToPixel(caretRect.minY + halfLeading + naturalLineHeight + 1, scale: backingScale)
        let originX = Self.snapToPixel(
            min(max(caretRect.maxX + 2, screenBounds.minX + 4), screenBounds.maxX - panelWidth - 4),
            scale: backingScale
        )
        let originY = Self.snapToPixel(
            min(max(panelTopY - panelHeight, screenBounds.minY + 2), screenBounds.maxY - panelHeight - 2),
            scale: backingScale
        )

        let frame = CGRect(x: originX, y: originY, width: panelWidth, height: panelHeight)
        ghostView.configureEmoji(
            attributedString: attr,
            drawOrigin: CGPoint(x: padX, y: max(0, (panelHeight - size.height) / 2)),
            backingColor: Self.inlineBackingColor(for: typography)
        )

        panel.setFrame(frame, display: true)
        ghostView.frame = CGRect(origin: .zero, size: frame.size)
        ghostView.needsDisplay = true
    }

    // MARK: - Colors & Attributed String Styling (1-to-1 Cotypist Assets.car)

    /// Exact Cotypist `suggestionDefault` colors (`#7F7F7F` light, `#8C8C8C` dark),
    /// adapting automatically when the editor exposes an explicit foreground color.
    static func ghostTextColor(for typography: FieldTypography) -> NSColor {
        if let fg = typography.foregroundColor?.usingColorSpace(.sRGB), fg.alphaComponent > 0.3 {
            return fg.withAlphaComponent(typography.isDarkBackground ? 0.50 : 0.46)
        }
        return typography.isDarkBackground
            ? NSColor(white: 0.549, alpha: 1.0)
            : NSColor(white: 0.498, alpha: 1.0)
    }

    /// Exact Cotypist `autocorrectStrikethroughRed` (`Assets.car`).
    static func autocorrectRed(isDark: Bool) -> NSColor {
        isDark
            ? NSColor(srgbRed: 0.8784, green: 0.3333, blue: 0.3333, alpha: 1.0)
            : NSColor(srgbRed: 0.7804, green: 0.2784, blue: 0.2784, alpha: 1.0)
    }

    /// Exact Cotypist `autocorrectCorrectionGreen` (`Assets.car`).
    static func autocorrectGreen(isDark: Bool) -> NSColor {
        isDark
            ? NSColor(srgbRed: 0.0745, green: 0.6824, blue: 0.2431, alpha: 1.0)
            : NSColor(srgbRed: 0.0392, green: 0.5412, blue: 0.1882, alpha: 1.0)
    }

    static func inlineBackingColor(for typography: FieldTypography) -> NSColor {
        if let bg = typography.backgroundColor?.usingColorSpace(.sRGB), bg.alphaComponent > 0.3 {
            return bg.withAlphaComponent(0.94)
        }
        return typography.isDarkBackground
            ? NSColor(white: 0.13, alpha: 0.92)
            : NSColor(white: 0.99, alpha: 0.92)
    }

    private static func buildCompletionAttributedString(
        text: String,
        font: NSFont,
        baseColor: NSColor,
        firstLineHeadIndent: CGFloat,
        lineSpacing: CGFloat,
        acceptBadge: String?
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.firstLineHeadIndent = firstLineHeadIndent
        paragraph.headIndent = 0
        paragraph.tailIndent = 0
        if lineSpacing > 0.5 {
            paragraph.lineSpacing = lineSpacing
        }

        let result = NSMutableAttributedString()
        let baseAlpha = baseColor.alphaComponent

        // Apply Cotypist's gentle exponential tail fade on longer predictions so the ghost
        // text feels effortless and fades naturally into the page.
        let totalChars = text.count
        if totalChars <= 36 {
            result.append(NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: baseColor,
                .paragraphStyle: paragraph,
            ]))
        } else {
            var offset = 0
            let words = splitPreservingSpaces(text)
            for chunk in words {
                let progress = max(0.0, Double(offset - 28) / Double(max(1, totalChars - 28)))
                let fadeFactor = progress > 0 ? max(0.58, exp(-0.55 * progress)) : 1.0
                let chunkColor = baseColor.withAlphaComponent(baseAlpha * CGFloat(fadeFactor))
                result.append(NSAttributedString(string: chunk, attributes: [
                    .font: font,
                    .foregroundColor: chunkColor,
                    .paragraphStyle: paragraph,
                ]))
                offset += chunk.count
            }
        }

        if let badge = acceptBadge, !badge.isEmpty {
            let hintFont = NSFont.systemFont(ofSize: max(9, font.pointSize * 0.72), weight: .medium)
            let hintColor = baseColor.withAlphaComponent(baseAlpha * 0.65)
            result.append(NSAttributedString(string: " \(badge)", attributes: [
                .font: hintFont,
                .foregroundColor: hintColor,
                .paragraphStyle: paragraph,
            ]))
        }

        return result
    }

    private static func splitPreservingSpaces(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for ch in text {
            if ch.isWhitespace && !current.isEmpty && !current.last!.isWhitespace {
                chunks.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        p.isReleasedWhenClosed = false
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.titleVisibility = .hidden
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.setAccessibilityElement(false)
        p.contentView = ghostView
        return p
    }
}

// MARK: - Pure AppKit NSLayoutManager Inline Ghost View (1-to-1 Cotypist Draw Architecture)

private final class InlineGhostTextView: NSView {
    struct CompletionLayoutMetrics {
        let usedSize: CGSize
        let firstLineBaselineFromTop: CGFloat
    }

    private enum Mode {
        case none
        case completion(drawInlineBacking: Bool, backingColor: NSColor, naturalLineHeight: CGFloat)
        case autocorrect(
            strikeRect: CGRect?,
            correction: NSAttributedString,
            correctionOrigin: CGPoint,
            font: NSFont,
            strikeColor: NSColor,
            backingColor: NSColor
        )
        case emoji(attributed: NSAttributedString, drawOrigin: CGPoint, backingColor: NSColor)
    }

    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer()
    private var mode: Mode = .none

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 4
        textContainer.lineBreakMode = .byTruncatingTail
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func defaultLineHeight(for font: NSFont) -> CGFloat {
        let h = layoutManager.defaultLineHeight(for: font)
        return h > 4 ? h : ceil(font.ascender - font.descender + font.leading)
    }

    func configureCompletion(
        attributedString: NSAttributedString,
        containerWidth: CGFloat,
        maxHeight: CGFloat,
        naturalLineHeight: CGFloat,
        drawInlineBacking: Bool,
        backingColor: NSColor
    ) -> CompletionLayoutMetrics {
        textContainer.containerSize = CGSize(width: containerWidth, height: maxHeight)
        if !textStorage.isEqual(to: attributedString) {
            textStorage.setAttributedString(attributedString)
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let baselineFromTop: CGFloat
        if layoutManager.numberOfGlyphs > 0 {
            let locY = layoutManager.location(forGlyphAt: 0).y
            baselineFromTop = locY > 1 ? locY : ceil(naturalLineHeight * 0.8)
        } else {
            baselineFromTop = ceil(naturalLineHeight * 0.8)
        }
        mode = .completion(
            drawInlineBacking: drawInlineBacking,
            backingColor: backingColor,
            naturalLineHeight: naturalLineHeight
        )
        return CompletionLayoutMetrics(
            usedSize: CGSize(width: ceil(used.maxX), height: ceil(used.maxY)),
            firstLineBaselineFromTop: baselineFromTop
        )
    }

    func configureAutocorrect(
        strikeRect: CGRect?,
        correctionString: NSAttributedString,
        correctionOrigin: CGPoint,
        font: NSFont,
        strikeColor: NSColor,
        backingColor: NSColor
    ) {
        mode = .autocorrect(
            strikeRect: strikeRect,
            correction: correctionString,
            correctionOrigin: correctionOrigin,
            font: font,
            strikeColor: strikeColor,
            backingColor: backingColor
        )
    }

    func configureEmoji(
        attributedString: NSAttributedString,
        drawOrigin: CGPoint,
        backingColor: NSColor
    ) {
        mode = .emoji(attributed: attributedString, drawOrigin: drawOrigin, backingColor: backingColor)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        switch mode {
        case .none:
            return

        case .completion(let drawInlineBacking, let backingColor, let naturalLineHeight):
            guard textStorage.length > 0 else { return }
            let glyphRange = layoutManager.glyphRange(for: textContainer)
            guard glyphRange.length > 0 else { return }

            // When completing mid-line over existing text, mask only the tight glyph fragments
            // so ghost text stays clean without drawing a giant popup bubble.
            if drawInlineBacking {
                ctx.saveGState()
                ctx.setShouldAntialias(true)
                ctx.setFillColor(backingColor.cgColor)
                layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
                    guard usedRect.width > 1 && usedRect.height > 1 else { return }
                    let tightHeight = min(usedRect.height, naturalLineHeight + 1)
                    let tight = CGRect(
                        x: usedRect.minX - 2,
                        y: usedRect.minY - 0.5,
                        width: usedRect.width + 4,
                        height: tightHeight + 1
                    )
                    let path = CGPath(roundedRect: tight, cornerWidth: 3, cornerHeight: 3, transform: nil)
                    ctx.addPath(path)
                    ctx.fillPath()
                }
                ctx.restoreGState()
            }

            layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)

        case .autocorrect(let strikeRect, let correction, let correctionOrigin, let font, let strikeColor, let backingColor):
            ctx.saveGState()
            ctx.setShouldAntialias(true)

            // 1. Subtle red highlight + crisp strikethrough directly over the misspelled word.
            if let rect = strikeRect, rect.width > 1 {
                let highlightRect = rect.insetBy(dx: -1.5, dy: 0)
                let redFillPath = CGPath(roundedRect: highlightRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
                ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.25).cgColor)
                ctx.addPath(redFillPath)
                ctx.fillPath()

                // Optical center through x-height (matching Cotypist's ascender/descender/xHeight calculation).
                let totalMetric = max(1, font.ascender - font.descender)
                let baselineY = rect.minY + (rect.height * (font.ascender / totalMetric))
                let strikeY = round(baselineY - font.xHeight * 0.45) + 0.5
                ctx.setStrokeColor(strikeColor.cgColor)
                ctx.setLineWidth(1.25)
                ctx.move(to: CGPoint(x: rect.minX, y: strikeY))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: strikeY))
                ctx.strokePath()
            }

            // 2. Green inline replacement immediately beside the typo word.
            let fixSize = correction.size()
            let fixRect = CGRect(
                x: correctionOrigin.x - 3,
                y: correctionOrigin.y,
                width: fixSize.width + 6,
                height: fixSize.height
            )
            let greenPath = CGPath(roundedRect: fixRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.setFillColor(backingColor.cgColor)
            ctx.addPath(greenPath)
            ctx.fillPath()
            ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.25).cgColor)
            ctx.addPath(greenPath)
            ctx.fillPath()

            correction.draw(at: correctionOrigin)
            ctx.restoreGState()

        case .emoji(let attributed, let drawOrigin, let backingColor):
            ctx.saveGState()
            ctx.setShouldAntialias(true)
            let size = attributed.size()
            let bgRect = CGRect(x: drawOrigin.x - 3, y: drawOrigin.y, width: size.width + 6, height: size.height)
            let path = CGPath(roundedRect: bgRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.setFillColor(backingColor.withAlphaComponent(0.82).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            attributed.draw(at: drawOrigin)
            ctx.restoreGState()
        }
    }
}
