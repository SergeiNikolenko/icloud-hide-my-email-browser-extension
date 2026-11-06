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
    private var generation: Task<Void, Never>?
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

        let size = panel.contentView?.fittingSize ?? CGSize(width: 300, height: 60)
        let width = max(min(max(anchor.width, 280), 380), size.width)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - size.height - 4)
        if let visible = screen?.visibleFrame {
            if origin.y < visible.minY { origin.y = anchor.maxY + 4 }
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
        }
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: size.height)), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
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
                symbol: "envelope.badge.shield.half.filled",
                title: state.generated ?? String(localized: "Hide My Email"),
                subtitle: state.site.map { String(localized: "New address for \($0)") }
                    ?? String(localized: "New address"),
                isBusy: state.generated == nil || state.isWorking,
                action: onCreate
            )
            .disabled(state.generated == nil || state.isWorking)

            ForEach(state.existing) { address in
                SuggestionRow(symbol: "envelope", title: address.hme, subtitle: address.label,
                              isBusy: false) { onPick(address) }
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

private struct SuggestionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let isBusy: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
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
            .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 9))
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

    static func show(_ message: String, symbol: String = "checkmark.circle.fill") {
        let content = HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
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
