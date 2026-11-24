import Foundation

public struct SwitcherConfiguration: Equatable, Sendable {
    public var autoSwitchEnabled: Bool
    public var midWordSwitchEnabled: Bool
    public var doubleCapsFixEnabled: Bool
    public var autocorrectEnabled: Bool
    public var yofikatorEnabled: Bool
    public var userWordExceptions: Set<String>

    public init(
        autoSwitchEnabled: Bool = true,
        midWordSwitchEnabled: Bool = true,
        doubleCapsFixEnabled: Bool = true,
        autocorrectEnabled: Bool = true,
        yofikatorEnabled: Bool = true,
        userWordExceptions: Set<String> = []
    ) {
        self.autoSwitchEnabled = autoSwitchEnabled
        self.midWordSwitchEnabled = midWordSwitchEnabled
        self.doubleCapsFixEnabled = doubleCapsFixEnabled
        self.autocorrectEnabled = autocorrectEnabled
        self.yofikatorEnabled = yofikatorEnabled
        self.userWordExceptions = userWordExceptions
    }
}

public enum SwitcherActionKind: String, Equatable, Sendable {
    case autoSwitch
    case doubleCaps
    case autocorrect
    case yofikator
    case manualSwitch
    case manualRevert
}

/// Exact minimal retyping instruction for the system event tap.
public struct SwitcherAction: Equatable, Sendable {
    public let kind: SwitcherActionKind
    /// Original full word before transformation.
    public let originalWord: String
    /// Full replacement word after transformation.
    public let replacementWord: String
    /// Number of characters to delete from the right (including trailing boundary if retyped).
    public let backspaces: Int
    /// Characters to type after deleting `backspaces`.
    public let textToType: String
    /// Target keyboard layout (nil if layout should remain unchanged).
    public let targetLanguage: SwitcherLanguage?
    /// Word to add to user/session exceptions if this action was a manual revert.
    public let learnedException: String?

    public init(
        kind: SwitcherActionKind,
        originalWord: String,
        replacementWord: String,
        backspaces: Int,
        textToType: String,
        targetLanguage: SwitcherLanguage?,
        learnedException: String? = nil
    ) {
        self.kind = kind
        self.originalWord = originalWord
        self.replacementWord = replacementWord
        self.backspaces = backspaces
        self.textToType = textToType
        self.targetLanguage = targetLanguage
        self.learnedException = learnedException
    }
}

public struct BufferedKeystroke: Equatable, Sendable {
    public let stroke: KeyStroke?
    public let character: Character

    public init(stroke: KeyStroke?, character: Character) {
        self.stroke = stroke
        self.character = character
    }
}

public struct PipelineDiagnostics: Sendable, Equatable {
    public let input: String
    public let currentLanguage: SwitcherLanguage
    public let convertedCandidate: String
    public let skippedByFilter: Bool
    public let doubleCapsFixed: String?
    public let kbm: KbmDiagnostics?
    public let autocorrect: AutocorrectResult?
    public let finalOutput: String
    public let finalLanguage: SwitcherLanguage
    public let appliedActions: [SwitcherActionKind]
}

/// Complete stateful Caramba 3-stage pipeline (Double-Caps -> KBM Auto-Switch -> Autocorrect/Yofikator),
/// plus minimal retyping diff, undo/revert memory, and manual word/selection conversion.
public final class SwitcherPipeline {
    public let model: LogosModel
    public let classifier: KbmClassifier
    public let autocorrect: AutocorrectEngine
    public let appex: AppexMatcher
    public var layoutMap: KeyboardLayoutMap

    private var buffer: [BufferedKeystroke] = []
    private var bufferLanguage: SwitcherLanguage = .english

    /// Last committed word + trailing boundary so Option / Double Shift works even after pressing Space.
    private struct LastWordRecord {
        var keystrokes: [BufferedKeystroke]
        var trailingBoundary: String
        var language: SwitcherLanguage
        var wasAutoSwitched: Bool
        var originalWordBeforeAutoSwitch: String?
        var originalLanguageBeforeAutoSwitch: SwitcherLanguage?
    }

    private var lastWord: LastWordRecord?
    /// Words the user manually reverted during this session — never auto-switched again.
    public private(set) var sessionExceptions: Set<String> = []

    public init(model: LogosModel, layoutMap: KeyboardLayoutMap = .macRussian) {
        self.model = model
        self.classifier = KbmClassifier(model: model.kbm)
        self.autocorrect = AutocorrectEngine(model: model.autocorrect)
        self.appex = AppexMatcher(appex: model.appex, feats: model.feats)
        self.layoutMap = layoutMap
    }

    public var currentWord: String {
        String(buffer.map(\.character))
    }

    public var activeBufferLanguage: SwitcherLanguage? {
        buffer.isEmpty ? nil : bufferLanguage
    }

    public var hasLastWord: Bool {
        guard let lastWord else { return false }
        return !lastWord.keystrokes.isEmpty
    }

    /// Seeds `lastWord` from an external Accessibility read (e.g. when the user
    /// presses Option after "ssd " even if the keystroke buffer was cleared by
    /// a layout shortcut, click, or autocomplete accept).
    public func seedLastWord(word: String, trailingBoundary: String, language: SwitcherLanguage) {
        let strokes = word.map { ch in
            BufferedKeystroke(stroke: layoutMap.keyStroke(for: ch, in: language), character: ch)
        }
        lastWord = LastWordRecord(
            keystrokes: strokes,
            trailingBoundary: trailingBoundary,
            language: language,
            wasAutoSwitched: false,
            originalWordBeforeAutoSwitch: nil,
            originalLanguageBeforeAutoSwitch: nil
        )
    }

    /// Extracts the last non-whitespace word (plus up to 2 trailing spaces) immediately
    /// before the caret from a focused field's prefix text, so Option works reliably
    /// on words like `"ssd "` even after Space or buffer resets.
    public static func extractTrailingWord(from prefix: String) -> (word: String, trailingSpaces: String)? {
        guard !prefix.isEmpty else { return nil }
        var end = prefix.endIndex
        var spaceCount = 0
        while end > prefix.startIndex && spaceCount < 2 {
            let prev = prefix.index(before: end)
            if prefix[prev] == " " || prefix[prev] == "\u{00A0}" {
                end = prev
                spaceCount += 1
            } else {
                break
            }
        }
        // If there were 3+ spaces or a newline/tab right before the caret, don't reach far back.
        if end > prefix.startIndex {
            let prev = prefix.index(before: end)
            if prefix[prev].isWhitespace {
                return nil
            }
        } else {
            return nil
        }

        var start = end
        while start > prefix.startIndex {
            let prev = prefix.index(before: start)
            if prefix[prev].isWhitespace {
                break
            }
            start = prev
        }

        let word = String(prefix[start..<end])
        guard !word.isEmpty, word.count <= 48 else { return nil }
        let trailingSpaces = String(repeating: " ", count: spaceCount)
        return (word, trailingSpaces)
    }

    /// Infers the actual script language of a single typed character when unambiguous
    /// (Latin letter -> `.english`, Cyrillic letter -> `.russian`), returning `nil` for
    /// punctuation/digits so callers keep the current word's layout.
    public static func inferCharacterLanguage(_ character: Character) -> SwitcherLanguage? {
        for scalar in character.unicodeScalars {
            if (0x0400...0x04FF).contains(scalar.value) {
                return .russian
            }
            if (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value) {
                return .english
            }
        }
        return nil
    }

    public func resetBuffer() {
        buffer.removeAll(keepingCapacity: true)
    }

    public func resetAll() {
        buffer.removeAll(keepingCapacity: true)
        lastWord = nil
    }

    public func handleBackspace() {
        if !buffer.isEmpty {
            buffer.removeLast()
        } else if var last = lastWord {
            if !last.trailingBoundary.isEmpty {
                last.trailingBoundary.removeLast()
                lastWord = last
            } else if !last.keystrokes.isEmpty {
                last.keystrokes.removeLast()
                buffer = last.keystrokes
                bufferLanguage = last.language
                lastWord = nil
            }
        }
    }

    /// Processes a non-boundary character typed by the user and optionally returns a mid-word auto-switch.
    /// When `swallowTriggerCharacter` is true, the caller suppresses the triggering keyDown event,
    /// so backspaces only remove the already-typed prefix before typing the converted word.
    public func processCharacter(
        _ character: Character,
        stroke: KeyStroke?,
        currentLanguage: SwitcherLanguage,
        config: SwitcherConfiguration,
        policy: AppSwitchPolicy = .normal,
        swallowTriggerCharacter: Bool = false
    ) -> SwitcherAction? {
        // Trust the actual script of the typed character when unambiguous so a stale
        // Carbon TIS layout cache in background apps can never invert conversion direction.
        let effectiveLanguage = Self.inferCharacterLanguage(character) ?? (buffer.isEmpty ? currentLanguage : bufferLanguage)

        if buffer.isEmpty {
            bufferLanguage = effectiveLanguage
        } else if bufferLanguage != effectiveLanguage {
            // User manually changed layout mid-word — restart buffer cleanly.
            buffer.removeAll(keepingCapacity: true)
            bufferLanguage = effectiveLanguage
        }

        // Cap buffer length to avoid runaway memory on huge unbroken pastes/inputs.
        if buffer.count >= 64 {
            buffer.removeAll(keepingCapacity: true)
            return nil
        }

        buffer.append(BufferedKeystroke(stroke: stroke, character: character))

        // Preserve mid-word auto-switch revert metadata if the user kept typing into the same word.
        let continuedAutoSwitch = (lastWord?.wasAutoSwitched == true)
            && (lastWord?.trailingBoundary.isEmpty == true)
            && (lastWord?.language == effectiveLanguage)
            && ((lastWord?.keystrokes.count ?? 0) + 1 == buffer.count)
        let origWordBeforeSwitch: String?
        let origLangBeforeSwitch: SwitcherLanguage?
        if continuedAutoSwitch,
           let prevOrig = lastWord?.originalWordBeforeAutoSwitch,
           let prevLang = lastWord?.originalLanguageBeforeAutoSwitch {
            let appendedOrig: String
            if let stroke, let mapped = layoutMap.character(for: stroke, in: prevLang) {
                appendedOrig = String(mapped)
            } else {
                appendedOrig = layoutMap.convert(String(character), from: effectiveLanguage, to: prevLang)
            }
            origWordBeforeSwitch = prevOrig + appendedOrig
            origLangBeforeSwitch = prevLang
        } else {
            origWordBeforeSwitch = nil
            origLangBeforeSwitch = nil
        }

        // Update lastWord snapshot so Option / Double Shift works even before pressing Space!
        lastWord = LastWordRecord(
            keystrokes: buffer,
            trailingBoundary: "",
            language: effectiveLanguage,
            wasAutoSwitched: continuedAutoSwitch,
            originalWordBeforeAutoSwitch: origWordBeforeSwitch,
            originalLanguageBeforeAutoSwitch: origLangBeforeSwitch
        )

        guard config.autoSwitchEnabled,
              config.midWordSwitchEnabled,
              policy == .normal,
              buffer.count >= 3 else {
            return nil
        }

        let word = String(buffer.map(\.character))
        guard !isExcluded(word, config: config) else { return nil }

        let targetLang = effectiveLanguage.opposite
        let converted = convertKeystrokes(buffer, from: effectiveLanguage, to: targetLang)
        guard converted != word else { return nil }

        if WordFilters.shouldSkipAutoSwitch(typedWord: word, convertedWord: converted) {
            return nil
        }

        let diag = classifier.classify(
            typedWord: word,
            convertedWord: converted,
            currentLanguage: effectiveLanguage,
            isCompleteWord: false
        )

        guard case .switchLayout(let target, let newWord) = diag.decision, target == targetLang else {
            return nil
        }

        // Safety gate for mid-word switching: only trigger mid-word when the model has strong
        // evidence (either target is a known word prefix or score margin >= 3), avoiding jitter
        // on short 3-letter ambiguous prefixes.
        let strongMidWordSignal: Bool = {
            let targetScore = (target == .russian) ? diag.ruScore : diag.enScore
            let currentScore = (effectiveLanguage == .russian) ? diag.ruScore : diag.enScore
            if targetScore == .knownWord { return true }
            if case .weighted(let tw) = targetScore, case .weighted(let cw) = currentScore {
                return (tw - cw) >= 3
            }
            return false
        }()

        guard strongMidWordSignal else { return nil }

        let newKeystrokes = rebuildKeystrokes(from: buffer, text: newWord, targetLanguage: target)
        let onScreenBeforeTrigger = swallowTriggerCharacter ? String(word.dropLast()) : word
        let diff = Self.computeRetypeDiff(from: onScreenBeforeTrigger, to: newWord)

        buffer = newKeystrokes
        bufferLanguage = target
        lastWord = LastWordRecord(
            keystrokes: newKeystrokes,
            trailingBoundary: "",
            language: target,
            wasAutoSwitched: true,
            originalWordBeforeAutoSwitch: word,
            originalLanguageBeforeAutoSwitch: effectiveLanguage
        )

        return SwitcherAction(
            kind: .autoSwitch,
            originalWord: word,
            replacementWord: newWord,
            backspaces: diff.backspaces,
            textToType: diff.textToType,
            targetLanguage: target,
            learnedException: nil
        )
    }

    /// Processes a word boundary character (Space, Return, Tab, etc.) and runs the exact
    /// 3-stage Caramba pipeline: Double-Caps -> KBM Auto-Switch -> Autocorrect / Yofikator.
    /// When `swallowBoundary` is true, the caller suppresses the boundary keyDown event so
    /// Enter/Tab/Space are sent ONLY after the word is converted (preventing premature send
    /// in chat apps or premature focus jump in forms).
    public func processBoundary(
        _ boundary: String,
        currentLanguage: SwitcherLanguage,
        config: SwitcherConfiguration,
        policy: AppSwitchPolicy = .normal,
        swallowBoundary: Bool = false,
        fallbackAutocorrect: ((String) -> String?)? = nil
    ) -> SwitcherAction? {
        guard !buffer.isEmpty else {
            // Multiple spaces / boundary keys: just clear lastWord if non-space or append space.
            if boundary == " ", var last = lastWord, last.trailingBoundary.count < 2 {
                last.trailingBoundary += boundary
                lastWord = last
            } else {
                lastWord = nil
            }
            return nil
        }

        let initialKeystrokes = buffer
        let originalWord = String(initialKeystrokes.map(\.character))
        let initialLanguage = layoutMap.detectDominantLanguage(originalWord, fallback: bufferLanguage)
        let wasPreviouslyAutoSwitched = (lastWord?.wasAutoSwitched == true)
            && (lastWord?.trailingBoundary.isEmpty == true)
            && (lastWord?.language == initialLanguage)
            && (lastWord?.keystrokes.count == initialKeystrokes.count)
        let prevOrigWord = wasPreviouslyAutoSwitched ? lastWord?.originalWordBeforeAutoSwitch : nil
        let prevOrigLang = wasPreviouslyAutoSwitched ? lastWord?.originalLanguageBeforeAutoSwitch : nil
        buffer.removeAll(keepingCapacity: true)

        // Retain lastWord only across Space so Option works right after "word ".
        // Return/Enter/Tab submit messages or change focus/lines, so clear lastWord there.
        let keepLastWordAcrossBoundary = (boundary == " ")
        if keepLastWordAcrossBoundary {
            lastWord = LastWordRecord(
                keystrokes: initialKeystrokes,
                trailingBoundary: boundary,
                language: initialLanguage,
                wasAutoSwitched: wasPreviouslyAutoSwitched,
                originalWordBeforeAutoSwitch: prevOrigWord,
                originalLanguageBeforeAutoSwitch: prevOrigLang
            )
        } else {
            lastWord = nil
        }

        guard policy != .disableAll else {
            return nil
        }

        var workingWord = originalWord
        var workingLanguage = initialLanguage
        var workingKeystrokes = initialKeystrokes
        var primaryKind: SwitcherActionKind?
        var switchedLayout: SwitcherLanguage?
        var didAutoSwitch = false

        // Stage 1: Double-Caps fix (ПРивет -> Привет, HEllo -> Hello)
        if config.doubleCapsFixEnabled,
           WordFilters.isDoubleCapsShape(workingWord),
           !isExcluded(workingWord, config: config),
           classifier.canFixDoubleCaps(workingWord) {
            let fixed = Self.fixDoubleCaps(workingWord)
            if fixed != workingWord {
                workingWord = fixed
                workingKeystrokes = rebuildKeystrokes(from: workingKeystrokes, text: fixed, targetLanguage: workingLanguage)
                primaryKind = .doubleCaps
            }
        }

        // Stage 2: Auto-Switch (KBM Classifier)
        if config.autoSwitchEnabled,
           policy == .normal,
           !isExcluded(workingWord, config: config) {
            let targetLang = workingLanguage.opposite
            let converted = convertKeystrokes(workingKeystrokes, from: workingLanguage, to: targetLang)
            if converted != workingWord,
               !WordFilters.shouldSkipAutoSwitch(typedWord: workingWord, convertedWord: converted) {
                let diag = classifier.classify(
                    typedWord: workingWord,
                    convertedWord: converted,
                    currentLanguage: workingLanguage,
                    isCompleteWord: true
                )
                if case .switchLayout(let target, let newWord) = diag.decision, target == targetLang {
                    workingWord = newWord
                    workingLanguage = target
                    workingKeystrokes = rebuildKeystrokes(from: workingKeystrokes, text: newWord, targetLanguage: target)
                    switchedLayout = target
                    primaryKind = .autoSwitch
                    didAutoSwitch = true
                }
            }
        }

        // Stage 3: Autocorrect & Yofikator (on the final-layout word)
        var didSpellAutocorrect = false
        if (config.autocorrectEnabled || config.yofikatorEnabled),
           !isExcluded(workingWord, config: config) {
            if let ac = autocorrect.evaluate(
                word: workingWord,
                autocorrectEnabled: config.autocorrectEnabled,
                yofikatorEnabled: config.yofikatorEnabled
            ) {
                workingWord = ac.replacement
                workingKeystrokes = rebuildKeystrokes(from: workingKeystrokes, text: ac.replacement, targetLanguage: workingLanguage)
                if primaryKind == nil {
                    primaryKind = ac.isYofikator ? .yofikator : .autocorrect
                }
            } else if config.autocorrectEnabled, let fallbackAutocorrect {
                // Fallback multilingual spellchecker autocorrect (handles Russian/English
                // transpositions and mistypes like "моудль" -> "модуль", "криов" -> "криво",
                // "дефотом" -> "дефолтом", "прилоенжие" -> "приложение" on Space by default).
                let (lead, core, trail) = Self.splitSurroundingPunctuation(workingWord)
                if !core.isEmpty, !isExcluded(core, config: config),
                   let fixedCore = fallbackAutocorrect(core),
                   fixedCore != core {
                    let fixedFull = lead + fixedCore + trail
                    workingWord = fixedFull
                    workingKeystrokes = rebuildKeystrokes(from: workingKeystrokes, text: fixedFull, targetLanguage: workingLanguage)
                    didSpellAutocorrect = true
                    if primaryKind == nil {
                        primaryKind = .autocorrect
                    }
                }
            }
        }

        guard let kind = primaryKind, workingWord != originalWord else {
            return nil
        }

        let diff: (backspaces: Int, textToType: String)
        if swallowBoundary {
            let wordDiff = Self.computeRetypeDiff(from: originalWord, to: workingWord)
            diff = (wordDiff.backspaces, wordDiff.textToType + boundary)
        } else {
            diff = Self.computeRetypeDiff(from: originalWord + boundary, to: workingWord + boundary)
        }

        if keepLastWordAcrossBoundary {
            let revertable = didAutoSwitch || wasPreviouslyAutoSwitched || didSpellAutocorrect
            lastWord = LastWordRecord(
                keystrokes: workingKeystrokes,
                trailingBoundary: boundary,
                language: workingLanguage,
                wasAutoSwitched: revertable,
                originalWordBeforeAutoSwitch: (didAutoSwitch || didSpellAutocorrect) ? originalWord : prevOrigWord,
                originalLanguageBeforeAutoSwitch: (didAutoSwitch || didSpellAutocorrect) ? initialLanguage : prevOrigLang
            )
        } else {
            lastWord = nil
        }

        return SwitcherAction(
            kind: kind,
            originalWord: originalWord,
            replacementWord: workingWord,
            backspaces: diff.backspaces,
            textToType: diff.textToType,
            targetLanguage: switchedLayout,
            learnedException: nil
        )
    }

    /// Manual switch triggered by Option tap or Double Shift (when no text is selected).
    /// If the previous word was just auto-switched, reverts it cleanly and learns it as an exception!
    public func manualSwitchLastWord(currentLanguage: SwitcherLanguage) -> SwitcherAction? {
        guard let record = lastWord, !record.keystrokes.isEmpty else {
            return nil
        }

        let currentText = String(record.keystrokes.map(\.character))
        let boundary = record.trailingBoundary

        // If the word was just auto-switched, revert it back and learn it as an exception.
        if record.wasAutoSwitched,
           let origWord = record.originalWordBeforeAutoSwitch,
           let origLang = record.originalLanguageBeforeAutoSwitch {
            sessionExceptions.insert(origWord.lowercased())

            let fromFull = currentText + boundary
            let toFull = origWord + boundary
            let diff = Self.computeRetypeDiff(from: fromFull, to: toFull)
            let restoredStrokes = rebuildKeystrokes(from: record.keystrokes, text: origWord, targetLanguage: origLang)

            if boundary.isEmpty {
                buffer = restoredStrokes
                bufferLanguage = origLang
            }
            lastWord = LastWordRecord(
                keystrokes: restoredStrokes,
                trailingBoundary: boundary,
                language: origLang,
                wasAutoSwitched: false,
                originalWordBeforeAutoSwitch: nil,
                originalLanguageBeforeAutoSwitch: nil
            )

            return SwitcherAction(
                kind: .manualRevert,
                originalWord: currentText,
                replacementWord: origWord,
                backspaces: diff.backspaces,
                textToType: diff.textToType,
                targetLanguage: origLang,
                learnedException: origWord.lowercased()
            )
        }

        // Otherwise manually flip the word to the opposite layout, always trusting the
        // word's actual script so a stale TIS cache can never make converted == currentText.
        let sourceLang = layoutMap.detectDominantLanguage(currentText, fallback: record.language)
        let targetLang = sourceLang.opposite
        var converted = convertKeystrokes(record.keystrokes, from: sourceLang, to: targetLang)
        if converted == currentText {
            converted = layoutMap.convert(currentText, from: sourceLang, to: targetLang)
        }
        guard converted != currentText else { return nil }

        let fromFull = currentText + boundary
        let toFull = converted + boundary
        let diff = Self.computeRetypeDiff(from: fromFull, to: toFull)
        let newStrokes = rebuildKeystrokes(from: record.keystrokes, text: converted, targetLanguage: targetLang)

        if boundary.isEmpty {
            buffer = newStrokes
            bufferLanguage = targetLang
        }
        lastWord = LastWordRecord(
            keystrokes: newStrokes,
            trailingBoundary: boundary,
            language: targetLang,
            wasAutoSwitched: false,
            originalWordBeforeAutoSwitch: nil,
            originalLanguageBeforeAutoSwitch: nil
        )

        return SwitcherAction(
            kind: .manualSwitch,
            originalWord: currentText,
            replacementWord: converted,
            backspaces: diff.backspaces,
            textToType: diff.textToType,
            targetLanguage: targetLang,
            learnedException: nil
        )
    }

    /// Converts arbitrary selected text between EN and RU based on dominant script.
    public func convertSelection(
        _ text: String,
        fallbackLanguage: SwitcherLanguage = .english
    ) -> (converted: String, targetLanguage: SwitcherLanguage)? {
        guard !text.isEmpty else { return nil }
        let source = layoutMap.detectDominantLanguage(text, fallback: fallbackLanguage)
        let target = source.opposite
        let converted = layoutMap.convert(text, from: source, to: target)
        guard converted != text else { return nil }
        return (converted, target)
    }

    /// Stateless diagnostic evaluator (ideal for Settings Live Tester & unit tests).
    public func diagnose(
        word: String,
        currentLanguage: SwitcherLanguage,
        config: SwitcherConfiguration = SwitcherConfiguration(),
        isCompleteWord: Bool = true
    ) -> PipelineDiagnostics {
        var workingWord = word
        var workingLang = currentLanguage
        var applied: [SwitcherActionKind] = []
        var doubleCapsFixed: String?

        if isCompleteWord,
           config.doubleCapsFixEnabled,
           WordFilters.isDoubleCapsShape(workingWord),
           !isExcluded(workingWord, config: config),
           classifier.canFixDoubleCaps(workingWord) {
            let fixed = Self.fixDoubleCaps(workingWord)
            if fixed != workingWord {
                workingWord = fixed
                doubleCapsFixed = fixed
                applied.append(.doubleCaps)
            }
        }

        let converted = layoutMap.convert(workingWord, from: workingLang, to: workingLang.opposite)
        let skipped = isExcluded(workingWord, config: config)
            || WordFilters.shouldSkipAutoSwitch(typedWord: workingWord, convertedWord: converted)

        var kbmDiag: KbmDiagnostics?
        if config.autoSwitchEnabled && !skipped && converted != workingWord {
            let diag = classifier.classify(
                typedWord: workingWord,
                convertedWord: converted,
                currentLanguage: workingLang,
                isCompleteWord: isCompleteWord
            )
            kbmDiag = diag
            if case .switchLayout(let target, let newWord) = diag.decision {
                workingWord = newWord
                workingLang = target
                applied.append(.autoSwitch)
            }
        }

        var acResult: AutocorrectResult?
        if isCompleteWord,
           (config.autocorrectEnabled || config.yofikatorEnabled),
           !isExcluded(workingWord, config: config) {
            if let ac = autocorrect.evaluate(
                word: workingWord,
                autocorrectEnabled: config.autocorrectEnabled,
                yofikatorEnabled: config.yofikatorEnabled
            ) {
                acResult = ac
                workingWord = ac.replacement
                applied.append(ac.isYofikator ? .yofikator : .autocorrect)
            }
        }

        return PipelineDiagnostics(
            input: word,
            currentLanguage: currentLanguage,
            convertedCandidate: converted,
            skippedByFilter: skipped,
            doubleCapsFixed: doubleCapsFixed,
            kbm: kbmDiag,
            autocorrect: acResult,
            finalOutput: workingWord,
            finalLanguage: workingLang,
            appliedActions: applied
        )
    }

    // MARK: - Helpers

    private func isExcluded(_ word: String, config: SwitcherConfiguration) -> Bool {
        let lower = word.lowercased()
        return sessionExceptions.contains(lower) || config.userWordExceptions.contains(lower)
    }

    /// Converts recorded keystrokes using physical keyCodes when available, falling back to char map.
    private func convertKeystrokes(
        _ strokes: [BufferedKeystroke],
        from source: SwitcherLanguage,
        to target: SwitcherLanguage
    ) -> String {
        var out = ""
        out.reserveCapacity(strokes.count)
        for item in strokes {
            if let stroke = item.stroke, let mapped = layoutMap.character(for: stroke, in: target) {
                out.append(mapped)
            } else {
                out.append(layoutMap.convert(String(item.character), from: source, to: target))
            }
        }
        return out
    }

    private func rebuildKeystrokes(
        from existing: [BufferedKeystroke],
        text: String,
        targetLanguage: SwitcherLanguage
    ) -> [BufferedKeystroke] {
        let chars = Array(text)
        if chars.count == existing.count {
            return zip(existing, chars).map { old, ch in
                let stroke = old.stroke ?? layoutMap.keyStroke(for: ch, in: targetLanguage)
                return BufferedKeystroke(stroke: stroke, character: ch)
            }
        }
        return chars.map { ch in
            BufferedKeystroke(stroke: layoutMap.keyStroke(for: ch, in: targetLanguage), character: ch)
        }
    }

    public static func fixDoubleCaps(_ word: String) -> String {
        let chars = Array(word)
        guard chars.count >= 3 else { return word }
        return String(chars[0]) + String(chars[1]).lowercased() + String(chars[2...])
    }

    private static let leadingPunct: Set<Character> = Set(["(", "[", "{", "\"", "'", "«", "—", "–"])
    private static let trailingPunct: Set<Character> = Set([".", ",", "!", "?", ";", ":", ")", "]", "}", "\"", "'", "»"])

    private static func splitSurroundingPunctuation(_ word: String) -> (lead: String, core: String, trail: String) {
        var chars = Array(word)
        var lead = ""
        var trail = ""
        while let first = chars.first, leadingPunct.contains(first) {
            lead.append(chars.removeFirst())
        }
        while let last = chars.last, trailingPunct.contains(last) {
            trail.insert(chars.removeLast(), at: trail.startIndex)
        }
        return (lead, String(chars), trail)
    }

    /// Caramba retype optimization: finds longest common prefix so we only backspace & retype the differing tail.
    public static func computeRetypeDiff(from old: String, to new: String) -> (backspaces: Int, textToType: String) {
        let oldChars = Array(old)
        let newChars = Array(new)
        var common = 0
        let limit = min(oldChars.count, newChars.count)
        while common < limit && oldChars[common] == newChars[common] {
            common += 1
        }
        let backspaces = oldChars.count - common
        let tail = String(newChars[common...])
        return (backspaces, tail)
    }
}

