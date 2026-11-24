import Darwin
import Foundation
import Metal
import OSLog
import os
import llama

public enum LlamaEngineError: LocalizedError, Sendable {
    case modelNotFound(String)
    case modelLoadFailed(String)
    case contextInitFailed
    case tokenizationFailed
    case decodeFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let path): return "Model file not found: \(path)"
        case .modelLoadFailed(let path): return "Could not load GGUF model: \(path)"
        case .contextInitFailed: return "Could not initialize llama.cpp inference context"
        case .tokenizationFailed: return "Failed to tokenize completion prompt"
        case .decodeFailed(let code): return "llama.cpp decode failed (code \(code))"
        }
    }
}

public struct GenerationConfig: Sendable {
    public var maxTokens: Int
    public var temperature: Float
    public var topK: Int32
    public var topP: Float
    public var minP: Float
    public var repeatPenalty: Float
    public var contextSize: UInt32
    public var preferGPU: Bool
    public var loraPath: String?
    public var loraScale: Float

    public init(
        maxTokens: Int = 24,
        temperature: Float = 0.15,
        topK: Int32 = 40,
        topP: Float = 0.9,
        minP: Float = 0.05,
        repeatPenalty: Float = 1.08,
        contextSize: UInt32 = 1536,
        preferGPU: Bool = true,
        loraPath: String? = nil,
        loraScale: Float = 1.0
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repeatPenalty = repeatPenalty
        self.contextSize = contextSize
        self.preferGPU = preferGPU
        self.loraPath = loraPath
        self.loraScale = loraScale
    }
}

public struct EngineStatus: Equatable, Sendable {
    public let loadedModelPath: String?
    public let usingGPU: Bool
    public let contextSize: UInt32
    public let loraActive: Bool
}

/// Fast, cancellable, in-process llama.cpp autocomplete engine with KV-cache
/// prefix reuse and automatic Metal -> CPU fallback.
public actor LlamaEngine {
    private static let logger = Logger(subsystem: "com.nikolenko.HideMyEmail", category: "Autocomplete")
    private static let backendInitOnce: Void = {
        llama_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            let message = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty {
                LlamaEngine.logger.error("llama.cpp: \(message, privacy: .public)")
            }
        }, nil)
        llama_backend_init()
    }()

    private let generationCounter = OSAllocatedUnfairLock(initialState: UInt64(0))

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var batch: OpaquePointer?
    private var vocab: OpaquePointer?
    private var loraAdapter: OpaquePointer?
    private var loadedModelPath: String?
    private var loadedLoraPath: String?
    private var loadedLoraScale: Float = 1.0
    private var usingGPU = false
    private var contextSize: UInt32 = 2048
    private var cachedTokens: [llama_token] = []

    public init() {
        _ = Self.backendInitOnce
    }

    deinit {
        if let batch { llama_batch_ext_free(batch) }
        if let context { llama_free(context) }
        if let loraAdapter { llama_adapter_lora_free(loraAdapter) }
        if let model { llama_model_free(model) }
    }

    /// Bumps the cancellation token from any thread so an in-flight decode loop
    /// aborts on its next token boundary without waiting on the actor.
    nonisolated public func cancelActiveGeneration() -> UInt64 {
        generationCounter.withLock { counter in
            counter &+= 1
            return counter
        }
    }

    nonisolated private func isCurrent(generationID: UInt64) -> Bool {
        generationCounter.withLock { $0 == generationID }
    }

    public var status: EngineStatus {
        EngineStatus(
            loadedModelPath: loadedModelPath,
            usingGPU: usingGPU,
            contextSize: contextSize,
            loraActive: loraAdapter != nil
        )
    }

    public var isLoaded: Bool {
        model != nil && context != nil
    }

    /// Returns the process's real physical memory footprint in MB (matching Activity Monitor's "Memory" column).
    nonisolated public static func currentProcessMemoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / (1024 * 1024))
    }

    public func unload() {
        if let batch { llama_batch_ext_free(batch) }
        if let context { llama_free(context) }
        if let loraAdapter { llama_adapter_lora_free(loraAdapter) }
        if let model { llama_model_free(model) }
        batch = nil
        context = nil
        loraAdapter = nil
        model = nil
        vocab = nil
        loadedModelPath = nil
        loadedLoraPath = nil
        loadedLoraScale = 1.0
        usingGPU = false
        cachedTokens = []
    }

    private func applyLoraIfNeeded(path rawPath: String?, scale: Float) {
        guard let model, let ctx = context else { return }
        let normalizedPath: String? = rawPath.flatMap { p in
            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, FileManager.default.fileExists(atPath: trimmed) else { return nil }
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }

        if normalizedPath == loadedLoraPath && abs(scale - loadedLoraScale) < 0.001 {
            return
        }

        // Clear KV cache whenever adapter weights or scale change.
        if let memory = llama_get_memory(ctx) {
            llama_memory_clear(memory, true)
        }
        cachedTokens = []

        if normalizedPath == nil {
            _ = llama_set_adapters_lora(ctx, nil, 0, nil)
            if let existing = loraAdapter {
                llama_adapter_lora_free(existing)
                loraAdapter = nil
            }
            loadedLoraPath = nil
            loadedLoraScale = 1.0
            return
        }

        guard let loraPath = normalizedPath else { return }
        if loraPath == loadedLoraPath, let existing = loraAdapter {
            var existingPtr: OpaquePointer? = existing
            var s = scale
            let rc = llama_set_adapters_lora(ctx, &existingPtr, 1, &s)
            if rc == 0 {
                loadedLoraScale = scale
            }
            return
        }

        // Detach and release previous LoRA before loading the new one.
        _ = llama_set_adapters_lora(ctx, nil, 0, nil)
        if let existing = loraAdapter {
            llama_adapter_lora_free(existing)
            loraAdapter = nil
        }

        guard let newAdapter = llama_adapter_lora_init(model, loraPath) else {
            Self.logger.error("Failed to initialize LoRA adapter at \(loraPath, privacy: .public) (may be incompatible with active base model)")
            loadedLoraPath = nil
            loadedLoraScale = 1.0
            return
        }

        var adapterPtr: OpaquePointer? = newAdapter
        var scaleValue = scale
        let rc = llama_set_adapters_lora(ctx, &adapterPtr, 1, &scaleValue)
        if rc != 0 {
            Self.logger.error("Failed to attach LoRA adapter to context (code \(rc))")
            llama_adapter_lora_free(newAdapter)
            loadedLoraPath = nil
            loadedLoraScale = 1.0
            return
        }

        loraAdapter = newAdapter
        loadedLoraPath = loraPath
        loadedLoraScale = scale
        Self.logger.info("Applied LoRA adapter \(URL(fileURLWithPath: loraPath).lastPathComponent, privacy: .public) (scale=\(scale))")
    }

    public func loadModel(at url: URL, config: GenerationConfig = GenerationConfig()) throws {
        let path = url.standardizedFileURL.path
        if loadedModelPath == path, model != nil, context != nil {
            applyLoraIfNeeded(path: config.loraPath, scale: config.loraScale)
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw LlamaEngineError.modelNotFound(path)
        }

        unload()

        let metalDeviceName = MTLCreateSystemDefaultDevice()?.name ?? ""
        let isParavirtualGPU = metalDeviceName.localizedCaseInsensitiveContains("Paravirtual")
        let canTryGPU = config.preferGPU && llama_supports_gpu_offload() && !isParavirtualGPU
        let attempts: [Int32] = canTryGPU ? [99, 0] : [0]
        var lastError: Error = LlamaEngineError.modelLoadFailed(path)

        for gpuLayers in attempts {
            var mparams = llama_model_default_params()
            mparams.n_gpu_layers = gpuLayers

            guard let loadedModel = llama_model_load_from_file(path, mparams) else {
                lastError = LlamaEngineError.modelLoadFailed(path)
                continue
            }

            var cparams = llama_context_default_params()
            cparams.n_ctx = config.contextSize
            cparams.n_batch = 512
            cparams.n_ubatch = 256
            // Quantize KV cache to Q8_0 with Flash Attention to keep total RAM comfortably under 1 GB.
            cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
            cparams.type_k = GGML_TYPE_Q8_0
            cparams.type_v = GGML_TYPE_Q8_0
            let threads = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))
            cparams.n_threads = Int32(threads)
            cparams.n_threads_batch = Int32(max(threads, ProcessInfo.processInfo.activeProcessorCount - 1))

            var ctx = llama_init_from_model(loadedModel, cparams)
            if ctx == nil {
                // Fallback to default F16 KV + auto flash attention if a model architecture rejects Q8_0 KV.
                cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
                cparams.type_k = GGML_TYPE_F16
                cparams.type_v = GGML_TYPE_F16
                ctx = llama_init_from_model(loadedModel, cparams)
            }
            guard let ctx else {
                llama_model_free(loadedModel)
                lastError = LlamaEngineError.contextInitFailed
                continue
            }

            guard let extBatch = llama_batch_ext_init(ctx) else {
                llama_free(ctx)
                llama_model_free(loadedModel)
                lastError = LlamaEngineError.contextInitFailed
                continue
            }

            self.model = loadedModel
            self.context = ctx
            self.batch = extBatch
            self.vocab = llama_model_get_vocab(loadedModel)
            self.loadedModelPath = path
            self.usingGPU = gpuLayers > 0
            self.contextSize = llama_n_ctx(ctx)
            self.cachedTokens = []
            self.applyLoraIfNeeded(path: config.loraPath, scale: config.loraScale)
            Self.logger.info("Loaded model \(url.lastPathComponent, privacy: .public) (gpu=\(gpuLayers > 0), ctx=\(self.contextSize))")
            return
        }

        throw lastError
    }

    /// Generates an inline text continuation for `context`, reusing the KV cache
    /// for shared prompt prefixes and stopping early if cancelled.
    public func complete(
        context completionContext: CompletionContext,
        modelURL: URL,
        config: GenerationConfig = GenerationConfig(),
        generationID: UInt64? = nil
    ) throws -> String? {
        let genID = generationID ?? cancelActiveGeneration()
        guard isCurrent(generationID: genID) else { return nil }

        try loadModel(at: modelURL, config: config)
        guard isCurrent(generationID: genID) else { return nil }
        guard let ctx = self.context, let batch = self.batch, let vocab = self.vocab else {
            throw LlamaEngineError.contextInitFailed
        }

        let format = ModelPromptFormat.detect(from: modelURL)
        let prompt = PromptBuilder.buildPrompt(for: completionContext, format: format)
        let promptTokens = try tokenize(prompt, vocab: vocab, addSpecial: true)
        guard !promptTokens.isEmpty else { return nil }

        // Keep enough room in n_ctx for generated tokens.
        let effectiveMaxTokens = config.maxTokens == 24 ? completionContext.maxLength.maxTokens : config.maxTokens
        let maxPromptTokens = max(64, Int(self.contextSize) - effectiveMaxTokens - 8)
        let boundedTokens: [llama_token]
        if promptTokens.count > maxPromptTokens {
            let bos = llama_vocab_bos(vocab)
            let tail = Array(promptTokens.suffix(maxPromptTokens - 1))
            boundedTokens = bos >= 0 ? ([bos] + tail) : Array(promptTokens.suffix(maxPromptTokens))
        } else {
            boundedTokens = promptTokens
        }

        // Reuse KV-cache prefix where possible.
        var commonPrefix = 0
        let maxCommon = min(cachedTokens.count, boundedTokens.count)
        while commonPrefix < maxCommon && cachedTokens[commonPrefix] == boundedTokens[commonPrefix] {
            commonPrefix += 1
        }
        // Keep at least 1 token to decode so logits for the last prompt position are fresh.
        if commonPrefix == boundedTokens.count && commonPrefix > 0 {
            commonPrefix -= 1
        }

        let memory = llama_get_memory(ctx)
        if commonPrefix < cachedTokens.count {
            if let memory {
                let removed = llama_memory_seq_rm(memory, 0, Int32(commonPrefix), -1)
                if !removed {
                    llama_memory_clear(memory, true)
                    commonPrefix = 0
                }
            } else {
                commonPrefix = 0
            }
        }
        cachedTokens = Array(boundedTokens.prefix(commonPrefix))

        // Prefill only the divergent suffix in chunks of n_batch (512).
        let chunkSize = 512
        var pos = commonPrefix
        while pos < boundedTokens.count {
            guard isCurrent(generationID: genID) else { return nil }
            let end = min(pos + chunkSize, boundedTokens.count)
            llama_batch_ext_clear(batch)
            for i in pos..<end {
                let idx = llama_batch_ext_add_token(batch, 0, boundedTokens[i])
                guard idx >= 0 else {
                    if let memory { llama_memory_clear(memory, true) }
                    cachedTokens = []
                    throw LlamaEngineError.decodeFailed(-1)
                }
                var p = Int32(i)
                llama_batch_ext_set_pos(batch, idx, &p)
                llama_batch_ext_set_output_logits(batch, idx, i == boundedTokens.count - 1)
            }
            let rc = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)
            if rc != 0 {
                if let memory { llama_memory_clear(memory, true) }
                cachedTokens = []
                throw LlamaEngineError.decodeFailed(rc)
            }
            cachedTokens.append(contentsOf: boundedTokens[pos..<end])
            pos = end
        }

        // Configure lightweight sampler chain (penalties -> top_k -> top_p -> min_p -> temp -> dist/greedy).
        let chainParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(chainParams) else {
            throw LlamaEngineError.contextInitFailed
        }
        defer { llama_sampler_free(sampler) }

        if config.temperature <= 0.01 {
            if config.repeatPenalty > 1.0 {
                llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, config.repeatPenalty, 0.0, 0.0))
            }
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(config.topK))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(config.topP, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_min_p(config.minP, 1))
            if config.repeatPenalty > 1.0 {
                llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, config.repeatPenalty, 0.0, 0.0))
            }
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(config.temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(42))
        }

        // Token-by-token generation loop.
        var generatedBytes = Data()
        var currentPos = Int32(boundedTokens.count)
        var emittedWords = 0
        let sentenceStopLimit = completionContext.maxLength == .long ? 2 : 1
        let softCharBreak = completionContext.maxLength == .long ? 220 : (completionContext.maxLength == .short ? 48 : 96)

        for step in 0..<effectiveMaxTokens {
            guard isCurrent(generationID: genID) else { return nil }
            let token = llama_sampler_sample(sampler, ctx, -1)
            llama_sampler_accept(sampler, token)

            if llama_vocab_is_eog(vocab, token) {
                break
            }

            let piece = tokenToData(token, vocab: vocab)
            generatedBytes.append(piece)

            if let textSoFar = String(data: generatedBytes, encoding: .utf8) {
                if textSoFar.contains("\n") || textSoFar.contains("\r") {
                    break
                }
                emittedWords = textSoFar.split(whereSeparator: { $0.isWhitespace }).count
                if completionContext.maxLength == .currentWord {
                    let body = textSoFar.first == " " ? String(textSoFar.dropFirst()) : textSoFar
                    if body.contains(where: { $0.isWhitespace }) && !body.trimmingCharacters(in: .whitespaces).isEmpty {
                        break
                    }
                }
                // Stop cleanly once a substantive sentence finishes instead of starting a cut-off second sentence.
                let trimmed = textSoFar.trimmingCharacters(in: .whitespaces)
                if step >= 1, let last = trimmed.last, ".!?".contains(last) {
                    let alnumCount = trimmed.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
                    let completedSentences = trimmed.filter { ".!?".contains($0) }.count
                    if (alnumCount >= 2 || emittedWords >= 2) && completedSentences >= sentenceStopLimit {
                        break
                    }
                }
                if textSoFar.count >= softCharBreak && textSoFar.last?.isWhitespace == true {
                    break
                }
            }

            if step + 1 < effectiveMaxTokens {
                llama_batch_ext_clear(batch)
                let idx = llama_batch_ext_add_token(batch, 0, token)
                guard idx >= 0 else { break }
                var p = currentPos
                llama_batch_ext_set_pos(batch, idx, &p)
                llama_batch_ext_set_output_logits(batch, idx, true)
                let rc = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)
                if rc != 0 { break }
                cachedTokens.append(token)
                currentPos += 1
            }
        }

        guard isCurrent(generationID: genID) else { return nil }
        let raw = String(decoding: generatedBytes, as: UTF8.self)
        return PromptBuilder.cleanSuggestion(
            raw,
            prefix: completionContext.prefix,
            suffix: completionContext.suffix,
            allowMidLine: completionContext.allowMidLine,
            maxLength: completionContext.maxLength
        )
    }

    /// Rewrites fast, typo-heavy Russian/English input into clean, properly punctuated,
    /// natural prose (Wispr / dictation style) while preserving technical terms and meaning.
    public func polishText(
        _ text: String,
        style: TextPolishStyle = .clean,
        appName: String? = nil,
        modelURL: URL,
        loraPath: String? = nil,
        loraScale: Float = 1.0,
        generationID: UInt64? = nil
    ) throws -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }

        let genID = generationID ?? cancelActiveGeneration()
        guard isCurrent(generationID: genID) else { return nil }

        let config = GenerationConfig(
            maxTokens: min(384, max(48, trimmed.count + 40)),
            temperature: 0.0,
            topK: 1,
            topP: 1.0,
            minP: 0.0,
            repeatPenalty: 1.05,
            contextSize: 1536,
            preferGPU: true,
            loraPath: loraPath,
            loraScale: loraScale
        )
        try loadModel(at: modelURL, config: config)
        guard isCurrent(generationID: genID) else { return nil }
        guard let ctx = self.context, let batch = self.batch, let vocab = self.vocab else {
            throw LlamaEngineError.contextInitFailed
        }

        let format = ModelPromptFormat.detect(from: modelURL)
        let prompt = PromptBuilder.buildPolishPrompt(text: trimmed, style: style, appName: appName, format: format)
        let promptTokens = try tokenize(prompt, vocab: vocab, addSpecial: true)
        guard !promptTokens.isEmpty else { return nil }

        let maxPromptTokens = max(128, Int(self.contextSize) - config.maxTokens - 8)
        let boundedTokens = promptTokens.count > maxPromptTokens
            ? Array(promptTokens.prefix(maxPromptTokens))
            : promptTokens

        // Clear KV cache cleanly for full-message rewrite so completion cache never leaks in.
        if let memory = llama_get_memory(ctx) {
            llama_memory_clear(memory, true)
        }
        cachedTokens = []

        let chunkSize = 512
        var pos = 0
        while pos < boundedTokens.count {
            guard isCurrent(generationID: genID) else { return nil }
            let end = min(pos + chunkSize, boundedTokens.count)
            llama_batch_ext_clear(batch)
            for i in pos..<end {
                let idx = llama_batch_ext_add_token(batch, 0, boundedTokens[i])
                guard idx >= 0 else { throw LlamaEngineError.decodeFailed(-1) }
                var p = Int32(i)
                llama_batch_ext_set_pos(batch, idx, &p)
                llama_batch_ext_set_output_logits(batch, idx, i == boundedTokens.count - 1)
            }
            let rc = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)
            if rc != 0 {
                if let memory = llama_get_memory(ctx) { llama_memory_clear(memory, true) }
                throw LlamaEngineError.decodeFailed(rc)
            }
            cachedTokens.append(contentsOf: boundedTokens[pos..<end])
            pos = end
        }

        let chainParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(chainParams) else {
            throw LlamaEngineError.contextInitFailed
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, config.repeatPenalty, 0.0, 0.0))
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var generatedBytes = Data()
        var currentPos = Int32(boundedTokens.count)
        let allowNewlines = trimmed.contains("\n")

        for step in 0..<config.maxTokens {
            guard isCurrent(generationID: genID) else { return nil }
            let token = llama_sampler_sample(sampler, ctx, -1)
            llama_sampler_accept(sampler, token)

            if llama_vocab_is_eog(vocab, token) {
                break
            }

            let piece = tokenToData(token, vocab: vocab)
            generatedBytes.append(piece)

            if let textSoFar = String(data: generatedBytes, encoding: .utf8) {
                if !allowNewlines && textSoFar.contains("\n") && !textSoFar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    break
                }
                if textSoFar.contains("<|im_end|>") || textSoFar.contains("<end_of_turn>") || textSoFar.contains("\nInput:") {
                    break
                }
            }

            if step + 1 < config.maxTokens {
                llama_batch_ext_clear(batch)
                let idx = llama_batch_ext_add_token(batch, 0, token)
                guard idx >= 0 else { break }
                var p = currentPos
                llama_batch_ext_set_pos(batch, idx, &p)
                llama_batch_ext_set_output_logits(batch, idx, true)
                let rc = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)
                if rc != 0 { break }
                cachedTokens.append(token)
                currentPos += 1
            }
        }

        guard isCurrent(generationID: genID) else { return nil }
        let raw = String(decoding: generatedBytes, as: UTF8.self)
        return PromptBuilder.cleanPolishedText(raw, original: trimmed)
    }

    /// Returns up to 5 contextual word alternatives / synonyms for `word` (Cotypist Labs Thesaurus).
    public func suggestSynonyms(
        word: String,
        contextSentence: String,
        modelURL: URL,
        loraPath: String? = nil,
        loraScale: Float = 1.0,
        generationID: UInt64? = nil
    ) throws -> [String] {
        let cleanWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanWord.count >= 2 else { return [] }

        let genID = generationID ?? cancelActiveGeneration()
        guard isCurrent(generationID: genID) else { return [] }

        let config = GenerationConfig(
            maxTokens: 48,
            temperature: 0.0,
            topK: 1,
            topP: 1.0,
            minP: 0.0,
            repeatPenalty: 1.1,
            contextSize: 1536,
            preferGPU: true,
            loraPath: loraPath,
            loraScale: loraScale
        )
        try loadModel(at: modelURL, config: config)
        guard isCurrent(generationID: genID) else { return [] }
        guard let ctx = self.context, let batch = self.batch, let vocab = self.vocab else {
            throw LlamaEngineError.contextInitFailed
        }

        let format = ModelPromptFormat.detect(from: modelURL)
        let prompt = PromptBuilder.buildSynonymsPrompt(word: cleanWord, contextSentence: contextSentence, format: format)
        let promptTokens = try tokenize(prompt, vocab: vocab, addSpecial: true)
        guard !promptTokens.isEmpty else { return [] }

        let maxPromptTokens = max(128, Int(self.contextSize) - config.maxTokens - 8)
        let boundedTokens = promptTokens.count > maxPromptTokens
            ? Array(promptTokens.prefix(maxPromptTokens))
            : promptTokens

        if let memory = llama_get_memory(ctx) {
            llama_memory_clear(memory, true)
        }
        cachedTokens = []

        let chunkSize = 512
        var pos = 0
        while pos < boundedTokens.count {
            guard isCurrent(generationID: genID) else { return [] }
            let end = min(pos + chunkSize, boundedTokens.count)
            llama_batch_ext_clear(batch)
            for i in pos..<end {
                let idx = llama_batch_ext_add_token(batch, 0, boundedTokens[i])
                guard idx >= 0 else { throw LlamaEngineError.decodeFailed(-1) }
                var p = Int32(i)
                llama_batch_ext_set_pos(batch, idx, &p)
                llama_batch_ext_set_output_logits(batch, idx, i == boundedTokens.count - 1)
            }
            let rc = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)
            if rc != 0 {
                if let memory = llama_get_memory(ctx) { llama_memory_clear(memory, true) }
                throw LlamaEngineError.decodeFailed(rc)
            }
            cachedTokens.append(contentsOf: boundedTokens[pos..<end])
            pos = end
        }

        let chainParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(chainParams) else {
            throw LlamaEngineError.contextInitFailed
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, config.repeatPenalty, 0.0, 0.0))
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var generatedBytes = Data()
        var currentPos = Int32(boundedTokens.count)
        for step in 0..<config.maxTokens {
            guard isCurrent(generationID: genID) else { return [] }
            let token = llama_sampler_sample(sampler, ctx, -1)
            llama_sampler_accept(sampler, token)
            if llama_vocab_is_eog(vocab, token) { break }

            generatedBytes.append(tokenToData(token, vocab: vocab))
            if let textSoFar = String(data: generatedBytes, encoding: .utf8) {
                if textSoFar.contains("\n") && !textSoFar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    break
                }
                if textSoFar.filter({ $0 == "," }).count >= 5 {
                    break
                }
            }

            if step + 1 < config.maxTokens {
                llama_batch_ext_clear(batch)
                let idx = llama_batch_ext_add_token(batch, 0, token)
                guard idx >= 0 else { break }
                var p = currentPos
                llama_batch_ext_set_pos(batch, idx, &p)
                llama_batch_ext_set_output_logits(batch, idx, true)
                if llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch) != 0 { break }
                cachedTokens.append(token)
                currentPos += 1
            }
        }

        guard isCurrent(generationID: genID) else { return [] }
        let raw = String(decoding: generatedBytes, as: UTF8.self)
        return PromptBuilder.parseSynonyms(raw, original: cleanWord)
    }

    private func tokenize(_ text: String, vocab: OpaquePointer, addSpecial: Bool) throws -> [llama_token] {
        let utf8 = Array(text.utf8)
        let estimate = Int32(utf8.count + 16)
        var tokens = [llama_token](repeating: 0, count: Int(estimate))
        var count = utf8.withUnsafeBufferPointer { buf -> Int32 in
            let ptr = buf.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }
            return llama_tokenize(vocab, ptr, Int32(utf8.count), &tokens, estimate, addSpecial, false)
        }
        if count < 0 {
            let needed = Int(-count)
            tokens = [llama_token](repeating: 0, count: needed)
            count = utf8.withUnsafeBufferPointer { buf -> Int32 in
                let ptr = buf.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }
                return llama_tokenize(vocab, ptr, Int32(utf8.count), &tokens, Int32(needed), addSpecial, false)
            }
        }
        guard count >= 0 else { throw LlamaEngineError.tokenizationFailed }
        return Array(tokens.prefix(Int(count)))
    }

    private func tokenToData(_ token: llama_token, vocab: OpaquePointer) -> Data {
        var buffer = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if n < 0 {
            buffer = [CChar](repeating: 0, count: Int(-n) + 1)
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard n > 0 else { return Data() }
        return Data(bytes: buffer, count: Int(n))
    }
}

