import Foundation

public struct AutocorrectResult: Equatable, Sendable {
    public let original: String
    public let replacement: String
    public let isYofikator: Bool
}

/// Bit-exact Swift implementation of Caramba's Autocorrect & Yofikator engine
/// (72,661 DAWG rules + 2,420 insert strings, UTF-8 byte-offset patching).
public struct AutocorrectEngine: Sendable {
    public let model: AutocorrectModel

    private static let leadingPunct: Set<Character> = Set(["(", "[", "{", "\"", "'", "«", "—", "–"])
    private static let trailingPunct: Set<Character> = Set([".", ",", "!", "?", ";", ":", ")", "]", "}", "\"", "'", "»"])

    public init(model: AutocorrectModel) {
        self.model = model
    }

    /// Evaluates autocorrect / yofikator on a completed word (may include surrounding punctuation).
    public func evaluate(
        word: String,
        autocorrectEnabled: Bool,
        yofikatorEnabled: Bool
    ) -> AutocorrectResult? {
        guard autocorrectEnabled || yofikatorEnabled, !word.isEmpty else {
            return nil
        }

        // Try the whole word first (handles rules with leading punctuation like ".cmo" -> ".com").
        if let direct = matchCore(word, autocorrectEnabled: autocorrectEnabled, yofikatorEnabled: yofikatorEnabled) {
            return direct
        }

        // Otherwise strip surrounding punctuation and preserve it around the replacement.
        var chars = Array(word)
        var prefix = ""
        var suffix = ""
        while let first = chars.first, Self.leadingPunct.contains(first) {
            prefix.append(chars.removeFirst())
        }
        while let last = chars.last, Self.trailingPunct.contains(last) {
            suffix.insert(chars.removeLast(), at: suffix.startIndex)
        }
        guard !chars.isEmpty, (!prefix.isEmpty || !suffix.isEmpty) else {
            return nil
        }
        let core = String(chars)
        guard let coreResult = matchCore(core, autocorrectEnabled: autocorrectEnabled, yofikatorEnabled: yofikatorEnabled) else {
            return nil
        }
        return AutocorrectResult(
            original: word,
            replacement: prefix + coreResult.replacement + suffix,
            isYofikator: coreResult.isYofikator
        )
    }

    private func matchCore(
        _ word: String,
        autocorrectEnabled: Bool,
        yofikatorEnabled: Bool
    ) -> AutocorrectResult? {
        // 1. Try exact case match first.
        if let ruleId = model.graph.exactLookup("\u{02}\(word)\u{03}"),
           let result = apply(ruleId: Int(ruleId), to: word, matchedLowercased: false,
                              autocorrectEnabled: autocorrectEnabled, yofikatorEnabled: yofikatorEnabled) {
            return result
        }

        // 2. Try lowercased match for case-insensitive rules.
        let lower = word.lowercased()
        if lower != word,
           let ruleId = model.graph.exactLookup("\u{02}\(lower)\u{03}"),
           let result = apply(ruleId: Int(ruleId), to: word, matchedLowercased: true,
                              autocorrectEnabled: autocorrectEnabled, yofikatorEnabled: yofikatorEnabled) {
            return result
        }

        return nil
    }

    private func apply(
        ruleId: Int,
        to originalWord: String,
        matchedLowercased: Bool,
        autocorrectEnabled: Bool,
        yofikatorEnabled: Bool
    ) -> AutocorrectResult? {
        guard ruleId >= 0, ruleId < model.rules.count else { return nil }
        let rule = model.rules[ruleId]
        guard rule.insertId >= 0, rule.insertId < model.insertPool.count else { return nil }

        // If matched only via lowercasing, skip case-sensitive rules.
        if matchedLowercased && rule.caseSensitive {
            return nil
        }

        let insertText = model.insertPool[rule.insertId]
        let isYo = rule.isYofikator || insertText.contains("ё") || insertText.contains("Ё")

        if isYo {
            guard yofikatorEnabled else { return nil }
        } else {
            guard autocorrectEnabled else { return nil }
        }

        let base = matchedLowercased ? originalWord.lowercased() : originalWord
        let utf8 = Array(base.utf8)
        let prefixLen = rule.prefixLen
        let suffixLen = rule.suffixLen
        guard prefixLen >= 0, suffixLen >= 0, prefixLen + suffixLen <= utf8.count else {
            return nil
        }

        var outBytes: [UInt8] = []
        outBytes.reserveCapacity(utf8.count + insertText.utf8.count)
        if prefixLen > 0 {
            outBytes.append(contentsOf: utf8[0..<prefixLen])
        }
        outBytes.append(contentsOf: insertText.utf8)
        if suffixLen > 0 {
            outBytes.append(contentsOf: utf8[(utf8.count - suffixLen)..<utf8.count])
        }

        guard let rawReplaced = String(bytes: outBytes, encoding: .utf8) else {
            return nil
        }

        let finalText = matchedLowercased
            ? applyCasing(from: originalWord, to: rawReplaced)
            : rawReplaced

        guard finalText != originalWord else { return nil }

        return AutocorrectResult(
            original: originalWord,
            replacement: finalText,
            isYofikator: isYo
        )
    }

    /// Preserves ALL CAPS, Title Case, or per-character capitalization from originalWord.
    private func applyCasing(from original: String, to replacement: String) -> String {
        let origChars = Array(original)
        let letters = origChars.filter(\.isLetter)
        guard !letters.isEmpty else { return replacement }

        // ALL CAPS (e.g. "ЕЛКА" -> "ЁЛКА", "ВПЕРЕД" -> "ВПЕРЁД")
        if letters.allSatisfy(\.isUppercase) {
            return replacement.uppercased()
        }

        // Title Case (first letter uppercase, rest lowercase: "Елка" -> "Ёлка", "Teh" -> "The")
        if let first = origChars.first, first.isUppercase,
           origChars.dropFirst().filter(\.isLetter).allSatisfy(\.isLowercase) {
            guard let repFirst = replacement.first else { return replacement }
            return String(repFirst).uppercased() + replacement.dropFirst()
        }

        // Per-character casing fallback (useful when only a middle letter changed, e.g. e -> ё).
        let repChars = Array(replacement)
        if repChars.count == origChars.count {
            var out = ""
            out.reserveCapacity(repChars.count)
            for (o, r) in zip(origChars, repChars) {
                out.append(o.isUppercase ? String(r).uppercased() : String(r))
            }
            return out
        }

        return replacement
    }
}

