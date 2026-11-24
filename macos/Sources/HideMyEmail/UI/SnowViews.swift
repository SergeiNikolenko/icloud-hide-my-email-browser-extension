import AppKit
import SnowpileCore
import SwiftUI

struct SnowMenuModule: View {
    @ObservedObject var controller: SnowpileController
    @ObservedObject var prefs: SnowpileCore.Preferences
    @ObservedObject var weather: WeatherModel
    @State private var dockAllowed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SymbolBadge(systemName: effectSymbol, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snowpile")
                        .font(.system(size: 14, weight: .semibold))
                    Text(statusSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { prefs.snowing },
                    set: { on in
                        if on { controller.resume() } else { controller.pauseIndefinitely() }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(.horizontal, 4)

            HStack(spacing: 6) {
                Menu {
                    ForEach(PauseDuration.allCases) { duration in
                        if duration == .untilTomorrow { Divider() }
                        Button(duration.title) { controller.pause(for: duration) }
                    }
                    Divider()
                    Button("Indefinitely") { controller.pauseIndefinitely() }
                } label: {
                    Label("Pause For", systemImage: "timer")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.glass)
                .controlSize(.regular)

                if controller.activeEffect == .snow {
                    Button {
                        controller.shakeOff()
                    } label: {
                        Label("Shake Off", systemImage: "wind")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)

                    Button {
                        controller.buildSnowman()
                    } label: {
                        Image(systemName: "figure.stand")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .help("Build a Snowman")
                }
            }

            Picker("Effect", selection: $prefs.selection) {
                Text("Like Outside").tag("weather")
                Divider()
                ForEach(SnowMode.allCases) { mode in
                    Text(mode == .custom ? String(localized: "Custom Snow") : mode.title)
                        .tag("snow:" + mode.rawValue)
                }
                Divider()
                ForEach(Effect.allCases.filter { $0 != .snow }) { effect in
                    Text(effect.title).tag(effect.rawValue)
                }
            }
            .pickerStyle(.menu)
            .font(.system(size: 12))

            if prefs.followWeather {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: weather.conditions?.recommendedEffect == .rain ? "cloud.rain" : "cloud.snow")
                            .foregroundStyle(.secondary)
                        Text(prefs.place.name)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        if let now = weather.conditions {
                            Text(now.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(weather.failed ? "Could not update" : "Updating…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if prefs.snowing, let now = weather.conditions, now.recommendedEffect == nil {
                        HStack(spacing: 6) {
                            Text("Clear sky — waiting for snow or rain")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("Snow Now") {
                                prefs.selection = "snow:" + prefs.mode.rawValue
                            }
                            .buttonStyle(.glass)
                            .controlSize(.mini)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.fill.quaternary, in: .rect(cornerRadius: 10))
            } else if prefs.effect != .snow || prefs.mode == .custom {
                VStack(spacing: 8) {
                    snowSlider(title: "Intensity", value: $prefs.intensity, range: 0.3...3.0)
                    if prefs.effect != .starfall {
                        snowSlider(title: "Wind", value: $prefs.wind, range: 0...2.5)
                    }
                }
                .padding(.horizontal, 4)
            }

            Divider()

            VStack(spacing: 6) {
                if prefs.followWeather || [.snow, .rain, .sakura, .leaves].contains(prefs.effect) {
                    HStack(spacing: 12) {
                        Toggle("Windows", isOn: $prefs.onWindows)
                        Toggle("Dock", isOn: $prefs.onDock)
                            .disabled(!dockAllowed)
                        Toggle("Floor", isOn: $prefs.onFloor)
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                }
                HStack(spacing: 8) {
                    Text("Interact with Pointer")
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Toggle("", isOn: $prefs.pointer)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 4)
        }
        .task {
            dockAllowed = AX.isTrusted
        }
    }

    private func snowSlider(title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(String(format: "%.1f×", value.wrappedValue))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).controlSize(.mini)
        }
    }

    private var effectSymbol: String {
        switch controller.activeEffect {
        case .snow: return "snowflake"
        case .rain: return "cloud.bolt.rain.fill"
        case .sakura: return "camera.macro"
        case .leaves: return "leaf.fill"
        case .fireflies: return "sparkles"
        case .starfall: return "star.fill"
        }
    }

    private var statusColor: Color {
        guard prefs.snowing else { return .secondary }
        if prefs.followWeather, let now = weather.conditions, now.recommendedEffect == nil {
            return .secondary
        }
        return .green
    }

    private var statusSubtitle: String {
        if !prefs.snowing {
            return prefs.pauseStatusSummary() ?? String(localized: "Paused")
        }
        if prefs.followWeather {
            if let summary = weather.conditions?.summary {
                return "\(prefs.place.name) · \(summary)"
            }
            return String(localized: "Following Weather (\(prefs.place.name))")
        }
        return prefs.effect == .snow ? prefs.mode.title : prefs.effect.title
    }
}

struct SnowSettingsView: View {
    @ObservedObject var controller: SnowpileController
    @ObservedObject var prefs: SnowpileCore.Preferences
    @ObservedObject var weather: WeatherModel

    @State private var choosingPlace = false
    @State private var screens = NSScreen.screens
    @State private var dockAllowed = AX.isTrusted

    var body: some View {
        Form {
            Section("Effect & Weather") {
                Toggle("Enable Desktop Effects", isOn: Binding(
                    get: { prefs.snowing },
                    set: { on in if on { controller.resume() } else { controller.pauseIndefinitely() } }
                ))
                if !prefs.snowing, prefs.pausedUntil != nil {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let summary = prefs.pauseStatusSummary(now: context.date) {
                            Text(summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Picker("Effect", selection: $prefs.selection) {
                    Text("Like Outside").tag("weather")
                    Divider()
                    ForEach(SnowMode.allCases) { mode in
                        Text(mode == .custom ? String(localized: "Custom Snow") : mode.title)
                            .tag("snow:" + mode.rawValue)
                    }
                    Divider()
                    ForEach(Effect.allCases.filter { $0 != .snow }) { effect in
                        Text(effect.title).tag(effect.rawValue)
                    }
                }

                if prefs.followWeather {
                    LabeledContent("Place") {
                        Button(prefs.place.name) { choosingPlace = true }
                            .popover(isPresented: $choosingPlace) {
                                SnowPlacePicker { place in
                                    prefs.place = place
                                    choosingPlace = false
                                }
                            }
                    }
                    LabeledContent("Weather") {
                        if let now = weather.conditions {
                            Text(now.summary).foregroundStyle(.secondary)
                        } else {
                            Text(weather.failed ? "Could not update" : "Updating…").foregroundStyle(.secondary)
                        }
                    }
                    SecureField("Yandex Weather API Key (optional)", text: $prefs.yandexKey)
                } else if prefs.effect != .snow || prefs.mode == .custom {
                    LabeledContent("Intensity") {
                        Slider(value: $prefs.intensity, in: 0.3...3.0).frame(width: 220)
                    }
                    if prefs.effect != .starfall {
                        LabeledContent("Wind") {
                            Slider(value: $prefs.wind, in: 0...2.5).frame(width: 220)
                        }
                    }
                }

                HStack {
                    Button("Shake Off Snow") { controller.shakeOff() }
                        .disabled(controller.activeEffect != .snow)
                    Button("Build a Snowman") { controller.buildSnowman() }
                        .disabled(controller.activeEffect != .snow)
                    Spacer()
                }
            }

            Section("Surfaces & Displays") {
                Toggle("Settle on Windows", isOn: $prefs.onWindows)
                Toggle("Settle on Dock", isOn: $prefs.onDock)
                    .disabled(!dockAllowed)
                    .help("Allow Accessibility in General to use the Dock.")
                Toggle("Settle on Floor", isOn: $prefs.onFloor)
                Toggle("Interact with Pointer", isOn: $prefs.pointer)

                if screens.count > 1 {
                    Picker("Displays", selection: $prefs.display) {
                        Text("All Displays").tag(SnowpileCore.Preferences.allDisplays)
                        Text("Main Display").tag(SnowpileCore.Preferences.mainDisplay)
                        Divider()
                        ForEach(screens, id: \.self) { screen in
                            Text(screen.localizedName).tag(SnowpileCore.Preferences.id(of: screen))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            dockAllowed = AX.isTrusted
        }
    }
}

private struct SnowPlacePicker: View {
    let pick: (Place) -> Void
    @State private var text = ""
    @State private var places: [Place] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("City", text: $text)
                .textFieldStyle(.roundedBorder)
            ForEach(places) { place in
                Button { pick(place) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(place.name)
                        if !place.detail.isEmpty {
                            Text(place.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 260)
        .task(id: text) {
            let query = text.trimmingCharacters(in: .whitespaces)
            guard query.count >= 2 else { places = []; return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            places = (try? await SnowpileController.searchPlaces(query)) ?? []
        }
    }
}

