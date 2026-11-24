import AppKit
import DuoCore
import DuoRender
import Observation
import QuartzCore

/// Runs the Mac Duo desktop-fold effect inside KeyVeil with strict multi-display safety.
@MainActor
@Observable
final class DuoFoldController {
    static let shared = DuoFoldController()

    enum Status: Equatable {
        case noSensor
        case needsPermission
        case ready
        case off
    }

    private(set) var angle: Double = 0
    private(set) var isActive = false
    private(set) var isPreviewing = false
    private(set) var sensorAvailable = false
    private(set) var screenRecordingGranted = DuoScreenRecordingPermission.isGranted

    var status: Status {
        if !sensorAvailable { return .noSensor }
        if !screenRecordingGranted { return .needsPermission }
        return preferences.isEnabled ? .ready : .off
    }

    var sensorResolution: String { monitor.resolutionLabel }

    @ObservationIgnored let preferences = DuoPreferences.shared
    @ObservationIgnored private let monitor = DuoLidMonitor()
    @ObservationIgnored private let stream = DuoScreenStream()
    @ObservationIgnored private let snapshot = DuoScreenSnapshot()
    @ObservationIgnored private let overlay = DuoFoldOverlay()
    @ObservationIgnored private var decider: FoldDecider
    @ObservationIgnored private var spring = DampedSpring(frequency: 11)
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastFrame: CFTimeInterval = 0
    @ObservationIgnored private var lastPublish: CFTimeInterval = 0
    @ObservationIgnored private var snapshotTimer: Timer?
    @ObservationIgnored private var captureInFlight = false
    @ObservationIgnored private var streamRestarts = 0
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var isScreenLocked = false
    @ObservationIgnored private var layout: (id: CGDirectDisplayID?, frame: CGRect?) = (nil, nil)
    @ObservationIgnored private var scrubAngle: Double?
    @ObservationIgnored private var reveal: Reveal?
    @ObservationIgnored private var activationTime: CFTimeInterval = 0
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var lastPermission = DuoScreenRecordingPermission.isGranted
    @ObservationIgnored private var drewSettledFrame = false
    @ObservationIgnored private var revealScheduled = false
    @ObservationIgnored private var started = false
    /// Suppresses clamshell re-triggering near 0°..5° after lid shuts while external display stays awake.
    @ObservationIgnored private var clamshellSuppressed = false
    @ObservationIgnored private var displayCallbackRegistered = false

    private struct Reveal {
        let startedAt: CFTimeInterval
        let duration: CFTimeInterval = 0.9
        func progress(at time: CFTimeInterval) -> Double {
            let t = min(max((time - startedAt) / duration, 0), 1)
            return 1 - (1 - pow(1 - t, 3))
        }
        func isOver(at time: CFTimeInterval) -> Bool { time - startedAt >= duration + 0.05 }
    }

    private static let armCeiling: Double = 70
    private static let clamshellCloseThreshold: Double = 5.0
    private static let clamshellReleaseThreshold: Double = 15.0

    private init() {
        decider = FoldDecider(startAngle: DuoPreferences.shared.effect.startAngle)
    }

    func start() {
        guard !started else { return }
        started = true
        sensorAvailable = monitor.isAvailable
        DuoLog.app.notice("MacDuo start: sensor \(self.sensorAvailable), screenRecording \(DuoScreenRecordingPermission.isGranted), model \(DuoMacModel.identifier, privacy: .public)")
        overlay.warmUp()
        observeSystem()
        registerDisplayReconfigurationCallback()
        watchPermission()
        guard sensorAvailable else { return }
        monitor.onSample = { [weak self] tracker, time in self?.handle(tracker: tracker, at: time) }
        monitor.onOverrideEnded = { [weak self] in
            guard let self, self.isPreviewing, self.scrubAngle == nil else { return }
            self.finishPreview()
        }
        monitor.onFailure = { [weak self] in self?.endFold(animated: false) }
        stream.onInterruption = { [weak self] in self?.streamInterrupted() }
        monitor.start()
        angle = monitor.tracker.angle
        layout = (NSScreen.activeBuiltIn?.duoDisplayID, NSScreen.activeBuiltIn?.frame)
        Task {
            await snapshot.warm()
            try? await Task.sleep(for: .milliseconds(600))
            await stream.warm()
        }
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        unregisterDisplayReconfigurationCallback()
        monitor.stop()
        stopDisplayLink()
        overlay.dismiss(animated: false)
        stopWarming()
        overlay.endLive()
        isActive = false
        isPreviewing = false
        reveal = nil
        started = false
    }

    // MARK: Preview & Scrub

    func preview() {
        guard reveal == nil, !isActive || isPreviewing else { return }
        refreshPermission()
        guard screenRecordingGranted else {
            Toast.show(String(localized: "Allow Screen Recording in System Settings for Mac Duo"), symbol: "video.slash.fill", tint: .orange)
            return
        }
        guard NSScreen.activeBuiltIn != nil else {
            Toast.show(String(localized: "Built-in MacBook display is not active"), symbol: "laptopcomputer.slash", tint: .orange)
            return
        }
        let effect = preferences.effect
        let sweep = ScriptedSweep(
            startedAt: CACurrentMediaTime() + 0.05,
            open: min(effect.startAngle + 30, 135),
            shut: max(effect.startAngle - effect.span * 1.1, 8)
        )
        isPreviewing = true
        monitor.override = { time in sweep.angle(at: time) }
        monitor.setRate(.moving)
        decider.forceIdle()
    }

    func scrub(to angle: Double?) {
        guard screenRecordingGranted, sensorAvailable || angle != nil else { return }
        if let angle {
            guard NSScreen.activeBuiltIn != nil else { return }
            scrubAngle = angle
            if !isPreviewing {
                isPreviewing = true
                monitor.setRate(.moving)
            }
            monitor.override = { [weak self] _ in self?.scrubAngle }
            if !isActive {
                let now = CACurrentMediaTime()
                decider.forceActive(at: now)
                beginFold(at: now, snapping: true)
            }
        } else {
            scrubAngle = nil
            monitor.override = nil
            finishPreview()
        }
    }

    private func finishPreview() {
        guard isPreviewing else { return }
        isPreviewing = false
        monitor.override = nil
        monitor.resetBaseline()
        decider.forceIdle()
        endFold(animated: true)
    }

    func refreshPermission() {
        let granted = DuoScreenRecordingPermission.isGranted
        if screenRecordingGranted != granted {
            screenRecordingGranted = granted
        }
        if granted && !lastPermission {
            lastPermission = true
            Task {
                await snapshot.warm()
                await stream.warm()
            }
        } else {
            lastPermission = granted
        }
    }

    // MARK: Lid Samples

    private func handle(tracker: AngleTracker, at time: CFTimeInterval) {
        publishAngle(tracker.angle, at: time)
        guard !isSuspended else { return }

        // Clamshell protection: if built-in display is offline (closed lid with external monitor),
        // dismiss any overlay immediately and suppress re-triggering until lid opens past 15°.
        guard NSScreen.activeBuiltIn != nil else {
            if isActive || reveal != nil || overlay.hasAnyWindow {
                dismissEverythingImmediately()
            }
            clamshellSuppressed = true
            decider.forceIdle()
            monitor.setRate(.resting)
            return
        }

        if scrubAngle != nil {
            if isActive, overlay.isVisible, displayLink == nil { startDisplayLink() }
            return
        }

        if clamshellSuppressed {
            if tracker.angle >= Self.clamshellReleaseThreshold {
                clamshellSuppressed = false
            } else {
                return
            }
        }

        // If lid shuts almost all the way (< 5°) while an external display keeps the Mac awake,
        // tear down the overlay before WindowServer moves it onto the external display!
        if !isPreviewing && tracker.angle < Self.clamshellCloseThreshold && NSScreen.screens.count > 1 {
            if isActive || reveal != nil || overlay.hasAnyWindow {
                dismissEverythingImmediately()
            }
            clamshellSuppressed = true
            decider.forceIdle()
            monitor.setRate(.resting)
            return
        }

        if isPreviewing, monitor.override == nil, scrubAngle == nil {
            finishPreview()
            return
        }

        let effect = preferences.effect
        decider.startAngle = effect.startAngle
        decider.armCeiling = Self.armCeiling
        let previous = decider.phase
        let phase = decider.update(
            tracker: tracker,
            enabled: (preferences.isEnabled || isPreviewing) && reveal == nil,
            time: time
        )

        switch (previous, phase) {
        case (_, .active) where !isActive:
            beginFold(at: time, snapping: false)
        case (.active, .idle), (.active, .armed):
            endFold(animated: true)
        case (_, .armed):
            warmCapture()
        case (.armed, .idle):
            stopWarming()
        default:
            break
        }
        if isActive, !overlay.isVisible, !captureInFlight {
            present()
        }
        if isActive, overlay.isVisible, displayLink == nil {
            startDisplayLink()
        }

        let wantsFast = isPreviewing || isActive || phase == .armed
        monitor.setRate(wantsFast ? .moving : (tracker.angle <= effect.startAngle + Self.armCeiling + 25 ? .watching : .resting))
    }

    private func publishAngle(_ value: Double, at time: CFTimeInterval) {
        guard time - lastPublish > 0.1 || abs(value - angle) > 1 else { return }
        lastPublish = time
        if abs(angle - value) > 0.005 { angle = value }
    }

    // MARK: Warm-up

    private func warmCapture() {
        guard DuoScreenRecordingPermission.isGranted, NSScreen.activeBuiltIn != nil else { return }
        if preferences.effect.livePicture {
            snapshotTimer?.invalidate()
            snapshotTimer = nil
            stream.start()
        } else {
            stream.stop()
            overlay.endLive()
            guard snapshotTimer == nil else { return }
            Task { _ = await snapshot.capture() }
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.captureSnapshotForWarmUp() }
            }
            RunLoop.main.add(timer, forMode: .common)
            snapshotTimer = timer
        }
    }

    private func captureSnapshotForWarmUp() {
        Task { _ = await snapshot.capture() }
    }

    private func stopWarming() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        stream.stop()
        overlay.endLive()
        snapshot.discard()
    }

    private func streamInterrupted() {
        guard isActive || decider.phase == .armed, preferences.effect.livePicture, !isSuspended,
              DuoScreenRecordingPermission.isGranted, NSScreen.activeBuiltIn != nil else { return }
        guard streamRestarts < 2 else { return }
        streamRestarts += 1
        stream.start()
    }

    // MARK: Fold

    private func beginFold(at time: CFTimeInterval, snapping: Bool) {
        guard DuoScreenRecordingPermission.isGranted, NSScreen.activeBuiltIn != nil else {
            decider.forceIdle()
            return
        }
        isActive = true
        activationTime = time
        drewSettledFrame = false
        streamRestarts = 0
        spring.snap(to: snapping ? monitor.tracker.angle : max(monitor.tracker.angle, preferences.effect.startAngle))
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        present()
    }

    private func endFold(animated: Bool) {
        guard isActive || overlay.isVisible else { return }
        isActive = false
        stopDisplayLink()
        overlay.dismiss(animated: animated)
        snapshot.discard()
        if !animated {
            stream.stop()
            overlay.endLive()
        } else {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(320))
                guard let self, !self.isActive, self.decider.phase != .armed else { return }
                self.stream.stop()
                self.overlay.endLive()
            }
        }
    }

    private func dismissEverythingImmediately() {
        isActive = false
        isPreviewing = false
        reveal = nil
        scrubAngle = nil
        captureInFlight = false
        monitor.override = nil
        stopDisplayLink()
        overlay.dismiss(animated: false)
        stopWarming()
    }

    private func present() {
        guard let screen = NSScreen.activeBuiltIn else {
            dismissEverythingImmediately()
            return
        }
        if preferences.effect.livePicture, overlay.showLive(on: screen) {
            stream.start()
            startDisplayLink()
            if let frame = stream.takeFrame() {
                overlay.absorb(frame)
                return
            }
            if let image = snapshot.image, snapshot.capturedDisplayID == screen.duoDisplayID {
                overlay.seed(image)
                return
            }
            requestSeed()
            return
        }
        if let image = snapshot.image, snapshot.capturedDisplayID == screen.duoDisplayID {
            overlay.showStill(image, on: screen) { [weak self] in self?.startDisplayLink() }
            return
        }
        captureInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let image = await self.snapshot.capture()
            self.captureInFlight = false
            // Always re-fetch fresh activeBuiltIn AFTER await!
            guard self.isActive, !self.overlay.isVisible, let image,
                  let freshScreen = NSScreen.activeBuiltIn,
                  self.snapshot.capturedDisplayID == freshScreen.duoDisplayID else { return }
            self.overlay.showStill(image, on: freshScreen) { [weak self] in self?.startDisplayLink() }
        }
    }

    private func requestSeed() {
        captureInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let image = await self.snapshot.capture()
            self.captureInFlight = false
            guard self.isActive, !self.overlay.isPictureReady, let image,
                  let freshScreen = NSScreen.activeBuiltIn,
                  self.snapshot.capturedDisplayID == freshScreen.duoDisplayID else { return }
            self.overlay.seed(image)
        }
    }

    // MARK: Frames

    private func startDisplayLink() {
        stopDisplayLink()
        guard let window = overlay.hostWindow else { return }
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        lastFrame = CACurrentMediaTime()
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        // Guard every frame against external display relocation or built-in disconnect.
        guard overlay.verifyPlacement() else {
            dismissEverythingImmediately()
            return
        }
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastFrame, 1.0 / 240), 1.0 / 20)
        lastFrame = now
        var hasNewFrame = false
        if let frame = stream.takeFrame() {
            overlay.absorb(frame)
            hasNewFrame = true
        }
        if let reveal {
            drawReveal(reveal, at: now)
            return
        }
        let target = scrubAngle ?? monitor.tracker.extrapolatedAngle(at: now)
        let wasSettled = spring.isSettled(at: target, tolerance: 0.02)
        spring.advance(toward: target, dt: dt)
        if wasSettled, !hasNewFrame, spring.isSettled(at: target, tolerance: 0.02), drewSettledFrame { return }
        drewSettledFrame = spring.isSettled(at: target, tolerance: 0.02) && !hasNewFrame
        draw(angle: spring.value, at: now)
    }

    private func draw(angle: Double, at time: CFTimeInterval) {
        overlay.render(FrameParameters.make(effect: preferences.effect, screenSize: overlay.screenSize, angle: angle, time: time))
    }

    private func drawReveal(_ reveal: Reveal, at time: CFTimeInterval) {
        let effect = preferences.effect
        let progress = reveal.progress(at: time)
        overlay.render(FrameParameters.make(effect: effect, screenSize: overlay.screenSize, angle: effect.startAngle,
                                            progressOverride: progress, flat: true, time: time))
        if reveal.isOver(at: time) {
            self.reveal = nil
            stopDisplayLink()
            overlay.dismiss(animated: true, duration: 0.12)
            snapshot.discard()
        }
    }

    // MARK: Focus on Wake

    private func beginReveal() {
        guard preferences.focusOnWake, preferences.isEnabled, DuoScreenRecordingPermission.isGranted,
              !isActive, reveal == nil, NSScreen.activeBuiltIn != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let image = await self.snapshot.capture(),
                  !self.isActive, self.reveal == nil, !self.isSuspended,
                  // CRITICAL FIX: always re-fetch fresh activeBuiltIn AFTER await so stale
                  // pre-wake coordinates never place a reveal overlay onto the external display!
                  let freshScreen = NSScreen.activeBuiltIn,
                  self.snapshot.capturedDisplayID == freshScreen.duoDisplayID else { return }
            self.reveal = Reveal(startedAt: CACurrentMediaTime() + 0.05)
            self.overlay.showStill(image, on: freshScreen) { [weak self] in self?.startDisplayLink() }
        }
    }

    // MARK: System Notifications

    private func watchPermission() {
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPermission()
            }
        }
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func observeSystem() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isScreenLocked = true }
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasLocked = self.isScreenLocked
                self.isScreenLocked = false
                if wasLocked, !self.isSuspended { self.scheduleReveal() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    private func scheduleReveal() {
        guard !revealScheduled else { return }
        revealScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self else { return }
            self.revealScheduled = false
            guard !self.isScreenLocked, !self.isSuspended else { return }
            self.beginReveal()
        }
    }

    private func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        dismissEverythingImmediately()
        decider.forceIdle()
    }

    private func resume() {
        guard isSuspended else { return }
        isSuspended = false
        clamshellSuppressed = false
        monitor.resetBaseline()
        monitor.setRate(.resting)
        if !isScreenLocked { scheduleReveal() }
    }

    /// CRITICAL FIX: tears down BOTH active folds AND focus-on-wake reveals immediately without
    /// animation whenever screen parameters change (plugging/unplugging external monitor,
    /// clamshell close, resolution switch) so an overlay can NEVER get stranded on another display.
    private func screensChanged() {
        let screen = NSScreen.activeBuiltIn
        let fresh = (screen?.duoDisplayID, screen?.frame)
        let changed = fresh.0 != layout.id || fresh.1 != layout.frame
        layout = fresh
        if changed || screen == nil || !overlay.verifyPlacement() {
            if isActive || reveal != nil || overlay.hasAnyWindow {
                dismissEverythingImmediately()
            } else {
                stopWarming()
            }
            decider.forceIdle()
            stream.invalidateFilter()
            snapshot.invalidateFilter()
            if screen != nil {
                Task {
                    await snapshot.warm()
                    await stream.warm()
                }
            }
        }
    }

    /// CoreGraphics display reconfiguration fires with `beginConfigurationFlag` BEFORE
    /// WindowServer moves windows off a vanishing built-in display onto an external monitor.
    /// Tearing down all overlay windows (including fading ones) here prevents even a single
    /// stray frame from appearing on the primary external monitor.
    private static let displayReconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        let relevant: CGDisplayChangeSummaryFlags = [
            .beginConfigurationFlag,
            .removeFlag,
            .disabledFlag,
            .movedFlag,
            .setModeFlag,
            .addFlag,
            .enabledFlag,
        ]
        guard !flags.intersection(relevant).isEmpty, let userInfo else { return }
        let controller = Unmanaged<DuoFoldController>.fromOpaque(userInfo).takeUnretainedValue()
        let isBegin = flags.contains(.beginConfigurationFlag)
        let handle: @MainActor () -> Void = {
            if isBegin {
                if controller.isActive || controller.reveal != nil || controller.overlay.hasAnyWindow {
                    controller.dismissEverythingImmediately()
                }
                controller.decider.forceIdle()
            } else {
                controller.screensChanged()
            }
        }
        if isBegin && Thread.isMainThread {
            MainActor.assumeIsolated { handle() }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { handle() }
            }
        }
    }

    private func registerDisplayReconfigurationCallback() {
        guard !displayCallbackRegistered else { return }
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        if CGDisplayRegisterReconfigurationCallback(Self.displayReconfigCallback, ptr) == .success {
            displayCallbackRegistered = true
        }
    }

    private func unregisterDisplayReconfigurationCallback() {
        guard displayCallbackRegistered else { return }
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(Self.displayReconfigCallback, ptr)
        displayCallbackRegistered = false
    }

    func diagnostics() -> String {
        """
        KeyVeil Mac Duo
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Model \(DuoMacModel.identifier)
        Sensor \(sensorAvailable ? "available, \(monitor.resolutionLabel)" : "not found")
        Angle \(String(format: "%.2f", angle))°
        Screen recording \(DuoScreenRecordingPermission.isGranted ? "granted" : "not granted")
        Enabled \(preferences.isEnabled), focus on wake \(preferences.focusOnWake)
        Preset \(preferences.preset?.title ?? "Custom")
        Built-in display \(NSScreen.activeBuiltIn.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) @\($0.backingScaleFactor)x" } ?? "none/offline")
        All screens \(NSScreen.screens.count)
        """
    }
}

