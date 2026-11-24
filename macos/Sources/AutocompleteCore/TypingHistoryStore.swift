import Foundation

public enum PersonalizationStrength: String, CaseIterable, Identifiable, Sendable, Codable {
    case off
    case gentle
    case balanced
    case strong

    public var id: String { rawValue }

    public var maxStyleSamples: Int {
        switch self {
        case .off: return 0
        case .gentle: return 1
        case .balanced: return 2
        case .strong: return 3
        }
    }

    public var maxSampleChars: Int {
        switch self {
        case .off: return 0
        case .gentle: return 140
        case .balanced: return 200
        case .strong: return 260
        }
    }

    public var maxVocabularyWords: Int {
        switch self {
        case .off: return 0
        case .gentle: return 6
        case .balanced: return 12
        case .strong: return 20
        }
    }

    public var sliderIndex: Double {
        switch self {
        case .off: return 0
        case .gentle: return 1
        case .balanced: return 2
        case .strong: return 3
        }
    }

    public static func from(sliderIndex: Double) -> PersonalizationStrength {
        switch Int(sliderIndex.rounded()) {
        case 0: return .off
        case 1: return .gentle
        case 2: return .balanced
        default: return .strong
        }
    }
}

public struct CompletionStats: Codable, Equatable, Sendable {
    public var completionsAccepted: Int
    public var wordsAccepted: Int
    public var charactersSaved: Int

    public init(completionsAccepted: Int = 0, wordsAccepted: Int = 0, charactersSaved: Int = 0) {
        self.completionsAccepted = completionsAccepted
        self.wordsAccepted = wordsAccepted
        self.charactersSaved = charactersSaved
    }
}

public struct WritingSample: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let bundleID: String
    public let appName: String
    public let language: String
    public let updatedAt: Date
    public let acceptedCompletion: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        bundleID: String,
        appName: String,
        language: String,
        updatedAt: Date = Date(),
        acceptedCompletion: Bool
    ) {
        self.id = id
        self.text = text
        self.bundleID = bundleID
        self.appName = appName
        self.language = language
        self.updatedAt = updatedAt
        self.acceptedCompletion = acceptedCompletion
    }
}

/// Privacy-first local writing style store, personal vocabulary learner, completion statistics
/// tracker, and JSONL training-data exporter (full Cotypist Personalization & Training parity).
public final class TypingHistoryStore: @unchecked Sendable {
    public static let shared = TypingHistoryStore()

    private struct StoreEnvelope: Codable {
        var samples: [WritingSample]
        var vocabulary: [String: Int]
        var stats: CompletionStats
    }

    private let lock = NSLock()
    private let storageURL: URL
    private let maxSamples: Int
    private var samples: [WritingSample] = []
    private var vocabulary: [String: Int] = [:]
    private var stats = CompletionStats()

    public init(storageURL: URL? = nil, maxSamples: Int = 2000) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.storageURL = base
                .appendingPathComponent("KeyVeil", isDirectory: true)
                .appendingPathComponent("typing-history.json")
        }
        self.maxSamples = maxSamples
        loadFromDisk()
    }

    public var count: Int {
        lock.withLock { samples.count }
    }

    public var learnedWordCount: Int {
        lock.withLock { vocabulary.values.filter { $0 >= 2 }.count }
    }

    public var completionStats: CompletionStats {
        lock.withLock { stats }
    }

    public func allSamples() -> [WritingSample] {
        lock.withLock { samples }
    }

    public func countsByApp() -> [(bundleID: String, appName: String, count: Int)] {
        lock.withLock {
            var map: [String: (name: String, count: Int)] = [:]
            for s in samples {
                let prev = map[s.bundleID]
                map[s.bundleID] = (s.appName, (prev?.count ?? 0) + 1)
            }
            return map.map { ($0.key, $0.value.name, $0.value.count) }
                .sorted { $0.count > $1.count }
        }
    }

    /// Returns true if the user has naturally written this word at least twice,
    /// protecting personal jargon/names from aggressive spellcheck replacements.
    public func isLearnedPersonalWord(_ word: String) -> Bool {
        let key = word.lowercased()
        guard key.count >= 4 else { return false }
        return lock.withLock { (vocabulary[key] ?? 0) >= 2 }
    }

    /// Returns the user's highest-frequency personal words in the active language
    /// for Cotypist-style "Personalize word choice".
    public func topVocabularyWords(forLanguage lang: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        return lock.withLock {
            vocabulary
                .filter { word, freq in
                    freq >= 2 && word.count >= 4 && !Self.stopWords.contains(word) && (lang == "other" || Self.detectLanguage(word) == lang)
                }
                .sorted { a, b in
                    if a.value != b.value { return a.value > b.value }
                    return a.key < b.key
                }
                .prefix(limit)
                .map(\.key)
        }
    }

    /// Records completion acceptance metrics (mirroring Cotypist's completionStats.json).
    public func recordAcceptance(insertedText: String) {
        let trimmed = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        lock.withLock {
            stats.completionsAccepted += 1
            stats.wordsAccepted += max(1, words)
            stats.charactersSaved += insertedText.count
            saveToDiskLocked()
        }
    }

    /// Imports cumulative completion stats from Cotypist's `completionStats.json` if present.
    @discardableResult
    public func importCotypistStats(from url: URL? = nil) -> CompletionStats? {
        let fileURL: URL
        if let url {
            fileURL = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            fileURL = base.appendingPathComponent("app.cotypist.Cotypist/completionStats.json")
        }
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let perDay = json["perDay"] as? [String: Any] else {
            return nil
        }

        var importedCompletions = 0
        var importedWords = 0
        var importedChars = 0
        for (_, dayObj) in perDay {
            guard let dayDict = dayObj as? [String: Any] else { continue }
            for bucket in ["short", "long"] {
                guard let b = dayDict[bucket] as? [String: Any] else { continue }
                importedCompletions += (b["completionCount"] as? Int) ?? 0
                importedWords += (b["wordCountTotal"] as? Int) ?? 0
                importedChars += (b["characterCount"] as? Int) ?? 0
            }
        }
        guard importedCompletions > 0 else { return nil }
        let imported = CompletionStats(
            completionsAccepted: importedCompletions,
            wordsAccepted: importedWords,
            charactersSaved: importedChars
        )
        lock.withLock {
            stats.completionsAccepted = max(stats.completionsAccepted, imported.completionsAccepted)
            stats.wordsAccepted = max(stats.wordsAccepted, imported.wordsAccepted)
            stats.charactersSaved = max(stats.charactersSaved, imported.charactersSaved)
            saveToDiskLocked()
        }
        return imported
    }

    /// Records a writing excerpt after scrubbing sensitive tokens/secrets and updates
    /// the local personal vocabulary frequency table.
    @discardableResult
    public func record(
        text: String,
        bundleID: String,
        appName: String,
        acceptedCompletion: Bool
    ) -> Bool {
        guard let cleaned = Self.sanitizeSnippet(text) else { return false }
        let lang = Self.detectLanguage(cleaned)
        let extractedWords = Self.extractVocabularyTokens(from: cleaned)

        lock.withLock {
            for token in extractedWords {
                vocabulary[token, default: 0] += (acceptedCompletion ? 2 : 1)
            }
            if vocabulary.count > 4000 {
                // Prune lowest-frequency singletons to keep memory tiny.
                vocabulary = vocabulary.filter { $0.value >= 2 }
            }

            // Merge/replace if the newest sample for the same app is a prefix of this one.
            if let lastIdx = samples.lastIndex(where: { $0.bundleID == bundleID }) {
                let existing = samples[lastIdx]
                if cleaned == existing.text {
                    saveToDiskLocked()
                    return
                }
                if cleaned.hasPrefix(existing.text) || existing.text.hasPrefix(cleaned) {
                    if cleaned.count >= existing.text.count {
                        samples[lastIdx] = WritingSample(
                            id: existing.id,
                            text: cleaned,
                            bundleID: bundleID,
                            appName: appName,
                            language: lang,
                            updatedAt: Date(),
                            acceptedCompletion: existing.acceptedCompletion || acceptedCompletion
                        )
                        saveToDiskLocked()
                    }
                    return
                }
            }

            samples.append(WritingSample(
                text: cleaned,
                bundleID: bundleID,
                appName: appName,
                language: lang,
                updatedAt: Date(),
                acceptedCompletion: acceptedCompletion
            ))
            if samples.count > maxSamples {
                samples.removeFirst(samples.count - maxSamples)
            }
            saveToDiskLocked()
        }
        return true
    }

    /// Returns relevant recent writing examples matching the active language, app, and
    /// lexical topic overlap (TF-IDF-style token similarity) so completions adapt to
    /// the user's voice and current subject.
    public func relevantSamples(
        forPrefix prefix: String,
        bundleID: String?,
        strength: PersonalizationStrength
    ) -> [String] {
        let limit = strength.maxStyleSamples
        guard limit > 0 else { return [] }
        let maxChars = strength.maxSampleChars
        let targetLang = Self.detectLanguage(prefix)
        let normalizedPrefixTail = prefix.suffix(80).lowercased()
        let prefixTokens = Set(Self.extractVocabularyTokens(from: String(prefix.suffix(240))))

        return lock.withLock {
            guard !samples.isEmpty else { return [] }

            var scored: [(score: Double, sample: WritingSample)] = []
            let total = Double(max(samples.count, 1))

            for (idx, sample) in samples.enumerated() {
                if targetLang != "other" && sample.language != targetLang {
                    continue
                }
                let lower = sample.text.lowercased()
                if !normalizedPrefixTail.isEmpty && (lower.contains(normalizedPrefixTail) || normalizedPrefixTail.contains(lower.prefix(40))) {
                    continue
                }

                var score = Double(idx) / total // recency 0..1
                if let bundleID, sample.bundleID == bundleID {
                    score += 1.8
                }
                if sample.acceptedCompletion {
                    score += 0.6
                }
                if sample.text.count >= 35 {
                    score += 0.3
                }
                if !prefixTokens.isEmpty {
                    let sampleTokens = Set(Self.extractVocabularyTokens(from: sample.text))
                    let overlap = prefixTokens.intersection(sampleTokens).count
                    if overlap > 0 {
                        score += min(3.0, Double(overlap) * 0.9)
                    }
                }
                scored.append((score, sample))
            }

            scored.sort { $0.score > $1.score }

            var chosen: [String] = []
            for item in scored {
                let candidate = String(item.sample.text.prefix(maxChars))
                if chosen.contains(where: { $0.prefix(32).lowercased() == candidate.prefix(32).lowercased() }) {
                    continue
                }
                chosen.append(candidate)
                if chosen.count >= limit { break }
            }
            return chosen
        }
    }

    /// Exports all locally collected writing samples as a clean JSONL dataset ready for
    /// LoRA fine-tuning (e.g. mlx-lm / llama.cpp finetune).
    @discardableResult
    public func exportTrainingDataJSONL(to url: URL) throws -> Int {
        let snapshot = lock.withLock { samples }
        var lines: [String] = []
        lines.reserveCapacity(snapshot.count)
        let encoder = JSONEncoder()
        for sample in snapshot {
            let record: [String: String] = [
                "text": sample.text,
                "app": sample.appName,
                "language": sample.language,
            ]
            if let data = try? encoder.encode(record), let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }
        let body = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return lines.count
    }

    public func clearAll() {
        lock.withLock {
            samples = []
            vocabulary = [:]
            saveToDiskLocked()
        }
    }

    public func clear(bundleID: String) {
        lock.withLock {
            samples.removeAll { $0.bundleID == bundleID }
            rebuildVocabularyLocked()
            saveToDiskLocked()
        }
    }

    // MARK: - Language & Secret Redaction (matching Cotypist's privacy guards)

    public static func detectLanguage(_ text: String) -> String {
        var cyrillic = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if (0x0400...0x04FF).contains(scalar.value) {
                cyrillic += 1
            } else if (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value) {
                latin += 1
            }
        }
        if cyrillic >= 3 && cyrillic >= latin { return "ru" }
        if latin >= 3 { return "en" }
        return "other"
    }

    /// Extracts a clean trailing sentence/paragraph snippet and drops anything looking
    /// like credentials, private keys, API tokens, JWTs, or IBANs.
    public static func sanitizeSnippet(_ raw: String) -> String? {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.count >= 20 else { return nil }

        let paragraphs = normalized.split(separator: "\n", omittingEmptySubsequences: true)
        let candidate = String(paragraphs.last ?? Substring(normalized))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard candidate.count >= 20 else { return nil }
        let bounded = candidate.count > 320 ? String(candidate.suffix(320)) : candidate

        if containsSensitiveData(bounded) {
            return nil
        }

        let words = bounded.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 3 else { return nil }

        return bounded
    }

    /// Returns true if `text` contains patterns resembling API keys, private keys,
    /// JWTs, passwords, or IBANs (used to scrub both style history and screen context).
    public static func containsSensitiveData(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for regex in sensitivePatterns {
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    private static func extractVocabularyTokens(from text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && $0 != "-" })
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
            .filter { token in
                guard token.count >= 4 && token.count <= 28 && !stopWords.contains(token) else { return false }
                return !hasTripleRepeatedChar(token)
            }
    }

    private static func hasTripleRepeatedChar(_ word: String) -> Bool {
        var prev: Character?
        var run = 0
        for ch in word {
            if ch == prev {
                run += 1
                if run >= 3 { return true }
            } else {
                prev = ch
                run = 1
            }
        }
        return false
    }

    private static let stopWords: Set<String> = [
        // Russian function words
        "этот", "этого", "этой", "этом", "этих", "чтобы", "когда", "только", "просто",
        "если", "либо", "было", "будет", "быть", "может", "можно", "надо", "нужно",
        "очень", "меня", "тебя", "себя", "него", "есть", "здесь", "потом", "сейчас",
        "тоже", "даже", "через", "после", "перед", "между", "более", "менее", "около",
        // English function words
        "this", "that", "with", "from", "have", "will", "would", "could", "should",
        "about", "there", "their", "they", "them", "been", "were", "what", "when",
        "where", "which", "your", "just", "like", "some", "more", "into", "than", "then",
    ]

    private static let sensitivePatterns: [NSRegularExpression] = {
        let patterns = [
            "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----",
            "\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b",
            "\\b(?:sk|rk)_(?:live|test)_[0-9A-Za-z]{16,}",
            "\\bsk-(?:proj-)?[0-9A-Za-z_-]{20,}",
            "\\bgh[pousr]_[0-9A-Za-z]{20,}",
            "\\bAIza[0-9A-Za-z_-]{35}",
            "\\bxox[baprs]-[0-9A-Za-z-]{10,}",
            "\\beyJ[0-9A-Za-z_-]{8,}\\.[0-9A-Za-z_-]{8,}\\.[0-9A-Za-z_-]{8,}",
            "[A-Za-z][A-Za-z0-9+.\\-]*://[^\\s/:@]+:[^\\s/@]+@",
            "\\b[A-Z]{2}\\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,3})?\\b",
            "(?i)\\b(?:password|passwd|passphrase|secret|api[_-]?key|access[_-]?key|private[_-]?key|token|credential)\\s*[:=]\\s*\\S+",
            "^[ \\t]*(?:export[ \\t]+)?[A-Z][A-Z0-9_]*=",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    // MARK: - Persistence

    private func rebuildVocabularyLocked() {
        var next: [String: Int] = [:]
        for sample in samples {
            for token in Self.extractVocabularyTokens(from: sample.text) {
                next[token, default: 0] += (sample.acceptedCompletion ? 2 : 1)
            }
        }
        vocabulary = next
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        if let envelope = try? JSONDecoder().decode(StoreEnvelope.self, from: data) {
            lock.withLock {
                samples = Array(envelope.samples.suffix(maxSamples))
                vocabulary = envelope.vocabulary
                stats = envelope.stats
                if vocabulary.isEmpty && !samples.isEmpty {
                    rebuildVocabularyLocked()
                }
            }
            return
        }
        // Backwards-compatible migration from earlier plain [WritingSample] array format.
        // Only seed personal vocabulary from accepted completions during legacy migration
        // so historical pre-filter typo drafts never pollute the learned word list.
        if let legacy = try? JSONDecoder().decode([WritingSample].self, from: data) {
            lock.withLock {
                samples = Array(legacy.suffix(maxSamples))
                var next: [String: Int] = [:]
                for sample in samples where sample.acceptedCompletion {
                    for token in Self.extractVocabularyTokens(from: sample.text) {
                        next[token, default: 0] += 2
                    }
                }
                vocabulary = next
            }
        }
    }

    private func saveToDiskLocked() {
        let dir = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let envelope = StoreEnvelope(samples: samples, vocabulary: vocabulary, stats: stats)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
