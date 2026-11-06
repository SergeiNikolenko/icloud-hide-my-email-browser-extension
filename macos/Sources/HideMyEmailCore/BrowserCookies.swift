import CommonCrypto
import Compression
import Foundation
import SQLite3

/// Reads the icloud.com session a browser already holds, so signing in once
/// in the browser (including with a passkey) is enough for the app.
public enum BrowserCookies {
    public enum Engine: Sendable, Equatable {
        case safari
        case gecko
        case chromium(safeStorageService: String, safeStorageAccount: String)
    }

    public struct Browser: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let bundleID: String
        public let engine: Engine
        /// Relative to ~/Library/Application Support.
        public let dataPath: String
    }

    /// Safari's session comes from the bundled Safari extension, so the app never
    /// reads Safari's own cookie store.
    public static let safari = Browser(id: "safari", name: "Safari", bundleID: "com.apple.Safari", engine: .safari,
                                       dataPath: "")
    public static let safariExtensionID = "com.nikolenko.HideMyEmail.Safari"
    static let appGroup = "XNPNVQSG77.com.nikolenko.HideMyEmail"

    public static let browsers: [Browser] = [
        safari,
        Browser(id: "zen", name: "Zen", bundleID: "app.zen-browser.zen", engine: .gecko, dataPath: "zen/Profiles"),
        Browser(id: "firefox", name: "Firefox", bundleID: "org.mozilla.firefox", engine: .gecko,
                dataPath: "Firefox/Profiles"),
        Browser(id: "arc", name: "Arc", bundleID: "company.thebrowser.Browser",
                engine: .chromium(safeStorageService: "Arc Safe Storage", safeStorageAccount: "Arc"),
                dataPath: "Arc/User Data"),
        Browser(id: "chrome", name: "Google Chrome", bundleID: "com.google.Chrome",
                engine: .chromium(safeStorageService: "Chrome Safe Storage", safeStorageAccount: "Chrome"),
                dataPath: "Google/Chrome"),
        Browser(id: "brave", name: "Brave", bundleID: "com.brave.Browser",
                engine: .chromium(safeStorageService: "Brave Safe Storage", safeStorageAccount: "Brave"),
                dataPath: "BraveSoftware/Brave-Browser"),
        Browser(id: "edge", name: "Microsoft Edge", bundleID: "com.microsoft.edgemac",
                engine: .chromium(safeStorageService: "Microsoft Edge Safe Storage", safeStorageAccount: "Microsoft Edge"),
                dataPath: "Microsoft Edge"),
        Browser(id: "vivaldi", name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi",
                engine: .chromium(safeStorageService: "Vivaldi Safe Storage", safeStorageAccount: "Vivaldi"),
                dataPath: "Vivaldi"),
    ]

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    public static func installed() -> [Browser] {
        browsers.filter { browser in
            browser.engine == .safari
                || FileManager.default.fileExists(atPath: supportDirectory.appendingPathComponent(browser.dataPath).path)
        }
    }

    /// The browser's cookies for a domain, across all of its profiles.
    public static func cookies(from browser: Browser, domain: String) throws -> [StoredCookie] {
        let root = supportDirectory.appendingPathComponent(browser.dataPath)
        switch browser.engine {
        case .safari:
            guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup),
                  let data = try? Data(contentsOf: directory.appendingPathComponent("SafariSession.json"))
            else { return [] }
            return try JSONDecoder().decode(SafariSession.self, from: data).cookies
                .filter { $0.domain.hasSuffix(domain) }
                .map { cookie in
                    StoredCookie(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                                 expires: cookie.expirationDate.map(Date.init(timeIntervalSince1970:)),
                                 isSecure: cookie.secure)
                }
        case .gecko:
            return profiles(in: root, containing: "cookies.sqlite").flatMap { profile in
                geckoDatabaseCookies(profile: profile, domain: domain) + geckoSessionCookies(profile: profile, domain: domain)
            }
        case .chromium(let service, let account):
            let databases = profiles(in: root, containing: "Cookies") + profiles(in: root, containing: "Network/Cookies")
            guard !databases.isEmpty else { return [] }
            let key = try chromiumKey(service: service, account: account)
            return databases.flatMap { chromiumCookies(database: $0, domain: domain, key: key) }
        }
    }

    private static func profiles(in root: URL, containing file: String) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return children.map { $0.appendingPathComponent(file) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Gecko

    private static func geckoDatabaseCookies(profile: URL, domain: String) -> [StoredCookie] {
        rows(copyingDatabase: profile, sql: """
            SELECT name, value, host, path, expiry, isSecure FROM moz_cookies WHERE host LIKE ?
            """, domain: domain) { statement in
            let expiry = sqlite3_column_int64(statement, 4)
            // Gecko stores expiry in seconds, newer builds in milliseconds.
            let seconds = expiry > 100_000_000_000 ? Double(expiry) / 1000 : Double(expiry)
            return StoredCookie(name: text(statement, 0), value: text(statement, 1), domain: text(statement, 2),
                                path: text(statement, 3), expires: Date(timeIntervalSince1970: seconds),
                                isSecure: sqlite3_column_int(statement, 5) != 0)
        }
    }

    /// Session cookies live only in the session store, compressed as mozLz4.
    private static func geckoSessionCookies(profile: URL, domain: String) -> [StoredCookie] {
        let directory = profile.deletingLastPathComponent()
        let candidates = ["sessionstore-backups/recovery.jsonlz4", "sessionstore.jsonlz4"]
            .map { directory.appendingPathComponent($0) }
        guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: file), let json = decompressMozLz4(data),
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let cookies = object["cookies"] as? [[String: Any]]
        else { return [] }
        return cookies.compactMap { cookie in
            guard let host = cookie["host"] as? String, host.hasSuffix(domain),
                  let name = cookie["name"] as? String, let value = cookie["value"] as? String else { return nil }
            return StoredCookie(name: name, value: value, domain: host, path: cookie["path"] as? String ?? "/",
                                expires: nil, isSecure: cookie["secure"] as? Bool ?? true)
        }
    }

    static func decompressMozLz4(_ data: Data) -> Data? {
        let magic = Data("mozLz40\0".utf8)
        guard data.count > 12, data.prefix(8) == magic else { return nil }
        let size = data.subdata(in: 8..<12).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
        let source = data.subdata(in: 12..<data.count)
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination in
            source.withUnsafeBytes { input in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, size,
                                          input.bindMemory(to: UInt8.self).baseAddress!, source.count,
                                          nil, COMPRESSION_LZ4_RAW)
            }
        }
        return written == size ? output : nil
    }

    // MARK: Safari

    /// What SafariExtension/Resources/background.js sends: `browser.cookies` records.
    private struct SafariSession: Decodable {
        struct Cookie: Decodable {
            let name: String
            let value: String
            let domain: String
            let path: String
            let expirationDate: Double?
            let secure: Bool
        }

        let cookies: [Cookie]
    }

    // MARK: Chromium

    private static func chromiumKey(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let password = item as? Data else {
            throw CocoaError(.fileReadNoPermission)
        }
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        _ = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.bindMemory(to: CChar.self).baseAddress, password.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                         keyBytes.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
                }
            }
        }
        return key
    }

    private static func chromiumCookies(database: URL, domain: String, key: Data) -> [StoredCookie] {
        let version = Int(rows(copyingDatabase: database, sql: "SELECT value FROM meta WHERE key = 'version'",
                               domain: nil) { text($0, 0) }.first ?? "0") ?? 0
        return rows(copyingDatabase: database, sql: """
            SELECT name, encrypted_value, host_key, path, expires_utc, is_secure, value FROM cookies WHERE host_key LIKE ?
            """, domain: domain) { statement in
            var value = text(statement, 6)
            if value.isEmpty, let blob = sqlite3_column_blob(statement, 1) {
                let encrypted = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 1)))
                value = decryptChromium(encrypted, key: key, hasDomainHash: version >= 24) ?? ""
            }
            let expires = sqlite3_column_int64(statement, 4)
            // Chromium counts microseconds since 1601-01-01.
            let date = expires > 0 ? Date(timeIntervalSince1970: Double(expires) / 1_000_000 - 11_644_473_600) : nil
            return StoredCookie(name: text(statement, 0), value: value, domain: text(statement, 2),
                                path: text(statement, 3), expires: date, isSecure: sqlite3_column_int(statement, 5) != 0)
        }.filter { !$0.value.isEmpty }
    }

    static func decryptChromium(_ data: Data, key: Data, hasDomainHash: Bool) -> String? {
        guard data.count > 3, data.prefix(3) == Data("v10".utf8) else { return nil }
        let payload = data.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        var written = 0
        let outputCount = output.count
        let status = output.withUnsafeMutableBytes { out in
            payload.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, payload.count, out.baseAddress, outputCount, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        var plain = output.prefix(written)
        if hasDomainHash, plain.count >= 32 { plain = plain.dropFirst(32) }
        return String(data: plain, encoding: .utf8)
    }

    // MARK: SQLite

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    /// Browsers keep their databases locked and journaled, so read a copy
    /// together with its write-ahead log.
    private static func rows<T>(copyingDatabase source: URL, sql: String, domain: String?,
                                map: (OpaquePointer?) -> T) -> [T] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("db.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) {
                try? FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        if let domain {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, "%\(domain)", -1, transient)
        }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(map(statement))
        }
        return result
    }
}
