import Foundation

public enum ModelPromptFormat: String, Equatable, Sendable {
    case base
    case qwenInstruct
    case qwen2Instruct
    case gemmaInstruct
    case llama3Instruct

    public static func detect(from modelURL: URL?) -> ModelPromptFormat {
        guard let name = modelURL?.lastPathComponent.lowercased() else { return .base }
        if name.contains("base") || name.contains("-pt") || name.contains("_pt") {
            return .base
        }
        if name.contains("gemma") && (name.contains("it") || name.contains("instruct")) {
            return .gemmaInstruct
        }
        if name.contains("llama-3") || name.contains("llama3") {
            return name.contains("instruct") ? .llama3Instruct : .base
        }
        if name.contains("qwen2") {
            return (name.contains("instruct") || name.contains("chat")) ? .qwen2Instruct : .base
        }
        if name.contains("qwen3.5") || name.contains("qwen35") || name.contains("qwen3") {
            // Non-base Qwen3 / Qwen3.5 releases are instruction/chat models with <think> support.
            return .qwenInstruct
        }
        if name.contains("qwen") && (name.contains("instruct") || name.contains("chat")) {
            return .qwen2Instruct
        }
        return .base
    }
}

public enum TextPolishStyle: String, CaseIterable, Identifiable, Sendable {
    case clean
    case agents
    case formal

    public var id: String { rawValue }
}

public enum CompletionLengthPreset: String, CaseIterable, Identifiable, Sendable {
    case currentWord
    case short
    case medium
    case long

    public var id: String { rawValue }

    public var maxTokens: Int {
        switch self {
        case .currentWord: return 8
        case .short: return 14
        case .medium: return 24
        case .long: return 48
        }
    }

    public var maxChars: Int {
        switch self {
        case .currentWord: return 32
        case .short: return 64
        case .medium: return 160
        case .long: return 260
        }
    }
}

public struct CompletionContext: Equatable, Sendable {
    public var prefix: String
    public var suffix: String
    public var appName: String?
    public var windowTitle: String?
    public var pageURL: String?
    public var screenContext: String?
    public var clipboard: String?
    public var userPrompt: String
    public var appPrompt: String
    public var styleSamples: [String]
    public var personalVocabulary: [String]
    public var maxLength: CompletionLengthPreset
    public var allowMidLine: Bool

    public init(
        prefix: String,
        suffix: String = "",
        appName: String? = nil,
        windowTitle: String? = nil,
        pageURL: String? = nil,
        screenContext: String? = nil,
        clipboard: String? = nil,
        userPrompt: String = "",
        appPrompt: String = "",
        styleSamples: [String] = [],
        personalVocabulary: [String] = [],
        maxLength: CompletionLengthPreset = .medium,
        allowMidLine: Bool = true
    ) {
        self.prefix = prefix
        self.suffix = suffix
        self.appName = appName
        self.windowTitle = windowTitle
        self.pageURL = pageURL
        self.screenContext = screenContext
        self.clipboard = clipboard
        self.userPrompt = userPrompt
        self.appPrompt = appPrompt
        self.styleSamples = styleSamples
        self.personalVocabulary = personalVocabulary
        self.maxLength = maxLength
        self.allowMidLine = allowMidLine
    }
}

public enum PromptBuilder {
    public static let maxPrefixChars = 1400
    public static let maxClipboardChars = 400
    public static let maxScreenContextChars = 650
    public static let maxSuffixChars = 200

    /// Exact instruction suffix used by Cotypist for instruction-tuned models.
    public static let cotypistInstructionSuffix =
        "\n\nNow, please complete the following text that I am typing. Write full, grammatically correct sentences in the language and style of the existing text. Avoid using placeholders. Do not mention that your task is to provide completions, or e.g. the fact that I am typing, etc.; just try to complete the sentence."

    /// Builds a natural continuation prompt matching Cotypist's architecture:
    /// - Base models (Qwen3.5-0.8B-Base, Qwen3-1.7B-Base, etc.): lightweight natural
    ///   author/style preamble + recent personal writing excerpts + exact live prefix
    ///   so the base model continues directly in the user's voice without bracket artifacts.
    /// - Instruct models (Qwen3-Instruct, Gemma-IT, Llama3-Instruct): Cotypist's exact
    ///   chat-template continuation framing with `/no_think` for Qwen3.
    public static func buildPrompt(
        for context: CompletionContext,
        format: ModelPromptFormat = .base
    ) -> String {
        let boundedPrefix = tailSubstring(context.prefix, limit: maxPrefixChars)
        let metadataBlock = buildContextMetadata(for: context)

        switch format {
        case .base:
            return buildBasePrompt(metadata: metadataBlock, styleSamples: context.styleSamples, prefix: boundedPrefix)
        case .qwenInstruct:
            let userBody = buildInstructUserBody(metadata: metadataBlock, styleSamples: context.styleSamples)
            return "<|im_start|>user\n/no_think\n\(userBody)\(cotypistInstructionSuffix)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\(boundedPrefix)"
        case .qwen2Instruct:
            let userBody = buildInstructUserBody(metadata: metadataBlock, styleSamples: context.styleSamples)
            return "<|im_start|>system\nYou are an inline writing autocomplete engine. Continue the user's text naturally in the same language and tone without commentary.<|im_end|>\n<|im_start|>user\n\(userBody)\(cotypistInstructionSuffix)<|im_end|>\n<|im_start|>assistant\n\(boundedPrefix)"
        case .gemmaInstruct:
            let userBody = buildInstructUserBody(metadata: metadataBlock, styleSamples: context.styleSamples)
            return "<start_of_turn>user\n\(userBody)\(cotypistInstructionSuffix)<end_of_turn>\n<start_of_turn>model\n\(boundedPrefix)"
        case .llama3Instruct:
            let userBody = buildInstructUserBody(metadata: metadataBlock, styleSamples: context.styleSamples)
            return "<|start_header_id|>user<|end_header_id|>\n\n\(userBody)\(cotypistInstructionSuffix)<|eot_id|>\n<|start_header_id|>assistant<|end_header_id|>\n\n\(boundedPrefix)"
        }
    }

    private static func buildContextMetadata(for context: CompletionContext) -> [String] {
        var lines: [String] = []

        let style = context.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !style.isEmpty {
            lines.append(style)
        }

        let perApp = context.appPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !perApp.isEmpty {
            lines.append(perApp)
        }

        if let app = context.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
            if let title = context.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty, title != app {
                lines.append("Application: \(app) — \(String(title.prefix(80)))")
            } else {
                lines.append("Application: \(app)")
            }
        }

        if let rawURL = context.pageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           (rawURL.hasPrefix("http://") || rawURL.hasPrefix("https://")) {
            let cleanedURL = rawURL
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
            lines.append("Page: \(String(cleanedURL.prefix(120)))")
        }

        if let screen = context.screenContext?.trimmingCharacters(in: .whitespacesAndNewlines), !screen.isEmpty {
            let boundedScreen = tailSubstring(screen, limit: maxScreenContextChars)
            lines.append("Visible screen context:\n\(boundedScreen)")
        }

        if let clip = context.clipboard?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
            let collapsed = clip
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n+", with: " ", options: .regularExpression)
            lines.append("Clipboard: \(String(collapsed.prefix(maxClipboardChars)))")
        }

        if !context.personalVocabulary.isEmpty {
            let vocabList = context.personalVocabulary.prefix(20).joined(separator: ", ")
            lines.append("Preferred vocabulary: \(vocabList)")
        }

        return lines
    }

    private static func buildBasePrompt(
        metadata: [String],
        styleSamples: [String],
        prefix: String
    ) -> String {
        var sections: [String] = []

        if !metadata.isEmpty {
            sections.append(metadata.joined(separator: "\n"))
        }

        let cleanSamples = styleSamples
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanSamples.isEmpty {
            sections.append(cleanSamples.joined(separator: "\n\n"))
        }

        if sections.isEmpty {
            return prefix
        }

        return sections.joined(separator: "\n\n---\n\n") + "\n\n---\n\n" + prefix
    }

    private static func buildInstructUserBody(metadata: [String], styleSamples: [String]) -> String {
        var parts = metadata
        let cleanSamples = styleSamples
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanSamples.isEmpty {
            parts.append("Recent examples of my writing style:\n" + cleanSamples.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    /// Cleans raw model output into a crisp inline continuation suitable for
    /// rendering directly inside the user's text editor.
    public static func cleanSuggestion(
        _ raw: String,
        prefix: String,
        suffix: String = "",
        allowMidLine: Bool = true,
        maxLength: CompletionLengthPreset = .medium
    ) -> String? {
        var text = raw

        // Strip common special / control tokens that some models emit as plain text.
        let controlMarkers = [
            "<|endoftext|>", "<|im_end|>", "<|im_start|>",
            "<end_of_turn>", "<start_of_turn>", "<|eot_id|>", "<|end|>",
            "<eos>", "</s>", "</think>", "<think>", "\r"
        ]
        for marker in controlMarkers {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
            }
        }

        // Keep inline suggestions within the current paragraph (stop before newline or divider).
        if let nl = text.firstIndex(of: "\n") {
            text = String(text[..<nl])
        }
        if let div = text.range(of: "---") {
            text = String(text[..<div.lowerBound])
        }

        // Strip leaked metadata headers if a small model tries to repeat them.
        for leaked in ["Application:", "Page:", "Visible screen context:", "Clipboard:", "Preferred vocabulary:", "[App:", "[Clipboard:"] {
            if let range = text.range(of: leaked) {
                text = String(text[..<range.lowerBound])
            }
        }

        // Normalize runs of internal spaces while preserving a single leading space if needed.
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }

        // Do not double-space if prefix already ends with whitespace.
        if let last = prefix.last, last.isWhitespace {
            while text.first?.isWhitespace == true {
                text.removeFirst()
            }
        }

        // Trim trailing whitespace so Tab lands neatly after the completed word/clause.
        while text.last?.isWhitespace == true {
            text.removeLast()
        }

        // When completing mid-line, avoid duplicating text that already follows the cursor.
        if allowMidLine && !suffix.isEmpty {
            let trimmedSuffix = suffix.prefix(maxSuffixChars)
            text = trimOverlap(suggestion: text, suffix: String(trimmedSuffix))
        }

        // If user chose "Current word only", trim cleanly after the first word.
        if maxLength == .currentWord {
            let leadingSpace = text.first == " " ? " " : ""
            let body = leadingSpace.isEmpty ? text : String(text.dropFirst())
            if let spaceIdx = body.firstIndex(where: { $0.isWhitespace }) {
                text = leadingSpace + String(body[..<spaceIdx])
            }
        }

        // Reject degenerate or empty completions.
        guard !text.isEmpty else { return nil }
        let nonWS = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nonWS.isEmpty else { return nil }
        let hasSubstantiveScalar = nonWS.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar.properties.isEmojiPresentation
        }
        guard hasSubstantiveScalar else { return nil }
        if isRepetitiveGarbage(text) { return nil }

        // Cap overly long predictions cleanly at a word boundary.
        let charLimit = maxLength.maxChars
        if text.count > charLimit {
            let cutoff = text.index(text.startIndex, offsetBy: charLimit)
            if let space = text[..<cutoff].lastIndex(of: " ") {
                text = String(text[..<space])
            } else {
                text = String(text[..<cutoff])
            }
        }

        return text.isEmpty ? nil : text
    }

    static func tailSubstring(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let start = text.index(text.endIndex, offsetBy: -limit)
        let slice = text[start...]
        if let boundary = slice.firstIndex(where: { $0.isWhitespace }) {
            let next = slice.index(after: boundary)
            if next < slice.endIndex {
                return String(slice[next...])
            }
        }
        return String(slice)
    }

    static func trimOverlap(suggestion: String, suffix: String) -> String {
        let maxCheck = min(suggestion.count, suffix.count)
        guard maxCheck >= 2 else { return suggestion }
        let sugChars = Array(suggestion)
        let sufChars = Array(suffix)
        for len in stride(from: maxCheck, through: 2, by: -1) {
            if Array(sugChars[(sugChars.count - len)...]) == Array(sufChars[..<len]) {
                return String(sugChars[..<(sugChars.count - len)]).trimmingCharacters(in: CharacterSet(charactersIn: " "))
            }
        }
        return suggestion
    }

    private static func isRepetitiveGarbage(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        if words.count >= 4 {
            var streak = 1
            for i in 1..<words.count {
                if words[i].lowercased() == words[i - 1].lowercased() {
                    streak += 1
                    if streak >= 3 { return true }
                } else {
                    streak = 1
                }
            }
        }
        if text.count >= 6 {
            let unique = Set(text)
            if unique.count == 1 { return true }
            // Catch runs of 6+ identical consecutive characters (e.g. "20000000000000000000").
            let chars = Array(text)
            var charRun = 1
            for i in 1..<chars.count {
                if chars[i] == chars[i - 1] {
                    charRun += 1
                    if charRun >= 6 { return true }
                } else {
                    charRun = 1
                }
            }
            // Catch short 2–4 character loops repeated 4+ times consecutively (e.g. "01010101").
            for unitLen in 2...4 where chars.count >= unitLen * 4 {
                var idx = 0
                while idx + unitLen * 4 <= chars.count {
                    let pattern = chars[idx..<(idx + unitLen)]
                    var repeats = 1
                    var cursor = idx + unitLen
                    while cursor + unitLen <= chars.count && chars[cursor..<(cursor + unitLen)].elementsEqual(pattern) {
                        repeats += 1
                        cursor += unitLen
                    }
                    if repeats >= 4 { return true }
                    idx += 1
                }
            }
        }
        return false
    }

    // MARK: - Wispr-Style Text Polish (Typos, Grammar, Punctuation, Clarity)

    /// Builds a deterministic prompt that turns fast, typo-heavy messages into
    /// clean, well-punctuated, natural prose (like Wispr Flow / dictation cleanup)
    /// while preserving technical terms, file paths, code identifiers, and meaning.
    public static func buildPolishPrompt(
        text: String,
        style: TextPolishStyle = .clean,
        appName: String? = nil,
        format: ModelPromptFormat = .qwen2Instruct
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let styleGuidance: String
        switch style {
        case .clean:
            styleGuidance = "Сохраняй живой естественный стиль автора (включая обращение на «ты»)."
        case .agents:
            styleGuidance = "Сохраняй прямой рабочий тон для AI-агента, короткие понятные формулировки и все технические детали."
        case .formal:
            styleGuidance = "Сделай формулировки вежливыми, структурированными и деловыми, не меняя смысл."
        }

        let system = """
        Ты — точный корректор быстрой печати (как Wispr Flow) для русского и английского языков.
        Отредактируй ТОЛЬКО переданный ниже текст пользователя:
        - Исправь опечатки, пропуски и перестановки букв, слитные и раздельные написания («что бы» → «чтобы», «так же» → «также», «не логичностей» → «нелогичностей»).
        - Поставь заглавную букву в начале каждого предложения и убери двойные пробелы.
        - Аккуратно расставь запятые (перед «чтобы», «что», «который», «потому что», «если», «когда», «но», «а», между перечислениями и частями сложного предложения) и знаки препинания.
        - \(styleGuidance)
        - Сохрани язык, смысл, все технические термины, названия, пути и числа. Не меняй слова на другие по смыслу, не отвечай на текст и не пиши комментариев.
        - Выведи ТОЛЬКО готовый исправленный текст.
        """

        let user = "Исправь опечатки, заглавные буквы и расставь запятые:\n\(trimmed)"

        switch format {
        case .qwenInstruct:
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n/no_think\n\(user)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n"
        case .qwen2Instruct:
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        case .gemmaInstruct:
            return "<start_of_turn>user\n\(system)\n\n\(user)<end_of_turn>\n<start_of_turn>model\n"
        case .llama3Instruct:
            return "<|start_header_id|>system<|end_header_id|>\n\n\(system)<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n\(user)<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"
        case .base:
            return """
            Исправь опечатки, грамматику и знаки препинания. Сохрани смысл и термины.

            Input: проверь на виртуалке как выглядит прилоенжие и нет ли там косяков в интерфесе
            Output: Проверь на виртуалке, как выглядит приложение и нет ли там косяков в интерфейсе.

            Input: \(trimmed)
            Output: 
            """
        }
    }

    /// Cleans the raw output of `polishText`, stripping wrapper labels or quotes
    /// and rejecting runaway/hallucinated replies.
    public static func cleanPolishedText(_ raw: String, original: String) -> String? {
        var text = raw

        // Strip any <think>...</think> blocks if a thinking model emitted them.
        if let endThink = text.range(of: "</think>") {
            text = String(text[endThink.upperBound...])
        }

        let controlMarkers = [
            "<|endoftext|>", "<|im_end|>", "<|im_start|>",
            "<end_of_turn>", "<start_of_turn>", "<|eot_id|>", "<|end|>",
            "<eos>", "</s>", "<think>", "\r"
        ]
        for marker in controlMarkers {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
            }
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip common conversational preambles if a small model adds one.
        let preamblePrefixes = [
            "Исправленный текст:", "Исправленный вариант:", "Результат:", "Выход:",
            "Corrected text:", "Fixed text:", "Output:", "Result:"
        ]
        for prefix in preamblePrefixes {
            if text.lowercased().hasPrefix(prefix.lowercased()) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Unwrap matching outer quotes unless the original itself was quoted.
        let origTrimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("«", "»"), ("'", "'")]
        for (open, close) in quotePairs {
            if text.first == open && text.last == close && text.count >= 4,
               !(origTrimmed.first == open && origTrimmed.last == close) {
                text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // For single-line input, stop if a base model starts a second "Input:" block.
        if !origTrimmed.contains("\n"), let nextInput = text.range(of: "\nInput:") {
            text = String(text[..<nextInput.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !text.isEmpty else { return nil }
        if isRepetitiveGarbage(text) { return nil }

        // Sanity guard against models answering the user's question instead of editing it.
        let maxAllowedLen = max(origTrimmed.count * 2 + 48, 80)
        if text.count > maxAllowedLen { return nil }
        if text.count < max(2, origTrimmed.count / 3) { return nil }

        return text
    }

    // MARK: - Word Alternatives / Contextual Synonyms (Cotypist Labs Thesaurus)

    public static func buildSynonymsPrompt(
        word: String,
        contextSentence: String,
        format: ModelPromptFormat = .qwenInstruct
    ) -> String {
        let cleanWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContext = String(contextSentence.trimmingCharacters(in: .whitespacesAndNewlines).suffix(220))
        let isCyrillic = cleanWord.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }

        let system: String
        let user: String
        if isCyrillic {
            system = "Ты — точный контекстный словарь синонимов. Подбери до 5 естественных русских синонимов или близких замен для слова в нужной грамматической форме. Выведи ТОЛЬКО список через запятую, без пояснений и нумерации."
            user = cleanContext.isEmpty
                ? "Слово: \(cleanWord)\nСинонимы:"
                : "Контекст: «\(cleanContext)»\nЗамены для слова «\(cleanWord)» в той же форме:"
        } else {
            system = "You are a concise contextual thesaurus. Give up to 5 natural English synonyms or close word alternatives that fit the exact context and grammatical form. Output ONLY a comma-separated list with no explanations or numbering."
            user = cleanContext.isEmpty
                ? "Word: \(cleanWord)\nSynonyms:"
                : "Context: \"\(cleanContext)\"\nAlternatives for \"\(cleanWord)\":"
        }

        switch format {
        case .qwenInstruct:
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n/no_think\n\(user)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n"
        case .qwen2Instruct:
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        case .gemmaInstruct:
            return "<start_of_turn>user\n\(system)\n\n\(user)<end_of_turn>\n<start_of_turn>model\n"
        case .llama3Instruct:
            return "<|start_header_id|>system<|end_header_id|>\n\n\(system)<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n\(user)<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"
        case .base:
            return "\(system)\n\n\(user) "
        }
    }

    public static func parseSynonyms(_ raw: String, original: String) -> [String] {
        var text = raw
        if let endThink = text.range(of: "</think>") {
            text = String(text[endThink.upperBound...])
        }
        let controlMarkers = [
            "<|endoftext|>", "<|im_end|>", "<|im_start|>",
            "<end_of_turn>", "<start_of_turn>", "<|eot_id|>", "<|end|>",
            "<eos>", "</s>", "<think>", "\r"
        ]
        for marker in controlMarkers {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
            }
        }

        let origLower = original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let origStartsUpper = original.first?.isUppercase == true
        let origIsCyrillic = origLower.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let origIsLatin = !origIsCyrillic && origLower.unicodeScalars.contains {
            (0x0041...0x005A).contains($0.value) || (0x0061...0x007A).contains($0.value)
        }
        let pieces = text.components(separatedBy: CharacterSet(charactersIn: ",;\n•"))

        var result: [String] = []
        var seen = Set<String>([origLower])

        for piece in pieces {
            var item = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip leading numbering/bullets like "1.", "2)", "-", "*"
            item = item.replacingOccurrences(of: "^(?:\\d+[\\.)]|[-*–—])\\s*", with: "", options: .regularExpression)
            // Strip surrounding quotes and trailing punctuation
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: "\"'«».,:;!?() "))
            guard item.count >= 2, item.count <= 32 else { continue }
            // Keep single words or short two-word phrases only
            let wordCount = item.split(whereSeparator: { $0.isWhitespace }).count
            guard wordCount >= 1 && wordCount <= 2 else { continue }
            // Reject preamble lines like "Synonyms: ..."
            if item.contains(":") { continue }
            // Keep synonyms in the same script as the original word (reject CJK/cross-script leaks).
            if origIsCyrillic {
                let valid = item.unicodeScalars.allSatisfy { s in
                    (0x0400...0x04FF).contains(s.value) || s == " " || s == "-" || s == "\u{0301}"
                }
                if !valid { continue }
            } else if origIsLatin {
                let valid = item.unicodeScalars.allSatisfy { s in
                    (0x0041...0x005A).contains(s.value) || (0x0061...0x007A).contains(s.value) || s == " " || s == "-" || s == "'"
                }
                if !valid { continue }
            }

            let lower = item.lowercased()
            guard !seen.contains(lower) else { continue }
            seen.insert(lower)

            if origStartsUpper, let first = item.first, first.isLowercase {
                item = String(first).uppercased() + item.dropFirst()
            }
            result.append(item)
            if result.count >= 5 { break }
        }
        return result
    }
}
