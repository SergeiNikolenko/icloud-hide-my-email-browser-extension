import Foundation

/// A cookie that can be persisted, including session cookies, so the iCloud
/// session survives app restarts.
public struct StoredCookie: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expires: Date?
    public var isSecure: Bool

    public init(name: String, value: String, domain: String, path: String = "/",
                expires: Date? = nil, isSecure: Bool = true) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.isSecure = isSecure
    }

    public init(_ cookie: HTTPCookie) {
        self.init(name: cookie.name, value: cookie.value, domain: cookie.domain,
                  path: cookie.path, expires: cookie.expiresDate, isSecure: cookie.isSecure)
    }

    public var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path,
        ]
        if let expires { properties[.expires] = expires }
        if isSecure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    func matches(_ url: URL, now: Date) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let expires, expires < now { return false }
        if isSecure, url.scheme != "https" { return false }
        let cookieDomain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domainMatches = host == cookieDomain || host.hasSuffix("." + cookieDomain)
        let requestPath = url.path.isEmpty ? "/" : url.path
        return domainMatches && requestPath.hasPrefix(path)
    }
}

/// Minimal cookie jar with explicit persistence; URLSession's shared storage
/// would mix the app session with other cookies and drop session cookies.
public struct CookieJar: Codable, Sendable {
    public private(set) var cookies: [StoredCookie]

    public init(cookies: [StoredCookie] = []) {
        self.cookies = cookies
    }

    public var isEmpty: Bool { cookies.isEmpty }

    public func headerValue(for url: URL, now: Date = Date()) -> String? {
        let matching = cookies.filter { $0.matches(url, now: now) }
        guard !matching.isEmpty else { return nil }
        return matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    public mutating func merge(_ incoming: [StoredCookie], now: Date = Date()) {
        for cookie in incoming {
            cookies.removeAll {
                $0.name == cookie.name && $0.domain.lowercased() == cookie.domain.lowercased()
                    && $0.path == cookie.path
            }
            let isDeletion = cookie.value.isEmpty || (cookie.expires.map { $0 < now } ?? false)
            if !isDeletion {
                cookies.append(cookie)
            }
        }
    }

    public mutating func merge(responseHeaders: [String: String], for url: URL) {
        merge(HTTPCookie.cookies(withResponseHeaderFields: responseHeaders, for: url).map(StoredCookie.init))
    }
}
