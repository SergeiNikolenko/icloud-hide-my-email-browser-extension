import AppKit
import DuoCore
import SwiftUI

struct DuoMenuModule: View {
    let controller: DuoFoldController
    @Bindable var prefs: DuoPreferences
    let onDismiss: () -> Void

    @State private var sleepDisabled = false
    @State private var loadedSleepState = false
    @State private var changingSleep = false

    private var sleepBinding: Binding<Bool> {
        Binding(
            get: { sleepDisabled },
            set: { wanted in
                guard loadedSleepState, !changingSleep, wanted != sleepDisabled else { return }
                sleepDisabled = wanted
                changingSleep = true
                Task {
                    let actual = await DuoSleepControl.setSleepDisabled(wanted)
                    sleepDisabled = actual
                    changingSleep = false
                }
            }
        )
    }

    var body: some View {
        let status = controller.status
        let hasBuiltIn = NSScreen.activeBuiltIn != nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SymbolBadge(
                    systemName: controller.sensorAvailable
                        ? (prefs.isEnabled ? "laptopcomputer" : "laptopcomputer.slash")
                        : "desktopcomputer",
                    size: 34
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac Duo")
                        .font(.system(size: 14, weight: .semibold))
                    Text(statusSubtitle(status: status, hasBuiltIn: hasBuiltIn))
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor(status: status, hasBuiltIn: hasBuiltIn))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $prefs.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!controller.sensorAvailable)
            }
            .padding(.horizontal, 4)

            if status == .needsPermission {
                HStack(spacing: 8) {
                    Image(systemName: "video.slash.fill")
                        .foregroundStyle(.orange)
                    Text("Allow Screen Recording to fold the desktop.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Allow…") {
                        DuoScreenRecordingPermission.request()
                        DuoScreenRecordingPermission.openSettings()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10))
            }

            HStack(spacing: 8) {
                Button {
                    onDismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        controller.preview()
                    }
                } label: {
                    Label("Preview Fold", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .disabled(status == .noSensor || status == .needsPermission)

                Menu {
                    ForEach(EffectPreset.allCases, id: \.self) { preset in
                        Button {
                            prefs.apply(preset)
                        } label: {
                            if prefs.preset == preset {
                                Label(preset.title, systemImage: "checkmark")
                            } else {
                                Text(preset.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(prefs.preset?.title ?? String(localized: "Custom"))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .fixedSize()
            }

            Divider()

            VStack(spacing: 8) {
                duoSlider(
                    title: "Start Angle",
                    valueText: "\(Int(prefs.effect.startAngle.rounded()))°",
                    value: $prefs.effect.startAngle,
                    range: 40...125
                )
                duoSlider(
                    title: "Frost",
                    valueText: "\(Int(prefs.effect.blurRadius.rounded()))",
                    value: $prefs.effect.blurRadius,
                    range: 16...180
                )
                duoSlider(
                    title: "Darkness",
                    valueText: "\(Int((prefs.effect.dimming * 100).rounded()))%",
                    value: $prefs.effect.dimming,
                    range: 0...1
                )
            }
            .padding(.horizontal, 4)

            Divider()

            VStack(spacing: 6) {
                duoToggle("Live Picture", isOn: $prefs.effect.livePicture)
                duoToggle("Focus on Wake", isOn: $prefs.focusOnWake)
                duoToggle("Keep Awake With Lid Closed", isOn: sleepBinding)
                    .disabled(!loadedSleepState || changingSleep)
            }
            .padding(.horizontal, 4)
        }
        .task {
            controller.refreshPermission()
            let current = await DuoSleepControl.readSleepDisabled()
            sleepDisabled = current
            loadedSleepState = true
        }
    }

    private func duoToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
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

    private func duoSlider(title: LocalizedStringKey, valueText: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(valueText).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.mini)
        }
    }

    private func statusSubtitle(status: DuoFoldController.Status, hasBuiltIn: Bool) -> String {
        let deg = String(format: "%.0f°", controller.angle)
        switch status {
        case .noSensor: return String(localized: "No lid angle sensor")
        case .needsPermission: return String(localized: "Screen Recording needed · \(deg)")
        case .off: return String(localized: "Off · \(deg)")
        case .ready:
            if !hasBuiltIn {
                return String(localized: "Built-in display offline · \(deg)")
            }
            return controller.isActive
                ? String(localized: "Folding · \(deg)")
                : String(localized: "Ready · \(deg)")
        }
    }

    private func statusColor(status: DuoFoldController.Status, hasBuiltIn: Bool) -> Color {
        switch status {
        case .noSensor, .off: return .secondary
        case .needsPermission: return .orange
        case .ready: return hasBuiltIn ? .green : .secondary
        }
    }
}

struct DuoSettingsView: View {
    let controller: DuoFoldController
    @Bindable var prefs: DuoPreferences

    @State private var sleepDisabled = false
    @State private var loadedSleepState = false
    @State private var changingSleep = false
    @State private var scrub: Double = 0
    @State private var isScrubbing = false
    @State private var copiedDiagnostics = false
    @State private var showFineTuning = false

    private var canRun: Bool {
        controller.status == .ready || controller.status == .off
    }

    private var sleepBinding: Binding<Bool> {
        Binding(
            get: { sleepDisabled },
            set: { wanted in
                guard loadedSleepState, !changingSleep, wanted != sleepDisabled else { return }
                sleepDisabled = wanted
                changingSleep = true
                Task {
                    let actual = await DuoSleepControl.setSleepDisabled(wanted)
                    sleepDisabled = actual
                    changingSleep = false
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Fold the desktop when the lid closes", isOn: $prefs.isEnabled)
                    .disabled(!controller.sensorAvailable)
                Toggle("Bring the desktop into focus on wake", isOn: $prefs.focusOnWake)
                    .disabled(!controller.sensorAvailable)
                if prefs.focusOnWake {
                    Button("Open Lock Screen Settings…") { DuoLockScreenSettings.open() }
                        .controlSize(.small)
                }
                Toggle("Live picture while folding", isOn: $prefs.effect.livePicture)
                Toggle("Show lid angle in menu bar", isOn: $prefs.showsAngleInMenuBar)
                    .disabled(!controller.sensorAvailable)
            }

            Section("Clamshell Power") {
                Toggle("Keep the Mac awake with the lid closed", isOn: sleepBinding)
                    .disabled(!loadedSleepState || changingSleep)
                Text("Uses macOS pmset disablesleep (asks for administrator password). The display still turns off when shut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Fold Style & Geometry") {
                Picker("Preset", selection: Binding(
                    get: { prefs.preset },
                    set: { if let p = $0 { prefs.apply(p) } }
                )) {
                    ForEach(EffectPreset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(Optional(preset))
                    }
                    if prefs.preset == nil {
                        Text("Custom").tag(Optional<EffectPreset>.none)
                    }
                }

                HStack {
                    Button("Preview Fold") { controller.preview() }
                        .disabled(!canRun)
                    Spacer()
                    Button("Reset Defaults") { prefs.resetEffect() }
                        .disabled(prefs.preset == .duo)
                }

                LabeledContent("Drag to Fold") {
                    Slider(value: $scrub, in: 0...1) { editing in
                        isScrubbing = editing
                        controller.scrub(to: editing ? scrubAngle(for: scrub) : nil)
                    }
                    .frame(width: 220)
                    .disabled(!canRun)
                    .onChange(of: scrub) { _, value in
                        if isScrubbing { controller.scrub(to: scrubAngle(for: value)) }
                    }
                }

                LabeledContent("Start Angle (\(Int(prefs.effect.startAngle.rounded()))°)") {
                    Slider(value: $prefs.effect.startAngle, in: 40...125, step: 1).frame(width: 220)
                }
                LabeledContent("Span (\(Int(prefs.effect.span.rounded()))°)") {
                    Slider(value: $prefs.effect.span, in: 15...90, step: 1).frame(width: 220)
                }
                LabeledContent("Frost (\(Int(prefs.effect.blurRadius.rounded())) pt)") {
                    Slider(value: $prefs.effect.blurRadius, in: 16...180, step: 2).frame(width: 220)
                }
                LabeledContent("Darkness (\(Int((prefs.effect.dimming * 100).rounded()))%)") {
                    Slider(value: $prefs.effect.dimming, in: 0...1, step: 0.05).frame(width: 220)
                }
                LabeledContent("Darkness Reaches (\(Int((prefs.effect.dimReach * 100).rounded()))%)") {
                    Slider(value: $prefs.effect.dimReach, in: 0.2...1, step: 0.05).frame(width: 220)
                }
                LabeledContent("Depth (\(String(format: "%.2f×", prefs.effect.depth)))") {
                    Slider(value: $prefs.effect.depth, in: 0...1.6, step: 0.05).frame(width: 220)
                }
                LabeledContent("Viewing Distance (\(String(format: "%.1f", prefs.effect.eyeDistance)))") {
                    Slider(value: $prefs.effect.eyeDistance, in: 1.2...5, step: 0.1).frame(width: 220)
                }
                LabeledContent("Sheen (\(Int((prefs.effect.sheen * 100).rounded()))%)") {
                    Slider(value: $prefs.effect.sheen, in: 0...1, step: 0.05).frame(width: 220)
                }
            }

            Section {
                DisclosureGroup("Fine Tuning", isExpanded: $showFineTuning) {
                    LabeledContent("Frost at Hinge (\(Int((prefs.effect.blurFloor * 100).rounded()))%)") {
                        Slider(value: $prefs.effect.blurFloor, in: 0...0.5).frame(width: 220)
                    }
                    LabeledContent("Darkness Starts (\(Int((prefs.effect.dimStart * 100).rounded()))%)") {
                        Slider(value: $prefs.effect.dimStart, in: 0...0.6).frame(width: 220)
                    }
                    LabeledContent("Darkness at Hinge (\(Int((prefs.effect.dimHingeFloor * 100).rounded()))%)") {
                        Slider(value: $prefs.effect.dimHingeFloor, in: 0...0.5).frame(width: 220)
                    }
                    LabeledContent("Eye Height (\(String(format: "%.2f", prefs.effect.eyeHeight)))") {
                        Slider(value: $prefs.effect.eyeHeight, in: -0.3...0.5).frame(width: 220)
                    }
                    LabeledContent("Grain (\(Int((prefs.effect.grain * 100).rounded()))%)") {
                        Slider(value: $prefs.effect.grain, in: 0...1).frame(width: 220)
                    }
                }
            }

            Section("Status & Permissions") {
                LabeledContent("Lid Sensor") {
                    Text(controller.sensorAvailable
                         ? String(format: "%.1f° (%@)", controller.angle, controller.sensorResolution)
                         : String(localized: "Unavailable"))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Screen Recording") {
                    if controller.screenRecordingGranted {
                        Text("Allowed").foregroundStyle(.green)
                    } else {
                        Button("Allow…") {
                            DuoScreenRecordingPermission.request()
                            DuoScreenRecordingPermission.openSettings()
                        }
                    }
                }
                HStack {
                    Button(copiedDiagnostics ? "Copied Diagnostics" : "Copy Diagnostics") {
                        Filler.copy(controller.diagnostics())
                        copiedDiagnostics = true
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .task {
            scrub = 0
            controller.refreshPermission()
            let current = await DuoSleepControl.readSleepDisabled()
            sleepDisabled = current
            loadedSleepState = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshPermission()
            if !changingSleep {
                Task {
                    let current = await DuoSleepControl.readSleepDisabled()
                    sleepDisabled = current
                    loadedSleepState = true
                }
            }
        }
    }

    private func scrubAngle(for t: Double) -> Double {
        let effect = prefs.effect
        let open = min(effect.startAngle + 25, 135)
        let shut = max(effect.startAngle - effect.span * 1.1, 8)
        return open + (shut - open) * t
    }
}

