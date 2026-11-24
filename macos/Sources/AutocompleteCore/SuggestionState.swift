import Foundation

public enum TrailingPunctuationMode: String, CaseIterable, Identifiable, Sendable {
    case neither
    case fullCompletionsOnly
    case both

    public var id: String { rawValue }
}

public enum SuggestionKind: Equatable, Sendable {
    case completion
    case emoji(triggerLength: Int, shortcode: String)
    case autocorrect(wordLength: Int, original: String)
}

public struct ActiveSuggestion: Equatable, Sendable {
    public var text: String
    public var kind: SuggestionKind
    public var anchorPrefix: String

    public init(text: String, kind: SuggestionKind, anchorPrefix: String) {
        self.text = text
        self.kind = kind
        self.anchorPrefix = anchorPrefix
    }

    /// Number of characters before the caret that should be deleted before inserting `text`.
    public var deleteBeforeCount: Int {
        switch kind {
        case .completion:
            return 0
        case .emoji(let triggerLength, _):
            return triggerLength
        case .autocorrect(let wordLength, _):
            return wordLength
        }
    }

    public var supportsWordByWord: Bool {
        if case .completion = kind { return true }
        return false
    }
}

public enum SuggestionState {
    /// Checks whether inline completion should run for the current caret context.
    public static func shouldTriggerCompletion(
        prefix: String,
        suffix: String,
        selectionLength: Int,
        allowMidLine: Bool
    ) -> Bool {
        guard selectionLength == 0 else { return false }
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }

        // Avoid completing inside URLs or raw email addresses.
        if let lastToken = prefix.split(whereSeparator: { $0.isWhitespace }).last {
            let token = String(lastToken)
            if token.contains("://") || token.hasPrefix("www.") || token.contains("@") {
                return false
            }
        }

        if !allowMidLine {
            let sameLineSuffix = suffix.prefix { $0 != "\n" && $0 != "\r" }
            if sameLineSuffix.contains(where: { !$0.isWhitespace }) {
                return false
            }
        }
        return true
    }

    /// Smooth type-through: when the user types characters that already match the
    /// beginning of an active LLM suggestion, trim the matched prefix instead of
    /// flickering or re-querying the model.
    public static func advanceByTyping(
        typed: String,
        suggestion: ActiveSuggestion
    ) -> ActiveSuggestion? {
        guard case .completion = suggestion.kind, !typed.isEmpty else { return nil }
        guard suggestion.text.hasPrefix(typed) else { return nil }
        let remaining = String(suggestion.text.dropFirst(typed.count))
        guard !remaining.isEmpty else { return nil }
        return ActiveSuggestion(
            text: remaining,
            kind: .completion,
            anchorPrefix: suggestion.anchorPrefix + typed
        )
    }

    /// Splits the next logical word (including any leading whitespace) for
    /// word-by-word acceptance (e.g. Option+Tab / Option+Right).
    /// Works cleanly with English, Russian (Cyrillic), numbers, and punctuation.
    public static func splitNextWord(_ text: String) -> (accepted: String, remaining: String) {
        guard !text.isEmpty else { return ("", "") }
        var idx = text.startIndex

        // 1. Consume leading whitespace.
        while idx < text.endIndex && text[idx].isWhitespace {
            idx = text.index(after: idx)
        }

        if idx == text.endIndex {
            return (text, "")
        }

        // 2. Consume a word (letters, numbers, apostrophe/hyphen inside words) OR a single punctuation cluster.
        let isWordChar: (Character) -> Bool = { ch in
            ch.isLetter || ch.isNumber || ch == "'" || ch == "’" || ch == "-"
        }

        if isWordChar(text[idx]) {
            while idx < text.endIndex && isWordChar(text[idx]) {
                idx = text.index(after: idx)
            }
            // Attach immediately following sentence punctuation (e.g., comma or period) if followed by space or end.
            if idx < text.endIndex && ",.;:!?".contains(text[idx]) {
                let next = text.index(after: idx)
                if next == text.endIndex || text[next].isWhitespace {
                    idx = next
                }
            }
        } else {
            while idx < text.endIndex && !text[idx].isWhitespace && !isWordChar(text[idx]) {
                idx = text.index(after: idx)
            }
        }

        return (String(text[..<idx]), String(text[idx...]))
    }

    /// Applies Cotypist's trailing-punctuation preference to an accepted chunk:
    /// when trailing punctuation should be held back, strips trailing `. , ; : ! ?`
    /// from the accepted text and prepends it back to `remaining` so pressing accept
    /// again inserts it.
    public static func applyTrailingPunctuation(
        accepted: String,
        remaining: String,
        isFullAcceptance: Bool,
        mode: TrailingPunctuationMode
    ) -> (accepted: String, remaining: String) {
        let shouldInclude: Bool
        switch mode {
        case .both: shouldInclude = true
        case .fullCompletionsOnly: shouldInclude = isFullAcceptance
        case .neither: shouldInclude = false
        }
        guard !shouldInclude else { return (accepted, remaining) }

        let punct: Set<Character> = [".", ",", ";", ":", "!", "?"]
        var cut = accepted.endIndex
        while cut > accepted.startIndex {
            let prev = accepted.index(before: cut)
            if punct.contains(accepted[prev]) {
                cut = prev
            } else {
                break
            }
        }

        // Only hold back punctuation if there is actual text before it.
        guard cut < accepted.endIndex,
              accepted[..<cut].contains(where: { !$0.isWhitespace }) else {
            return (accepted, remaining)
        }

        let head = String(accepted[..<cut])
        let held = String(accepted[cut...])
        return (head, held + remaining)
    }
}

