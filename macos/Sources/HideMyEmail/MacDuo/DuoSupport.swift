import AppKit
import CoreGraphics
import DuoCore
import Foundation
import LidAngle
import os

extension NSScreen {
    var duoDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The MacBook's own built-in display, ONLY when it is online, active, and awake.
    /// Returns nil in clamshell mode or while the built-in panel is powering off,
    /// preventing the fold overlay from relocating onto an external display.
    static var activeBuiltIn: NSScreen? {
        screens.first { screen in
            guard let id = screen.duoDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
                && CGDisplayIsOnline(id) != 0
                && CGDisplayIsActive(id) != 0
                && CGDisplayIsAsleep(id) == 0
                && screen.frame.width > 0
                && screen.frame.height > 0
        }
    }
}

enum DuoLog {
    static let app = Logger(subsystem: "com.nikolenko.HideMyEmail", category: "MacDuo")
    static let fold = Logger(subsystem: "com.nikolenko.HideMyEmail", category: "MacDuo.Fold")
    static let capture = Logger(subsystem: "com.nikolenko.HideMyEmail", category: "MacDuo.Capture")
}

enum DuoMacModel {
    static let identifier: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }()
}

enum DuoScreenRecordingPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    )!

    @MainActor
    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}

enum DuoLockScreenSettings {
    static let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!

    @MainActor
    static func open() {
        NSWorkspace.shared.open(url)
    }
}

enum DuoSleepControl {
    /// Reads `pmset -g` off the main thread so `Process.waitUntilExit()` never pumps
    /// a nested RunLoop during SwiftUI AttributeGraph updates.
    static func readSleepDisabled() async -> Bool {
        await Task.detached(priority: .utility) {
            readSleepDisabledBlocking()
        }.value
    }

    private nonisolated static func readSleepDisabledBlocking() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.first == "SleepDisabled", parts.count > 1 { return parts[1] == "1" }
        }
        return false
    }

    static func setSleepDisabled(_ disabled: Bool) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let script = "do shell script \"/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)\" with administrator privileges"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            return readSleepDisabledBlocking()
        }.value
    }
}

/// Polls the MacBook lid hinge sensor and feeds AngleTracker with the same
/// 3-tier adaptive rate as standalone Mac Duo (resting / watching / moving).
@MainActor
final class DuoLidMonitor {
    enum Rate: TimeInterval {
        case resting = 0.25
        case watching = 0.1
        case moving = 0.02
    }

    private let sensor = LidAngleSensor()
    private(set) var tracker = AngleTracker()
    private var timer: Timer?
    private(set) var rate: Rate?
    private var failures = 0

    var override: ((CFTimeInterval) -> Double?)?
    var onSample: ((AngleTracker, CFTimeInterval) -> Void)?
    var onOverrideEnded: (() -> Void)?
    var onFailure: (() -> Void)?

    var isAvailable: Bool { sensor.isAvailable }

    var resolutionLabel: String {
        sensor.resolution?.label ?? "—"
    }

    func start() {
        guard sensor.isAvailable else { return }
        if let initial = sensor.read() {
            tracker.reset(to: initial, at: CACurrentMediaTime())
        }
        setRate(.resting)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        rate = nil
    }

    func setRate(_ wanted: Rate) {
        guard wanted != rate else { return }
        rate = wanted
        timer?.invalidate()
        let timer = Timer(timeInterval: wanted.rawValue, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = wanted.rawValue * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func resetBaseline() {
        if let initial = sensor.read() {
            tracker.reset(to: initial, at: CACurrentMediaTime())
        }
    }

    private func poll() {
        let now = CACurrentMediaTime()
        let reading: Double
        if let override {
            guard let scripted = override(now) else {
                self.override = nil
                resetBaseline()
                onOverrideEnded?()
                return
            }
            reading = scripted
        } else {
            guard let read = sensor.read() else {
                failures += 1
                if failures == 30 {
                    DuoLog.app.error("Lid sensor failed 30 reads in a row")
                    onFailure?()
                }
                return
            }
            if failures > 0 { failures = 0 }
            reading = read
        }
        tracker.ingest(reading, at: now)
        onSample?(tracker, now)
    }
}

