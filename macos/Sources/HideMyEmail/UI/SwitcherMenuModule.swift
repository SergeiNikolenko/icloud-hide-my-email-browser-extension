import AppKit
import LayoutSwitcherCore
import SwiftUI

struct SwitcherMenuModule: View {
    let switcher: SwitcherController
    let onDismiss: () -> Void

    private var prefs: SwitcherPreferences { switcher.preferences }

    var body: some View {
        @Bindable var prefs = switcher.preferences

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SymbolBadge(
                    systemName: switcher.isSecureInputActive
                        ? "lock.shield.fill"
                        : (prefs.isEnabled ? "keyboard.badge.ellipsis" : "keyboard"),
                    size: 34
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Autoswitching")
                        .font(.system(size: 14, weight: .semibold))
                    Text(statusSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $prefs.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 4)

            if switcher.isSecureInputActive {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                    Text("Secure Input is active (password field). Switching is paused.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10))
            }

            HStack(spacing: 8) {
                Button {
                    switcher.switchActiveLayout()
                } label: {
                    HStack(spacing: 6) {
                        Text(switcher.currentLanguage.shortLabel)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.fill.tertiary, in: .capsule)
                        Text(switcher.currentLayoutName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .help("Switch active keyboard layout")

                Button {
                    onDismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        switcher.triggerManualSwitch()
                    }
                } label: {
                    Label("Convert", systemImage: "character.cursor.ibeam")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .help("Convert last word or selection (Option / Double Shift)")
            }

            if let last = switcher.lastAction {
                HStack(spacing: 8) {
                    Image(systemName: actionIcon(last.kind))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("\(last.originalWord) → \(last.replacementWord)")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Exclude") {
                        switcher.excludeLastActionWord()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.fill.quaternary, in: .rect(cornerRadius: 10))
            }

            Divider()

            VStack(spacing: 6) {
                quickToggle("Mistype Autocorrect", isOn: $prefs.autocorrectEnabled)
                quickToggle("Yofikator (е → ё)", isOn: $prefs.yofikatorEnabled)
                quickToggle("Fix Double-Caps (ПРивет)", isOn: $prefs.doubleCapsFixEnabled)
                quickToggle("Single Shift Layout Switch", isOn: $prefs.singleShiftEnabled)
                quickToggle("Paste Without Formatting (\(prefs.pastePlainTextShortcut.shortBadge))", isOn: $prefs.pastePlainTextEnabled)
            }
            .padding(.horizontal, 4)

            if !switcher.lastExternalBundleID.isEmpty, !switcher.lastExternalAppName.isEmpty {
                let excluded = switcher.isAppExcluded(switcher.lastExternalBundleID)
                HStack(spacing: 6) {
                    Button {
                        switcher.toggleExcluded(bundleID: switcher.lastExternalBundleID)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: excluded ? "play.fill" : "hand.raised.fill")
                                .font(.system(size: 10))
                            Text(excluded
                                 ? String(localized: "Enable in \(switcher.lastExternalAppName)")
                                 : String(localized: "Disable in \(switcher.lastExternalAppName)"))
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    if switcher.switchCountToday > 0 || switcher.correctionCountToday > 0 {
                        Text("\(switcher.switchCountToday) ⇄ · \(switcher.correctionCountToday) ✎")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func quickToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    private var statusSubtitle: String {
        if switcher.isSecureInputActive {
            return String(localized: "Paused in password field")
        }
        if !prefs.isEnabled {
            return String(localized: "Off (L⇧+R⇧ to resume)")
        }
        if !switcher.isEventTapActive {
            return String(localized: "Accessibility permission needed")
        }
        if switcher.frontmostPolicy == .disableAll {
            return String(localized: "Excluded in \(switcher.frontmostAppName)")
        }
        if switcher.frontmostPolicy == .disableAutoSwitch {
            return String(localized: "Manual only in \(switcher.frontmostAppName)")
        }
        if !switcher.frontmostAppName.isEmpty {
            return String(localized: "Active in \(switcher.frontmostAppName)")
        }
        return String(localized: "Active · EN ↔ RU")
    }

    private var statusColor: Color {
        if switcher.isSecureInputActive || !switcher.isEventTapActive { return .orange }
        if !prefs.isEnabled || switcher.frontmostPolicy != .normal { return .secondary }
        return .green
    }

    private func actionIcon(_ kind: SwitcherActionKind) -> String {
        switch kind {
        case .autoSwitch, .manualSwitch: return "arrow.left.arrow.right"
        case .manualRevert: return "arrow.uturn.backward"
        case .doubleCaps: return "textformat.size"
        case .autocorrect, .yofikator: return "wand.and.stars"
        }
    }
}

