import AppKit
import AutocompleteCore
import Carbon
import Foundation
import LayoutSwitcherCore
import Observation
import os

/// Main orchestrator for the native Caramba Switcher replacement inside KeyVeil.
/// Manages LogosModel, SwitcherPipeline, Carbon TIS input sources, CGEventTap,
/// modifier gestures (Option, Double Shift, Single Shift, Left+Right Shift),
/// Cmd+Shift+V plain paste, Secure Input detection, and live UI state.
@MainActor
@Observable
final class SwitcherController {
    static let shared = SwitcherController()

    private(set) var isModelLoaded = false
    private(set) var modelVersion = "—"
    private(set) var isEventTapActive = false
    private(set) var isSecureInputActive = false
    private(set) var currentLanguage: SwitcherLanguage = .english
    private(set) var currentLayoutName = "U.S."
    private(set) var frontmostAppName = ""
    private(set) var frontmostBundleID = ""
    private(set) var lastExternalAppName = ""
    private(set) var lastExternalBundleID = ""
    private(set) var frontmostPolicy: AppSwitchPolicy = .normal
    private(set) var lastAction: SwitcherAction?
    private(set) var switchCountToday = 0
    private(set) var correctionCountToday = 0
    private(set) var lastError: String?

    @ObservationIgnored let preferences = SwitcherPreferences.shared
    @ObservationIgnored private(set) var pipeline: SwitcherPipeline?
    @ObservationIgnored private let inputSources = InputSourceManager()
    @ObservationIgnored private let retypeQueue = DispatchQueue(label: "com.nikolenko.KeyVeil.retype", qos: .userInteractive)
    @ObservationIgnored private let logger = Logger(subsystem: "com.nikolenko.HideMyEmail", category: "LayoutSwitcher")

    @ObservationIgnored private var eventTap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var isRetyping = false
    @ObservationIgnored private var pendingFastKeys: [(keyCode: UInt16, isShifted: Bool)] = []
    @ObservationIgnored private var secureInputTimer: Timer?
    @ObservationIgnored private var workspaceObserver: NSObjectProtocol?

    // Gesture state: Option and Shift are tracked completely independently so shortcuts like
    // Option+Shift+Left (word selection) can never cross-contaminate Option release detection.
    @ObservationIgnored private var leftShiftDown = false
    @ObservationIgnored private var rightShiftDown = false
    @ObservationIgnored private var shiftGestureInterrupted = false
    @ObservationIgnored private var splitShiftTriggered = false
    @ObservationIgnored private var shiftDownTime: TimeInterval = 0
    @ObservationIgnored private var lastCleanShiftTapTime: TimeInterval = 0
    @ObservationIgnored private var pendingSingleShiftTask: Task<Void, Never>?

    @ObservationIgnored private var optionCleanDown = false
    @ObservationIgnored private var optionDownTime: TimeInterval = 0
    @ObservationIgnored private var pendingManualSwitchAfterRetype = false

    private struct SelectionUndoRecord {
        let displayedText: String
        let revertText: String
        let revertLanguage: SwitcherLanguage
    }
    @ObservationIgnored private var lastSelectionUndo: SelectionUndoRecord?

    private init() {}

    func start() {
        loadModelIfNeeded()
        configureInputSources()
        observeFrontmostApp()
        refreshSecureInputState()
        startSecureInputMonitor()
        installEventTapIfPossible()
    }

    func restartEventTap() {
        stopEventTap()
        installEventTapIfPossible()
    }

    func loadModelIfNeeded() {
        guard pipeline == nil else { return }
        do {
            let model = try LogosModel.loadBundled()
            let liveMap = inputSources.buildLiveLayoutMap()
            pipeline = SwitcherPipeline(model: model, layoutMap: liveMap)
            modelVersion = model.version
            isModelLoaded = true
            lastError = nil
            logger.notice("Loaded Logos model \(model.version, privacy: .public) (KBM featureSets=\(model.kbm.featureSets.count), autocorrect=\(model.autocorrect.rules.count))")
        } catch {
            lastError = error.localizedDescription
            isModelLoaded = false
            logger.error("Failed to load Logos model: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func configureInputSources() {
        let (lang, name) = inputSources.currentLayoutSnapshot()
        currentLanguage = lang
        currentLayoutName = name

        inputSources.onLayoutChanged = { [weak self] lang, name in
            guard let self else { return }
            self.currentLanguage = lang
            self.currentLayoutName = name
        }
        inputSources.onLayoutMapRebuilt = { [weak self] newMap in
            self?.pipeline?.layoutMap = newMap
        }
    }

    private func observeFrontmostApp() {
        updateFrontmostApp(NSWorkspace.shared.frontmostApplication)
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.handleAppActivated(app)
            }
        }
    }

    private func handleAppActivated(_ app: NSRunningApplication?) {
        optionCleanDown = false
        shiftGestureInterrupted = true
        lastSelectionUndo = nil
        pipeline?.resetAll()
        updateFrontmostApp(app)
        refreshSecureInputState()

        // Caramba Feats: auto-switch to English when focusing terminals (Terminal, iTerm2, Alacritty, etc.)
        if preferences.isEnabled,
           preferences.switchToEnglishInTerminals,
           let pipeline,
           let app,
           pipeline.appex.shouldSwitchToEnglishOnFocus(
               bundleIdentifier: app.bundleIdentifier,
               executablePath: app.executableURL?.path,
               appName: app.localizedName
           ),
           currentLanguage != .english {
            _ = inputSources.select(
                language: .english,
                retries: pipeline.model.feats.layoutSwitchNumRetries,
                retryDelayMs: pipeline.model.feats.layoutSwitchRetryDelayMs
            )
        }
    }

    private func updateFrontmostApp(_ app: NSRunningApplication?) {
        frontmostAppName = app?.localizedName ?? ""
        frontmostBundleID = app?.bundleIdentifier ?? ""
        if let bid = app?.bundleIdentifier, bid != Bundle.main.bundleIdentifier {
            lastExternalBundleID = bid
            lastExternalAppName = app?.localizedName ?? bid
        }
        guard let pipeline else {
            frontmostPolicy = .normal
            return
        }
        frontmostPolicy = pipeline.appex.policy(
            bundleIdentifier: app?.bundleIdentifier,
            executablePath: app?.executableURL?.path,
            windowTitle: nil,
            userExcludedBundleIDs: preferences.excludedAppBundleIDs,
            useBuiltInRules: preferences.useBuiltInAppExceptions
        )
    }

    func isAppExcluded(_ bundleID: String) -> Bool {
        preferences.excludedAppBundleIDs.contains(bundleID)
    }

    func toggleExcluded(bundleID: String) {
        if preferences.excludedAppBundleIDs.contains(bundleID) {
            preferences.excludedAppBundleIDs.remove(bundleID)
        } else {
            preferences.excludedAppBundleIDs.insert(bundleID)
        }
        updateFrontmostApp(NSWorkspace.shared.frontmostApplication)
    }

    private func startSecureInputMonitor() {
        secureInputTimer?.invalidate()
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSecureInputState()
            }
        }
    }

    func refreshSecureInputState() {
        isSecureInputActive = IsSecureEventInputEnabled()
    }

    // MARK: - User Actions (UI & Shortcuts)

    func toggleEnabled(showHUD: Bool = false) {
        preferences.isEnabled.toggle()
        lastSelectionUndo = nil
        pipeline?.resetAll()
        if showHUD {
            let msg = preferences.isEnabled
                ? String(localized: "Autoswitching On")
                : String(localized: "Autoswitching Off")
            Toast.show(msg, symbol: preferences.isEnabled ? "keyboard.badge.ellipsis" : "keyboard", tint: preferences.isEnabled ? .green : .secondary)
        }
    }

    func switchActiveLayout() {
        let next = currentLanguage.opposite
        let retries = pipeline?.model.feats.layoutSwitchNumRetries ?? 2
        let retryDelay = pipeline?.model.feats.layoutSwitchRetryDelayMs ?? 25
        _ = inputSources.select(language: next, retries: retries, retryDelayMs: retryDelay)
    }

    func triggerManualSwitch() {
        guard let pipeline, !isRetyping else { return }
        if IsSecureEventInputEnabled() || frontmostPolicy == .disableAll { return }

        AutocompleteController.shared.dismissSuggestion()

        let (activeLang, activeName) = inputSources.currentLayoutSnapshot()
        if activeLang != currentLanguage || activeName != currentLayoutName {
            currentLanguage = activeLang
            currentLayoutName = activeName
        }

        let feats = pipeline.model.feats

        // 1. Caramba Switcher Pro exact order (0x100253894):
        //    When a freshly typed word is in the buffer (not cleared by click/arrow/Enter/shortcut),
        //    switch it directly in place without touching the clipboard or being fooled by browser
        //    URL-bar inline autocomplete selection.
        if pipeline.hasLastWord,
           let action = pipeline.manualSwitchLastWord(currentLanguage: activeLang) {
            lastSelectionUndo = nil
            if let learned = action.learnedException, preferences.autoLearnRevertedWords {
                preferences.addWordException(learned)
            }
            logger.info("Manual Option/DoubleShift -> typed word switch (\(action.kind.rawValue, privacy: .public))")
            executeRetype(action: action)
            return
        }

        // 2. Word buffer is empty (user selected text via mouse/arrows/Cmd+A, or just converted a selection).
        //    Fast non-destructive AX selection read first, ALWAYS replaced via Cmd+V (never unreliable AX write).
        if let axSelected = TextRetypingEngine.readSelectedText(),
           let converted = pipeline.convertSelection(axSelected, fallbackLanguage: activeLang) {
            isRetyping = true
            let action = SwitcherAction(
                kind: .manualSwitch,
                originalWord: axSelected,
                replacementWord: converted.converted,
                backspaces: 0,
                textToType: converted.converted,
                targetLanguage: converted.targetLanguage,
                learnedException: nil
            )
            let nextUndo = Self.makeSelectionUndo(
                displayed: converted.converted,
                revert: axSelected,
                revertLanguage: converted.targetLanguage.opposite
            )
            logger.info("Manual Option/DoubleShift -> selection switch (AX read + Cmd+V)")
            retypeQueue.async { [weak self] in
                self?.selectLayoutFromBackground(
                    converted.targetLanguage,
                    retries: feats.layoutSwitchNumRetries,
                    retryDelayMs: feats.layoutSwitchRetryDelayMs
                )
                TextRetypingEngine.replaceSelectedText(
                    with: converted.converted,
                    savedPasteboard: nil
                )
                DispatchQueue.main.async {
                    self?.lastSelectionUndo = nextUndo
                    self?.finishAction(action)
                }
            }
            return
        }

        // 2.5. Accessibility trailing-word fallback: if the keystroke buffer was cleared
        //      (e.g. by layout hotkey, autocomplete accept, mouse click, or multiple spaces)
        //      and nothing is selected, read the word immediately before the caret (e.g. "ssd ")
        //      and switch it directly in place.
        if let snapshot = TextContextReader.readFocusedContext(),
           snapshot.selectionLengthUTF16 == 0,
           let (word, trailingSpaces) = SwitcherPipeline.extractTrailingWord(from: snapshot.prefix) {
            let detectedLang = pipeline.layoutMap.detectDominantLanguage(word, fallback: activeLang)
            pipeline.seedLastWord(word: word, trailingBoundary: trailingSpaces, language: detectedLang)
            if let action = pipeline.manualSwitchLastWord(currentLanguage: detectedLang) {
                lastSelectionUndo = nil
                logger.info("Manual Option/DoubleShift -> AX trailing-word switch")
                executeRetype(action: action)
                return
            }
        }

        // 3. Universal Caramba clipboard selection_switch (0x10025935c) for Electron/Chromium/Firefox/Terminal
        //    and all apps that do not expose AXSelectedTextAttribute — with fallback to immediate undo toggle
        //    if the user presses Option a second time right after converting a single-line selection.
        let pendingUndo = lastSelectionUndo
        isRetyping = true
        retypeQueue.async { [weak self] in
            if let captured = TextRetypingEngine.readSelectedTextViaClipboard() {
                let converted = DispatchQueue.main.sync {
                    self?.pipeline?.convertSelection(captured.text, fallbackLanguage: activeLang)
                }
                guard let converted else {
                    TextRetypingEngine.restorePasteboard(captured.savedPasteboard)
                    DispatchQueue.main.async { self?.isRetyping = false }
                    return
                }
                self?.selectLayoutFromBackground(
                    converted.targetLanguage,
                    retries: feats.layoutSwitchNumRetries,
                    retryDelayMs: feats.layoutSwitchRetryDelayMs
                )
                TextRetypingEngine.replaceSelectedText(
                    with: converted.converted,
                    savedPasteboard: captured.savedPasteboard
                )
                let action = SwitcherAction(
                    kind: .manualSwitch,
                    originalWord: captured.text,
                    replacementWord: converted.converted,
                    backspaces: 0,
                    textToType: converted.converted,
                    targetLanguage: converted.targetLanguage,
                    learnedException: nil
                )
                let nextUndo = Self.makeSelectionUndo(
                    displayed: converted.converted,
                    revert: captured.text,
                    revertLanguage: converted.targetLanguage.opposite
                )
                DispatchQueue.main.async {
                    self?.logger.info("Manual Option/DoubleShift -> selection switch (Cmd+C + Cmd+V)")
                    self?.lastSelectionUndo = nextUndo
                    self?.finishAction(action)
                }
                return
            }

            // Nothing currently selected: if user immediately tapped Option again after converting
            // a single-line selection, cleanly toggle it back.
            if let undo = pendingUndo {
                self?.selectLayoutFromBackground(
                    undo.revertLanguage,
                    retries: feats.layoutSwitchNumRetries,
                    retryDelayMs: feats.layoutSwitchRetryDelayMs
                )
                TextRetypingEngine.replaceTrailingTextViaClipboard(
                    backspaceCount: undo.displayedText.count,
                    replacement: undo.revertText
                )
                let action = SwitcherAction(
                    kind: .manualSwitch,
                    originalWord: undo.displayedText,
                    replacementWord: undo.revertText,
                    backspaces: undo.displayedText.count,
                    textToType: undo.revertText,
                    targetLanguage: undo.revertLanguage,
                    learnedException: nil
                )
                let flippedUndo = Self.makeSelectionUndo(
                    displayed: undo.revertText,
                    revert: undo.displayedText,
                    revertLanguage: undo.revertLanguage.opposite
                )
                DispatchQueue.main.async {
                    self?.logger.info("Manual Option/DoubleShift -> toggled prior selection")
                    self?.lastSelectionUndo = flippedUndo
                    self?.finishAction(action)
                }
                return
            }

            DispatchQueue.main.async {
                self?.isRetyping = false
            }
        }
    }

    private nonisolated static func makeSelectionUndo(
        displayed: String,
        revert: String,
        revertLanguage: SwitcherLanguage
    ) -> SelectionUndoRecord? {
        guard displayed.count <= 80,
              !displayed.contains("\n"),
              !displayed.contains("\r"),
              !displayed.contains("\t") else {
            return nil
        }
        return SelectionUndoRecord(
            displayedText: displayed,
            revertText: revert,
            revertLanguage: revertLanguage
        )
    }

    private nonisolated func selectLayoutFromBackground(
        _ language: SwitcherLanguage,
        retries: Int,
        retryDelayMs: Int
    ) {
        let attempts = max(0, retries)
        for attempt in 0...attempts {
            let ok = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    self.inputSources.selectOnce(language: language)
                }
            }
            if ok { return }
            if attempt < attempts {
                Thread.sleep(forTimeInterval: Double(retryDelayMs) / 1000.0)
            }
        }
    }

    func excludeLastActionWord() {
        guard let last = lastAction else { return }
        preferences.addWordException(last.originalWord)
        Toast.show(String(localized: "Added “\(last.originalWord)” to exceptions"), symbol: "hand.raised.fill", tint: .accentColor)
    }

    @discardableResult
    func importFromCaramba() -> CarambaImportSummary {
        importFromCaramba(explicitPath: nil)
    }

    func importFromCaramba(explicitPath: String?) -> CarambaImportSummary {
        let summary = CarambaImporter.importExceptions(from: explicitPath)
        preferences.applyImportedCaramba(summary)
        return summary
    }

    func diagnoseTestInput(_ text: String, language: SwitcherLanguage) -> PipelineDiagnostics? {
        pipeline?.diagnose(
            word: text,
            currentLanguage: language,
            config: preferences.pipelineConfiguration(),
            isCompleteWord: true
        )
    }

    // MARK: - CGEventTap

    private func installEventTapIfPossible() {
        guard AX.isTrusted else {
            isEventTapActive = false
            return
        }
        guard eventTap == nil else {
            isEventTapActive = true
            return
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<SwitcherController>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                controller.handleEvent(type: type, event: event)
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            isEventTapActive = false
            logger.error("Failed to create CGEventTap (Accessibility / Input Monitoring required)")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.isEventTapActive = true
        logger.notice("LayoutSwitcher CGEventTap active (enabled=\(self.preferences.isEnabled), singleShift=\(self.preferences.singleShiftEnabled), manual=\(self.preferences.manualTrigger.rawValue, privacy: .public))")
    }

    private func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isEventTapActive = false
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable automatically if macOS disabled the tap due to momentary system load.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Ignore our own synthetic retype / clipboard events and Autocomplete's synthetic events!
        let userData = event.getIntegerValueField(.eventSourceUserData)
        if userData == TextRetypingEngine.syntheticEventTag || userData == TextInserter.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        // Queue regular user keystrokes that arrive during the brief ~60ms retype window
        // so fast typists never drop or scramble letters, then replay them in the new layout.
        if isRetyping {
            if type == .flagsChanged {
                syncModifierStateDuringRetype(event)
                return Unmanaged.passUnretained(event)
            }
            if type == .leftMouseDown || type == .rightMouseDown {
                optionCleanDown = false
                shiftGestureInterrupted = true
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown {
                optionCleanDown = false
                shiftGestureInterrupted = true
                let flags = event.flags
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                if !flags.contains(.maskCommand) && !flags.contains(.maskControl) && !flags.contains(.maskAlternate)
                    && pendingFastKeys.count < 32 {
                    let isShifted = flags.contains(.maskShift) || flags.contains(.maskAlphaShift)
                    pendingFastKeys.append((keyCode: keyCode, isShifted: isShifted))
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Mouse clicks move the caret or create a selection -> clear both buffer and lastWord
        // so Option switches the new selection instead of a stale word typed earlier.
        if type == .leftMouseDown || type == .rightMouseDown {
            optionCleanDown = false
            shiftGestureInterrupted = true
            lastSelectionUndo = nil
            pipeline?.resetAll()
            return Unmanaged.passUnretained(event)
        }

        // Never inspect or transform input while Secure Input (password field) is active.
        if IsSecureEventInputEnabled() {
            if !isSecureInputActive { isSecureInputActive = true }
            optionCleanDown = false
            shiftGestureInterrupted = true
            lastSelectionUndo = nil
            pipeline?.resetAll()
            return Unmanaged.passUnretained(event)
        } else if isSecureInputActive {
            isSecureInputActive = false
        }

        if type == .flagsChanged {
            handleFlagsChanged(event)
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            return handleKeyDown(event)
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Modifier Gestures (Option, Double Shift, Single Shift, Left+Right Shift)

    private func syncModifierStateDuringRetype(_ event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let rawFlags = flags.rawValue
        let primaryMods = flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
        let hasFn = flags.contains(.maskSecondaryFn)
        let now = ProcessInfo.processInfo.systemUptime

        if keyCode == UInt16(kVK_Option) || keyCode == UInt16(kVK_RightOption) {
            shiftGestureInterrupted = true
            if primaryMods == .maskAlternate && !hasFn {
                if !optionCleanDown {
                    optionCleanDown = true
                    optionDownTime = now
                }
            } else if primaryMods.isEmpty && !hasFn {
                if optionCleanDown {
                    optionCleanDown = false
                    if now - optionDownTime < 0.50,
                       preferences.manualTrigger == .option || preferences.manualTrigger == .both {
                        pendingManualSwitchAfterRetype = true
                    }
                }
            } else {
                optionCleanDown = false
            }
            return
        }

        optionCleanDown = false
        shiftGestureInterrupted = true
        let hwLeftShift: UInt64 = 0x0000_0002
        let hwRightShift: UInt64 = 0x0000_0004
        if !flags.contains(.maskShift) {
            leftShiftDown = false
            rightShiftDown = false
            splitShiftTriggered = false
        } else if (rawFlags & (hwLeftShift | hwRightShift)) != 0 {
            leftShiftDown = (rawFlags & hwLeftShift) != 0
            rightShiftDown = (rawFlags & hwRightShift) != 0
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let rawFlags = flags.rawValue
        let now = ProcessInfo.processInfo.systemUptime

        // Hardware device-dependent shift masks distinguish Left vs Right Shift for LShift+RShift.
        let hwLeftShift: UInt64 = 0x0000_0002
        let hwRightShift: UInt64 = 0x0000_0004

        // Device-independent primary modifier mask (matches Caramba 0x100252f58: 0x1e0000 =
        // Shift | Control | Option | Command), keeping external/Logitech keyboards 100% reliable.
        let primaryMods = flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
        let hasCmdOrCtrl = flags.contains(.maskCommand) || flags.contains(.maskControl)
        let hasFn = flags.contains(.maskSecondaryFn)

        switch keyCode {
        case UInt16(kVK_Shift), UInt16(kVK_RightShift):
            // Any Shift transition invalidates a pending Option-only tap (fixes Option+Shift+Left).
            optionCleanDown = false

            let isLeft = (keyCode == UInt16(kVK_Shift))
            let hasDeviceShiftBits = (rawFlags & (hwLeftShift | hwRightShift)) != 0
            let thisSideDown: Bool
            if hasDeviceShiftBits {
                thisSideDown = (rawFlags & (isLeft ? hwLeftShift : hwRightShift)) != 0
            } else {
                thisSideDown = flags.contains(.maskShift)
            }

            if isLeft {
                if !leftShiftDown && thisSideDown {
                    leftShiftDown = true
                    shiftDownTime = now
                    if !rightShiftDown {
                        shiftGestureInterrupted = hasCmdOrCtrl || flags.contains(.maskAlternate) || hasFn
                    }
                } else if leftShiftDown && !thisSideDown {
                    leftShiftDown = false
                    handleShiftReleased(now: now)
                }
            } else {
                if !rightShiftDown && thisSideDown {
                    rightShiftDown = true
                    shiftDownTime = now
                    if !leftShiftDown {
                        shiftGestureInterrupted = hasCmdOrCtrl || flags.contains(.maskAlternate) || hasFn
                    }
                } else if rightShiftDown && !thisSideDown {
                    rightShiftDown = false
                    handleShiftReleased(now: now)
                }
            }

            // Left Shift + Right Shift simultaneously -> toggle Autoswitching ON/OFF!
            if leftShiftDown && rightShiftDown && !shiftGestureInterrupted && !splitShiftTriggered {
                if preferences.splitShiftToggleEnabled {
                    splitShiftTriggered = true
                    pendingSingleShiftTask?.cancel()
                    toggleEnabled(showHUD: true)
                }
            }

            if !leftShiftDown && !rightShiftDown {
                splitShiftTriggered = false
            }

        case UInt16(kVK_Option), UInt16(kVK_RightOption):
            // Pressing Option interrupts any active Shift gesture.
            shiftGestureInterrupted = true

            if primaryMods == .maskAlternate && !hasFn {
                if !optionCleanDown {
                    optionCleanDown = true
                    optionDownTime = now
                }
            } else if primaryMods.isEmpty && !hasFn {
                if optionCleanDown {
                    optionCleanDown = false
                    let elapsed = now - optionDownTime
                    if elapsed < 0.50 {
                        if preferences.manualTrigger == .option || preferences.manualTrigger == .both {
                            DispatchQueue.main.async { [weak self] in
                                self?.triggerManualSwitch()
                            }
                        }
                    }
                }
            } else {
                optionCleanDown = false
            }

        default:
            optionCleanDown = false
            shiftGestureInterrupted = true
        }
    }

    private func handleShiftReleased(now: TimeInterval) {
        guard !leftShiftDown && !rightShiftDown else { return }
        if splitShiftTriggered || shiftGestureInterrupted {
            shiftGestureInterrupted = false
            return
        }
        let pressDuration = now - shiftDownTime
        guard pressDuration < 0.40 else { return }

        let doubleShiftAllowed = (preferences.manualTrigger == .doubleShift || preferences.manualTrigger == .both)
        let sinceLastTap = now - lastCleanShiftTapTime

        if doubleShiftAllowed && sinceLastTap < 0.42 {
            // Double Shift detected!
            lastCleanShiftTapTime = 0
            pendingSingleShiftTask?.cancel()
            pendingSingleShiftTask = nil
            DispatchQueue.main.async { [weak self] in
                self?.triggerManualSwitch()
            }
            return
        }

        lastCleanShiftTapTime = now

        if preferences.singleShiftEnabled {
            pendingSingleShiftTask?.cancel()
            let nextLang = currentLanguage.opposite
            let retries = pipeline?.model.feats.layoutSwitchNumRetries ?? 2
            let retryDelay = pipeline?.model.feats.layoutSwitchRetryDelayMs ?? 25
            if doubleShiftAllowed {
                // Brief grace window to distinguish Single Shift from Double Shift.
                pendingSingleShiftTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(260))
                    guard !Task.isCancelled, let self else { return }
                    self.pipeline?.resetBuffer()
                    if self.inputSources.select(language: nextLang, retries: retries, retryDelayMs: retryDelay) {
                        self.currentLanguage = nextLang
                    }
                }
            } else {
                // Dispatch off the synchronous CGEventTap callback so HIToolbox finishes
                // Shift-up cleanly and the tap never blocks on TIS retries.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pipeline?.resetBuffer()
                    if self.inputSources.select(language: nextLang, retries: retries, retryDelayMs: retryDelay) {
                        self.currentLanguage = nextLang
                    }
                }
            }
        }
    }

    // MARK: - KeyDown Handling

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        optionCleanDown = false
        shiftGestureInterrupted = true
        lastSelectionUndo = nil
        pendingSingleShiftTask?.cancel()
        pendingSingleShiftTask = nil

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Caramba feature: Paste without formatting on configurable hotkey (Cmd+Shift+V, Cmd+V, Cmd+Option+Shift+V)!
        if matchesPastePlainTextShortcut(keyCode: keyCode, flags: flags) {
            pipeline?.resetAll()
            isRetyping = true
            retypeQueue.async { [weak self] in
                TextRetypingEngine.pasteWithoutFormatting()
                DispatchQueue.main.async { self?.isRetyping = false }
            }
            return nil // swallow original plain-paste shortcut
        }

        // Ignore any Cmd/Ctrl/Option shortcuts (including Cmd+A, Cmd+C, Cmd+V, Option+Left)
        // and clear both buffer and lastWord so Option switches selections cleanly.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            pipeline?.resetAll()
            return Unmanaged.passUnretained(event)
        }

        guard let pipeline else {
            return Unmanaged.passUnretained(event)
        }

        // Backspace
        if keyCode == UInt16(kVK_Delete) {
            pipeline.handleBackspace()
            return Unmanaged.passUnretained(event)
        }

        // Caret-moving / selection / Escape keys clear both buffer and lastWord.
        let resetKeyCodes: Set<UInt16> = [
            UInt16(kVK_Escape), UInt16(kVK_ForwardDelete),
            UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow),
            UInt16(kVK_UpArrow), UInt16(kVK_DownArrow),
            UInt16(kVK_Home), UInt16(kVK_End),
            UInt16(kVK_PageUp), UInt16(kVK_PageDown),
        ]
        if resetKeyCodes.contains(keyCode) {
            pipeline.resetAll()
            return Unmanaged.passUnretained(event)
        }

        // Refresh live active layout snapshot (cheap Carbon lookup) so manual macOS switches stay in sync.
        let (activeLang, activeName) = inputSources.currentLayoutSnapshot()
        if activeLang != currentLanguage || activeName != currentLayoutName {
            currentLanguage = activeLang
            currentLayoutName = activeName
        }

        let config = preferences.pipelineConfiguration()
        let policy = frontmostPolicy

        // Word boundary keys: Space, Return, Enter, Tab
        if keyCode == UInt16(kVK_Space) || keyCode == UInt16(kVK_Return)
            || keyCode == UInt16(kVK_ANSI_KeypadEnter) || keyCode == UInt16(kVK_Tab) {
            let boundary: String
            switch keyCode {
            case UInt16(kVK_Space): boundary = " "
            case UInt16(kVK_Tab): boundary = "\t"
            default: boundary = "\n"
            }

            if let action = pipeline.processBoundary(
                boundary,
                currentLanguage: activeLang,
                config: config,
                policy: policy,
                swallowBoundary: true,
                fallbackAutocorrect: { word in
                    AutocorrectHelper.autoCorrectTypedWord(word)
                }
            ) {
                // Swallow the boundary key (Return/Tab/Space) so we convert the word FIRST
                // and then emit the boundary key at the end — preventing premature Enter send
                // in chat apps or premature Tab focus jump in forms.
                DispatchQueue.main.async { [weak self] in
                    self?.executeRetype(action: action)
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // Regular character key: extract typed Unicode character from the CGEvent.
        guard let typed = extractTypedCharacter(from: event) else {
            return Unmanaged.passUnretained(event)
        }

        // Always trust the actual script of the typed letter over Carbon's sometimes-stale
        // background TIS cache so manual layout switches mid-session never blind auto-switching.
        let effectiveLang = SwitcherPipeline.inferCharacterLanguage(typed) ?? pipeline.activeBufferLanguage ?? activeLang
        if effectiveLang != currentLanguage {
            currentLanguage = effectiveLang
        }

        let isShifted = flags.contains(.maskShift) || flags.contains(.maskAlphaShift)
        let stroke = KeyStroke(keyCode: keyCode, shifted: isShifted)

        if let action = pipeline.processCharacter(
            typed,
            stroke: stroke,
            currentLanguage: effectiveLang,
            config: config,
            policy: policy,
            swallowTriggerCharacter: true
        ) {
            if action.kind == .autoSwitch,
               AutocompletePreferences.shared.isEnabled,
               AutocompletePreferences.shared.emojiSuggestions,
               AutocompleteCore.EmojiCatalog.match(prefix: action.originalWord) != nil {
                return Unmanaged.passUnretained(event)
            }
            // Swallow the triggering character so we only backspace the already-displayed
            // prefix and type the converted word cleanly with zero race condition.
            DispatchQueue.main.async { [weak self] in
                self?.executeRetype(action: action)
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func extractTypedCharacter(from event: CGEvent) -> Character? {
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return nil }
        let str = String(utf16CodeUnits: chars, count: length)
        guard let first = str.first, let scalar = first.unicodeScalars.first, scalar.value >= 0x20 else {
            return nil
        }
        return first
    }

    private func executeRetype(action: SwitcherAction) {
        guard let pipeline, !isRetyping else { return }
        AutocompleteController.shared.dismissSuggestion()
        isRetyping = true

        let feats = pipeline.model.feats
        let layoutMap = pipeline.layoutMap
        let activeLang = currentLanguage
        let app = NSWorkspace.shared.frontmostApplication
        let specialBrowser = pipeline.appex.hasSpecialBrowserBehavior(
            bundleIdentifier: app?.bundleIdentifier,
            executablePath: app?.executableURL?.path,
            appName: app?.localizedName
        )

        retypeQueue.async { [weak self] in
            TextRetypingEngine.performRetype(
                action: action,
                feats: feats,
                specialBrowser: specialBrowser,
                layoutMap: layoutMap,
                targetLanguage: activeLang
            ) { [weak self] newLang in
                self?.selectLayoutFromBackground(
                    newLang,
                    retries: feats.layoutSwitchNumRetries,
                    retryDelayMs: feats.layoutSwitchRetryDelayMs
                )
            }
            DispatchQueue.main.async {
                self?.finishAction(action)
            }
        }
    }

    private func finishAction(_ action: SwitcherAction) {
        if let targetLang = action.targetLanguage {
            currentLanguage = targetLang
        }
        lastAction = action
        switch action.kind {
        case .autoSwitch, .manualSwitch, .manualRevert:
            switchCountToday += 1
        case .autocorrect, .yofikator, .doubleCaps:
            correctionCountToday += 1
        }
        if preferences.soundFeedbackEnabled {
            playSubtleSound(for: action.kind)
        }

        let queued = pendingFastKeys
        pendingFastKeys.removeAll(keepingCapacity: true)
        if queued.isEmpty {
            isRetyping = false
            if pendingManualSwitchAfterRetype {
                pendingManualSwitchAfterRetype = false
                triggerManualSwitch()
            }
            return
        }

        guard let pipeline else {
            isRetyping = false
            pendingManualSwitchAfterRetype = false
            return
        }
        let replayLang = action.targetLanguage ?? currentLanguage
        let layoutMap = pipeline.layoutMap
        let config = preferences.pipelineConfiguration()
        let policy = frontmostPolicy
        retypeQueue.async { [weak self] in
            let source = CGEventSource(stateID: .privateState)
            var followUpAction: SwitcherAction?
            for item in queued {
                if item.keyCode == UInt16(kVK_Delete) {
                    TextRetypingEngine.postVirtualKey(CGKeyCode(kVK_Delete), flags: [], source: source)
                    DispatchQueue.main.sync { self?.pipeline?.handleBackspace() }
                } else if item.keyCode == UInt16(kVK_Space) {
                    TextRetypingEngine.postVirtualKey(CGKeyCode(kVK_Space), flags: [], source: source)
                    let next = DispatchQueue.main.sync {
                        self?.pipeline?.processBoundary(
                            " ",
                            currentLanguage: replayLang,
                            config: config,
                            policy: policy,
                            fallbackAutocorrect: { word in
                                AutocorrectHelper.autoCorrectTypedWord(word)
                            }
                        )
                    }
                    if let next { followUpAction = next }
                } else if item.keyCode == UInt16(kVK_Return) || item.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                    TextRetypingEngine.postVirtualKey(CGKeyCode(kVK_Return), flags: [], source: source)
                    let next = DispatchQueue.main.sync {
                        self?.pipeline?.processBoundary("\n", currentLanguage: replayLang, config: config, policy: policy)
                    }
                    if let next { followUpAction = next }
                } else if item.keyCode == UInt16(kVK_Tab) {
                    TextRetypingEngine.postVirtualKey(CGKeyCode(kVK_Tab), flags: [], source: source)
                    let next = DispatchQueue.main.sync {
                        self?.pipeline?.processBoundary("\t", currentLanguage: replayLang, config: config, policy: policy)
                    }
                    if let next { followUpAction = next }
                } else {
                    let stroke = KeyStroke(keyCode: item.keyCode, shifted: item.isShifted)
                    if let ch = layoutMap.character(for: stroke, in: replayLang) {
                        TextRetypingEngine.postCharacter(ch, language: replayLang, layoutMap: layoutMap, source: source)
                        let next = DispatchQueue.main.sync {
                            self?.pipeline?.processCharacter(ch, stroke: stroke, currentLanguage: replayLang, config: config, policy: policy)
                        }
                        if let next { followUpAction = next }
                    }
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRetyping = false
                if let followUpAction {
                    self.executeRetype(action: followUpAction)
                } else if self.pendingManualSwitchAfterRetype {
                    self.pendingManualSwitchAfterRetype = false
                    self.triggerManualSwitch()
                }
            }
        }
    }

    private func playSubtleSound(for kind: SwitcherActionKind) {
        let name: NSSound.Name = (kind == .autoSwitch || kind == .manualSwitch)
            ? NSSound.Name(preferences.soundName)
            : "Pop"
        if let sound = NSSound(named: name) {
            sound.volume = 0.25
            sound.play()
        }
    }

    private func matchesPastePlainTextShortcut(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard keyCode == UInt16(kVK_ANSI_V), !flags.contains(.maskControl) else { return false }
        switch preferences.pastePlainTextShortcut {
        case .off:
            return false
        case .cmdShiftV:
            return flags.contains(.maskCommand) && flags.contains(.maskShift) && !flags.contains(.maskAlternate)
        case .cmdV:
            return flags.contains(.maskCommand) && !flags.contains(.maskShift) && !flags.contains(.maskAlternate)
        case .cmdOptionShiftV:
            return flags.contains(.maskCommand) && flags.contains(.maskShift) && flags.contains(.maskAlternate)
        }
    }
}

