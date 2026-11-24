import Foundation

public enum AppSwitchPolicy: Equatable, Sendable {
    /// Normal switching and autocorrection allowed.
    case normal
    /// Disable automatic switching (manual switching still allowed).
    case disableAutoSwitch
    /// Disable all switching & autocorrection (e.g. password managers, remote desktop, games).
    case disableAll
}

/// Evaluates Caramba's 486 built-in Appex rules + user app exceptions + Feats config
/// (terminal EN-on-focus and browser special behavior).
public struct AppexMatcher: Sendable {
    public let appex: AppexModel
    public let feats: FeatsConfig

    public init(appex: AppexModel, feats: FeatsConfig) {
        self.appex = appex
        self.feats = feats
    }

    public func policy(
        bundleIdentifier: String?,
        executablePath: String?,
        windowTitle: String?,
        userExcludedBundleIDs: Set<String>,
        useBuiltInRules: Bool = true
    ) -> AppSwitchPolicy {
        if let bid = bundleIdentifier, !bid.isEmpty, userExcludedBundleIDs.contains(bid) {
            return .disableAll
        }

        guard useBuiltInRules else {
            return .normal
        }

        var result: AppSwitchPolicy = .normal

        if let bid = bundleIdentifier?.lowercased(), !bid.isEmpty {
            result = merge(result, lookup(bid, kind: .bundleIdentifier))
        }
        if let path = executablePath?.lowercased(), !path.isEmpty {
            result = merge(result, lookup(path, kind: .executablePath))
        }
        if let title = windowTitle?.lowercased(), !title.isEmpty {
            result = merge(result, lookup(title, kind: .windowTitle))
        }

        return result
    }

    private func lookup(_ value: String, kind: AppexMatchKind) -> AppSwitchPolicy {
        let wrapped = "\u{02}\(value)\u{03}"
        let ids = appex.index.allSubstringValues(wrapped)
        var policy: AppSwitchPolicy = .normal

        for id in ids {
            guard let rules = appex.ruleSets[id] else { continue }
            for rule in rules where rule.isMacOS && rule.matchKind == kind {
                if rule.disablesAll {
                    return .disableAll
                }
                if rule.disablesAutoSwitch {
                    policy = .disableAutoSwitch
                }
            }
        }
        return policy
    }

    private func merge(_ a: AppSwitchPolicy, _ b: AppSwitchPolicy) -> AppSwitchPolicy {
        if a == .disableAll || b == .disableAll { return .disableAll }
        if a == .disableAutoSwitch || b == .disableAutoSwitch { return .disableAutoSwitch }
        return .normal
    }

    /// Returns true if focusing this app should automatically switch layout to English
    /// (e.g. Terminal, iTerm, Alacritty, Termius, Hyper from FeatsConfig).
    public func shouldSwitchToEnglishOnFocus(
        bundleIdentifier: String?,
        executablePath: String?,
        appName: String?
    ) -> Bool {
        let haystack = [bundleIdentifier, executablePath, appName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        guard !haystack.isEmpty else { return false }
        return feats.switchToEnglishOnFocus.contains { pattern in
            !pattern.isEmpty && haystack.contains(pattern.lowercased())
        }
    }

    /// Returns true if the app requires Caramba's browser special retype behavior
    /// (Safari, Chrome, Brave URL bar autocomplete handling).
    public func hasSpecialBrowserBehavior(
        bundleIdentifier: String?,
        executablePath: String?,
        appName: String?
    ) -> Bool {
        let haystack = [bundleIdentifier, executablePath, appName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        guard !haystack.isEmpty else { return false }
        return feats.specialBehaviors.contains { behavior in
            let pat = behavior.pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !pat.isEmpty && haystack.contains(pat)
        }
    }
}

