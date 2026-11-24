import AppKit
import ApplicationServices
import AutocompleteCore
import Carbon.HIToolbox
import Foundation
import Observation
import OSLog

enum AutocompleteEngineState: Equatable {
    case disabled
    case noModel
    case idle(modelName: String)
    case loading(modelName: String)
    case ready(modelName: String, usingGPU: Bool)
    case error(String)
}

/// Core Cotypist-style inline autocomplete orchestrator integrated into KeyVeil.
/// Uses CGEventTap + Accessibility + local llama.cpp (Metal/CPU) + local writing-style
/// personalization with zero telemetry or bloat.
@MainActor
@Observable
final class AutocompleteController {
    static let shared = AutocompleteController()

    private(set) var engineState: AutocompleteEngineState = .disabled
    private(set) var availableModels: [LocalModel] = []
    private(set) var activeSuggestion: ActiveSuggestion?
    private(set) var isSecureInputActive = false
    private(set) var lastExternalBundleID: String?
    private(set) var lastExternalAppName: String?
    private(set) var downloadingModelID: String?
    private(set) var downloadProgress: Double = 0
    private(set) var lastDownloadError: String?
    private(set) var recordedStyleSampleCount: Int = TypingHistoryStore.shared.count
    private(set) var learnedWordCount: Int = TypingHistoryStore.shared.learnedWordCount
    private(set) var completionStats: CompletionStats = TypingHistoryStore.shared.completionStats
    private(set) var isPolishing = false
    private(set) var isLookingUpSynonyms = false
    private(set) var isLoraActive = false
    private(set) var lastImportMessage: String?
    private(set) var loadedMemoryMB: Int?

    let preferences = AutocompletePreferences.shared

    @ObservationIgnored private let logger = Logger(subsystem: "com.nikolenko.HideMyEmail", category: "Autocomplete")
    @ObservationIgnored private let engine = LlamaEngine()
    @ObservationIgnored private let historyStore = TypingHistoryStore.shared
    @ObservationIgnored private var eventTap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var inferenceTask: Task<Void, Never>?
    @ObservationIgnored private var polishTask: Task<Void, Never>?
    @ObservationIgnored private var autoPolishTask: Task<Void, Never>?
    @ObservationIgnored private var synonymsTask: Task<Void, Never>?
    @ObservationIgnored private var idleUnloadTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: URLSessionDownloadTask?
    @ObservationIgnored private var escapePausedUntil: Date?
    @ObservationIgnored private var lastAutoPolishedInput: String?
    @ObservationIgnored private var lastAutoPolishedOutput: String?
    @ObservationIgnored private var lastAutoPolishAt: Date = .distantPast
    @ObservationIgnored private var undoneAutoPolishInput: String?
    @ObservationIgnored private var synonymMenuTarget: SynonymMenuTarget?

    private static let codeEditorBundleIDs: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.barebones.bbedit",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.goland",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
    ]
    @ObservationIgnored private var lastCaretRect: CGRect = .zero
    @ObservationIgnored private var lastTypography: FieldTypography = .fallback
    @ObservationIgnored private var lastTypoWordRect: CGRect?
    @ObservationIgnored private var lastSnapshotBundleID: String?
    @ObservationIgnored private var lastSnapshotAppName: String?
    @ObservationIgnored private var started = false

    private init() {}

    var selectedModel: LocalModel? {
        ModelCatalog.preferredDefaultModel(from: availableModels, savedPath: preferences.selectedModelPath)
    }

    func start() {
        guard !started else { return }
        started = true
        TextContextReader.registerBundledWebFontsIfAvailable()
        refreshModels()
        if historyStore.completionStats.completionsAccepted == 0 {
            _ = historyStore.importCotypistStats()
        }
        refreshHistoryCounters()
        recordFrontmostExternalApp(NSWorkspace.shared.frontmostApplication)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                ?? NSWorkspace.shared.frontmostApplication
            MainActor.assumeIsolated {
                self.dismissSuggestion()
                self.cancelAutoPolish()
                TextContextReader.invalidateScreenContextCache()
                self.recordFrontmostExternalApp(app)
                self.isSecureInputActive = TextContextReader.isSecureEventInputActive
            }
        }

        // Immediately release model memory when the Mac sleeps or screen locks.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                self.unloadModelNow()
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                self.unloadModelNow()
            }
        }

        installEventTapIfNeeded()
        syncEngineState()
    }

    private func recordFrontmostExternalApp(_ app: NSRunningApplication?) {
        guard let app, let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return }
        lastExternalBundleID = bundleID
        lastExternalAppName = app.localizedName ?? bundleID
    }

    func restartIfTrusted() {
        installEventTapIfNeeded()
        syncEngineState()
    }

    private func refreshHistoryCounters() {
        recordedStyleSampleCount = historyStore.count
        learnedWordCount = historyStore.learnedWordCount
        completionStats = historyStore.completionStats
    }

    func clearTypingHistory(bundleID: String? = nil) {
        if let bundleID {
            historyStore.clear(bundleID: bundleID)
        } else {
            historyStore.clearAll()
        }
        refreshHistoryCounters()
    }

    func isLearningExcluded(_ bundleID: String) -> Bool {
        preferences.learningExcludedBundleIDs.contains(bundleID)
    }

    func toggleLearningExcluded(bundleID: String) {
        if preferences.learningExcludedBundleIDs.contains(bundleID) {
            preferences.learningExcludedBundleIDs.remove(bundleID)
        } else {
            preferences.learningExcludedBundleIDs.insert(bundleID)
        }
    }

    func selectLoraAdapter(url: URL) {
        let path = url.standardizedFileURL.path
        guard ModelCatalog.isValidLoRAFile(at: url) else {
            Toast.show(String(localized: "Selected file is not a valid GGUF LoRA adapter"), symbol: "exclamationmark.triangle.fill", tint: .orange)
            return
        }
        preferences.loraAdapterPath = path
        isLoraActive = false
    }

    func clearLoraAdapter() {
        preferences.loraAdapterPath = nil
        isLoraActive = false
    }

    func openModelsFolder() {
        let dir = ModelCatalog.appModelsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @discardableResult
    func exportTrainingData(to url: URL) throws -> Int {
        try historyStore.exportTrainingDataJSONL(to: url)
    }

    @discardableResult
    func importFromCotypist() -> String {
        var importedParts: [String] = []
        if let suite = UserDefaults(suiteName: "app.cotypist.Cotypist") {
            if let prompt = suite.string(forKey: "CompletionManager_userPrompt")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prompt.isEmpty {
                preferences.userPrompt = prompt
                importedParts.append(String(localized: "style prompt"))
            }
            if suite.object(forKey: "TrainingDataCollector_enabled") != nil {
                preferences.recordAllTyping = suite.bool(forKey: "TrainingDataCollector_enabled")
                importedParts.append(String(localized: "learning preference"))
            }
            if suite.object(forKey: "AccessoryButtonsViewController_enabled") != nil {
                preferences.showShortcutHints = suite.bool(forKey: "AccessoryButtonsViewController_enabled")
            }
        }
        if let stats = historyStore.importCotypistStats() {
            importedParts.append(String(localized: "\(stats.completionsAccepted) completions"))
        }
        refreshHistoryCounters()
        refreshModels()
        let message: String
        if importedParts.isEmpty {
            message = String(localized: "No Cotypist settings or statistics found")
        } else {
            message = String(localized: "Imported from Cotypist: \(importedParts.joined(separator: ", "))")
        }
        lastImportMessage = message
        return message
    }

    /// Cleanly releases llama.cpp Metal residency sets before process exit so
    /// ggml_metal's C++ static destructors never abort during NSApplication.terminate.
    func shutdownForTermination() {
        dismissSuggestion()
        debounceTask?.cancel()
        debounceTask = nil
        inferenceTask?.cancel()
        inferenceTask = nil
        polishTask?.cancel()
        polishTask = nil
        autoPolishTask?.cancel()
        autoPolishTask = nil
        synonymsTask?.cancel()
        synonymsTask = nil
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        _ = engine.cancelActiveGeneration()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        let semaphore = DispatchSemaphore(value: 0)
        let engineRef = engine
        Task.detached(priority: .userInitiated) {
            await engineRef.unload()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2.0)
    }

    func refreshModels() {
        availableModels = ModelCatalog.discoverModels(customPaths: preferences.customModelPaths)
        if let chosen = selectedModel, preferences.selectedModelPath != chosen.id {
            preferences.selectedModelPath = chosen.id
        }
        syncEngineState()
    }

    func setEnabled(_ enabled: Bool) {
        preferences.isEnabled = enabled
        if !enabled {
            dismissSuggestion()
            if !preferences.polishEnabled {
                unloadModelNow()
            }
            engineState = .disabled
        } else {
            installEventTapIfNeeded()
            syncEngineState()
        }
    }

    func selectModel(_ model: LocalModel) {
        preferences.selectedModelPath = model.id
        dismissSuggestion()
        unloadModelNow()
        syncEngineState()
    }

    /// Immediately unloads the LLM from RAM/VRAM (0 MB model footprint) while
    /// keeping autocomplete armed for instant on-demand reload on the next keystroke.
    func unloadModelNow() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        inferenceTask?.cancel()
        inferenceTask = nil
        _ = engine.cancelActiveGeneration()
        loadedMemoryMB = nil
        isLoraActive = false
        Task { await engine.unload() }
        if !preferences.isEnabled {
            engineState = .disabled
        } else if let model = selectedModel {
            engineState = .idle(modelName: model.name)
        } else {
            engineState = .noModel
        }
    }

    func addCustomModel(url: URL) {
        let path = url.standardizedFileURL.path
        guard ModelCatalog.isValidGGUFFile(at: url) else {
            engineState = .error(String(localized: "Selected file is not a valid GGUF model."))
            return
        }
        if !preferences.customModelPaths.contains(path) {
            preferences.customModelPaths.append(path)
        }
        preferences.selectedModelPath = path
        refreshModels()
        syncEngineState(forceReload: true)
    }

    func isAppExcluded(_ bundleID: String) -> Bool {
        preferences.excludedBundleIDs.contains(bundleID)
    }

    func toggleExcluded(bundleID: String) {
        if preferences.excludedBundleIDs.contains(bundleID) {
            preferences.excludedBundleIDs.remove(bundleID)
        } else {
            preferences.excludedBundleIDs.insert(bundleID)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
                dismissSuggestion()
            }
        }
    }

    func downloadModel(_ preset: DownloadableModel) {
        guard downloadingModelID == nil else { return }
        downloadingModelID = preset.id
        downloadProgress = 0
        lastDownloadError = nil

        let dir = ModelCatalog.appModelsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(preset.filename)

        let delegate = ModelDownloadDelegate(
            onProgress: { [weak self] fraction in
                Task { @MainActor in self?.downloadProgress = fraction }
            },
            onComplete: { [weak self] tempURL, error in
                Task { @MainActor in
                    guard let self else { return }
                    defer {
                        self.downloadingModelID = nil
                        self.downloadTask = nil
                    }
                    if let error {
                        self.lastDownloadError = error.localizedDescription
                        return
                    }
                    guard let tempURL else { return }
                    do {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.moveItem(at: tempURL, to: destination)
                        self.preferences.selectedModelPath = destination.path
                        self.refreshModels()
                        self.syncEngineState(forceReload: true)
                    } catch {
                        self.lastDownloadError = error.localizedDescription
                    }
                }
            }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: preset.downloadURL)
        self.downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadingModelID = nil
        downloadProgress = 0
    }

    func showDemoPreview() {
        let sample = ActiveSuggestion(
            text: " tomorrow morning at 10:00 so we can walk through the final details.",
            kind: .completion,
            anchorPrefix: "Let's meet"
        )
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let anchor = CGRect(x: screen.midX - 110, y: screen.midY - 60, width: 2, height: 20)
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let demoTypography = FieldTypography(
            font: NSFont.systemFont(ofSize: 15),
            foregroundColor: nil,
            backgroundColor: nil,
            isDarkBackground: isDark,
            lineLeftX: screen.midX - 200,
            lineStepHeight: 20,
            fieldVisibleFrame: CGRect(x: screen.midX - 200, y: screen.midY - 140, width: 380, height: 120),
            hasSameLineSuffix: false
        )
        GhostOverlayPanel.shared.show(
            suggestion: sample,
            at: anchor,
            typography: demoTypography,
            acceptBadge: preferences.acceptShortcut.badge,
            showShortcutHint: preferences.showShortcutHints
        )
    }

    // MARK: - Engine Lifecycle

    /// Keeps the model unloaded (0 MB RAM) until the user actually types or triggers Polish.
    private func syncEngineState(forceReload: Bool = false) {
        guard preferences.isEnabled else {
            engineState = .disabled
            return
        }
        guard let model = selectedModel else {
            engineState = .noModel
            return
        }
        if !forceReload {
            if case .ready(let loadedName, _) = engineState, loadedName == model.name {
                return
            }
            // Stay in `.idle` (unloaded) so idle apps consume zero model memory.
            engineState = .idle(modelName: model.name)
            return
        }
        unloadModelNow()
        engineState = .idle(modelName: model.name)
    }

    private func scheduleIdleUnload(modelName: String) {
        idleUnloadTask?.cancel()
        let seconds = preferences.idleUnloadDelay.rawValue
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.engine.unload()
            self.loadedMemoryMB = nil
            if case .ready = self.engineState {
                self.engineState = .idle(modelName: modelName)
            }
            self.logger.info("Unloaded idle autocomplete model after \(seconds)s to free memory")
        }
    }

    private func updateLoadedMemory(for model: LocalModel) {
        // File weights are mmap'd + runtime KV/compute buffers live in phys_footprint.
        let runtimeMB = LlamaEngine.currentProcessMemoryMB()
        let modelFileMB = Int(model.sizeBytes / (1024 * 1024))
        loadedMemoryMB = max(runtimeMB, modelFileMB + max(0, runtimeMB - 60))
    }

    // MARK: - Event Tap

    private func installEventTapIfNeeded() {
        guard eventTap == nil, AX.isTrusted else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated {
                    if let tap = AutocompleteController.shared.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                }
                return Unmanaged.passUnretained(event)
            }
            return MainActor.assumeIsolated {
                AutocompleteController.shared.handleEvent(type: type, event: event)
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: nil
        ) else {
            logger.warning("Could not create CGEventTap; Accessibility permission may be required.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard preferences.isEnabled || preferences.polishEnabled else { return Unmanaged.passUnretained(event) }
        guard !TextInserter.isSynthesizing else { return Unmanaged.passUnretained(event) }
        let eventTag = event.getIntegerValueField(.eventSourceUserData)
        if eventTag == TextInserter.syntheticMarker || eventTag == TextRetypingEngine.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown || type == .rightMouseDown || type == .scrollWheel {
            TextContextReader.invalidateScreenContextCache()
            cancelAutoPolish()
            if activeSuggestion != nil {
                dismissSuggestion()
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Global Wispr-style Text Polish shortcut (works even when inline autocomplete is paused).
        if preferences.polishEnabled,
           preferences.polishShortcut.matches(keyCode: keyCode, flags: flags) {
            dismissSuggestion()
            polishCurrentField()
            return nil
        }

        // Contextual Word Alternatives / Synonyms shortcut (Cotypist Labs Thesaurus).
        if preferences.synonymsShortcut.matches(keyCode: keyCode, flags: flags) {
            dismissSuggestion()
            showSynonymsForCurrentWord()
            return nil
        }

        guard preferences.isEnabled else { return Unmanaged.passUnretained(event) }

        // Yield whenever Hide My Email's own email suggestion panel is visible.
        if SuggestionPanel.shared.isVisible {
            if activeSuggestion != nil { dismissSuggestion() }
            return Unmanaged.passUnretained(event)
        }

        // Ignore frontmost excluded apps or our own windows.
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            if bundleID == Bundle.main.bundleIdentifier || preferences.excludedBundleIDs.contains(bundleID) {
                if activeSuggestion != nil { dismissSuggestion() }
                return Unmanaged.passUnretained(event)
            }
        }

        // Manual Invoke Completion shortcut (works in both Automatic and Shortcut-Only modes).
        if preferences.invokeShortcut.matches(keyCode: keyCode, flags: flags) {
            escapePausedUntil = nil
            dismissSuggestion()
            evaluateFocusedField(manualInvoke: true)
            return nil
        }

        if let current = activeSuggestion {
            // 1. Accept Full Suggestion (e.g., Tab)
            if preferences.acceptShortcut.matches(keyCode: keyCode, flags: flags) {
                acceptFull(current)
                return nil
            }

            // 2. Accept Next Word (e.g., Option+Right / Option+Tab)
            if current.supportsWordByWord,
               preferences.acceptWordShortcut.matches(keyCode: keyCode, flags: flags) {
                acceptNextWord(current)
                return nil
            }

            // 3. Escape behavior (dismiss & pause 5s / dismiss once / pass through to app).
            if keyCode == Int64(kVK_Escape) {
                switch preferences.escapeBehavior {
                case .dismissAndPause:
                    escapePausedUntil = Date().addingTimeInterval(5.0)
                    dismissSuggestion()
                    return nil
                case .dismiss:
                    dismissSuggestion()
                    return nil
                case .passThrough:
                    dismissSuggestion()
                    return Unmanaged.passUnretained(event)
                }
            }

            // 4. Smooth zero-flicker type-through using exact glyph advance width,
            //    followed by a quick AX caret re-sync in case typing wrapped a line or drifted.
            if !flags.contains(.maskCommand) && !flags.contains(.maskControl),
               let typed = eventUnicodeString(event), !typed.isEmpty,
               typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                if let advanced = AutocompleteCore.SuggestionState.advanceByTyping(typed: typed, suggestion: current) {
                    activeSuggestion = advanced
                    lastCaretRect.origin.x += GhostOverlayPanel.advanceWidth(of: typed, font: lastTypography.font)
                    let nearRightEdge = lastTypography.fieldVisibleFrame.map { lastCaretRect.origin.x >= $0.maxX - 10 } ?? false
                    if !nearRightEdge {
                        GhostOverlayPanel.shared.show(
                            suggestion: advanced,
                            at: lastCaretRect,
                            typography: lastTypography,
                            acceptBadge: preferences.acceptShortcut.badge,
                            showShortcutHint: preferences.showShortcutHints
                        )
                    }
                    scheduleCaretResync(expectedText: advanced.text)
                    return Unmanaged.passUnretained(event)
                }
            }

            // Any other key clears the current suggestion.
            dismissSuggestion()
        }

        // Ignore Command / Control shortcuts (Cmd+C, Cmd+V, Cmd+Z, etc.).
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            if keyCode == Int64(kVK_ANSI_Z),
               flags.contains(.maskCommand),
               !flags.contains(.maskShift),
               Date().timeIntervalSince(lastAutoPolishAt) < 15.0 {
                // User undid our automatic post-factum polish — do not re-apply it to the same text.
                undoneAutoPolishInput = lastAutoPolishedInput
            }
            cancelPendingWork()
            cancelAutoPolish()
            return Unmanaged.passUnretained(event)
        }

        // Capture completed sentences into local Typing History when user presses Return.
        if (keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_ANSI_KeypadEnter))
            && preferences.personalizationStrength != .off
            && preferences.recordAllTyping {
            captureCurrentSentenceForStyleHistory()
        }

        // Navigation / Return / Escape cancel pending completions without re-triggering.
        let nonTriggerKeys: Set<Int64> = [
            Int64(kVK_Escape), Int64(kVK_Return), Int64(kVK_ANSI_KeypadEnter),
            Int64(kVK_Tab), Int64(kVK_UpArrow), Int64(kVK_DownArrow),
            Int64(kVK_LeftArrow), Int64(kVK_RightArrow), Int64(kVK_Home),
            Int64(kVK_End), Int64(kVK_PageUp), Int64(kVK_PageDown),
        ]
        if nonTriggerKeys.contains(keyCode) {
            cancelPendingWork()
            cancelAutoPolish()
            return Unmanaged.passUnretained(event)
        }

        let typedChar = eventUnicodeString(event)
        let isSentencePunct = (typedChar?.count == 1) && (typedChar.map { ".!?".contains($0) } ?? false)

        // Also learn writing style passively after sentence-ending punctuation.
        if preferences.personalizationStrength != .off && preferences.recordAllTyping, isSentencePunct {
            captureCurrentSentenceForStyleHistory()
        }

        // Schedule debounced completion + automatic post-factum polish after typing.
        scheduleEvaluation()
        scheduleAutoPolish(afterPunctuation: isSentencePunct)
        return Unmanaged.passUnretained(event)
    }

    private func acceptFull(_ suggestion: ActiveSuggestion) {
        let isCompletion: Bool = {
            if case .completion = suggestion.kind { return true }
            return false
        }()

        let (toInsert, heldBack): (String, String)
        if isCompletion {
            (toInsert, heldBack) = AutocompleteCore.SuggestionState.applyTrailingPunctuation(
                accepted: suggestion.text,
                remaining: "",
                isFullAcceptance: true,
                mode: preferences.trailingPunctuationMode
            )
        } else {
            (toInsert, heldBack) = (suggestion.text, "")
        }

        // Record completion acceptance statistics & local writing style.
        if isCompletion {
            historyStore.recordAcceptance(insertedText: toInsert)
            if preferences.personalizationStrength != .off,
               let bundleID = lastSnapshotBundleID, let appName = lastSnapshotAppName,
               !preferences.learningExcludedBundleIDs.contains(bundleID) {
                let combined = suggestion.anchorPrefix + toInsert
                _ = historyStore.record(text: combined, bundleID: bundleID, appName: appName, acceptedCompletion: true)
            }
            refreshHistoryCounters()
        }

        if heldBack.isEmpty {
            dismissSuggestion()
            TextInserter.insert(toInsert, deletingBefore: suggestion.deleteBeforeCount) { [weak self] in
                guard let self, isCompletion else { return }
                self.scheduleEvaluation(delayMs: max(self.preferences.debounceMilliseconds, 340))
            }
        } else {
            // Keep held-back trailing punctuation inline so pressing Tab again inserts it.
            let next = ActiveSuggestion(
                text: heldBack,
                kind: .completion,
                anchorPrefix: suggestion.anchorPrefix + toInsert
            )
            activeSuggestion = next
            lastCaretRect.origin.x += GhostOverlayPanel.advanceWidth(of: toInsert, font: lastTypography.font)
            GhostOverlayPanel.shared.show(
                suggestion: next,
                at: lastCaretRect,
                typography: lastTypography,
                acceptBadge: preferences.acceptShortcut.badge,
                showShortcutHint: preferences.showShortcutHints
            )
            TextInserter.insert(toInsert, deletingBefore: 0)
        }
    }

    private func acceptNextWord(_ suggestion: ActiveSuggestion) {
        let (rawWord, rawRemaining) = AutocompleteCore.SuggestionState.splitNextWord(suggestion.text)
        guard !rawWord.isEmpty else {
            dismissSuggestion()
            return
        }
        let (word, remaining) = AutocompleteCore.SuggestionState.applyTrailingPunctuation(
            accepted: rawWord,
            remaining: rawRemaining,
            isFullAcceptance: false,
            mode: preferences.trailingPunctuationMode
        )

        TextInserter.insert(word, deletingBefore: 0)
        historyStore.recordAcceptance(insertedText: word)
        if remaining.isEmpty {
            if preferences.personalizationStrength != .off,
               let bundleID = lastSnapshotBundleID, let appName = lastSnapshotAppName,
               !preferences.learningExcludedBundleIDs.contains(bundleID) {
                _ = historyStore.record(
                    text: suggestion.anchorPrefix + word,
                    bundleID: bundleID,
                    appName: appName,
                    acceptedCompletion: true
                )
            }
            refreshHistoryCounters()
            dismissSuggestion()
            scheduleEvaluation(delayMs: max(preferences.debounceMilliseconds, 320))
        } else {
            refreshHistoryCounters()
            let next = ActiveSuggestion(
                text: remaining,
                kind: .completion,
                anchorPrefix: suggestion.anchorPrefix + word
            )
            activeSuggestion = next
            lastCaretRect.origin.x += GhostOverlayPanel.advanceWidth(of: word, font: lastTypography.font)
            GhostOverlayPanel.shared.show(
                suggestion: next,
                at: lastCaretRect,
                typography: lastTypography,
                acceptBadge: preferences.acceptShortcut.badge,
                showShortcutHint: preferences.showShortcutHints
            )
            scheduleCaretResync(expectedText: next.text, delayMs: 45)
        }
    }

    private func scheduleCaretResync(expectedText: String, delayMs: Int = 25) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard let self, let current = self.activeSuggestion, current.text == expectedText else { return }
            guard let freshCaret = TextContextReader.readLiveCaretRect() else { return }
            let dx = abs(freshCaret.minX - self.lastCaretRect.minX)
            let dy = abs(freshCaret.minY - self.lastCaretRect.minY)
            if dx > 1.5 || dy > 1.0 {
                self.lastCaretRect = freshCaret
                GhostOverlayPanel.shared.show(
                    suggestion: current,
                    at: freshCaret,
                    typography: self.lastTypography,
                    acceptBadge: self.preferences.acceptShortcut.badge,
                    showShortcutHint: self.preferences.showShortcutHints
                )
            }
        }
    }

    private func captureCurrentSentenceForStyleHistory() {
        Task { @MainActor [weak self] in
            guard let self, self.preferences.isEnabled,
                  self.preferences.personalizationStrength != .off,
                  self.preferences.recordAllTyping,
                  !TextContextReader.isSecureEventInputActive else { return }
            guard let snapshot = TextContextReader.readFocusedContext(),
                  !self.preferences.excludedBundleIDs.contains(snapshot.bundleID),
                  !self.preferences.learningExcludedBundleIDs.contains(snapshot.bundleID) else { return }
            // Do not pollute writing style examples with typo-heavy drafts.
            guard AutocorrectHelper.isCleanForStyleHistory(snapshot.prefix) else { return }
            if self.historyStore.record(
                text: snapshot.prefix,
                bundleID: snapshot.bundleID,
                appName: snapshot.appName,
                acceptedCompletion: false
            ) {
                self.refreshHistoryCounters()
            }
        }
    }

    // MARK: - Wispr-Style Text Polish

    /// Rewrites either the selected text or the entire focused input field using the
    /// local model (fixing typos, wrong layout, grammar, and punctuation) and replaces
    /// it in place so Cmd+Z can undo cleanly.
    func polishCurrentField() {
        guard !isPolishing else { return }
        guard !TextContextReader.isSecureEventInputActive else {
            Toast.show(String(localized: "Cannot polish password fields"), symbol: "lock.fill", tint: .orange)
            return
        }
        guard let model = selectedModel else {
            Toast.show(String(localized: "Download a local model in Settings → Autocomplete"), symbol: "exclamationmark.triangle.fill", tint: .orange)
            return
        }
        guard let snapshot = TextContextReader.readFocusedContext() else {
            Toast.show(String(localized: "Place cursor in a text field first"), symbol: "text.cursor", tint: .secondary)
            return
        }

        var selectedText: String?
        if snapshot.selectionLengthUTF16 > 0 {
            var val: CFTypeRef?
            if AXUIElementCopyAttributeValue(snapshot.element, kAXSelectedTextAttribute as CFString, &val) == .success,
               let str = val as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selectedText = str
            }
        }

        let isSelection = selectedText != nil
        let sourceText = selectedText ?? (snapshot.prefix + snapshot.suffix)
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            Toast.show(String(localized: "Nothing to polish"), symbol: "text.cursor", tint: .secondary)
            return
        }

        isPolishing = true
        dismissSuggestion()
        Toast.show(String(localized: "Polishing text…"), symbol: "sparkles", tint: .accentColor)

        let preCleaned = AutocorrectHelper.deterministicQuickPolish(trimmed)
        let style = preferences.polishStyle
        let appName = snapshot.appName
        let loraPath = preferences.loraAdapterPath
        let loraScale = Float(preferences.loraScale)
        let genID = engine.cancelActiveGeneration()

        if case .idle = engineState {
            engineState = .loading(modelName: model.name)
        }

        polishTask?.cancel()
        polishTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isPolishing = false }
            do {
                let polished = try await self.engine.polishText(
                    preCleaned,
                    style: style,
                    appName: appName,
                    modelURL: model.url,
                    loraPath: loraPath,
                    loraScale: loraScale,
                    generationID: genID
                )
                guard !Task.isCancelled else { return }

                let status = await self.engine.status
                self.engineState = .ready(modelName: model.name, usingGPU: status.usingGPU)
                self.isLoraActive = status.loraActive
                self.updateLoadedMemory(for: model)
                self.scheduleIdleUnload(modelName: model.name)

                let finalOutput = polished ?? (preCleaned != trimmed ? preCleaned : nil)
                guard let finalOutput, !finalOutput.isEmpty else {
                    Toast.show(String(localized: "Text already looks good"), symbol: "checkmark.circle", tint: .secondary)
                    return
                }
                if finalOutput == trimmed {
                    Toast.show(String(localized: "Text already looks good"), symbol: "checkmark.circle", tint: .secondary)
                    return
                }

                TextInserter.replaceField(with: finalOutput, selectAll: !isSelection) {
                    Toast.show(String(localized: "Text polished · ⌘Z to undo"), symbol: "sparkles", tint: .green)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.logger.error("Text polish error: \(error.localizedDescription, privacy: .public)")
                Toast.show(String(localized: "Could not polish text"), symbol: "exclamationmark.triangle.fill", tint: .red)
            }
        }
    }

    // MARK: - Automatic Post-Factum Text Polish (Typos, Capitalization & Commas)

    private func cancelAutoPolish() {
        autoPolishTask?.cancel()
        autoPolishTask = nil
    }

    private func scheduleAutoPolish(afterPunctuation: Bool) {
        cancelAutoPolish()
        guard preferences.polishEnabled, preferences.autoPolishEnabled else { return }
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           Self.codeEditorBundleIDs.contains(bundleID) || preferences.excludedBundleIDs.contains(bundleID) {
            return
        }
        let delayMs = afterPunctuation ? 550 : preferences.autoPolishDelayMs
        autoPolishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled, let self else { return }
            await self.runAutoPolishPass()
        }
    }

    private func runAutoPolishPass() async {
        guard preferences.polishEnabled,
              preferences.autoPolishEnabled,
              !isPolishing,
              !isLookingUpSynonyms,
              !TextContextReader.isSecureEventInputActive,
              !SuggestionPanel.shared.isVisible else {
            return
        }
        guard let snapshot = TextContextReader.readFocusedContext() else { return }
        guard !preferences.excludedBundleIDs.contains(snapshot.bundleID),
              !Self.codeEditorBundleIDs.contains(snapshot.bundleID),
              snapshot.selectionLengthUTF16 == 0,
              snapshot.suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let rawPrefix = snapshot.prefix
        let hadTrailingSpace = rawPrefix.hasSuffix(" ")
        let trimmed = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 14, trimmed.count <= 600 else { return }
        guard trimmed != lastAutoPolishedOutput,
              trimmed != lastAutoPolishedInput,
              trimmed != undoneAutoPolishInput else {
            return
        }
        guard AutocorrectHelper.needsPostFactumPolish(trimmed) else { return }

        let hadSentenceEnd = trimmed.last.map { ".!?".contains($0) } ?? false
        let quickCleaned = AutocorrectHelper.deterministicQuickPolish(trimmed)

        let expectedPrefix = rawPrefix
        let expectedSuffix = snapshot.suffix
        let expectedBundleID = snapshot.bundleID

        var candidateOutput: String? = quickCleaned != trimmed ? quickCleaned : nil

        if let model = selectedModel {
            let genID = engine.cancelActiveGeneration()
            if case .idle = engineState {
                engineState = .loading(modelName: model.name)
            }
            do {
                let llmPolished = try await engine.polishText(
                    quickCleaned,
                    style: preferences.polishStyle,
                    appName: snapshot.appName,
                    modelURL: model.url,
                    loraPath: preferences.loraAdapterPath,
                    loraScale: Float(preferences.loraScale),
                    generationID: genID
                )
                guard !Task.isCancelled else { return }
                let status = await engine.status
                self.engineState = .ready(modelName: model.name, usingGPU: status.usingGPU)
                self.isLoraActive = status.loraActive
                self.updateLoadedMemory(for: model)
                self.scheduleIdleUnload(modelName: model.name)

                if let llmPolished, !llmPolished.isEmpty {
                    candidateOutput = llmPolished
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.logger.error("Auto-polish LLM error: \(error.localizedDescription, privacy: .public)")
            }
        }

        guard var finalOutput = candidateOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
              !finalOutput.isEmpty else {
            return
        }

        // When the user paused right after pressing Space mid-sentence, do not prematurely
        // close the sentence with a trailing period; keep the trailing space so typing continues smoothly.
        if hadTrailingSpace {
            if !hadSentenceEnd && finalOutput.hasSuffix(".") && !finalOutput.hasSuffix("...") {
                finalOutput.removeLast()
            }
            finalOutput += " "
        }

        guard finalOutput != expectedPrefix else { return }

        // Strict freshness check: abort silently if the user typed anything or switched apps while generating.
        guard let fresh = TextContextReader.readFocusedContext(),
              fresh.bundleID == expectedBundleID,
              fresh.prefix == expectedPrefix,
              fresh.suffix == expectedSuffix,
              fresh.selectionLengthUTF16 == 0,
              !SuggestionPanel.shared.isVisible else {
            return
        }

        dismissSuggestion()
        lastAutoPolishedInput = trimmed
        lastAutoPolishedOutput = finalOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        lastAutoPolishAt = Date()

        if let tail = AutocorrectHelper.minimalTailReplacement(from: expectedPrefix, to: finalOutput) {
            TextInserter.insert(tail.insertText, deletingBefore: tail.deleteCount) {
                Toast.show(String(localized: "Auto-fixed · ⌘Z to undo"), symbol: "wand.and.stars", tint: .green)
            }
        } else {
            TextInserter.replaceField(with: finalOutput, selectAll: true) {
                Toast.show(String(localized: "Auto-fixed · ⌘Z to undo"), symbol: "wand.and.stars", tint: .green)
            }
        }
    }

    // MARK: - Word Alternatives / Synonyms (Cotypist Labs Thesaurus)

    /// Looks up up to 5 contextual synonyms for the selected word or the word right
    /// before the caret and presents a native popup menu at the caret to replace it in place.
    func showSynonymsForCurrentWord() {
        guard !isLookingUpSynonyms else { return }
        guard !TextContextReader.isSecureEventInputActive else {
            Toast.show(String(localized: "Cannot look up synonyms in password fields"), symbol: "lock.fill", tint: .orange)
            return
        }
        guard let model = selectedModel else {
            Toast.show(String(localized: "Download a local model in Settings → Autocomplete"), symbol: "exclamationmark.triangle.fill", tint: .orange)
            return
        }
        guard let snapshot = TextContextReader.readFocusedContext() else {
            Toast.show(String(localized: "Place cursor on a word first"), symbol: "text.cursor", tint: .secondary)
            return
        }
        guard !preferences.excludedBundleIDs.contains(snapshot.bundleID) else { return }

        var targetWord: String?
        var isSelection = false
        var trailingSpacesToDelete = 0

        if snapshot.selectionLengthUTF16 > 0 {
            var val: CFTypeRef?
            if AXUIElementCopyAttributeValue(snapshot.element, kAXSelectedTextAttribute as CFString, &val) == .success,
               let str = val as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= 2 && trimmed.count <= 32 && !trimmed.contains("\n") {
                    targetWord = trimmed
                    isSelection = true
                }
            }
        }

        if targetWord == nil {
            var working = snapshot.prefix
            while working.last == " " {
                working.removeLast()
                trailingSpacesToDelete += 1
            }
            var start = working.endIndex
            while start > working.startIndex {
                let prev = working.index(before: start)
                if working[prev].isLetter || working[prev] == "-" {
                    start = prev
                } else {
                    break
                }
            }
            let candidate = String(working[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if candidate.count >= 2 && candidate.count <= 32 {
                targetWord = candidate
            }
        }

        guard let word = targetWord else {
            Toast.show(String(localized: "Select or place cursor after a word"), symbol: "text.cursor", tint: .secondary)
            return
        }

        let contextSentence = String((snapshot.prefix + snapshot.suffix).suffix(240))
        let caretRect = snapshot.caretScreenRect
        let deleteBeforeCount = isSelection ? 0 : (word.count + trailingSpacesToDelete)
        let appendTrailingSpace = !isSelection && trailingSpacesToDelete > 0
        let loraPath = preferences.loraAdapterPath
        let loraScale = Float(preferences.loraScale)
        let genID = engine.cancelActiveGeneration()

        isLookingUpSynonyms = true
        dismissSuggestion()
        Toast.show(String(localized: "Finding alternatives for «\(word)»…"), symbol: "text.book.closed", tint: .accentColor)

        if case .idle = engineState {
            engineState = .loading(modelName: model.name)
        }

        synonymsTask?.cancel()
        synonymsTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isLookingUpSynonyms = false }
            do {
                let rawAlternatives = try await self.engine.suggestSynonyms(
                    word: word,
                    contextSentence: contextSentence,
                    modelURL: model.url,
                    loraPath: loraPath,
                    loraScale: loraScale,
                    generationID: genID
                )
                guard !Task.isCancelled else { return }

                let status = await self.engine.status
                self.engineState = .ready(modelName: model.name, usingGPU: status.usingGPU)
                self.isLoraActive = status.loraActive
                self.updateLoadedMemory(for: model)
                self.scheduleIdleUnload(modelName: model.name)

                let validAlternatives = rawAlternatives.filter { AutocorrectHelper.isValidDictionaryPhrase($0) }
                let alternatives = validAlternatives.isEmpty ? rawAlternatives : validAlternatives
                guard !alternatives.isEmpty else {
                    Toast.show(String(localized: "No alternatives found for «\(word)»"), symbol: "text.book.closed", tint: .secondary)
                    return
                }

                self.presentSynonymsMenu(
                    original: word,
                    alternatives: alternatives,
                    at: caretRect,
                    isSelection: isSelection,
                    deleteBeforeCount: deleteBeforeCount,
                    appendTrailingSpace: appendTrailingSpace
                )
            } catch {
                guard !Task.isCancelled else { return }
                self.logger.error("Synonym lookup error: \(error.localizedDescription, privacy: .public)")
                Toast.show(String(localized: "Could not load alternatives"), symbol: "exclamationmark.triangle.fill", tint: .red)
            }
        }
    }

    private func presentSynonymsMenu(
        original: String,
        alternatives: [String],
        at caretRect: CGRect,
        isSelection: Bool,
        deleteBeforeCount: Int,
        appendTrailingSpace: Bool
    ) {
        let menu = NSMenu(title: original)
        let header = NSMenuItem(
            title: String(localized: "Alternatives for «\(original)»"),
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let target = SynonymMenuTarget { chosen in
            let replacement = appendTrailingSpace ? "\(chosen) " : chosen
            if isSelection {
                TextInserter.replaceField(with: replacement, selectAll: false)
            } else {
                TextInserter.insert(replacement, deletingBefore: deleteBeforeCount)
            }
        }
        synonymMenuTarget = target

        for (index, alt) in alternatives.enumerated() {
            let item = NSMenuItem(
                title: alt,
                action: #selector(SynonymMenuTarget.pickItem(_:)),
                keyEquivalent: index < 9 ? "\(index + 1)" : ""
            )
            item.keyEquivalentModifierMask = []
            item.target = target
            item.representedObject = alt
            menu.addItem(item)
        }

        let screen = NSScreen.screens.first(where: { $0.frame.contains(caretRect.origin) }) ?? NSScreen.main
        let fallbackPoint = NSEvent.mouseLocation
        let anchorPoint: NSPoint
        if caretRect.width > 0 || caretRect.height > 0 {
            let clampedY = screen.map { max($0.visibleFrame.minY + 40, caretRect.minY - 6) } ?? (caretRect.minY - 6)
            anchorPoint = NSPoint(x: caretRect.minX, y: clampedY)
        } else {
            anchorPoint = fallbackPoint
        }
        menu.popUp(positioning: nil, at: anchorPoint, in: nil)
    }

    func dismissSuggestion() {
        cancelPendingWork()
        activeSuggestion = nil
        lastTypoWordRect = nil
        GhostOverlayPanel.shared.hide()
    }

    private func cancelPendingWork() {
        debounceTask?.cancel()
        debounceTask = nil
        inferenceTask?.cancel()
        inferenceTask = nil
        _ = engine.cancelActiveGeneration()
    }

    private func scheduleEvaluation(delayMs: Int? = nil) {
        cancelPendingWork()
        guard preferences.triggerMode == .afterPause else { return }
        if let until = escapePausedUntil, until > Date() {
            return
        }
        let delay = delayMs ?? preferences.debounceMilliseconds
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            self.evaluateFocusedField(manualInvoke: false)
        }
    }

    private func evaluateFocusedField(manualInvoke: Bool = false) {
        isSecureInputActive = TextContextReader.isSecureEventInputActive
        guard preferences.isEnabled, !SuggestionPanel.shared.isVisible else { return }
        if !manualInvoke {
            guard preferences.triggerMode == .afterPause else { return }
            if let until = escapePausedUntil, until > Date() { return }
        }

        guard let snapshot = TextContextReader.readFocusedContext() else { return }
        guard !preferences.excludedBundleIDs.contains(snapshot.bundleID) else { return }

        lastSnapshotBundleID = snapshot.bundleID
        lastSnapshotAppName = snapshot.appName

        // 1. Instant Emoji Shortcode Match (0ms, no LLM needed).
        if preferences.emojiSuggestions,
           let emojiSuggestion = EmojiCatalog.match(prefix: snapshot.prefix, skinTone: preferences.emojiSkinTone) {
            present(emojiSuggestion, snapshot: snapshot)
            return
        }

        // 2. Gentle Autocorrect / Typo Holdback (renders Cotypist-style inline red strikethrough + green fix).
        if !manualInvoke && preferences.autocorrectEnabled, let fix = AutocorrectHelper.check(prefix: snapshot.prefix) {
            var typoRect: CGRect?
            if case .autocorrect(let replaceLen, let original) = fix.kind {
                typoRect = TextContextReader.screenBoundsOfWordBeforeCaret(
                    of: snapshot.element,
                    caretUTF16: snapshot.caretLocationUTF16,
                    replaceLengthUTF16: replaceLen,
                    wordUTF16Length: original.utf16.count
                )
            }
            present(fix, snapshot: snapshot, typoWordRect: typoRect)
            return
        }

        // 3. Local LLM Completion with Writing Style & Personal Vocabulary Personalization.
        let triggerAllowed = manualInvoke
            ? (!snapshot.prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && snapshot.selectionLengthUTF16 == 0)
            : AutocompleteCore.SuggestionState.shouldTriggerCompletion(
                prefix: snapshot.prefix,
                suffix: snapshot.suffix,
                selectionLength: snapshot.selectionLengthUTF16,
                allowMidLine: preferences.allowMidLine
            )
        guard triggerAllowed else {
            return
        }

        guard let model = selectedModel else {
            engineState = .noModel
            return
        }

        let clipboard: String? = preferences.useClipboardContext
            ? NSPasteboard.general.string(forType: .string)
            : nil

        let screenInfo: (pageURL: String?, screenContext: String?) = preferences.useScreenContext
            ? TextContextReader.readScreenContext(for: snapshot)
            : (nil, nil)

        let styleSamples = historyStore.relevantSamples(
            forPrefix: snapshot.prefix,
            bundleID: snapshot.bundleID,
            strength: preferences.personalizationStrength
        )

        let personalVocab: [String]
        if preferences.personalizeWordChoice && preferences.personalizationStrength != .off {
            let lang = TypingHistoryStore.detectLanguage(snapshot.prefix)
            personalVocab = historyStore.topVocabularyWords(
                forLanguage: lang,
                limit: preferences.personalizationStrength.maxVocabularyWords
            ).filter { AutocorrectHelper.autoCorrectTypedWord($0) == nil }
        } else {
            personalVocab = []
        }

        let maxLength = preferences.maxCompletionLength
        let context = CompletionContext(
            prefix: snapshot.prefix,
            suffix: snapshot.suffix,
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            pageURL: screenInfo.pageURL,
            screenContext: screenInfo.screenContext,
            clipboard: clipboard,
            userPrompt: preferences.userPrompt,
            appPrompt: preferences.promptForApp(snapshot.bundleID),
            styleSamples: styleSamples,
            personalVocabulary: personalVocab,
            maxLength: maxLength,
            allowMidLine: preferences.allowMidLine
        )

        let config = GenerationConfig(
            maxTokens: maxLength.maxTokens,
            loraPath: preferences.loraAdapterPath,
            loraScale: Float(preferences.loraScale)
        )

        let genID = engine.cancelActiveGeneration()
        let expectedPrefix = snapshot.prefix
        let expectedBundleID = snapshot.bundleID

        if case .idle = engineState {
            engineState = .loading(modelName: model.name)
        }

        inferenceTask = Task {
            do {
                let result = try await engine.complete(
                    context: context,
                    modelURL: model.url,
                    config: config,
                    generationID: genID
                )
                guard !Task.isCancelled else { return }

                let status = await engine.status
                self.engineState = .ready(modelName: model.name, usingGPU: status.usingGPU)
                self.isLoraActive = status.loraActive
                self.updateLoadedMemory(for: model)
                self.scheduleIdleUnload(modelName: model.name)

                guard let text = result, !text.isEmpty else { return }

                // Re-read caret right before showing to make sure the user did not move or switch apps.
                guard let fresh = TextContextReader.readFocusedContext(),
                      fresh.bundleID == expectedBundleID,
                      fresh.prefix == expectedPrefix,
                      fresh.selectionLengthUTF16 == 0,
                      !SuggestionPanel.shared.isVisible else {
                    return
                }

                self.present(
                    ActiveSuggestion(text: text, kind: .completion, anchorPrefix: fresh.prefix),
                    snapshot: fresh
                )
            } catch {
                guard !Task.isCancelled else { return }
                self.logger.error("Autocomplete inference error: \(error.localizedDescription, privacy: .public)")
                self.engineState = .error(error.localizedDescription)
            }
        }
    }

    private func present(_ suggestion: ActiveSuggestion, snapshot: FocusedTextSnapshot, typoWordRect: CGRect? = nil) {
        activeSuggestion = suggestion
        lastCaretRect = snapshot.caretScreenRect
        lastTypography = snapshot.typography
        lastTypoWordRect = typoWordRect
        GhostOverlayPanel.shared.show(
            suggestion: suggestion,
            at: snapshot.caretScreenRect,
            typography: snapshot.typography,
            typoWordRect: typoWordRect,
            acceptBadge: preferences.acceptShortcut.badge,
            showShortcutHint: preferences.showShortcutHints
        )
    }

    private func eventUnicodeString(_ event: CGEvent) -> String? {
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 && length <= 8 else { return nil }
        var chars = [UniChar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: length)
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: (Double) -> Void
    let onComplete: (URL?, Error?) -> Void
    private var finished = false

    init(onProgress: @escaping (Double) -> Void, onComplete: @escaping (URL?, Error?) -> Void) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Move to a stable temp file because URLSession deletes `location` once this method returns.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("hme-model-\(UUID().uuidString).gguf")
        do {
            try FileManager.default.copyItem(at: location, to: copy)
            finished = true
            onComplete(copy, nil)
        } catch {
            finished = true
            onComplete(nil, error)
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        onComplete(nil, error)
        session.finishTasksAndInvalidate()
    }
}

@MainActor
private final class SynonymMenuTarget: NSObject {
    let onPick: (String) -> Void

    init(onPick: @escaping (String) -> Void) {
        self.onPick = onPick
    }

    @objc func pickItem(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String {
            onPick(value)
        }
    }
}
