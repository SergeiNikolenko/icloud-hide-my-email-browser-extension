import Foundation

public enum SiteIcon {
    private static let linkTag = try! NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive)
    private static let attribute = try! NSRegularExpression(
        pattern: "([a-zA-Z][a-zA-Z-]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")

    /// Icon URLs a page declares, best first: touch icons, then the largest
    /// `icon` links, then `/favicon.ico`.
    public static func candidates(in html: String, base: URL) -> [URL] {
        var scored: [(score: Int, url: URL)] = []
        let range = NSRange(html.startIndex..., in: html)
        for match in linkTag.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            var attributes: [String: String] = [:]
            for pair in attribute.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                guard let name = Range(pair.range(at: 1), in: tag) else { continue }
                let value = (2...4).lazy.compactMap { Range(pair.range(at: $0), in: tag) }.first.map { String(tag[$0]) }
                attributes[tag[name].lowercased()] = value ?? ""
            }
            let rel = Set((attributes["rel"] ?? "").lowercased().split(separator: " ").map(String.init))
            guard rel.contains("icon") || rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed"),
                  let href = attributes["href"]?.replacingOccurrences(of: "&amp;", with: "&"),
                  !href.hasPrefix("data:"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  url.scheme == "https" || url.scheme == "http" else { continue }
            let size = (attributes["sizes"] ?? "").split(separator: " ")
                .compactMap { Int($0.lowercased().split(separator: "x").first ?? "") }.max() ?? 0
            let isTouch = rel.contains { $0.hasPrefix("apple-touch-icon") }
            scored.append((isTouch ? 1000 + max(size, 180) : size, url))
        }
        var result = scored.sorted { $0.score > $1.score }.map(\.url)
        if let favicon = URL(string: "/favicon.ico", relativeTo: base)?.absoluteURL {
            result.append(favicon)
        }
        var seen = Set<URL>()
        return result.filter { seen.insert($0).inserted }
    }
}
