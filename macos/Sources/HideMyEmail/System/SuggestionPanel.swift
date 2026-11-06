import AppKit
import ApplicationServices
import HideMyEmailCore
import SwiftUI

@MainActor
@Observable
final class SuggestionState {
    var generated: String?
    var existing: [HMEAddress] = []
    var site: String?
    var isWorking = false
    var error: String?
}

/// A floating, non-activating panel under the focused email field, so the
/// field keeps keyboard focus while the user picks an address.
@MainActor
final class SuggestionPanel {
    static let shared = SuggestionPanel()

    private let state = SuggestionState()
    private var field: AXUIElement?
    private var anchor: CGRect = .zero
    private var placesAbove = false
    private var generation: Task<Void, Never>?
    private var watch: Task<Void, Never>?
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: SuggestionView(
            state: state,
            onCreate: { [weak self] in self?.createAndFill() },
            onPick: { [weak self] address in self?.fill(address.hme) }
        ))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }()

    private let model = AppModel.shared

    func show(for element: AXUIElement, anchor: CGRect) {
        let isSameField = field.map { CFEqual($0, element) } ?? false
        field = element
        self.anchor = anchor
        if !isSameField { placesAbove = false }
        state.site = model.context?.site
        state.existing = Array(model.siteAddresses.prefix(3))
        state.error = nil
        if !isSameField || state.generated == nil {
            state.generated = nil
            generation?.cancel()
            generation = Task {
                state.generated = try? await model.generate()
            }
        }

        layout()
        watch?.cancel()
        watch = Task { [weak self] in
            // Passwords and browsers open their AutoFill lists under the field a
            // moment after focus; make room for them instead of covering them.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.field != nil else { return }
                if !self.placesAbove, self.isBelowFieldTaken() {
                    self.placesAbove = true
                    self.layout()
                }
            }
        }
    }

    private func layout() {
        let size = panel.contentView?.fittingSize ?? CGSize(width: 300, height: 60)
        let width = max(min(max(anchor.width, 280), 380), size.width)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .infinite
        let below = anchor.minY - size.height - 4
        let above = anchor.maxY + 4
        let fitsAbove = above + size.height <= visible.maxY
        guard !placesAbove || fitsAbove else {
            panel.orderOut(nil)
            return
        }
        let y = placesAbove || below < visible.minY ? above : below
        let x = min(max(anchor.minX, visible.minX + 8), visible.maxX - width - 8)
        panel.setFrame(CGRect(x: x, y: y, width: width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    /// Whether another app's popup, such as the Passwords AutoFill list, sits
    /// right under the field.
    private func isBelowFieldTaken() -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        // CGWindowList uses top-left coordinates on the primary screen.
        let strip = CGRect(x: anchor.minX, y: primary.frame.maxY - anchor.minY,
                           width: max(anchor.width, 280), height: 160)
        let systemLayers = [CGWindowLevelKey.mainMenuWindow, .statusWindow, .dockWindow]
            .map { Int(CGWindowLevelForKey($0)) }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) != getpid(),
                  let layer = info[kCGWindowLayer as String] as? Int, layer > 0, !systemLayers.contains(layer),
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                      .flatMap({ CGRect(dictionaryRepresentation: $0) })
            else { return false }
            return bounds.height < 700 && bounds.width < 900 && bounds.intersects(strip)
        }
    }

    func hide() {
        watch?.cancel()
        generation?.cancel()
        field = nil
        state.isWorking = false
        panel.orderOut(nil)
    }

    private func createAndFill() {
        guard let hme = state.generated, !state.isWorking else { return }
        state.isWorking = true
        Task {
            do {
                let address = try await model.reserve(hme, label: state.site ?? model.context?.appName ?? "", note: "")
                fill(address.hme)
            } catch {
                state.error = error.localizedDescription
                state.isWorking = false
            }
        }
    }

    private func fill(_ text: String) {
        let target = field
        hide()
        Filler.insert(text, replacing: target)
    }
}

struct SuggestionView: View {
    let state: SuggestionState
    let onCreate: () -> Void
    let onPick: (HMEAddress) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SuggestionRow(
                icon: SymbolBadge(systemName: "envelope.fill", size: 24),
                title: state.generated ?? String(localized: "Hide My Email"),
                subtitle: state.site.map { String(localized: "New address for \($0)") }
                    ?? String(localized: "New address"),
                isBusy: state.generated == nil || state.isWorking,
                action: onCreate
            )
            .disabled(state.generated == nil || state.isWorking)

            ForEach(state.existing) { address in
                SuggestionRow(icon: SiteTile(address: address, size: 24), title: address.hme,
                              subtitle: address.label, isBusy: false) { onPick(address) }
            }

            if let error = state.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .padding(5)
        .frame(minWidth: 280, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(1)
    }
}

private struct SuggestionRow<Icon: View>: View {
    let icon: Icon
    let title: String
    let subtitle: String
    let isBusy: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect(cornerRadius: 9))
            .background(isHovered ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// A brief confirmation near the top of the screen, like the system HUDs.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var dismissal: Task<Void, Never>?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill", tint: Color = .green) {
        let content = HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(message).font(.system(size: 13, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(1)

        let panel = panel ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                                backing: .buffered, defer: true)
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            return panel
        }()
        Self.panel = panel
        let host = NSHostingView(rootView: AnyView(content))
        panel.contentView = host
        let size = host.fittingSize
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(CGRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 24,
                                  width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        dismissal?.cancel()
        dismissal = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }
            panel.orderOut(nil)
        }
    }
}
