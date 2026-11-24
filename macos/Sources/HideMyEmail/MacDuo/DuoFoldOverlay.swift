import AppKit
import DuoCore
import DuoRender
import Metal
import QuartzCore

/// Borderless overlay window strictly pinned to the built-in display.
/// Overriding `constrainFrameRect(_:to:)` prevents AppKit from shifting a secondary-display
/// full-screen borderless window across the display boundary onto the primary external monitor.
final class DuoOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class DuoMetalHostView: NSView {
    init(layer metalLayer: CALayer, scale: CGFloat) {
        super.init(frame: .zero)
        metalLayer.contentsScale = scale
        self.layer = metalLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.frame = bounds
    }
}

/// Owns the fold overlay window and enforces strict built-in-display containment so a piece
/// of the folded screen can NEVER spill or relocate onto an external/main display.
@MainActor
final class DuoFoldOverlay {
    private var window: DuoOverlayWindow?
    private var fadingWindow: DuoOverlayWindow?
    private var presenceWindow: DuoOverlayWindow?
    private var windowObservers: [NSObjectProtocol] = []
    private(set) var renderer: DuoRenderer?
    private var triedRenderer = false
    private var buildToken = 0
    private let buildQueue = DispatchQueue(label: "com.nikolenko.KeyVeil.duoPicture", qos: .userInteractive)
    private var revealed = false

    private(set) var targetDisplayID: CGDirectDisplayID?
    private(set) var targetFrame: CGRect = .zero
    private(set) var screenSize: CGSize = .zero
    private(set) var pixelScale: CGFloat = 2

    var isVisible: Bool { window != nil }
    var hasAnyWindow: Bool { window != nil || fadingWindow != nil }
    var isPictureReady: Bool { renderer?.isReady ?? false }
    var hostWindow: NSWindow? { window }

    @discardableResult
    func warmUp() -> Bool {
        if !triedRenderer {
            triedRenderer = true
            renderer = DuoRenderer()
        }
        keepPresence()
        return renderer != nil
    }

    /// Tiny invisible 1x1 window keeps KeyVeil in ScreenCaptureKit's on-screen app list so the
    /// capture filter can always exclude our own overlay windows.
    private func keepPresence() {
        guard presenceWindow == nil else { return }
        let origin = NSScreen.activeBuiltIn?.frame.origin ?? .zero
        let window = DuoOverlayWindow(contentRect: NSRect(origin: origin, size: CGSize(width: 1, height: 1)),
                                      styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .normal
        // Must stay >= 1/255 (~0.004) so WindowServer keeps KeyVeil in ScreenCaptureKit's
        // on-screen application list and the capture filter always excludes our own overlays.
        window.alphaValue = 0.004
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.setFrame(NSRect(origin: origin, size: CGSize(width: 1, height: 1)), display: false)
        window.orderFrontRegardless()
        presenceWindow = window
    }

    @discardableResult
    func showLive(on screen: NSScreen) -> Bool {
        dismiss(animated: false)
        guard warmUp(), let renderer, let displayID = screen.duoDisplayID,
              CGDisplayIsBuiltin(displayID) != 0, CGDisplayIsActive(displayID) != 0 else { return false }
        screenSize = screen.frame.size
        pixelScale = screen.backingScaleFactor
        guard renderer.beginLive(screenSize: screenSize, pixelScale: pixelScale) else { return false }
        buildToken += 1
        makeWindow(on: screen, displayID: displayID)
        return window != nil
    }

    func absorb(_ frame: MTLTexture) {
        guard verifyPlacement(), let renderer else { return }
        guard DisplayContainment.captureMatchesScreen(
            imageWidth: frame.width,
            imageHeight: frame.height,
            screenSize: screenSize,
            pixelScale: pixelScale
        ) else { return }
        renderer.absorb(frame)
        reveal()
    }

    func seed(_ image: CGImage) {
        guard verifyPlacement(), let renderer, renderer.seed(image) else { return }
        reveal()
    }

    func showStill(_ image: CGImage, on screen: NSScreen, then ready: @escaping @MainActor () -> Void) {
        dismiss(animated: false)
        guard warmUp(), let renderer, let displayID = screen.duoDisplayID,
              CGDisplayIsBuiltin(displayID) != 0, CGDisplayIsActive(displayID) != 0 else { return }
        screenSize = screen.frame.size
        pixelScale = screen.frame.width > 0 ? CGFloat(image.width) / screen.frame.width : screen.backingScaleFactor
        makeWindow(on: screen, displayID: displayID)
        guard let window else { return }
        buildToken += 1
        let token = buildToken
        let size = screenSize
        let scale = pixelScale
        buildQueue.async { [weak self, weak renderer] in
            guard let renderer else { return }
            let picture = renderer.makePicture(from: image, screenSize: size, pixelScale: scale)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.buildToken == token, self.window === window,
                          self.verifyPlacement(), let picture else { return }
                    renderer.adopt(picture)
                    ready()
                    self.reveal()
                }
            }
        }
    }

    private func makeWindow(on screen: NSScreen, displayID: CGDirectDisplayID) {
        guard let renderer else { return }
        let frame = screen.frame
        let view = DuoMetalHostView(layer: renderer.makeLayer(), scale: pixelScale)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]

        // Create borderless window with constrainFrameRect bypassed and immediately pin exact
        // global coordinates to the built-in display so AppKit never clamps/shifts it onto
        // an adjacent external display.
        let window = DuoOverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrame(frame, display: false)
        window.alphaValue = 0

        // Strict multi-display containment check: AppKit's window.screen returns the majority
        // screen even if part of the window spills across the display seam (when Displays Have
        // Separate Spaces is off). Reject any placement that is not strictly inside the built-in display.
        let otherFrames = NSScreen.screens
            .filter { $0.duoDisplayID != displayID }
            .map(\.frame)
        let placedOK = (window.screen?.duoDisplayID == nil || window.screen?.duoDisplayID == displayID)
            && DisplayContainment.isStrictlyContained(
                windowFrame: window.frame,
                builtInFrame: frame,
                otherDisplayFrames: otherFrames
            )
        if !placedOK {
            DuoLog.fold.error("Refusing overlay placement: frame \(NSStringFromRect(window.frame), privacy: .public) escaped built-in \(NSStringFromRect(frame), privacy: .public)")
            window.close()
            return
        }

        window.orderFrontRegardless()
        let stillPlacedOK = (window.screen?.duoDisplayID == nil || window.screen?.duoDisplayID == displayID)
            && DisplayContainment.isStrictlyContained(
                windowFrame: window.frame,
                builtInFrame: frame,
                otherDisplayFrames: otherFrames
            )
        if !stillPlacedOK {
            DuoLog.fold.error("WindowServer relocated overlay after orderFront: frame \(NSStringFromRect(window.frame), privacy: .public) vs built-in \(NSStringFromRect(frame), privacy: .public)")
            window.orderOut(nil)
            window.close()
            return
        }
        revealed = false
        targetDisplayID = displayID
        targetFrame = frame
        self.window = window
        installWindowObservers(for: window)
    }

    private func installWindowObservers(for tracked: DuoOverlayWindow) {
        removeWindowObservers()
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
        ]
        windowObservers = names.map { name in
            center.addObserver(forName: name, object: tracked, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.window === tracked {
                        _ = self.verifyPlacement()
                    } else if self.fadingWindow === tracked {
                        self.closeFading()
                    }
                }
            }
        }
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        for token in windowObservers {
            center.removeObserver(token)
        }
        windowObservers.removeAll()
    }

    /// Verifies that the overlay window is STILL pinned strictly to the active built-in display.
    /// If macOS relocated the window onto an external display (clamshell close / wake transition)
    /// or it spilled across the display seam, immediately tears down the overlay without animation.
    @discardableResult
    func verifyPlacement() -> Bool {
        if let fading = fadingWindow {
            let builtIn = NSScreen.activeBuiltIn
            let otherFrames = NSScreen.screens
                .filter { $0.duoDisplayID != builtIn?.duoDisplayID }
                .map(\.frame)
            let fadingOK = builtIn.map {
                DisplayContainment.isStrictlyContained(
                    windowFrame: fading.frame,
                    builtInFrame: $0.frame,
                    otherDisplayFrames: otherFrames
                )
            } ?? false
            if !fadingOK {
                closeFading()
            }
        }

        guard let window, let displayID = targetDisplayID else { return false }
        guard let currentBuiltIn = NSScreen.activeBuiltIn,
              currentBuiltIn.duoDisplayID == displayID else {
            DuoLog.fold.notice("Built-in display went offline or changed; dismissing overlay immediately")
            dismiss(animated: false)
            return false
        }
        if let placedID = window.screen?.duoDisplayID, placedID != displayID {
            DuoLog.fold.error("Overlay relocated to external display \(placedID); dismissing immediately")
            dismiss(animated: false)
            return false
        }
        let otherFrames = NSScreen.screens
            .filter { $0.duoDisplayID != displayID }
            .map(\.frame)
        if !DisplayContainment.isStrictlyContained(
            windowFrame: window.frame,
            builtInFrame: currentBuiltIn.frame,
            otherDisplayFrames: otherFrames
        ) {
            DuoLog.fold.error("Overlay frame \(NSStringFromRect(window.frame), privacy: .public) escaped built-in \(NSStringFromRect(currentBuiltIn.frame), privacy: .public); dismissing immediately")
            dismiss(animated: false)
            return false
        }
        if window.frame != currentBuiltIn.frame {
            window.setFrame(currentBuiltIn.frame, display: false)
            if (window.screen?.duoDisplayID != nil && window.screen?.duoDisplayID != displayID)
                || !DisplayContainment.isStrictlyContained(
                    windowFrame: window.frame,
                    builtInFrame: currentBuiltIn.frame,
                    otherDisplayFrames: otherFrames
                ) {
                dismiss(animated: false)
                return false
            }
            targetFrame = currentBuiltIn.frame
            screenSize = currentBuiltIn.frame.size
        }
        return true
    }

    private func reveal() {
        guard verifyPlacement(), let window, !revealed, renderer?.isReady == true else { return }
        revealed = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func render(_ parameters: FrameParameters) {
        guard verifyPlacement(), let renderer, renderer.isReady else { return }
        renderer.render(parameters)
    }

    func endLive() {
        renderer?.endLive()
    }

    func dismiss(animated: Bool, duration: TimeInterval = 0.24) {
        closeFading()
        targetDisplayID = nil
        targetFrame = .zero
        guard let window else { return }
        self.window = nil
        buildToken += 1
        renderer?.release()
        guard animated else {
            removeWindowObservers()
            window.orderOut(nil)
            window.close()
            return
        }
        fadingWindow = window
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if let self, self.fadingWindow === window {
                    self.fadingWindow = nil
                    self.removeWindowObservers()
                }
                window.orderOut(nil)
                window.close()
            }
        }
    }

    private func closeFading() {
        guard let fadingWindow else { return }
        self.fadingWindow = nil
        if self.window == nil { removeWindowObservers() }
        fadingWindow.orderOut(nil)
        fadingWindow.close()
    }
}

