import AppKit
import ApplicationServices
import Combine
import Foundation
import os

/// Runs the complete Snowpile weather/snow/effects simulation and Metal overlays inside KeyVeil.
@MainActor
public final class SnowpileController: ObservableObject {
    public static let shared = SnowpileController()
    private static let logger = Logger(subsystem: "com.nikolenko.HideMyEmail", category: "Snowpile")

    public let preferences: Preferences
    public let weather = WeatherModel()

    private let world = SnowWorld()
    private let effects = EffectWorld()
    private let departures = WindowDepartureTracker()
    private let elements = ElementLocator()
    private var overlays: [Overlay] = []
    private var timer: Timer?
    private var dockFrame: CGRect?
    private var ticks = 0
    private var lastSpaces: [Int] = []
    private var lastFrames: [CGRect] = []
    private var lastWindowChange: CFTimeInterval = 0
    private var lastSpaceChange: CFTimeInterval = 0
    private var lastDigest = 0
    private var lastStillDraw: CFTimeInterval = 0
    private var interactionMonitor: Any?
    private var shownScreens: [String] = []
    private var shownScreenFrames: [CGRect] = []
    private var shownScreenScales: [CGFloat] = []
    private var screens: [NSScreen] = []
    private var started = false
    private var cancellables: Set<AnyCancellable> = []

    public init(defaults: UserDefaults? = nil) {
        let store = defaults ?? Preferences.makeMigratedSuite()
        self.preferences = Preferences(defaults: store)
        self.preferences.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.weather.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    public var activeEffect: Effect {
        preferences.followWeather ? weather.conditions?.recommendedEffect ?? .snow : preferences.effect
    }

    public func start() {
        guard !started else { return }
        started = true
        preferences.onChange = { [weak self] in self?.apply() }
        weather.onChange = { [weak self] in self?.apply() }
        rebuildOverlays()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildOverlays() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }

        interactionMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseUp]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.world.running, self.world.settles.contains(.element) else { return }
                self.elements.noteInteraction(now: CACurrentMediaTime())
            }
        }

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        apply()
        Self.logger.notice("Snowpile started (snowing=\(self.preferences.snowing), followWeather=\(self.preferences.followWeather), selection=\(self.preferences.selection, privacy: .public), screens=\(self.screens.count))")
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let monitor = interactionMonitor {
            NSEvent.removeMonitor(monitor)
            interactionMonitor = nil
        }
        overlays.forEach { $0.close() }
        overlays.removeAll()
        started = false
    }

    public func togglePause() {
        if preferences.snowing {
            preferences.pauseIndefinitely()
        } else {
            preferences.resume()
        }
    }

    public func pause(for duration: PauseDuration) {
        preferences.pause(for: duration)
    }

    public func pauseIndefinitely() {
        preferences.pauseIndefinitely()
    }

    public func resume() {
        preferences.resume()
    }

    public func shakeOff() {
        world.shakeOff()
    }

    public func buildSnowman() {
        preferences.selection = "snow:" + preferences.mode.rawValue
        world.buildSnowman()
        poll()
    }

    public func didWake() {
        preferences.resumeIfPauseExpired()
        if !syncScreensIfNeeded() {
            overlays.forEach { $0.ensureOnTop() }
            poll()
        }
    }

    public static func searchPlaces(_ query: String) async throws -> [Place] {
        try await Weather.search(query)
    }

    private func apply() {
        weather.follow(preferences.followWeather ? preferences.place : nil, yandexKey: preferences.yandexKey)
        world.running = preferences.snowing && activeEffect == .snow
        effects.effect = activeEffect
        effects.running = preferences.snowing && (!preferences.followWeather || weather.conditions?.recommendedEffect == .rain)
        effects.intensity = preferences.followWeather ? weather.conditions?.rainIntensity ?? 0 : Float(preferences.intensity)
        effects.wind = preferences.followWeather ? Float(weather.conditions?.eastWind ?? 0) * 6 : Float(preferences.wind) * 35
        effects.lightningEnabled = !preferences.followWeather || weather.conditions?.thunderstorm == true
        effects.brushes = preferences.pointer
        effects.onWindows = preferences.onWindows
        effects.onDock = preferences.onDock
        effects.onFloor = preferences.onFloor
        effects.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if preferences.followWeather {
            let now = weather.conditions
            let storm = now.flatMap(SnowMode.outside)?.storm
            let side: Float = (now?.eastWind ?? 0) < 0 ? -1 : 1
            let realWind = Float(abs(now?.eastWind ?? 0)) * 6
            world.falling = (storm?.intensity ?? 0) > 0
            world.intensity = storm?.intensity ?? 0
            world.windBase = side * min(max(realWind, storm?.wind ?? 0), 180)
            world.windWanders = false
            world.windStrength = storm?.gusts ?? 0.35
            world.lift = storm?.lift ?? 0
            world.flakeScale = storm?.flakeScale ?? 1
            world.thaw = Float(min(max(now?.temperature ?? 0, 0) * 0.03, 0.3))
        } else {
            let storm = preferences.mode.storm
            let custom = preferences.mode == .custom
            world.falling = storm.intensity > 0
            world.intensity = custom ? Float(preferences.intensity) : storm.intensity
            world.windBase = custom ? 0 : storm.wind
            world.windWanders = true
            world.windStrength = custom ? Float(preferences.wind) : storm.gusts
            world.lift = storm.lift
            world.flakeScale = storm.flakeScale
            world.thaw = 0
        }
        world.brushes = preferences.pointer
        world.settles = Set([
            preferences.onWindows ? .window : nil,
            preferences.onWindows ? .element : nil,
            preferences.onDock ? .dock : nil,
            preferences.onFloor ? .ground : nil,
        ].compactMap { $0 })
        syncScreensIfNeeded()
        poll()
    }

    @discardableResult
    private func syncScreensIfNeeded() -> Bool {
        let desired = preferences.screens()
        let ids = desired.map(Preferences.id(of:))
        let frames = desired.map(\.frame)
        let scales = desired.map(\.backingScaleFactor)
        guard ids != shownScreens || frames != shownScreenFrames || scales != shownScreenScales else { return false }
        rebuildOverlays()
        return true
    }

    private func rebuildOverlays() {
        screens = preferences.screens()
        shownScreens = screens.map(Preferences.id(of:))
        shownScreenFrames = screens.map(\.frame)
        shownScreenScales = screens.map(\.backingScaleFactor)
        overlays.forEach { $0.close() }
        overlays = screens.enumerated().map { Overlay(screen: $1, index: $0, world: world, effects: effects) }
        world.setScreens(screens.map(\.frame), visible: screens.map(\.visibleFrame))
        effects.setScreens(screens.map(\.frame))
        poll()
    }

    private func poll() {
        if preferences.pausedUntil != nil, preferences.resumeIfPauseExpired() {
            return
        }
        ticks += 1
        if ticks % 30 == 0, syncScreensIfNeeded() {
            return
        }
        let snow = activeEffect == .snow
        if snow ? world.isIdle : effects.isIdle {
            overlays.forEach { $0.setActive(false) }
            return
        }
        let now = CACurrentMediaTime()
        let spaces = SpaceReader.current(for: screens)
        let switched = spaces != lastSpaces
        if switched {
            lastSpaceChange = now
            effects.spaceChanged()
            overlays.forEach { $0.ensureOnTop() }
        }
        lastSpaces = spaces
        world.setSpaces(spaces)
        if ticks % 10 == 0 { dockFrame = DockLocator.frame() }
        if switched || NSEvent.pressedMouseButtons != 0 || now - lastWindowChange < 1 || ticks % 5 == 0 {
            let ownedWindows = WindowList.currentWithOwners()
            let windows = ownedWindows.map { (key: $0.key, frame: $0.frame) }
            if snow && world.settles.contains(.element) {
                elements.refresh(now: now, visiblePIDs: ownedWindows.map(\.pid))
            }
            let frames = windows.map(\.frame)
            if frames != lastFrames {
                lastFrames = frames
                lastWindowChange = now
            }
            let departing = departures.departing(visible: windows, switched: now - lastSpaceChange < 1, now: now)
            let elementScene = elements.scene(in: windows)
            world.updateWindows(windows, elements: elementScene.elements, occluders: elementScene.occluders,
                                dock: dockFrame, now: now, departing: departing)
            effects.updateWindows(windows, dock: dockFrame)
        }
        if !snow {
            effects.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            for overlay in overlays {
                overlay.setActive(true)
                overlay.update(animating: effects.isAnimating, fast: !effects.reduceMotion && (effects.effect == .rain || effects.effect == .starfall), changed: true)
            }
            return
        }
        if !world.isAnimating {
            world.step(now: now, pointer: NSEvent.mouseLocation,
                       rolling: NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option)
        }
        let animating = world.isAnimating
        var changed = false
        if !animating, switched || now - lastWindowChange < 1 || now - lastStillDraw > 0.25 {
            let digest = world.sceneDigest
            changed = digest != lastDigest
            lastDigest = digest
            if changed { lastStillDraw = now }
        } else if animating {
            lastDigest = 0
        }
        for overlay in overlays {
            overlay.setActive(true)
            overlay.update(animating: animating, fast: world.isAnimatingFast, changed: changed)
        }
    }
}

enum WindowList {
    private static var widgetHost: pid_t?

    static func current() -> [(key: Int, frame: CGRect)] {
        currentWithOwners().map { ($0.key, $0.frame) }
    }

    static func currentWithOwners() -> [(key: Int, frame: CGRect, pid: pid_t)] {
        guard let primary = NSScreen.screens.first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let height = primary.frame.height
        if widgetHost.flatMap(NSRunningApplication.init(processIdentifier:)) == nil {
            widgetHost = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier
        }
        return info.compactMap { w in
            let layer = w[kCGWindowLayer as String] as? Int
            let ownerPID = (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init)
            let name = w[kCGWindowName as String] as? String ?? ""
            let widget = layer.map { $0 < 0 } == true && ownerPID == widgetHost && !name.isEmpty
            let app = !widget ? ownerPID.flatMap(NSRunningApplication.init(processIdentifier:)) : nil
            guard layer == 0 || widget,
                  shouldInclude(widget: widget, windowName: name, activationPolicy: app?.activationPolicy, hasBundleIdentifier: app?.bundleIdentifier != nil),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let number = w[kCGWindowNumber as String] as? Int,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  b.width >= 80, b.height >= 40
            else { return nil }
            let frame = CGRect(x: b.minX, y: height - b.maxY, width: b.width, height: b.height)
            return (number, widget ? frame.insetBy(dx: 12, dy: 0) : frame, ownerPID ?? 0)
        }
    }

    static func shouldInclude(widget: Bool, windowName: String, activationPolicy: NSApplication.ActivationPolicy?, hasBundleIdentifier: Bool) -> Bool {
        if widget { return true }
        guard let policy = activationPolicy else { return !windowName.isEmpty }
        if policy == .prohibited { return false }
        if policy != .regular && !hasBundleIdentifier && windowName.isEmpty { return false }
        return true
    }
}

enum DockLocator {
    static func frame() -> CGRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let primary = NSScreen.screens.first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for child in children {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            guard (role as? String) == kAXListRole else { continue }
            var position: CFTypeRef?
            var size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &size) == .success,
                  let position, CFGetTypeID(position) == AXValueGetTypeID(),
                  let size, CFGetTypeID(size) == AXValueGetTypeID() else { continue }
            var p = CGPoint.zero
            var s = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &p),
                  AXValueGetValue(size as! AXValue, .cgSize, &s) else { continue }
            guard s.width > s.height else { return nil }
            let rect = CGRect(x: p.x, y: primary.frame.height - p.y - s.height, width: s.width, height: s.height)
            return NSScreen.screens.contains { $0.frame.contains(rect) } ? rect : nil
        }
        return nil
    }
}

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSManagedDisplayGetCurrentSpace") private func CGSManagedDisplayGetCurrentSpace(_ connection: Int32, _ display: CFString) -> Int

enum SpaceReader {
    static func current(for screens: [NSScreen]) -> [Int] {
        let connection = CGSMainConnectionID()
        return screens.map { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let name = CFUUIDCreateString(nil, uuid) else { return 0 }
            return CGSManagedDisplayGetCurrentSpace(connection, name)
        }
    }
}

