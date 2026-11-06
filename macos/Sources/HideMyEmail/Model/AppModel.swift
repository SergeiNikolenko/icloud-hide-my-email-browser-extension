import AppKit
import HideMyEmailCore
import Observation
import SafariServices
import ServiceManagement
import SwiftUI

enum SessionState: Equatable {
    case unknown
    case signedOut
    case signedIn
}

/// The app the user was working in before opening the menu, and the site open in it.
struct BrowsingContext: Equatable {
    var appName: String
    var pid: pid_t
    var site: String?
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var state: SessionState = .unknown
    private(set) var addresses: [HMEAddress] = []
    private(set) var forwardToOptions: [String] = []
    private(set) var forwardTo = ""
    private(set) var isRefreshing = false
    var lastError: String?

    var context: BrowsingContext?

    var region: ICloudRegion {
        didSet { UserDefaults.standard.set(region.rawValue, forKey: "region") }
    }

    /// The browser whose icloud.com session the app uses.
    private(set) var sessionBrowser: BrowserCookies.Browser? {
        didSet { UserDefaults.standard.set(sessionBrowser?.id, forKey: "sessionBrowser") }
    }
    /// The browser the user is signing in with, while the app waits for the session.
    private(set) var pendingBrowser: BrowserCookies.Browser?
    /// Safari hands over its session only through the bundled extension.
    private(set) var safariExtensionEnabled = true

    private var client: ICloudClient?
    /// Sample addresses without an iCloud session, for screenshots (`--demo`).
    private var isDemo = false
    private var keepAliveTask: Task<Void, Never>?
    private var sessionWatch: Task<Void, Never>?

    private init() {
        region = UserDefaults.standard.string(forKey: "region").flatMap(ICloudRegion.init(rawValue:)) ?? .global
        sessionBrowser = UserDefaults.standard.string(forKey: "sessionBrowser")
            .flatMap { id in BrowserCookies.browsers.first { $0.id == id } }
        addresses = Cache.load() ?? []
    }

    var siteAddresses: [HMEAddress] {
        guard let site = context?.site else { return [] }
        return Sites.addresses(addresses, for: site).filter(\.isActive)
    }

    // MARK: Session

    func startDemo() {
        isDemo = true
        addresses = Demo.addresses
        forwardToOptions = [Demo.forwardTo]
        forwardTo = Demo.forwardTo
        state = .signedIn
    }

    func bootstrap() async {
        if let jar = Keychain.loadJar(region: region), !jar.isEmpty {
            await connect(jar: jar)
        } else {
            state = .signedOut
            watchQuietly()
        }
    }

    /// The default browser when the app can read its session, otherwise the first supported one.
    var preferredBrowser: BrowserCookies.Browser? {
        let installed = BrowserCookies.installed()
        let defaultID = NSWorkspace.shared.urlForApplication(toOpen: region.webOrigin)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        return installed.first { $0.bundleID == defaultID } ?? installed.first
    }

    /// Opens icloud.com in a browser and signs in as soon as a session shows up there.
    func signIn(with browser: BrowserCookies.Browser? = nil) {
        guard let browser = browser ?? preferredBrowser,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else { return }
        UserDefaults.standard.removeObject(forKey: "signedOutByUser")
        NSWorkspace.shared.open([region.webOrigin], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        pendingBrowser = browser
        watch([browser], every: .seconds(3), for: .seconds(600))
    }

    func cancelSignIn() {
        pendingBrowser = nil
        watchQuietly()
    }

    /// Picks up a session in the background without prompting: Safari and
    /// Gecko browsers need no Keychain access, and the session browser was
    /// already allowed.
    private func watchQuietly() {
        guard !UserDefaults.standard.bool(forKey: "signedOutByUser") else { return }
        let browsers = BrowserCookies.installed().filter { browser in
            if case .chromium = browser.engine { return browser.id == sessionBrowser?.id }
            return true
        }
        watch(browsers, every: .seconds(15), for: nil)
    }

    private func watch(_ browsers: [BrowserCookies.Browser], every interval: Duration, for timeout: Duration?) {
        sessionWatch?.cancel()
        let deadline = timeout.map { ContinuousClock.now + $0 }
        sessionWatch = Task { [weak self] in
            while !Task.isCancelled, deadline.map({ ContinuousClock.now < $0 }) ?? true {
                guard let self, self.state != .signedIn else { break }
                if browsers.contains(where: { $0.engine == .safari }) {
                    self.safariExtensionEnabled = (try? await SFSafariExtensionManager
                        .stateOfSafariExtension(withIdentifier: BrowserCookies.safariExtensionID).isEnabled) ?? false
                }
                for browser in browsers {
                    if let jar = await self.sessionJar(from: browser) {
                        self.sessionBrowser = browser
                        self.pendingBrowser = nil
                        Keychain.save(jar, region: self.region)
                        await self.connect(jar: jar)
                        return
                    }
                }
                try? await Task.sleep(for: interval)
            }
            // A timed-out sign-in falls back to the background watch, so a
            // session that appears later (or after the Safari extension is on) is still picked up.
            guard let self, !Task.isCancelled, self.pendingBrowser != nil else { return }
            self.pendingBrowser = nil
            self.watchQuietly()
        }
    }

    /// The browser's icloud.com session, if it is signed in.
    private func sessionJar(from browser: BrowserCookies.Browser) async -> CookieJar? {
        let domain = region.cookieDomain
        let cookies: [StoredCookie]
        do {
            cookies = try await Task.detached { try BrowserCookies.cookies(from: browser, domain: domain) }.value
        } catch {
            return nil
        }
        var jar = CookieJar()
        jar.merge(cookies)
        guard jar.cookies.contains(where: { $0.name.hasPrefix("X-APPLE-WEBAUTH") }) else { return nil }
        let client = ICloudClient(region: region, jar: jar)
        guard (try? await client.validate()) != nil else { return nil }
        return await client.jar
    }

    private func connect(jar: CookieJar) async {
        let region = region
        let client = ICloudClient(region: region, jar: jar) { jar in
            Keychain.save(jar, region: region)
        }
        do {
            try await client.validate()
        } catch ICloudError.signedOut {
            await sessionExpired()
            return
        } catch {
            // Offline or a server hiccup: keep the saved session and show the cache.
            lastError = error.localizedDescription
        }
        self.client = client
        state = .signedIn
        startKeepAlive()
        await refresh()
    }

    /// The browser usually still holds a live session when the app's copy
    /// expires, so take it again before asking the user to sign in.
    private func sessionExpired() async {
        client = nil
        keepAliveTask?.cancel()
        if let browser = sessionBrowser, let jar = await sessionJar(from: browser) {
            Keychain.save(jar, region: region)
            let region = region
            client = ICloudClient(region: region, jar: jar) { jar in Keychain.save(jar, region: region) }
            state = .signedIn
            startKeepAlive()
            await refresh()
            return
        }
        state = .signedOut
        watchQuietly()
    }

    /// Forgets the app's copy of the session. Logging out on the server would
    /// also end the session in the browser.
    func signOut() {
        UserDefaults.standard.set(true, forKey: "signedOutByUser")
        sessionWatch?.cancel()
        keepAliveTask?.cancel()
        client = nil
        Keychain.delete(region: region)
        addresses = []
        Cache.save([])
        state = .signedOut
    }

    /// Validating periodically rotates the session cookies before they expire.
    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20 * 60))
                guard let self, let client = self.client else { return }
                do {
                    try await client.validate()
                } catch ICloudError.signedOut {
                    await self.sessionExpired()
                } catch {}
            }
        }
    }

    func handleWake() {
        guard state == .signedIn else { return }
        Task { await refresh() }
    }

    // MARK: Addresses

    func refresh() async {
        guard !isDemo, let client else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let list = try await client.list()
            addresses = list.hmeEmails.sorted { $0.createTimestamp > $1.createTimestamp }
            forwardToOptions = list.forwardToEmails
            forwardTo = list.selectedForwardTo
            lastError = nil
            Cache.save(addresses)
        } catch {
            await report(error)
        }
    }

    func generate() async throws -> String {
        if isDemo { return Demo.generate() }
        return try await perform { try await $0.generate() }
    }

    func reserve(_ hme: String, label: String, note: String) async throws -> HMEAddress {
        if isDemo {
            let address = HMEAddress(anonymousId: UUID().uuidString, hme: hme, label: label, note: note,
                                     forwardToEmail: forwardTo)
            addresses.insert(address, at: 0)
            return address
        }
        let address = try await perform { try await $0.reserve(hme: hme, label: label, note: note) }
        addresses.insert(address, at: 0)
        Cache.save(addresses)
        return address
    }

    /// Generates and reserves an address labelled after the current site.
    func createForCurrentSite() async throws -> HMEAddress {
        let hme = try await generate()
        return try await reserve(hme, label: context?.site ?? context?.appName ?? "", note: "")
    }

    func update(_ address: HMEAddress, label: String, note: String) async {
        await mutate(address.id) { client in
            try await client.updateMetadata(anonymousId: address.id, label: label, note: note)
        } apply: { $0.label = label; $0.note = note }
    }

    func setActive(_ active: Bool, for ids: Set<String>) async {
        for id in ids {
            await mutate(id) { client in
                if active {
                    try await client.reactivate(anonymousId: id)
                } else {
                    try await client.deactivate(anonymousId: id)
                }
            } apply: { $0.isActive = active }
        }
    }

    func delete(_ ids: Set<String>) async {
        for id in ids {
            do {
                try await perform { try await $0.delete(anonymousId: id) }
                addresses.removeAll { $0.id == id }
            } catch {
                await report(error)
            }
        }
        Cache.save(addresses)
    }

    func setForwardTo(_ email: String) async {
        do {
            try await perform { try await $0.updateForwardTo(email) }
            forwardTo = email
        } catch {
            await report(error)
        }
    }

    private func mutate(_ id: String, _ action: (ICloudClient) async throws -> Void,
                        apply: (inout HMEAddress) -> Void) async {
        guard let client else { return }
        do {
            try await action(client)
            if let index = addresses.firstIndex(where: { $0.id == id }) {
                apply(&addresses[index])
            }
            Cache.save(addresses)
        } catch {
            await report(error)
        }
    }

    private func perform<T>(_ body: (ICloudClient) async throws -> T) async throws -> T {
        guard let client else { throw ICloudError.signedOut }
        do {
            return try await body(client)
        } catch ICloudError.signedOut {
            await sessionExpired()
            throw ICloudError.signedOut
        }
    }

    private func report(_ error: Error) async {
        if case ICloudError.signedOut = error {
            await sessionExpired()
        }
        lastError = error.localizedDescription
    }
}

// MARK: - Demo

@MainActor
enum Demo {
    static let isEnabled = CommandLine.arguments.contains("--demo")
    static let forwardTo = "alex.morgan@icloud.com"
    private static var panels: [NSPanel] = []

    /// The menu bar window and the email field suggestions in floating panels,
    /// as if Zen were on github.com, so they can be captured while a
    /// full-screen app hides the menu bar.
    static func showPanels() {
        AppModel.shared.context = BrowsingContext(appName: "Zen", pid: 0, site: "github.com")
        let suggestions = SuggestionState()
        suggestions.site = "github.com"
        suggestions.generated = generate()
        suggestions.existing = AppModel.shared.siteAddresses
        show(MenuView(model: .shared)
            .background(.windowBackground, in: .rect(cornerRadius: 18)), at: CGPoint(x: 80, y: 120))
        show(SuggestionView(state: suggestions, onCreate: {}, onPick: { _ in })
            .background(.windowBackground, in: .rect(cornerRadius: 15)), at: CGPoint(x: 460, y: 500))
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first(where: { $0.title == "Addresses" }) else { return }
            window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.setFrame(CGRect(x: 160, y: 80, width: 1280, height: 700), display: true)
            window.level = .floating
            window.orderFrontRegardless()
        }
    }

    private static func show(_ view: some View, at origin: CGPoint) {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        panel.setFrame(CGRect(origin: origin, size: host.fittingSize), display: true)
        panel.orderFrontRegardless()
        panels.append(panel)
    }

    static let addresses: [HMEAddress] = {
        let entries: [(String, String, String, Bool)] = [
            ("maple-orbit-7q", "github.com", "", true),
            ("quiet-fern-2x", "figma.com", "Design team trial", true),
            ("lunar-pebble-9k", "notion.so", "", true),
            ("amber-delta-4m", "airbnb.com", "Lisbon trip", true),
            ("cobalt-wren-6t", "spotify.com", "", true),
            ("misty-canyon-3r", "linear.app", "", true),
            ("velvet-atlas-8p", "booking.com", "", true),
            ("sunny-harbor-5d", "duolingo.com", "", true),
            ("brisk-meadow-1z", "medium.com", "Newsletter", false),
            ("coral-summit-0v", "producthunt.com", "", true),
            ("silent-ember-6w", "nytimes.com", "", false),
            ("frost-lagoon-2c", "vercel.com", "", true),
            ("tidal-prism-4h", "github.com", "Work account", true),
            ("olive-comet-7s", "dropbox.com", "", true),
        ]
        let now = Date().timeIntervalSince1970 * 1000
        return entries.enumerated().map { index, entry in
            HMEAddress(anonymousId: "demo-\(index)", hme: "\(entry.0)@icloud.com", label: entry.1,
                       note: entry.2, forwardToEmail: forwardTo, isActive: entry.3,
                       createTimestamp: now - Double(index) * 4.3 * 86_400_000)
        }
    }()

    private static let words = ["cedar", "glint", "harbor", "juniper", "lumen", "nimbus", "opal", "quartz",
                                "saffron", "tundra", "willow", "zephyr"]

    static func generate() -> String {
        let suffix = String((0..<2).map { _ in "0123456789abcdefghjkmnpqrstvwxyz".randomElement()! })
        return "\(words.randomElement()!)-\(words.randomElement()!)-\(suffix)@icloud.com"
    }
}

// MARK: - Persistence

enum Cache {
    static var url: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HideMyEmail", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("addresses.json")
    }

    static func load() -> [HMEAddress]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([HMEAddress].self, from: $0) }
    }

    static func save(_ addresses: [HMEAddress]) {
        try? JSONEncoder().encode(addresses).write(to: url, options: [.atomic, .completeFileProtection])
    }
}

enum Keychain {
    static let service = "HideMyEmail.session"

    static func save(_ jar: CookieJar, region: ICloudRegion) {
        guard let data = try? JSONEncoder().encode(jar) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: region.rawValue,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func loadJar(region: ICloudRegion) -> CookieJar? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: region.rawValue,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(CookieJar.self, from: data)
    }

    static func delete(region: ICloudRegion) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: region.rawValue,
        ] as CFDictionary)
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }
}
