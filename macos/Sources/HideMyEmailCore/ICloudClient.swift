import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Talks to the private iCloud web APIs the same way icloud.com does.
public actor ICloudClient {
    public let region: ICloudRegion
    public private(set) var jar: CookieJar
    private var premiumMailURL: URL?
    private let transport: HTTPTransport
    /// Called whenever the server rotates cookies, so the caller can persist them.
    private let onCookiesChanged: @Sendable (CookieJar) -> Void

    // Statuses with which setup.icloud.com rejects an expired or missing session.
    static let signedOutStatuses: Set<Int> = [401, 403, 421]

    public init(region: ICloudRegion, jar: CookieJar, transport: HTTPTransport = URLSessionTransport(),
                onCookiesChanged: @escaping @Sendable (CookieJar) -> Void = { _ in }) {
        self.region = region
        self.jar = jar
        self.transport = transport
        self.onCookiesChanged = onCookiesChanged
    }

    // MARK: Session

    /// Validates the session and discovers the Hide My Email service URL.
    public func validate() async throws {
        let data = try await request("POST", region.setupURL.appendingPathComponent("validate"), body: nil)
        struct Validate: Decodable {
            struct Service: Decodable { let url: String? }
            let webservices: [String: Service]?
        }
        let response = try JSONDecoder().decode(Validate.self, from: data)
        guard let url = response.webservices?["premiummailsettings"]?.url, let serviceURL = URL(string: url) else {
            throw ICloudError.subscriptionRequired
        }
        premiumMailURL = serviceURL
    }

    public func signOut() async {
        _ = try? await request("POST", region.setupURL.appendingPathComponent("logout"),
                               body: ["trustBrowsers": false, "allBrowsers": false])
        jar = CookieJar()
        onCookiesChanged(jar)
    }

    // MARK: Hide My Email

    public func list() async throws -> HMEList {
        try await premium("GET", "v2/hme/list", as: HMEList.self)
    }

    public func generate() async throws -> String {
        struct Result: Decodable { let hme: String }
        return try await premium("POST", "v1/hme/generate", as: Result.self).hme
    }

    public func reserve(hme: String, label: String, note: String?) async throws -> HMEAddress {
        struct Result: Decodable { let hme: HMEAddress }
        var body: [String: Any] = ["hme": hme, "label": label]
        body["note"] = note ?? ""
        return try await premium("POST", "v1/hme/reserve", body: body, as: Result.self).hme
    }

    public func updateMetadata(anonymousId: String, label: String, note: String) async throws {
        try await premiumAction("v1/hme/updateMetaData", ["anonymousId": anonymousId, "label": label, "note": note])
    }

    public func deactivate(anonymousId: String) async throws {
        try await premiumAction("v1/hme/deactivate", ["anonymousId": anonymousId])
    }

    public func reactivate(anonymousId: String) async throws {
        try await premiumAction("v1/hme/reactivate", ["anonymousId": anonymousId])
    }

    public func delete(anonymousId: String) async throws {
        try await premiumAction("v1/hme/delete", ["anonymousId": anonymousId])
    }

    public func updateForwardTo(_ email: String) async throws {
        try await premiumAction("v1/hme/updateForwardTo", ["forwardToEmail": email])
    }

    // MARK: Plumbing

    private struct Envelope<T: Decodable>: Decodable {
        struct Failure: Decodable { let errorMessage: String? }
        let success: Bool
        let result: T?
        let error: Failure?
    }

    private struct Empty: Decodable {}

    private func premiumAction(_ path: String, _ body: [String: Any]) async throws {
        _ = try await premium("POST", path, body: body, as: Empty.self, requireResult: false)
    }

    private func premium<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil,
                                       as type: T.Type, requireResult: Bool = true) async throws -> T {
        if premiumMailURL == nil {
            try await validate()
        }
        guard let base = premiumMailURL else { throw ICloudError.subscriptionRequired }
        let data = try await request(method, base.appendingPathComponent(path), body: body)
        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw ICloudError.server("")
        }
        guard envelope.success else { throw ICloudError.server(envelope.error?.errorMessage ?? "") }
        if let result = envelope.result { return result }
        if !requireResult, let empty = Empty() as? T { return empty }
        throw ICloudError.server("")
    }

    private func request(_ method: String, _ url: URL, body: [String: Any]?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(region.webOrigin.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(region.webOrigin.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        if let cookie = jar.headerValue(for: url) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw ICloudError.network(error.localizedDescription)
        }

        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        let before = jar.cookies
        jar.merge(responseHeaders: headers, for: url)
        if jar.cookies != before { onCookiesChanged(jar) }

        switch response.statusCode {
        case 200..<300:
            return data
        case let status where Self.signedOutStatuses.contains(status) && url.host?.hasPrefix("setup.") == true:
            throw ICloudError.signedOut
        case 401, 421:
            premiumMailURL = nil
            throw ICloudError.signedOut
        case 403:
            throw ICloudError.subscriptionRequired
        default:
            throw ICloudError.server("")
        }
    }
}
