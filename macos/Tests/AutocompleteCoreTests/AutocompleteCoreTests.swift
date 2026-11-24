import Foundation
import Testing
@testable import AutocompleteCore

@Suite struct PromptBuilderTests {
    @Test func buildsNaturalBasePromptWithStylePerAppAndSamples() {
        let ctx = CompletionContext(
            prefix: "Hi team, I wanted to follow up on",
            appName: "Mail",
            windowTitle: "Re: Quarterly planning",
            clipboard: "Meeting moved to Thursday 3pm",
            userPrompt: "Keep sentences concise.",
            appPrompt: "Use polite professional email tone.",
            styleSamples: ["Sounds good — I'll send the updated draft before 5pm."]
        )
        let prompt = PromptBuilder.buildPrompt(for: ctx, format: .base)
        #expect(prompt.contains("Keep sentences concise."))
        #expect(prompt.contains("Use polite professional email tone."))
        #expect(prompt.contains("Application: Mail — Re: Quarterly planning"))
        #expect(prompt.contains("Clipboard: Meeting moved to Thursday 3pm"))
        #expect(prompt.contains("Sounds good — I'll send the updated draft before 5pm."))
        #expect(!prompt.contains("[App:"))
        #expect(prompt.hasSuffix("Hi team, I wanted to follow up on"))
    }

    @Test func buildsCotypistInstructPromptsForChatModels() {
        let ctx = CompletionContext(
            prefix: "Let's finalize the release",
            appName: "Slack",
            userPrompt: "Write briefly."
        )
        let qwen = PromptBuilder.buildPrompt(for: ctx, format: .qwenInstruct)
        #expect(qwen.contains("<|im_start|>user\n/no_think\n"))
        #expect(qwen.contains(PromptBuilder.cotypistInstructionSuffix))
        #expect(qwen.contains("<|im_start|>assistant\n<think>\n\n</think>\nLet's finalize the release"))

        let gemma = PromptBuilder.buildPrompt(for: ctx, format: .gemmaInstruct)
        #expect(gemma.contains("<start_of_turn>user\n"))
        #expect(gemma.hasSuffix("<start_of_turn>model\nLet's finalize the release"))
    }

    @Test func detectsModelPromptFormatFromFilename() {
        #expect(ModelPromptFormat.detect(from: URL(fileURLWithPath: "/tmp/Qwen3.5-0.8B-Base.i1-Q4_K_M.gguf")) == .base)
        #expect(ModelPromptFormat.detect(from: URL(fileURLWithPath: "/tmp/Qwen3.5-0.8B-Q5_K_M.gguf")) == .qwenInstruct)
        #expect(ModelPromptFormat.detect(from: URL(fileURLWithPath: "/tmp/Qwen3-1.7B-Base.i1-Q4_K_M.gguf")) == .base)
        #expect(ModelPromptFormat.detect(from: URL(fileURLWithPath: "/tmp/Qwen3-1.7B-Instruct-Q4_K_M.gguf")) == .qwenInstruct)
        #expect(ModelPromptFormat.detect(from: URL(fileURLWithPath: "/tmp/Qwen2.5-1.5B-Instruct-IQ3_M.gguf")) == .qwen2Instruct)
        #expect(ModelPromptFormat.detect(from: URL(fileURLWithPath: "/tmp/gemma-4-e2b-it-Q4_K_M.gguf")) == .gemmaInstruct)
    }

    @Test func cleansPolishedTextOutput() {
        #expect(
            PromptBuilder.cleanPolishedText(
                "Исправленный текст: \"Проверь, пожалуйста, настройки.\"<|im_end|>",
                original: "проверь пожалуста насройки"
            ) == "Проверь, пожалуйста, настройки."
        )
        #expect(
            PromptBuilder.cleanPolishedText(
                "<think>thinking</think>\nПривет, как дела?",
                original: "привет как дела"
            ) == "Привет, как дела?"
        )
    }

    @Test func cleansControlTokensNewlinesAndDuplicateSpaces() {
        #expect(
            PromptBuilder.cleanSuggestion("  the schedule.<|endoftext|>ignored", prefix: "check ")
                == "the schedule."
        )
        #expect(
            PromptBuilder.cleanSuggestion(" tomorrow morning\nSecond line", prefix: "See you")
                == " tomorrow morning"
        )
        #expect(
            PromptBuilder.cleanSuggestion("   ", prefix: "Hello") == nil
        )
        #expect(
            PromptBuilder.cleanSuggestion("yes yes yes yes", prefix: "ok ") == nil
        )
        #expect(
            PromptBuilder.cleanSuggestion("20000000000000000000", prefix: "наши ") == nil
        )
        #expect(
            PromptBuilder.cleanSuggestion("0101010101", prefix: "код ") == nil
        )
        #expect(
            PromptBuilder.cleanSuggestion("2026 года", prefix: "до конца ") == "2026 года"
        )
        #expect(
            PromptBuilder.cleanSuggestion(".", prefix: "Привет") == nil
        )
        #expect(
            PromptBuilder.cleanSuggestion("  ,  ", prefix: "Hello") == nil
        )
        #expect(
            PromptBuilder.cleanSuggestion(" sounds good --- Application: Mail", prefix: "That") == " sounds good"
        )
    }

    @Test func trimsOverlapWithMidLineSuffix() {
        #expect(
            PromptBuilder.cleanSuggestion("very much for your help", prefix: "Thank you ", suffix: "for your help today.", allowMidLine: true)
                == "very much"
        )
    }
}

@Suite struct TypingHistoryStoreTests {
    @Test func redactsSecretsAndRetrievesMatchingStyleSamples() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("typing-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = TypingHistoryStore(storageURL: tmp, maxSamples: 20)

        // Sensitive strings must be rejected.
        #expect(!store.record(text: "Here is my OpenAI key sk-proj-1234567890abcdefghijklmnop for testing", bundleID: "com.apple.Notes", appName: "Notes", acceptedCompletion: false))
        #expect(!store.record(text: "Please use password=SuperSecret123 to log in right now", bundleID: "com.apple.Mail", appName: "Mail", acceptedCompletion: false))
        #expect(!store.record(text: "My AWS key is AKIAIOSFODNN7EXAMPLE in prod", bundleID: "com.apple.Mail", appName: "Mail", acceptedCompletion: false))
        #expect(store.count == 0)

        // Normal English & Russian writing samples are stored and retrieved by language + app.
        #expect(store.record(text: "Привет! Посмотрю правки вечером и сразу отпишусь по итогам.", bundleID: "ru.keepcoder.Telegram", appName: "Telegram", acceptedCompletion: true))
        #expect(store.record(text: "Thanks for the update — I'll review the deck and share feedback tomorrow.", bundleID: "com.apple.mail", appName: "Mail", acceptedCompletion: true))
        #expect(store.count == 2)

        let ruSamples = store.relevantSamples(forPrefix: "Привет, скоро ", bundleID: "ru.keepcoder.Telegram", strength: .balanced)
        #expect(ruSamples.count == 1)
        #expect(ruSamples[0].contains("Посмотрю правки"))

        let enSamples = store.relevantSamples(forPrefix: "Hey team, ", bundleID: "com.apple.mail", strength: .gentle)
        #expect(enSamples.count == 1)
        #expect(enSamples[0].contains("review the deck"))

        #expect(store.relevantSamples(forPrefix: "Hey team, ", bundleID: "com.apple.mail", strength: .off).isEmpty)

        store.clear(bundleID: "com.apple.mail")
        #expect(store.count == 1)
        store.clearAll()
        #expect(store.count == 0)
    }
}

@Suite struct SuggestionStateTests {
    @Test func advancesSmoothlyOnTypeThrough() {
        let initial = ActiveSuggestion(text: " tomorrow morning", kind: .completion, anchorPrefix: "See you")
        let afterSpace = SuggestionState.advanceByTyping(typed: " ", suggestion: initial)
        #expect(afterSpace?.text == "tomorrow morning")
        #expect(afterSpace?.anchorPrefix == "See you ")

        let afterTom = SuggestionState.advanceByTyping(typed: "tom", suggestion: afterSpace!)
        #expect(afterTom?.text == "orrow morning")

        // Non-matching typing clears the suggestion.
        #expect(SuggestionState.advanceByTyping(typed: "x", suggestion: afterTom!) == nil)
    }

    @Test func splitsNextWordForEnglishAndRussian() {
        let (w1, r1) = SuggestionState.splitNextWord(" tomorrow morning, please.")
        #expect(w1 == " tomorrow")
        #expect(r1 == " morning, please.")

        let (w2, r2) = SuggestionState.splitNextWord(r1)
        #expect(w2 == " morning,")
        #expect(r2 == " please.")

        let (ru1, ruRest) = SuggestionState.splitNextWord(" завтра утром на созвоне")
        #expect(ru1 == " завтра")
        #expect(ruRest == " утром на созвоне")
    }

    @Test func appliesTrailingPunctuationMode() {
        let fullHold = SuggestionState.applyTrailingPunctuation(
            accepted: " tomorrow morning.",
            remaining: "",
            isFullAcceptance: true,
            mode: .neither
        )
        #expect(fullHold.accepted == " tomorrow morning")
        #expect(fullHold.remaining == ".")

        let fullInclude = SuggestionState.applyTrailingPunctuation(
            accepted: " tomorrow morning.",
            remaining: "",
            isFullAcceptance: true,
            mode: .fullCompletionsOnly
        )
        #expect(fullInclude.accepted == " tomorrow morning.")
        #expect(fullInclude.remaining == "")

        let wordHold = SuggestionState.applyTrailingPunctuation(
            accepted: " morning,",
            remaining: " please.",
            isFullAcceptance: false,
            mode: .fullCompletionsOnly
        )
        #expect(wordHold.accepted == " morning")
        #expect(wordHold.remaining == ", please.")
    }

    @Test func suppressesInUrlsEmailsSelectionAndMidLineWhenDisabled() {
        #expect(!SuggestionState.shouldTriggerCompletion(prefix: "Hello world", suffix: "", selectionLength: 3, allowMidLine: true))
        #expect(!SuggestionState.shouldTriggerCompletion(prefix: "a", suffix: "", selectionLength: 0, allowMidLine: true))
        #expect(!SuggestionState.shouldTriggerCompletion(prefix: "Visit https://example", suffix: "", selectionLength: 0, allowMidLine: true))
        #expect(!SuggestionState.shouldTriggerCompletion(prefix: "Mail user@dom", suffix: "", selectionLength: 0, allowMidLine: true))
        #expect(!SuggestionState.shouldTriggerCompletion(prefix: "Hello ", suffix: "world", selectionLength: 0, allowMidLine: false))
        #expect(SuggestionState.shouldTriggerCompletion(prefix: "Hello ", suffix: "world", selectionLength: 0, allowMidLine: true))
    }
}

@Suite struct EmojiCatalogTests {
    @Test func matchesShortcodesPrefixesAndRussianAliases() {
        let rocket = EmojiCatalog.match(prefix: "Ready to ship :rock")
        #expect(rocket?.text == "🚀")
        #expect(rocket?.deleteBeforeCount == 5)

        let closed = EmojiCatalog.match(prefix: "Great work :thumbsup:")
        #expect(closed?.text == "👍")
        #expect(closed?.deleteBeforeCount == 10)

        let russian = EmojiCatalog.match(prefix: "Отлично :огонь")
        #expect(russian?.text == "🔥")
        #expect(russian?.deleteBeforeCount == 6)

        // Should not trigger on timestamps, URLs, or single char after colon.
        #expect(EmojiCatalog.match(prefix: "Meet at 12:30") == nil)
        #expect(EmojiCatalog.match(prefix: "https://ex") == nil)
        #expect(EmojiCatalog.match(prefix: "note :a") == nil)

        // Preferred skin tone applies only to skin-tone-capable emojis.
        let toned = EmojiCatalog.match(prefix: "Nice :thumbsup", skinTone: .medium)
        #expect(toned?.text == "👍\u{1F3FD}")
        let nonHuman = EmojiCatalog.match(prefix: "Ship :rocket", skinTone: .medium)
        #expect(nonHuman?.text == "🚀")
    }
}

@Suite struct AutocorrectTests {
    @Test func computesEditDistance() {
        // Adjacent transpositions count as 1 edit under Damerau-Levenshtein.
        #expect(AutocorrectHelper.editDistance("recieve", "receive") == 1)
        #expect(AutocorrectHelper.editDistance("teh", "the") == 1)
        #expect(AutocorrectHelper.editDistance("моудль", "модуль") == 1)
        #expect(AutocorrectHelper.editDistance("hello", "world") == 4)
    }

    @Test @MainActor func detectsCommonEnglishAndRussianTyposAndWrongLayout() {
        let suggestion = AutocorrectHelper.check(prefix: "Please recieve ")
        #expect(suggestion != nil)
        #expect(suggestion?.text.lowercased().trimmingCharacters(in: .whitespaces) == "receive")
        #expect(suggestion?.deleteBeforeCount == 8)

        // Russian typos (explicit language: "ru" + Damerau-Levenshtein).
        let ru1 = AutocorrectHelper.check(prefix: "проверь прилоенжие ")
        #expect(ru1?.text.trimmingCharacters(in: .whitespaces) == "приложение")

        let ru2 = AutocorrectHelper.check(prefix: "косяков в интерфесе ")
        #expect(ru2 != nil)

        let ru3 = AutocorrectHelper.check(prefix: "надо акуратно как моудль ")
        #expect(ru3?.text.trimmingCharacters(in: .whitespaces) == "модуль")

        // Wrong-layout rescue in Russian context (lbrndrf -> диктовка).
        let layout = AutocorrectHelper.check(prefix: "как виспер или lbrndrf ")
        #expect(layout?.text.trimmingCharacters(in: .whitespaces) == "диктовка")

        let preCleaned = AutocorrectHelper.preCleanForPolish("как виспер или lbrndrf")
        #expect(preCleaned.contains("диктовка"))

        // Code-like tokens and ALL CAPS are ignored.
        #expect(AutocorrectHelper.check(prefix: "foo_recieve ") == nil)
        #expect(AutocorrectHelper.check(prefix: "HTTPXYZ ") == nil)
    }

    @Test @MainActor func autoCorrectsFastTypingRussianTyposByDefaultWithoutManglingTechWords() {
        let expectedFixes: [(String, String)] = [
            ("моудль", "модуль"),
            ("криов", "криво"),
            ("дефотом", "дефолтом"),
            ("прилоенжие", "приложение"),
            ("рабоатло", "работало"),
            ("поялвется", "появляется"),
            ("редакриртовать", "редактировать"),
            ("пеерповерь", "перепроверь"),
            ("акуратно", "аккуратно"),
            ("коректно", "корректно"),
            ("перелкючил", "переключил"),
            ("следущие", "следующие"),
            ("вклчюиттть", "включить"),
            ("достверность", "достоверность"),
            ("проудмай", "продумай"),
            ("извелкать", "извлекать"),
            ("продложай", "продолжай"),
            ("немногго", "немного"),
        ]
        for (typo, expected) in expectedFixes {
            let fixed = AutocorrectHelper.autoCorrectTypedWord(typo)
            #expect(fixed == expected, "Expected '\(typo)' -> '\(expected)', got '\(fixed ?? "nil")'")
        }

        // Protected tech / AI / developer slang must never be auto-mangled.
        for safe in ["виспер", "свитчер", "хоткей", "виртуалке", "карамбе", "опшн", "субагентом", "кофолдинг", "промпт", "пофикси", "ребейзи"] {
            #expect(AutocorrectHelper.autoCorrectTypedWord(safe) == nil, "Should not mangle tech word '\(safe)'")
        }
    }
}

@Suite struct ModelCatalogTests {
    @Test func validatesGGUFHeaderAndRejectsGarbage() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let badFile = tmp.appendingPathComponent("fake.gguf")
        try Data("NOTGGUF".utf8).write(to: badFile)
        #expect(!ModelCatalog.isValidGGUFFile(at: badFile))

        let smallGood = tmp.appendingPathComponent("tiny.gguf")
        var data = Data([0x47, 0x47, 0x55, 0x46])
        data.append(Data(count: 1024))
        try data.write(to: smallGood)
        #expect(!ModelCatalog.isValidGGUFFile(at: smallGood))
        #expect(ModelCatalog.isValidLoRAFile(at: smallGood))

        let validLike = tmp.appendingPathComponent("valid.gguf")
        var big = Data([0x47, 0x47, 0x55, 0x46])
        big.append(Data(count: 1_100_000))
        try big.write(to: validLike)
        #expect(ModelCatalog.isValidGGUFFile(at: validLike))

        let found = ModelCatalog.discoverModels(
            appDir: tmp,
            legacyAppDir: tmp.appendingPathComponent("legacy-missing"),
            cotypistDir: tmp.appendingPathComponent("missing")
        )
        #expect(found.map(\.filename) == ["valid.gguf"])
        #expect(ModelCatalog.curatedDownloads.contains(where: { $0.id == "qwen3-1.7b-q3ks" }))
        #expect(ModelCatalog.curatedDownloads.contains(where: { $0.id == "qwen35-0.8b-q5km" }))
    }
}

@Suite struct LlamaEngineIntegrationTests {
    @Test func generatesEnglishAndRussianCompletionsWithStyleAndKVCacheReuse() async throws {
        let models = ModelCatalog.discoverModels()
        guard let model = ModelCatalog.preferredDefaultModel(from: models, savedPath: nil) else {
            // Skip gracefully on machines without a downloaded GGUF model.
            return
        }

        let engine = LlamaEngine()
        let config = GenerationConfig(maxTokens: 16, temperature: 0.15)
        let stylePrompt = ModelCatalog.importedCotypistUserPrompt() ?? ModelCatalog.defaultUserPrompt

        let en1 = try await engine.complete(
            context: CompletionContext(
                prefix: "Hi team, thanks for sending over the report. I will review it and get back to you",
                appName: "Mail",
                userPrompt: stylePrompt,
                styleSamples: ["Thanks for sharing — I'll check the details and follow up shortly."]
            ),
            modelURL: model.url,
            config: config
        )
        #expect(en1 != nil && !(en1 ?? "").isEmpty)
        print("[TEST EN1]", en1 ?? "<nil>")

        // Incremental follow-up exercises KV-cache prefix reuse.
        let en2 = try await engine.complete(
            context: CompletionContext(
                prefix: "Hi team, thanks for sending over the report. I will review it and get back to you by",
                appName: "Mail",
                userPrompt: stylePrompt,
                styleSamples: ["Thanks for sharing — I'll check the details and follow up shortly."]
            ),
            modelURL: model.url,
            config: config
        )
        #expect(en2 != nil && !(en2 ?? "").isEmpty)
        print("[TEST EN2]", en2 ?? "<nil>")

        let ru = try await engine.complete(
            context: CompletionContext(
                prefix: "Привет! Спасибо за сообщение, я посмотрю документы и отвечу тебе",
                appName: "Telegram",
                userPrompt: stylePrompt,
                styleSamples: ["Привет! Гляну вечером и сразу напишу."]
            ),
            modelURL: model.url,
            config: config
        )
        #expect(ru != nil && !(ru ?? "").isEmpty)
        print("[TEST RU]", ru ?? "<nil>")

        let preCleaned = await AutocorrectHelper.preCleanForPolish("проверь на виртуалке как выглядит прилоенжие как виспер или lbrndrf")
        #expect(preCleaned.contains("приложение"))
        #expect(preCleaned.contains("виспер"))
        #expect(preCleaned.contains("диктовка"))

        let polished = try await engine.polishText(
            preCleaned,
            style: .agents,
            appName: "Codex",
            modelURL: model.url
        )
        let ramLoaded = LlamaEngine.currentProcessMemoryMB()
        print("[TEST POLISH]", model.filename, "RAM=\(ramLoaded)MB ->", polished ?? "<nil>")
        #expect(polished != nil && !(polished ?? "").isEmpty)

        let synonyms = try await engine.suggestSynonyms(
            word: "быстро",
            contextSentence: "Нужно быстро проверить этот модуль перед релизом.",
            modelURL: model.url
        )
        print("[TEST SYNONYMS]", synonyms)
        #expect(!synonyms.isEmpty)

        let screenshotRaw = "и надо что бы автокомлпикт имел больше контекста с экрана  и прочего и так же надо что бы слова правились запятые добавлялись с больших букв было и прочее"
        let screenshotQuick = await AutocorrectHelper.deterministicQuickPolish(screenshotRaw)
        let screenshotPolished = try await engine.polishText(
            screenshotQuick,
            style: .agents,
            appName: "Codex",
            modelURL: model.url
        )
        print("[TEST SCREENSHOT POLISH]", screenshotPolished ?? "<nil>")
        #expect(screenshotPolished != nil)
        #expect(screenshotPolished?.first?.isUppercase == true)
        #expect(screenshotPolished?.contains("автокомплит") == true)
        #expect(screenshotPolished?.contains("правились") == true)
        #expect(screenshotPolished?.contains(",") == true)

        await engine.unload()
        let ramUnloaded = LlamaEngine.currentProcessMemoryMB()
        print("[TEST RAM UNLOADED]", "\(ramUnloaded) MB")
    }
}

@Suite struct CotypistParityTests {
    @Test func tracksPersonalVocabularyStatsExportAndTopicOverlap() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let storeURL = tmp.appendingPathComponent("history.json")
        let store = TypingHistoryStore(storageURL: storeURL)

        #expect(store.record(
            text: "Проверь пожалуйста новый пайплайн деплоя на стейджинге.",
            bundleID: "com.openai.codex",
            appName: "Codex",
            acceptedCompletion: false
        ))
        #expect(store.record(
            text: "Пайплайн деплоя на стейджинге прошёл без ошибок, запускаем релиз.",
            bundleID: "com.openai.codex",
            appName: "Codex",
            acceptedCompletion: true
        ))
        #expect(store.record(
            text: "Завтра вечером встретимся в кафе обсудить планы на отпуск.",
            bundleID: "ru.keepcoder.Telegram",
            appName: "Telegram",
            acceptedCompletion: false
        ))

        #expect(store.isLearnedPersonalWord("пайплайн"))
        #expect(store.isLearnedPersonalWord("стейджинге"))
        #expect(!store.isLearnedPersonalWord("незнакомоеслово"))

        let topRu = store.topVocabularyWords(forLanguage: "ru", limit: 10)
        #expect(topRu.contains("пайплайн"))

        // Topic overlap should rank the deployment sample above the unrelated cafe sample.
        let relevant = store.relevantSamples(
            forPrefix: "Нужно обновить пайплайн деплоя",
            bundleID: "com.apple.Notes",
            strength: .gentle
        )
        #expect(relevant.count == 1)
        #expect(relevant[0].lowercased().contains("пайплайн"))

        // Stats tracking + Cotypist stats import.
        store.recordAcceptance(insertedText: " перед релизом.")
        #expect(store.completionStats.completionsAccepted == 1)
        #expect(store.completionStats.wordsAccepted == 2)
        #expect(store.completionStats.charactersSaved == 15)

        let cotypistStatsURL = tmp.appendingPathComponent("completionStats.json")
        let cotypistJSON = """
        {"perDay":{"2026-04-01":{"short":{"completionCount":42,"wordCountTotal":120,"characterCount":750}}}}
        """
        try Data(cotypistJSON.utf8).write(to: cotypistStatsURL)
        let imported = store.importCotypistStats(from: cotypistStatsURL)
        #expect(imported?.completionsAccepted == 42)
        #expect(store.completionStats.completionsAccepted == 42)

        // JSONL fine-tuning export.
        let jsonlURL = tmp.appendingPathComponent("train.jsonl")
        let exportedCount = try store.exportTrainingDataJSONL(to: jsonlURL)
        #expect(exportedCount == 3)
        let jsonlText = try String(contentsOf: jsonlURL, encoding: .utf8)
        #expect(jsonlText.contains("\"text\""))
        #expect(jsonlText.contains("пайплайн"))

        // Persistence roundtrip across reloads.
        let reloaded = TypingHistoryStore(storageURL: storeURL)
        #expect(reloaded.count == 3)
        #expect(reloaded.isLearnedPersonalWord("пайплайн"))
        #expect(reloaded.completionStats.completionsAccepted == 42)
    }

    @Test func trimsCurrentWordLengthAndParsesSynonymsCleanly() {
        let oneWord = PromptBuilder.cleanSuggestion(
            " завтра утром на встрече",
            prefix: "Давай созвонимся",
            maxLength: .currentWord
        )
        #expect(oneWord == " завтра")

        let ctx = CompletionContext(
            prefix: "Проверь новый ",
            personalVocabulary: ["пайплайн", "стейджинг"]
        )
        let prompt = PromptBuilder.buildPrompt(for: ctx, format: .qwenInstruct)
        #expect(prompt.contains("Preferred vocabulary: пайплайн, стейджинг"))

        let parsedRu = PromptBuilder.parseSynonyms(
            "<think>\nhmm\n</think>\n1. оперативно, 2. стремительно, быстро, молниеносно, скоро, в темпе",
            original: "быстро"
        )
        #expect(parsedRu == ["оперативно", "стремительно", "молниеносно", "скоро", "в темпе"])

        let parsedCap = PromptBuilder.parseSynonyms("concise, brief, short", original: "Terse")
        #expect(parsedCap == ["Concise", "Brief", "Short"])
    }

    @Test @MainActor func fixesTechTyposPunctuationCapsAndIncludesScreenContext() {
        // Custom tech/modern Russian typo rescue & real mined chat typos.
        let realMinedTypos: [(String, String)] = [
            ("автокомлпикт", "автокомплит"),
            ("функцинал", "функционал"),
            ("накадвыаюстя", "накладываются"),
            ("првоерь", "проверь"),
            ("сжделай", "сделай"),
            ("давйа", "давай"),
            ("жавай", "давай"),
            ("рабоает", "работает"),
            ("привт", "привет"),
            ("тоде", "тоже"),
            ("нало", "надо"),
            ("своб", "свою"),
            ("чоень", "очень"),
            ("конекчно", "конечно"),
            ("подклчил", "подключил"),
            ("сраду", "сразу"),
            ("оснвоне", "основное"),
            ("прилоежние", "приложение"),
            ("прилежние", "приложение"),
            ("видое", "видео"),
            ("нейорнками", "нейронками"),
            ("псотмри", "посмотри"),
            ("выгдит", "выглядит"),
            ("смалйики", "смайлики"),
            ("акуант", "аккаунт"),
            ("хадача", "задача"),
            ("использвоать", "использовать"),
            ("пробелма", "проблема"),
        ]
        for (typo, expected) in realMinedTypos {
            let fixed = AutocorrectHelper.autoCorrectTypedWord(typo)
            #expect(fixed == expected, "Expected '\(typo)' -> '\(expected)', got '\(fixed ?? "nil")'")
        }
        // Real domain & colloquial words from user chats must never be mangled.
        for safe in ["правились", "визуализация", "телеграм", "гугл", "амнезия", "всплывашки", "побайтно", "задеплой", "нейронками"] {
            #expect(AutocorrectHelper.autoCorrectTypedWord(safe) == nil, "Should not mangle '\(safe)'")
        }

        let raw = "и надо что бы автокомлпикт имел больше контекста с экрана  и прочего и так же надо что бы слова правились запятые добавлялись с больших букв было и прочее"
        #expect(AutocorrectHelper.needsPostFactumPolish(raw))
        let quick = AutocorrectHelper.deterministicQuickPolish(raw)
        #expect(quick.hasPrefix("И надо, чтобы автокомплит"))
        #expect(!quick.contains("  "))
        #expect(!quick.contains("что бы"))

        // Code/shell input must never be auto-polished.
        #expect(AutocorrectHelper.looksLikeCodeOrCommand("git commit -m 'fix'"))
        #expect(!AutocorrectHelper.needsPostFactumPolish("func foo() { return bar }"))

        // Minimal tail diff computes compact incremental edits.
        let tail = AutocorrectHelper.minimalTailReplacement(
            from: "Привет, проверь пожалуйста новый автокомлпикт",
            to: "Привет, проверь пожалуйста новый автокомплит"
        )
        #expect(tail?.deleteCount == 5)
        #expect(tail?.insertText == "плит")

        // Screen context & page URL appear cleanly in completion prompt.
        let ctx = CompletionContext(
            prefix: "Да, светодиод на X1002 ",
            appName: "Codex",
            windowTitle: "Raspberry Pi SSD",
            pageURL: "https://example.com/docs/nvme",
            screenContext: "Напишите, горит ли светодиод на X1002 и какая модель SSD установлена."
        )
        let prompt = PromptBuilder.buildPrompt(for: ctx, format: .qwenInstruct)
        #expect(prompt.contains("Page: example.com/docs/nvme"))
        #expect(prompt.contains("Visible screen context:\nНапишите, горит ли светодиод на X1002"))
    }
}
