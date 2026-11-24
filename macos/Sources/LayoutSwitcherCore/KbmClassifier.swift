import Foundation

public enum KbmCandidateScore: Equatable, Sendable {
    /// No matching language pair / empty.
    case none
    /// Weighted n-gram feature score (weight sum across matched features).
    case weighted(Int32)
    /// Exact or prefix known-word feature matched (weight == 0, isKnownWord == true).
    case knownWord
    /// Collision / explicit exclusion marker matched (weight == 0, isKnownWord == false).
    case collision
}

public enum KbmDecision: Equatable, Sendable {
    /// Switch to the target language with the converted candidate word.
    case switchLayout(target: SwitcherLanguage, converted: String)
    /// Keep the current layout (current candidate won or both scored identically).
    case keepCurrent
    /// Explicit cross-layout collision (e.g. valid in both or marked excluded in model).
    case collision
    /// Model had no confident signal for either candidate (all scores == 0).
    case indeterminate
}

public struct KbmDiagnostics: Sendable, Equatable {
    public let ruCandidate: String
    public let enCandidate: String
    public let ruScore: KbmCandidateScore
    public let enScore: KbmCandidateScore
    public let decision: KbmDecision
}

/// Bit-exact Swift implementation of Caramba's caramba-core KbmClassifier
/// (reverse-engineered from 0x1002e0030, 0x1002e0cec, 0x1002e083c, 0x1002df804, 0x1002dfeb4).
public struct KbmClassifier: Sendable {
    public let model: KbmModel

    /// Punctuation stripped in the fallback pass of extract_features (0x1002e0168).
    private static let strippablePunctuation: Set<UnicodeScalar> = Set(
        "!\"'(),.:;?[]{}".unicodeScalars
    )

    /// Word boundary characters recognized by 0x1002e014c (\t, \n, \r, ' ', '-').
    private static let boundaryScalars: Set<UnicodeScalar> = Set(
        "\t\n\r -".unicodeScalars
    )

    public init(model: KbmModel) {
        self.model = model
    }

    /// Extracts all KbmFeatures matching a candidate string.
    /// - Parameters:
    ///   - word: The candidate word (without \x02/\x03 markers).
    ///   - isCompleteWord: True when evaluated at a word boundary (appends \x03),
    ///     false when evaluated mid-word while typing (only prepends \x02).
    public func extractFeatures(for word: String, isCompleteWord: Bool) -> [KbmFeature] {
        guard !word.isEmpty else { return [] }

        let primary = extractRawFeatures(for: word, isCompleteWord: isCompleteWord)
        if !primary.isEmpty {
            return primary
        }

        // Fallback pass (0x1002e00c0..0x1002e0340): strip surrounding punctuation if word is complete
        // or ends with a boundary character.
        let endsWithBoundary = word.unicodeScalars.last.map { Self.boundaryScalars.contains($0) } ?? false
        guard isCompleteWord || endsWithBoundary else {
            return []
        }

        let trimmed = stripSurroundingPunctuation(word)
        guard !trimmed.isEmpty, trimmed != word else {
            return []
        }
        return extractRawFeatures(for: trimmed, isCompleteWord: true)
    }

    /// Two-pass DAWG substring feature extraction matching 0x1002e1d98:
    /// - Pass 1 (lowercased): keeps features with isCaseSensitive == false
    /// - Pass 2 (original case): keeps features with isCaseSensitive == true
    private func extractRawFeatures(for word: String, isCompleteWord: Bool) -> [KbmFeature] {
        let wrappedOriginal = wrap(word, isCompleteWord: isCompleteWord)
        let wrappedLower = wrap(word.lowercased(), isCompleteWord: isCompleteWord)

        var features: [KbmFeature] = []

        // Pass 1: case-insensitive features from lowercased string
        let lowerIds = model.index.allSubstringValues(wrappedLower)
        for id in lowerIds {
            guard let set = model.featureSets[id] else { continue }
            for feat in set where !feat.isCaseSensitive {
                features.append(feat)
            }
        }

        // Pass 2: case-sensitive features from original-case string
        let origIds = (wrappedOriginal == wrappedLower)
            ? lowerIds
            : model.index.allSubstringValues(wrappedOriginal)
        for id in origIds {
            guard let set = model.featureSets[id] else { continue }
            for feat in set where feat.isCaseSensitive {
                features.append(feat)
            }
        }

        return features
    }

    private func wrap(_ word: String, isCompleteWord: Bool) -> String {
        if isCompleteWord {
            return "\u{02}\(word)\u{03}"
        } else {
            return "\u{02}\(word)"
        }
    }

    private func stripSurroundingPunctuation(_ word: String) -> String {
        var scalars = Array(word.unicodeScalars)
        while let last = scalars.last, Self.strippablePunctuation.contains(last) || Self.boundaryScalars.contains(last) {
            scalars.removeLast()
        }
        while let first = scalars.first,
              Self.strippablePunctuation.contains(first) || first == "-" || first == "(" || Self.boundaryScalars.contains(first) {
            scalars.removeFirst()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Exact port of score_candidate (0x1002e0cec).
    public func scoreCandidate(_ word: String, isCompleteWord: Bool) -> KbmCandidateScore {
        let features = extractFeatures(for: word, isCompleteWord: isCompleteWord)
        var totalWeight: Int32 = 0
        var hasKnownWord = false
        var hasCollision = false

        for feat in features {
            if feat.weight != 0 {
                totalWeight &+= feat.weight
            } else if feat.isKnownWord {
                hasKnownWord = true
            } else {
                hasCollision = true
            }
        }

        if hasCollision {
            return .collision
        }
        if hasKnownWord {
            return .knownWord
        }
        return .weighted(totalWeight)
    }

    /// Exact port of can_fix_double_caps (0x1002dfeb4):
    /// returns false if any matched feature marks the word as double-caps preventative
    /// (e.g. iOS, MacOS, SQL, C++).
    public func canFixDoubleCaps(_ word: String) -> Bool {
        let features = extractFeatures(for: word, isCompleteWord: true)
        return !features.contains { $0.isDoubleCapsPreventative }
    }

    /// Classifies a typed word against its opposite-layout conversion,
    /// matching classify_pair (0x1002e083c) + classify (0x1002df804).
    public func classify(
        typedWord: String,
        convertedWord: String,
        currentLanguage: SwitcherLanguage,
        isCompleteWord: Bool
    ) -> KbmDiagnostics {
        let ruWord = (currentLanguage == .russian) ? typedWord : convertedWord
        let enWord = (currentLanguage == .english) ? typedWord : convertedWord

        let ruScore = scoreCandidate(ruWord, isCompleteWord: isCompleteWord)
        let enScore = scoreCandidate(enWord, isCompleteWord: isCompleteWord)

        let decision = decide(
            ruScore: ruScore,
            enScore: enScore,
            ruWord: ruWord,
            enWord: enWord,
            currentLanguage: currentLanguage
        )

        return KbmDiagnostics(
            ruCandidate: ruWord,
            enCandidate: enWord,
            ruScore: ruScore,
            enScore: enScore,
            decision: decision
        )
    }

    private func decide(
        ruScore: KbmCandidateScore,
        enScore: KbmCandidateScore,
        ruWord: String,
        enWord: String,
        currentLanguage: SwitcherLanguage
    ) -> KbmDecision {
        // Explicit collision on either candidate aborts switching (0x1002e0980 / 0x1002e0b94).
        if ruScore == .collision || enScore == .collision {
            return .collision
        }

        // Known-word check: if both are known words, treat as collision (never switch a valid known word
        // into another valid known word). If exactly one is a known word, it wins.
        switch (ruScore, enScore) {
        case (.knownWord, .knownWord):
            return .collision
        case (.knownWord, _):
            return currentLanguage == .russian
                ? .keepCurrent
                : .switchLayout(target: .russian, converted: ruWord)
        case (_, .knownWord):
            return currentLanguage == .english
                ? .keepCurrent
                : .switchLayout(target: .english, converted: enWord)
        default:
            break
        }

        // Weighted score comparison (0x1002e099c..0x1002e0c80).
        guard case .weighted(let ruW) = ruScore, case .weighted(let enW) = enScore else {
            return .indeterminate
        }

        // Both scores zero => allScoresZero == true => indeterminate (do not switch).
        if ruW == 0 && enW == 0 {
            return .indeterminate
        }

        // Equal non-zero weights => ambiguous, keep current layout.
        if ruW == enW {
            return .keepCurrent
        }

        let winner: SwitcherLanguage = (ruW > enW) ? .russian : .english
        if winner == currentLanguage {
            return .keepCurrent
        } else {
            let converted = (winner == .russian) ? ruWord : enWord
            return .switchLayout(target: winner, converted: converted)
        }
    }
}

