import Foundation

public enum LogosModelError: Error, LocalizedError, Sendable {
    case missingResource
    case decompressionFailed
    case corruptedProtobuf(String)
    case corruptedDawg(String)

    public var errorDescription: String? {
        switch self {
        case .missingResource:
            return "Bundled Logos language model (logos.lzfse) could not be found."
        case .decompressionFailed:
            return "Failed to decompress bundled Logos language model."
        case .corruptedProtobuf(let message):
            return "Corrupted Logos protobuf: \(message)"
        case .corruptedDawg(let message):
            return "Corrupted Logos DAWG: \(message)"
        }
    }
}

public struct KbmFeature: Sendable, Equatable {
    public let langId: UInt32
    public let weight: Int32
    public let isKnownWord: Bool
    public let isCaseSensitive: Bool
    public let isDoubleCapsPreventative: Bool
}

public struct KbmModel: Sendable {
    public let index: DawgTrie
    public let featureSets: [UInt32: [KbmFeature]]
    public let languages: [UInt32: String]
}

public struct AppexRule: Sendable, Equatable {
    public let action: UInt8
    public let target: UInt8

    /// Platform nibble: 0x40 is macOS, 0x20 is Windows.
    public var isMacOS: Bool { (target & 0xF0) == 0x40 }
    /// Match field nibble: 0x02 = executable path, 0x04 = bundle ID, 0x08 = window title / URL.
    public var matchKind: AppexMatchKind? {
        switch target & 0x0F {
        case 0x02: return .executablePath
        case 0x04: return .bundleIdentifier
        case 0x08: return .windowTitle
        default: return nil
        }
    }
    /// 0x81 disables all switching/corrections; 0x82 disables auto-switching.
    public var disablesAll: Bool { action == 0x81 }
    public var disablesAutoSwitch: Bool { action == 0x81 || action == 0x82 }
}

public enum AppexMatchKind: Sendable, Equatable {
    case executablePath
    case bundleIdentifier
    case windowTitle
}

public struct AppexModel: Sendable {
    public let index: DawgTrie
    public let ruleSets: [UInt32: [AppexRule]]
}

public struct SpecialBehavior: Sendable, Equatable {
    public let pattern: String
    public let mode: UInt32
}

public struct FeatsConfig: Sendable, Equatable {
    public let specialBehaviors: [SpecialBehavior]
    public let switchToEnglishOnFocus: [String]
    public let delayBetweenLayoutActivationAndBackspacesMs: Int
    public let delayBetweenBackspacesAndRetypingMs: Int
    public let layoutSwitchNumRetries: Int
    public let layoutSwitchRetryDelayMs: Int
    public let splitShiftDelayMs: Int
}

public struct AutocorrectRule: Sendable, Equatable {
    public let prefixLen: Int
    public let suffixLen: Int
    public let insertId: Int
    public let caseSensitive: Bool
    public let isYofikator: Bool
}

public struct AutocorrectModel: Sendable {
    public let graph: DawgTrie
    public let rules: [AutocorrectRule]
    public let insertPool: [String]
}

/// Complete unpacked Caramba Logos language model (26.07.29.01).
public final class LogosModel: Sendable {
    public let version: String
    public let kbm: KbmModel
    public let appex: AppexModel
    public let feats: FeatsConfig
    public let autocorrect: AutocorrectModel

    private static let lock = NSLock()
    private static var cached: LogosModel?

    public static func loadBundled() throws -> LogosModel {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard let url = resolveBundledResourceURL() else {
            throw LogosModelError.missingResource
        }
        let compressed = try Data(contentsOf: url)
        let model = try LogosModel(lzfseData: compressed)
        cached = model
        return model
    }

    private static func resolveBundledResourceURL() -> URL? {
        if let url = Bundle.main.url(forResource: "logos", withExtension: "lzfse") {
            return url
        }
        // Check SPM resource bundles inside a packaged .app's Contents/Resources first
        // so packaged apps never fail if Bundle.module looks at the bundle root.
        if let resourceURL = Bundle.main.resourceURL {
            let candidates = [
                resourceURL.appendingPathComponent("KeyVeil_LayoutSwitcherCore.bundle/Contents/Resources/logos.lzfse"),
                resourceURL.appendingPathComponent("KeyVeil_LayoutSwitcherCore.bundle/logos.lzfse"),
                resourceURL.appendingPathComponent("HideMyEmail_LayoutSwitcherCore.bundle/Contents/Resources/logos.lzfse"),
                resourceURL.appendingPathComponent("HideMyEmail_LayoutSwitcherCore.bundle/logos.lzfse"),
            ]
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        if let url = Bundle.module.url(forResource: "logos", withExtension: "lzfse") {
            return url
        }
        return nil
    }

    public convenience init(lzfseData: Data) throws {
        guard let raw = try? (lzfseData as NSData).decompressed(using: .lzfse) as Data else {
            throw LogosModelError.decompressionFailed
        }
        try self.init(protobufData: raw)
    }

    public init(protobufData: Data) throws {
        var reader = ProtobufReader(protobufData)
        var version = ""
        var kbmData: Data?
        var appexData: Data?
        var featsData: Data?
        var autocorrectData: Data?

        while let (field, wireType) = try reader.readTag() {
            switch (field, wireType) {
            case (1, 2): version = try reader.readString()
            case (2, 2): kbmData = try reader.readLengthDelimited()
            case (3, 2): appexData = try reader.readLengthDelimited()
            case (4, 2): featsData = try reader.readLengthDelimited()
            case (5, 2): autocorrectData = try reader.readLengthDelimited()
            default: try reader.skip(wireType: wireType)
            }
        }

        guard let kbmData, let appexData, let featsData, let autocorrectData else {
            throw LogosModelError.corruptedProtobuf("Missing required top-level Logos sections")
        }

        self.version = version
        self.kbm = try Self.parseKbm(kbmData)
        self.appex = try Self.parseAppex(appexData)
        self.feats = try Self.parseFeats(featsData)
        self.autocorrect = try Self.parseAutocorrect(autocorrectData)
    }

    private static func parseKbm(_ data: Data) throws -> KbmModel {
        var reader = ProtobufReader(data)
        var dawgData: Data?
        var featureSets: [UInt32: [KbmFeature]] = [:]
        var languages: [UInt32: String] = [:]

        while let (field, wireType) = try reader.readTag() {
            switch (field, wireType) {
            case (2, 2):
                dawgData = try reader.readLengthDelimited()
            case (3, 2):
                let entryData = try reader.readLengthDelimited()
                let (key, features) = try parseKbmFeatureSetEntry(entryData)
                featureSets[key] = features
            case (4, 2):
                let langData = try reader.readLengthDelimited()
                let (key, value) = try parseLanguageEntry(langData)
                languages[key] = value
            default:
                try reader.skip(wireType: wireType)
            }
        }

        guard let dawgData else {
            throw LogosModelError.corruptedProtobuf("Missing KBM DAWG")
        }
        return KbmModel(index: try DawgTrie(data: dawgData), featureSets: featureSets, languages: languages)
    }

    private static func parseKbmFeatureSetEntry(_ data: Data) throws -> (UInt32, [KbmFeature]) {
        var reader = ProtobufReader(data)
        var key: UInt32 = 0
        var features: [KbmFeature] = []

        while let (field, wireType) = try reader.readTag() {
            switch (field, wireType) {
            case (1, 0):
                key = UInt32(truncatingIfNeeded: try reader.readVarint())
            case (2, 2):
                let setBytes = try reader.readLengthDelimited()
                var setReader = ProtobufReader(setBytes)
                while let (sf, sw) = try setReader.readTag() {
                    if sf == 1, sw == 2 {
                        let featBytes = try setReader.readLengthDelimited()
                        features.append(try parseKbmFeature(featBytes))
                    } else {
                        try setReader.skip(wireType: sw)
                    }
                }
            default:
                try reader.skip(wireType: wireType)
            }
        }
        return (key, features)
    }

    private static func parseKbmFeature(_ data: Data) throws -> KbmFeature {
        var reader = ProtobufReader(data)
        var langId: UInt32 = 0
        var weight: Int32 = 0
        var isKnownWord = false
        var isCaseSensitive = false
        var isDoubleCapsPreventative = false

        while let (field, wireType) = try reader.readTag() {
            switch (field, wireType) {
            case (1, 0): langId = UInt32(truncatingIfNeeded: try reader.readVarint())
            case (2, 0): weight = Int32(bitPattern: UInt32(truncatingIfNeeded: try reader.readVarint()))
            case (3, 0): isKnownWord = (try reader.readVarint()) != 0
            case (4, 0): isCaseSensitive = (try reader.readVarint()) != 0
            case (5, 0): isDoubleCapsPreventative = (try reader.readVarint()) != 0
            default: try reader.skip(wireType: wireType)
            }
        }
        return KbmFeature(
            langId: langId,
            weight: weight,
            isKnownWord: isKnownWord,
            isCaseSensitive: isCaseSensitive,
            isDoubleCapsPreventative: isDoubleCapsPreventative
        )
    }

    private static func parseLanguageEntry(_ data: Data) throws -> (UInt32, String) {
        var reader = ProtobufReader(data)
        var key: UInt32 = 0
        var value = ""
        while let (field, wireType) = try reader.readTag() {
            switch (field, wireType) {
            case (1, 0): key = UInt32(truncatingIfNeeded: try reader.readVarint())
            case (2, 2): value = try reader.readString()
            default: try reader.skip(wireType: wireType)
            }
        }
        return (key, value)
    }

    private static func parseAppex(_ data: Data) throws -> AppexModel {
        var reader = ProtobufReader(data)
        var dawgData: Data?
        var ruleSets: [UInt32: [AppexRule]] = [:]

        while let (field, wireType) = try reader.readTag() {
            switch (field, wireType) {
            case (2, 2):
                dawgData = try reader.readLengthDelimited()
            case (3, 2):
                let entryBytes = try reader.readLengthDelimited()
                var entryReader = ProtobufReader(entryBytes)
                var rid: UInt32 = 0
                var rules: [AppexRule] = []
                while let (ef, ew) = try entryReader.readTag() {
                    switch (ef, ew) {
                    case (1, 0):
                        rid = UInt32(truncatingIfNeeded: try entryReader.readVarint())
                    case (2, 2):
                        let rsBytes = try entryReader.readLengthDelimited()
                        var rsReader = ProtobufReader(rsBytes)
                        while let (rf, rw) = try rsReader.readTag() {
                            if rf == 1, rw == 2 {
                                let rawPairs = try rsReader.readLengthDelimited()
                                let bytes = Array(rawPairs)
                                var i = 0
                                while i + 1 < bytes.count {
                                    rules.append(AppexRule(action: bytes[i], target: bytes[i + 1]))
                                    i += 2
                                }
                            } else {
                                try rsReader.skip(wireType: rw)
                            }
                        }
                    default:
                        try entryReader.skip(wireType: ew)
                    }
                }
                ruleSets[rid] = rules
            default:
                try reader.skip(wireType: wireType)
            }
        }
        guard let dawgData else {
            throw LogosModelError.corruptedProtobuf("Missing Appex DAWG")
        }
        return AppexModel(index: try DawgTrie(data: dawgData), ruleSets: ruleSets)
    }

    private static func parseFeats(_ data: Data) throws -> FeatsConfig {
        var reader = ProtobufReader(data)
        var behaviors: [SpecialBehavior] = []
        var switchToEn: [String] = []
        var delayActivationToBackspaces = 25
        var delayBackspacesToRetype = 25
        var retries = 2
        var retryDelay = 25
        var splitShiftDelay = 100

        while let (field, wireType) = try reader.readTag() {
            switch (field, wireType) {
            case (1, 2):
                let sbData = try reader.readLengthDelimited()
                var sbReader = ProtobufReader(sbData)
                var pattern = ""
                var mode: UInt32 = 0
                while let (sf, sw) = try sbReader.readTag() {
                    switch (sf, sw) {
                    case (1, 2): pattern = try sbReader.readString()
                    case (2, 0): mode = UInt32(truncatingIfNeeded: try sbReader.readVarint())
                    default: try sbReader.skip(wireType: sw)
                    }
                }
                if !pattern.isEmpty {
                    behaviors.append(SpecialBehavior(pattern: pattern, mode: mode))
                }
            case (2, 2):
                switchToEn.append(try reader.readString())
            case (3, 0):
                delayActivationToBackspaces = Int(try reader.readVarint())
            case (4, 0):
                delayBackspacesToRetype = Int(try reader.readVarint())
            case (5, 0):
                retries = Int(try reader.readVarint())
            case (6, 0):
                retryDelay = Int(try reader.readVarint())
            case (7, 0):
                splitShiftDelay = Int(try reader.readVarint())
            default:
                try reader.skip(wireType: wireType)
            }
        }
        return FeatsConfig(
            specialBehaviors: behaviors,
            switchToEnglishOnFocus: switchToEn,
            delayBetweenLayoutActivationAndBackspacesMs: delayActivationToBackspaces,
            delayBetweenBackspacesAndRetypingMs: delayBackspacesToRetype,
            layoutSwitchNumRetries: retries,
            layoutSwitchRetryDelayMs: retryDelay,
            splitShiftDelayMs: splitShiftDelay
        )
    }

    private static func parseAutocorrect(_ data: Data) throws -> AutocorrectModel {
        var reader = ProtobufReader(data)
        var graphData: Data?
        var rules: [AutocorrectRule] = []
        var insertPool: [String] = []

        while let (field, wireType) = try reader.readTag() {
            switch (field, wireType) {
            case (1, 2):
                graphData = try reader.readLengthDelimited()
            case (2, 2):
                let ruleBytes = try reader.readLengthDelimited()
                var rr = ProtobufReader(ruleBytes)
                var prefixLen = 0
                var suffixLen = 0
                var insertId = 0
                var caseSensitive = false
                var isYofikator = false
                while let (rf, rw) = try rr.readTag() {
                    switch (rf, rw) {
                    case (1, 0): prefixLen = Int(try rr.readVarint())
                    case (2, 0): suffixLen = Int(try rr.readVarint())
                    case (3, 0): insertId = Int(try rr.readVarint())
                    case (4, 0): caseSensitive = (try rr.readVarint()) != 0
                    case (5, 0): isYofikator = (try rr.readVarint()) != 0
                    default: try rr.skip(wireType: rw)
                    }
                }
                rules.append(AutocorrectRule(
                    prefixLen: prefixLen,
                    suffixLen: suffixLen,
                    insertId: insertId,
                    caseSensitive: caseSensitive,
                    isYofikator: isYofikator
                ))
            case (3, 2):
                insertPool.append(try reader.readString())
            default:
                try reader.skip(wireType: wireType)
            }
        }

        guard let graphData else {
            throw LogosModelError.corruptedProtobuf("Missing Autocorrect DAWG")
        }
        return AutocorrectModel(
            graph: try DawgTrie(data: graphData),
            rules: rules,
            insertPool: insertPool
        )
    }
}
