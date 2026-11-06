import Foundation
import Observation

@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    static let defaultExcluded: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.apple.Passwords",
    ]

    var showsSuggestions: Bool {
        didSet { defaults.set(showsSuggestions, forKey: "showsSuggestions") }
    }

    var shortcut: Shortcut {
        didSet { defaults.set(shortcut.rawValue, forKey: "shortcut") }
    }

    var excludedBundleIDs: Set<String> {
        didSet { defaults.set(Array(excludedBundleIDs), forKey: "excludedBundleIDs") }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        showsSuggestions = defaults.object(forKey: "showsSuggestions") as? Bool ?? true
        shortcut = defaults.string(forKey: "shortcut").flatMap(Shortcut.init(rawValue:)) ?? .controlOptionE
        excludedBundleIDs = (defaults.array(forKey: "excludedBundleIDs") as? [String]).map(Set.init)
            ?? Self.defaultExcluded
    }
}
