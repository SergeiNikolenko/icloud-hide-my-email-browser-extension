import AppKit
import HideMyEmailCore
import SwiftUI

struct MenuView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                header
                switch model.state {
                case .unknown:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 120)
                case .signedOut:
                    SignedOutModule(model: model)
                case .signedIn:
                    GeneratorModule(model: model) { text in
                        dismiss()
                        AppDelegate.paste(text, into: model.context)
                    }
                    addressesModule
                }
                if !AX.isTrusted {
                    AccessibilityModule()
                }
                footer
            }
        }
        .padding(12)
        .frame(width: 340)
        .task { if model.state == .signedIn { await model.refresh() } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Hide My Email")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var visibleAddresses: [HMEAddress] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let site = Set(model.siteAddresses.map(\.id))
            return model.siteAddresses + model.addresses.filter { !site.contains($0.id) }
        }
        return model.addresses.filter {
            $0.label.localizedCaseInsensitiveContains(trimmed) || $0.hme.localizedCaseInsensitiveContains(trimmed)
                || $0.note.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var addressesModule: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.quaternary.opacity(0.6), in: .capsule)

            let addresses = visibleAddresses
            if addresses.isEmpty {
                Text(query.isEmpty ? "No addresses" : "No results")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(addresses) { address in
                            AddressRow(address: address, isForSite: model.siteAddresses.contains(address)) {
                                dismiss()
                                AppDelegate.paste(address.hme, into: model.context)
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(CGFloat(addresses.count) * 38, 266))
            }
        }
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button { open("manager") } label: {
                Label("Addresses", systemImage: "list.bullet")
            }
            Button {
                NSApp.activate()
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }

    private func open(_ id: String) {
        dismiss()
        NSApp.activate()
        openWindow(id: id)
    }
}

private struct GeneratorModule: View {
    let model: AppModel
    let onPaste: (String) -> Void

    @State private var hme: String?
    @State private var label = ""
    @State private var note = ""
    @State private var reserved: HMEAddress?
    @State private var isWorking = false
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hme ?? " ")
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .textSelection(.enabled)
                        .redacted(reason: hme == nil ? .placeholder : [])
                        .contentTransition(.opacity)
                    if !model.forwardTo.isEmpty {
                        Text("Forwards to \(model.forwardTo)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    Task { await generate() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, isActive: isWorking && reserved == nil)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("New Address")
                .disabled(isWorking)
            }

            if let reserved, reserved.hme == hme {
                HStack(spacing: 6) {
                    Label("Reserved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button {
                        Filler.copy(reserved.hme)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    Button {
                        onPaste(reserved.hme)
                    } label: {
                        Label(model.context.map { "Paste in \($0.appName)" } ?? "Paste", systemImage: "text.insert")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.context == nil)
                }
                .controlSize(.large)
            } else {
                VStack(spacing: 0) {
                    FieldRow(title: "Label", prompt: model.context?.site ?? "Required", text: $label)
                    Divider().padding(.leading, 10)
                    FieldRow(title: "Note", prompt: "Optional", text: $note)
                }
                .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 10))

                Button {
                    Task { await reserve() }
                } label: {
                    Text("Use This Address").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(hme == nil || isWorking || resolvedLabel.isEmpty)
            }

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .task(id: model.context?.site) {
            label = model.context?.site ?? ""
            if hme == nil { await generate() }
        }
    }

    private var resolvedLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? (model.context?.site ?? "") : trimmed
    }

    private func generate() async {
        isWorking = true
        error = nil
        reserved = nil
        copied = false
        defer { isWorking = false }
        do {
            let next = try await model.generate()
            withAnimation(.smooth) { hme = next }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reserve() async {
        guard let hme else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let address = try await model.reserve(hme, label: resolvedLabel,
                                                  note: note.trimmingCharacters(in: .whitespaces))
            withAnimation(.smooth) { reserved = address }
            note = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct FieldRow: View {
    let title: LocalizedStringKey
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(title)
            TextField(title, text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
    }
}

struct AddressRow: View {
    let address: HMEAddress
    let isForSite: Bool
    let onPaste: () -> Void
    @State private var isHovered = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            SiteBadge(label: address.label, isActive: address.isActive)
            VStack(alignment: .leading, spacing: 1) {
                Text(address.label.isEmpty ? address.hme : address.label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(address.hme)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if !address.isActive {
                Text("Inactive")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
            } else if isHovered {
                HStack(spacing: 2) {
                    Button {
                        Filler.copy(address.hme)
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help("Copy")
                    Button(action: onPaste) {
                        Image(systemName: "text.insert")
                    }
                    .help("Paste")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 38)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 10))
        .contentShape(.rect)
        .onHover { hovering in
            isHovered = hovering
            if !hovering { copied = false }
        }
        .contextMenu {
            Button("Copy Address") { Filler.copy(address.hme) }
            Button("Paste", action: onPaste).disabled(!address.isActive)
        }
    }
}

struct SiteBadge: View {
    let label: String
    let isActive: Bool

    var body: some View {
        Text(label.first.map { String($0).uppercased() } ?? "@")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(.quaternary.opacity(0.7), in: .circle)
            .opacity(isActive ? 1 : 0.5)
    }
}

private struct SignedOutModule: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .frame(width: 60, height: 60)
                .glassEffect(.regular, in: .circle)
            if let browser = model.pendingBrowser {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for iCloud in \(browser.name)…")
                        .font(.system(size: 13))
                    Spacer(minLength: 0)
                    Button("Cancel", action: model.cancelSignIn)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                if browser.engine == .safari, model.needsFullDiskAccess {
                    Button("Allow Full Disk Access…", action: AX.openFullDiskAccessSettings)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    Button {
                        model.signIn(with: BrowserCookies.safari)
                    } label: {
                        Text("Sign In to iCloud").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    Menu {
                        ForEach(BrowserCookies.installed()) { browser in
                            Button(browser.name) { model.signIn(with: browser) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .fixedSize()
                    .help("Sign In with Another Browser")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

private struct AccessibilityModule: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .foregroundStyle(.secondary)
            Text("Allow Accessibility to fill email fields")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Allow…") {
                AX.requestTrust()
                AX.openAccessibilitySettings()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}
