import AppKit
import HideMyEmailCore
import SwiftUI

/// A site's own icon, or a gray letter tile when the site has none, in the
/// manner of the Passwords app.
struct SiteTile: View {
    let label: String
    let site: String?
    var isActive = true
    var size: CGFloat = 28
    @State private var icon: NSImage?

    init(address: HMEAddress, size: CGFloat = 28) {
        label = address.label
        site = Sites.site(of: address)
        isActive = address.isActive
        self.size = size
    }

    init(site: String, size: CGFloat = 28) {
        label = site
        self.site = site
        self.size = size
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        Group {
            if let icon {
                // Touch icons are full-bleed artwork; small favicons get a margin.
                let isLarge = icon.representations.map(\.pixelsWide).max() ?? 0 >= 96
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(isLarge ? 0 : size * 0.16)
                    .frame(width: size, height: size)
                    .background(.white)
                    .clipShape(shape)
            } else {
                Text(label.first.map { String($0).uppercased() } ?? "@")
                    .font(.system(size: size * 0.46, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(LinearGradient(colors: [Color(white: 0.64), Color(white: 0.5)],
                                               startPoint: .top, endPoint: .bottom), in: shape)
            }
        }
        .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        .saturation(isActive ? 1 : 0)
        .opacity(isActive ? 1 : 0.55)
        .task(id: site) {
            guard let site, let data = await SiteIconStore.shared.icon(for: site) else { return }
            icon = NSImage(data: data)
        }
    }
}

/// A white symbol on an accent circle, like the active rows in system menu bar windows.
struct SymbolBadge: View {
    let systemName: String
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.accentColor, in: .circle)
    }
}

/// Fetches icons from the sites themselves and keeps them in the caches folder.
actor SiteIconStore {
    static let shared = SiteIconStore()

    private var memory: [String: Data] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.nikolenko.HideMyEmail/SiteIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        ]
        return URLSession(configuration: configuration)
    }()

    func icon(for site: String) async -> Data? {
        if let data = memory[site] { return data }
        if let task = inFlight[site] { return await task.value }
        let task = Task { await load(site) }
        inFlight[site] = task
        let data = await task.value
        inFlight[site] = nil
        memory[site] = data
        return data
    }

    private func load(_ site: String) async -> Data? {
        let file = directory.appendingPathComponent(site)
        // An empty file records a site without an icon; look again after a month.
        if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           modified.timeIntervalSinceNow > -30 * 86400, let data = try? Data(contentsOf: file) {
            return data.isEmpty ? nil : data
        }
        guard let result = await fetch(site) else { return nil }
        try? (result ?? Data()).write(to: file)
        return result
    }

    /// nil when the site could not be reached, so a later launch tries again.
    private func fetch(_ site: String) async -> Data?? {
        guard let home = URL(string: "https://\(site)/"),
              let (page, response) = try? await session.data(from: home) else { return nil }
        let candidates = SiteIcon.candidates(in: String(decoding: page.prefix(400_000), as: UTF8.self),
                                             base: response.url ?? home)
        for url in candidates.prefix(4) {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data), image.size.width >= 16 else { continue }
            return .some(data)
        }
        return .some(nil)
    }
}
