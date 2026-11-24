import Foundation

public enum ModelSource: String, Sendable, Hashable {
    case appModels
    case cotypistModels
    case custom
}

public struct LocalModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let filename: String
    public let url: URL
    public let sizeBytes: Int64
    public let source: ModelSource

    public init(id: String, name: String, filename: String, url: URL, sizeBytes: Int64, source: ModelSource) {
        self.id = id
        self.name = name
        self.filename = filename
        self.url = url
        self.sizeBytes = sizeBytes
        self.source = source
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

public struct DownloadableModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let filename: String
    public let downloadURL: URL
    public let approxSizeLabel: String
    public let summary: String

    public init(id: String, name: String, filename: String, downloadURL: URL, approxSizeLabel: String, summary: String) {
        self.id = id
        self.name = name
        self.filename = filename
        self.downloadURL = downloadURL
        self.approxSizeLabel = approxSizeLabel
        self.summary = summary
    }
}

public enum ModelCatalog {
    public static let defaultUserPrompt =
        "Write in a clear, natural, concise voice. Match the language and tone of the text."

    public static var appModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("KeyVeil/Models", isDirectory: true)
    }

    /// Legacy HideMyEmail models folder kept for seamless migration.
    public static var legacyAppModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("HideMyEmail/Models", isDirectory: true)
    }

    /// Read-only discovery of models previously downloaded by Cotypist so users
    /// do not have to re-download gigabytes of GGUF files.
    public static var cotypistModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("app.cotypist.Cotypist/Models", isDirectory: true)
    }

    public static let curatedDownloads: [DownloadableModel] = [
        DownloadableModel(
            id: "qwen3-1.7b-q3ks",
            name: "Qwen3 1.7B Instruct (Recommended, <1 GB RAM)",
            filename: "Qwen3-1.7B-Q3_K_S.gguf",
            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q3_K_S.gguf")!,
            approxSizeLabel: "~827 MB",
            summary: "Smartest EN & RU autocomplete + Wispr text polish under 1 GB RAM"
        ),
        DownloadableModel(
            id: "qwen35-0.8b-q5km",
            name: "Qwen3.5 0.8B Instruct (Fast & Compact)",
            filename: "Qwen3.5-0.8B-Q5_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q5_K_M.gguf")!,
            approxSizeLabel: "~563 MB",
            summary: "Hybrid DeltaNet, ~700 MB RAM, very fast autocomplete & polish"
        ),
        DownloadableModel(
            id: "qwen25-1.5b-instruct-iq3m",
            name: "Qwen2.5 1.5B Instruct (Balanced, <1 GB RAM)",
            filename: "Qwen2.5-1.5B-Instruct-IQ3_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-IQ3_M.gguf")!,
            approxSizeLabel: "~741 MB",
            summary: "Fast 1.5B instruct model (~840 MB RAM), EN & RU"
        ),
        DownloadableModel(
            id: "qwen3-0.6b-base-q4km",
            name: "Qwen3 0.6B Base (Ultra-Light)",
            filename: "Qwen3-0.6B-Base.i1-Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/mradermacher/Qwen3-0.6B-Base-i1-GGUF/resolve/main/Qwen3-0.6B-Base.i1-Q4_K_M.gguf")!,
            approxSizeLabel: "~378 MB",
            summary: "Smallest footprint (~500 MB RAM), basic completion only"
        ),
    ]

    public static func discoverModels(
        appDir: URL = appModelsDirectory,
        legacyAppDir: URL = legacyAppModelsDirectory,
        cotypistDir: URL = cotypistModelsDirectory,
        customPaths: [String] = []
    ) -> [LocalModel] {
        var result: [LocalModel] = []
        var seenPaths = Set<String>()
        var seenFilenames = Set<String>()

        func appendIfValid(url: URL, source: ModelSource) {
            let standardized = url.standardizedFileURL
            let path = standardized.path
            guard !seenPaths.contains(path) else { return }
            guard standardized.pathExtension.lowercased() == "gguf" else { return }
            guard isValidGGUFFile(at: standardized, sizeOut: nil) else { return }

            let filename = standardized.lastPathComponent
            if source != .custom && seenFilenames.contains(filename.lowercased()) {
                return
            }

            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            seenPaths.insert(path)
            seenFilenames.insert(filename.lowercased())
            result.append(LocalModel(
                id: path,
                name: displayName(for: filename),
                filename: filename,
                url: standardized,
                sizeBytes: size,
                source: source
            ))
        }

        for (dir, source) in [
            (appDir, ModelSource.appModels),
            (legacyAppDir, ModelSource.appModels),
            (cotypistDir, ModelSource.cotypistModels)
        ] {
            if let items = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for url in items.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
                    appendIfValid(url: url, source: source)
                }
            }
        }

        for raw in customPaths where !raw.isEmpty {
            appendIfValid(url: URL(fileURLWithPath: raw), source: .custom)
        }

        return result.sorted { a, b in
            if a.sizeBytes != b.sizeBytes { return a.sizeBytes < b.sizeBytes }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    public static func isValidGGUFFile(at url: URL, sizeOut: UnsafeMutablePointer<Int64>? = nil) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size > 1_000_000 else {
            return false
        }
        sizeOut?.pointee = size
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        return magic == Data([0x47, 0x47, 0x55, 0x46]) // "GGUF"
    }

    public static func isValidLoRAFile(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size > 1024 else {
            return false
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        return magic == Data([0x47, 0x47, 0x55, 0x46]) // "GGUF"
    }

    public static func displayName(for filename: String) -> String {
        var name = filename
        if name.lowercased().hasSuffix(".gguf") {
            name = String(name.dropLast(5))
        }
        return name
            .replacingOccurrences(of: ".i1-", with: " ")
            .replacingOccurrences(of: "-i1-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    /// Reads the user's previously configured Cotypist style prompt once (read-only)
    /// so migrating from Cotypist preserves their writing voice automatically.
    public static func importedCotypistUserPrompt() -> String? {
        guard let suite = UserDefaults(suiteName: "app.cotypist.Cotypist"),
              let prompt = suite.string(forKey: "CompletionManager_userPrompt") else {
            return nil
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Reads Cotypist's selected model stem (e.g. "Qwen3-1.7B-Base.i1-Q4_K_M") to pick
    /// the same default model if available locally.
    public static func importedCotypistSelectedModelHint() -> String? {
        guard let suite = UserDefaults(suiteName: "app.cotypist.Cotypist"),
              let selected = suite.string(forKey: "ModelRepository_selectedModel"),
              !selected.isEmpty else {
            return nil
        }
        return selected
    }

    public static func preferredDefaultModel(from models: [LocalModel], savedPath: String?) -> LocalModel? {
        if let savedPath, let exact = models.first(where: { $0.id == savedPath || $0.url.path == savedPath }) {
            return exact
        }
        // Prefer compact (< 850 MB) instruction-tuned models so RAM stays under 1 GB
        // while still delivering strong RU/EN completion and Wispr text polish.
        let compactInstruct = models.filter {
            $0.sizeBytes <= 850 * 1024 * 1024 && ModelPromptFormat.detect(from: $0.url) != .base
        }
        if let preferred = compactInstruct.max(by: { $0.sizeBytes < $1.sizeBytes }) {
            return preferred
        }
        if let hint = importedCotypistSelectedModelHint()?.lowercased() {
            let core = hint.replacingOccurrences(of: "-base", with: "")
            if let matched = models.first(where: {
                let lower = $0.filename.lowercased()
                return lower.contains(hint) || lower.contains(core) || (hint.contains("qwen3-1.7b") && lower.contains("qwen3-1.7b"))
            }) {
                return matched
            }
        }
        return models.first
    }
}

