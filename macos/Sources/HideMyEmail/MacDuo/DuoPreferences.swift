import Foundation
import Observation
import DuoCore

@MainActor
@Observable
final class DuoPreferences {
    static let shared = DuoPreferences()

    private enum Key {
        static let isEnabled = "duo.isEnabled"
        static let focusOnWake = "duo.focusOnWake"
        static let showsAngleInMenuBar = "duo.showsAngleInMenuBar"
        static let effect = "duo.effect"
        static let migratedFromMacDuo = "duo.migratedFromMacDuoV1"
    }

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.isEnabled) }
    }

    var focusOnWake: Bool {
        didSet { defaults.set(focusOnWake, forKey: Key.focusOnWake) }
    }

    var showsAngleInMenuBar: Bool {
        didSet { defaults.set(showsAngleInMenuBar, forKey: Key.showsAngleInMenuBar) }
    }

    var effect: EffectSettings {
        didSet { persistEffect() }
    }

    var preset: EffectPreset? {
        EffectPreset.matching(effect)
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        Self.migrateLegacyMacDuoIfNeeded(into: defaults)

        isEnabled = defaults.object(forKey: Key.isEnabled) as? Bool ?? true
        focusOnWake = defaults.object(forKey: Key.focusOnWake) as? Bool ?? true
        showsAngleInMenuBar = defaults.object(forKey: Key.showsAngleInMenuBar) as? Bool ?? false
        if let data = defaults.data(forKey: Key.effect),
           let decoded = try? JSONDecoder().decode(EffectSettings.self, from: data) {
            effect = decoded
        } else {
            effect = .duo
        }
    }

    func apply(_ preset: EffectPreset) {
        effect = preset.settings
    }

    func resetEffect() {
        effect = .duo
    }

    private func persistEffect() {
        if let data = try? JSONEncoder().encode(effect) {
            defaults.set(data, forKey: Key.effect)
        }
    }

    /// One-time migration of settings from standalone Mac Duo (com.mac-duo.app).
    private static func migrateLegacyMacDuoIfNeeded(into defaults: UserDefaults) {
        guard !defaults.bool(forKey: Key.migratedFromMacDuo) else { return }
        defaults.set(true, forKey: Key.migratedFromMacDuo)
        guard let legacy = UserDefaults(suiteName: "com.mac-duo.app") else { return }
        if defaults.object(forKey: Key.isEnabled) == nil, let v = legacy.object(forKey: "isEnabled") as? Bool {
            defaults.set(v, forKey: Key.isEnabled)
        }
        if defaults.object(forKey: Key.focusOnWake) == nil, let v = legacy.object(forKey: "focusOnWake") as? Bool {
            defaults.set(v, forKey: Key.focusOnWake)
        }
        if defaults.object(forKey: Key.showsAngleInMenuBar) == nil, let v = legacy.object(forKey: "showsAngleInMenuBar") as? Bool {
            defaults.set(v, forKey: Key.showsAngleInMenuBar)
        }
        if defaults.data(forKey: Key.effect) == nil, let data = legacy.data(forKey: "effect") {
            defaults.set(data, forKey: Key.effect)
        }
    }
}

