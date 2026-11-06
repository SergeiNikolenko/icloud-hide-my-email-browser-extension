import Foundation

public enum Sites {
    // Second-level public suffixes common enough to matter for labels. A full
    // public suffix list is overkill for grouping addresses by site.
    static let multiPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.nz", "org.nz", "co.jp", "ne.jp", "or.jp", "ac.jp", "co.kr", "or.kr",
        "com.br", "com.cn", "net.cn", "org.cn", "com.hk", "com.tw", "com.sg",
        "com.mx", "com.ar", "com.tr", "com.ua", "com.ru", "co.in", "co.za",
        "co.il", "com.my", "com.ph", "com.vn", "com.pl", "co.id", "github.io",
        "vercel.app", "netlify.app", "pages.dev", "herokuapp.com", "blogspot.com",
    ]

    /// The registrable domain ("eTLD+1") of a host, e.g. `accounts.google.co.uk` → `google.co.uk`.
    public static func registrableDomain(_ host: String) -> String {
        var labels = host.lowercased().split(separator: ".").map(String.init)
        if labels.first == "www" { labels.removeFirst() }
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        if labels.allSatisfy({ Int($0) != nil }) { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let keep = multiPartSuffixes.contains(lastTwo) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    public static func registrableDomain(of url: URL) -> String? {
        guard let scheme = url.scheme, ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else {
            return nil
        }
        return registrableDomain(host)
    }

    /// Addresses that belong to a site, matched on the registrable domain of
    /// their label or of the domain Safari recorded.
    public static func addresses(_ addresses: [HMEAddress], for site: String) -> [HMEAddress] {
        let target = registrableDomain(site)
        return addresses.filter { address in
            [address.domain, address.label].contains { candidate in
                let host = candidate.trimmingCharacters(in: .whitespaces).lowercased()
                guard host.contains("."), !host.contains(" ") else { return false }
                let parsed = URL(string: host.contains("://") ? host : "https://\(host)")?.host ?? host
                return registrableDomain(parsed) == target
            }
        }
    }
}
