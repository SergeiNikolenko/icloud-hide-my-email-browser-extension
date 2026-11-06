import Foundation

public struct HMEAddress: Codable, Identifiable, Hashable, Sendable {
    public var anonymousId: String
    public var hme: String
    public var label: String
    public var note: String
    public var forwardToEmail: String
    public var isActive: Bool
    public var createTimestamp: Double
    public var domain: String
    public var origin: String

    public var id: String { anonymousId }
    public var createdAt: Date { Date(timeIntervalSince1970: createTimestamp / 1000) }

    public init(
        anonymousId: String, hme: String, label: String, note: String = "",
        forwardToEmail: String = "", isActive: Bool = true,
        createTimestamp: Double = Date().timeIntervalSince1970 * 1000,
        domain: String = "", origin: String = "ON_DEMAND"
    ) {
        self.anonymousId = anonymousId
        self.hme = hme
        self.label = label
        self.note = note
        self.forwardToEmail = forwardToEmail
        self.isActive = isActive
        self.createTimestamp = createTimestamp
        self.domain = domain
        self.origin = origin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anonymousId = try c.decode(String.self, forKey: .anonymousId)
        hme = try c.decode(String.self, forKey: .hme)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        forwardToEmail = try c.decodeIfPresent(String.self, forKey: .forwardToEmail) ?? ""
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        createTimestamp = try c.decodeIfPresent(Double.self, forKey: .createTimestamp) ?? 0
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? "ON_DEMAND"
    }
}

public struct HMEList: Codable, Sendable {
    public var hmeEmails: [HMEAddress]
    public var selectedForwardTo: String
    public var forwardToEmails: [String]

    public init(hmeEmails: [HMEAddress], selectedForwardTo: String, forwardToEmails: [String]) {
        self.hmeEmails = hmeEmails
        self.selectedForwardTo = selectedForwardTo
        self.forwardToEmails = forwardToEmails
    }
}

public enum ICloudRegion: String, Codable, CaseIterable, Sendable {
    case global
    case china

    public var webOrigin: URL {
        URL(string: self == .global ? "https://www.icloud.com" : "https://www.icloud.com.cn")!
    }

    public var setupURL: URL {
        URL(string: self == .global
            ? "https://setup.icloud.com/setup/ws/1"
            : "https://setup.icloud.com.cn/setup/ws/1")!
    }

    public var cookieDomain: String { self == .global ? "icloud.com" : "icloud.com.cn" }
}

public enum ICloudError: LocalizedError, Equatable, Sendable {
    /// The session was rejected; the user has to sign in again.
    case signedOut
    /// The account has no iCloud+ subscription, which Hide My Email requires.
    case subscriptionRequired
    case server(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .signedOut:
            String(localized: "Your iCloud session has expired. Sign in again.")
        case .subscriptionRequired:
            String(localized: "Hide My Email requires an iCloud+ subscription.")
        case .server(let message):
            message.isEmpty ? String(localized: "iCloud could not complete the request. Try again.") : message
        case .network:
            String(localized: "Can't reach iCloud. Check your connection and try again.")
        }
    }
}
