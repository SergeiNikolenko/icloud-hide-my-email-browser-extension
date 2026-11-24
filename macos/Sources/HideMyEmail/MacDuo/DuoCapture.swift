import AppKit
import CoreMedia
import CoreVideo
import DuoCore
import DuoRender
import Metal
import ScreenCaptureKit

enum DuoContentFilterBuilder {
    @MainActor
    static func make(display id: CGDirectDisplayID) async -> SCContentFilter? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
            let bundleID = Bundle.main.bundleIdentifier ?? "com.nikolenko.HideMyEmail"
            let own = content.applications.filter { $0.bundleIdentifier == bundleID }
            return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        } catch {
            DuoLog.capture.error("Shareable content failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

@MainActor
final class DuoScreenSnapshot {
    private(set) var image: CGImage?
    private(set) var capturedDisplayID: CGDirectDisplayID?
    private var filter: SCContentFilter?
    private var filterDisplay: CGDirectDisplayID?
    private var inFlight: Task<CGImage?, Never>?

    func discard() {
        image = nil
        capturedDisplayID = nil
    }

    func invalidateFilter() {
        filter = nil
        filterDisplay = nil
    }

    func warm() async {
        guard let id = NSScreen.activeBuiltIn?.duoDisplayID, filter == nil || filterDisplay != id else { return }
        filter = await DuoContentFilterBuilder.make(display: id)
        filterDisplay = filter == nil ? nil : id
    }

    @discardableResult
    func capture() async -> CGImage? {
        if let inFlight { return await inFlight.value }
        let task = Task<CGImage?, Never> { [weak self] in
            guard let self else { return nil }
            let img = await self.performCapture()
            self.inFlight = nil
            return img
        }
        inFlight = task
        return await task.value
    }

    private func performCapture() async -> CGImage? {
        guard let screen = NSScreen.activeBuiltIn, let id = screen.duoDisplayID else { return nil }
        let filterSizeMismatch = filter.map {
            abs($0.contentRect.width - screen.frame.width) > 1
                || abs($0.contentRect.height - screen.frame.height) > 1
        } ?? true
        if filter == nil || filterDisplay != id || filterSizeMismatch {
            filter = await DuoContentFilterBuilder.make(display: id)
            filterDisplay = filter == nil ? nil : id
        }
        guard let filter else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        configuration.colorSpaceName = DuoScreenStream.colourSpace
        do {
            let captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            // Verify built-in display is still active and pixel dimensions still match (no mid-capture resize).
            guard let freshScreen = NSScreen.activeBuiltIn,
                  freshScreen.duoDisplayID == id,
                  DisplayContainment.captureMatchesScreen(
                      imageWidth: captured.width,
                      imageHeight: captured.height,
                      screenSize: freshScreen.frame.size,
                      pixelScale: freshScreen.backingScaleFactor
                  ) else {
                invalidateFilter()
                return nil
            }
            image = captured
            capturedDisplayID = id
            return captured
        } catch {
            DuoLog.capture.error("Snapshot failed: \(String(describing: error), privacy: .public)")
            invalidateFilter()
            return nil
        }
    }
}

@MainActor
final class DuoScreenStream {
    nonisolated static let colourSpace = DuoRenderer.colourSpace
    private static let minimumHandOver: CFTimeInterval = 1.0 / 60

    private final class Receiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        private let cache: CVMetalTextureCache
        private let lock = NSLock()
        private var currentTexture: MTLTexture?
        private var currentRef: CVMetalTexture?
        private var sequence: UInt64 = 0
        var onStop: (@Sendable (Error) -> Void)?

        init?(device: MTLDevice) {
            var created: CVMetalTextureCache?
            let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &created)
            guard status == kCVReturnSuccess, let created else { return nil }
            cache = created
        }

        func latest() -> (id: UInt64, texture: MTLTexture)? {
            lock.lock()
            defer { lock.unlock() }
            guard let currentTexture else { return nil }
            return (sequence, currentTexture)
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, sampleBuffer.isValid else { return }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let raw = attachments.first?[.status] as? Int,
               let status = SCFrameStatus(rawValue: raw),
               status != .complete {
                return
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            CVMetalTextureCacheFlush(cache, 0)
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            var ref: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm_srgb, width, height, 0, &ref
            )
            guard status == kCVReturnSuccess, let ref, let texture = CVMetalTextureGetTexture(ref) else { return }
            lock.lock()
            currentRef = ref
            currentTexture = texture
            sequence &+= 1
            lock.unlock()
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            onStop?(error)
        }
    }

    var onInterruption: (() -> Void)?

    private let device: MTLDevice?
    private var stream: SCStream?
    private var receiver: Receiver?
    private var filter: SCContentFilter?
    private var filterDisplay: CGDirectDisplayID?
    private var isRunning = false
    private var starting: Task<Void, Never>?
    private var consumed: UInt64 = 0
    private var lastHandOver: CFTimeInterval = 0
    private var generation = 0

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.device = device
    }

    func warm() async {
        guard let id = NSScreen.activeBuiltIn?.duoDisplayID, filter == nil || filterDisplay != id else { return }
        filter = await DuoContentFilterBuilder.make(display: id)
        filterDisplay = filter == nil ? nil : id
    }

    func invalidateFilter() {
        filter = nil
        filterDisplay = nil
    }

    func start() {
        guard !isRunning, starting == nil, device != nil else { return }
        guard let screen = NSScreen.activeBuiltIn, let id = screen.duoDisplayID else { return }
        isRunning = true
        generation += 1
        let token = generation
        starting = Task { [weak self] in
            await self?.begin(display: id, generation: token)
            if self?.generation == token { self?.starting = nil }
        }
    }

    func stop() {
        guard isRunning || stream != nil else { return }
        isRunning = false
        generation += 1
        starting?.cancel()
        starting = nil
        let closing = stream
        stream = nil
        receiver = nil
        consumed = 0
        lastHandOver = 0
        guard let closing else { return }
        Task { try? await closing.stopCapture() }
    }

    func takeFrame() -> MTLTexture? {
        let now = CACurrentMediaTime()
        guard now - lastHandOver >= Self.minimumHandOver else { return nil }
        guard let latest = receiver?.latest(), latest.id != consumed else { return nil }
        consumed = latest.id
        lastHandOver = now
        return latest.texture
    }

    private func begin(display id: CGDirectDisplayID, generation token: Int) async {
        guard let device, let receiver = Receiver(device: device) else {
            isRunning = false
            return
        }
        guard let screen = NSScreen.activeBuiltIn, screen.duoDisplayID == id else {
            if token == generation { isRunning = false }
            return
        }
        let filterSizeMismatch = filter.map {
            abs($0.contentRect.width - screen.frame.width) > 1
                || abs($0.contentRect.height - screen.frame.height) > 1
        } ?? true
        if filter == nil || filterDisplay != id || filterSizeMismatch {
            filter = await DuoContentFilterBuilder.make(display: id)
            filterDisplay = filter == nil ? nil : id
        }
        guard isRunning, token == generation, let filter else {
            if token == generation { isRunning = false }
            return
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = Self.colourSpace
        configuration.showsCursor = false
        configuration.queueDepth = 5
        configuration.scalesToFit = false

        let fresh = SCStream(filter: filter, configuration: configuration, delegate: receiver)
        receiver.onStop = { [weak self, weak fresh] error in
            Task { @MainActor in self?.stopped(fresh, error: error) }
        }
        do {
            try fresh.addStreamOutput(receiver, type: .screen,
                                      sampleHandlerQueue: DispatchQueue(label: "com.nikolenko.KeyVeil.duoFrames", qos: .userInteractive))
            try await fresh.startCapture()
            guard isRunning, token == generation, !Task.isCancelled else {
                try? await fresh.stopCapture()
                return
            }
            self.receiver = receiver
            self.stream = fresh
        } catch {
            DuoLog.capture.error("Stream failed: \(String(describing: error), privacy: .public)")
            invalidateFilter()
            if token == generation { isRunning = false }
        }
    }

    private func stopped(_ stopped: SCStream?, error: Error) {
        guard let stopped, stopped === stream else { return }
        stream = nil
        receiver = nil
        isRunning = false
        generation += 1
        consumed = 0
        lastHandOver = 0
        invalidateFilter()
        onInterruption?()
    }
}

