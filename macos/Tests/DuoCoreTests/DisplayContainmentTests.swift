import CoreGraphics
import Testing
@testable import DuoCore

@Suite("Multi-display containment")
struct DisplayContainmentTests {
    // Real dual-display layout: primary BenQ 1920x1080 + built-in Retina to its left at (-1024, 105).
    private let benq = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let builtIn = CGRect(x: -1024, y: 105, width: 1024, height: 665)

    @Test func exactBuiltInFrameIsAllowed() {
        #expect(DisplayContainment.isStrictlyContained(
            windowFrame: builtIn,
            builtInFrame: builtIn,
            otherDisplayFrames: [benq]
        ))
    }

    @Test func clamshellRelocationOntoPrimaryDisplayIsRejected() {
        // WindowServer shifts the 1024x665 window onto BenQ when the lid shuts.
        let relocated = CGRect(x: 0, y: 105, width: 1024, height: 665)
        #expect(!DisplayContainment.isStrictlyContained(
            windowFrame: relocated,
            builtInFrame: builtIn,
            otherDisplayFrames: [benq]
        ))
    }

    @Test func staleResolutionSpillingAcrossDisplaySeamIsRejected() {
        // Built-in switched from 1147x745 to 1024x665; a stale 1147-wide window spills +123pt onto BenQ.
        let spilling = CGRect(x: -1024, y: 105, width: 1147, height: 745)
        #expect(!DisplayContainment.isStrictlyContained(
            windowFrame: spilling,
            builtInFrame: builtIn,
            otherDisplayFrames: [benq]
        ))
    }

    @Test func slightHorizontalShiftOntoBenQIsRejected() {
        let shifted = CGRect(x: -1000, y: 105, width: 1024, height: 665)
        #expect(!DisplayContainment.isStrictlyContained(
            windowFrame: shifted,
            builtInFrame: builtIn,
            otherDisplayFrames: [benq]
        ))
    }

    @Test func mirroredDisplayFrameIsAllowed() {
        #expect(DisplayContainment.isStrictlyContained(
            windowFrame: builtIn,
            builtInFrame: builtIn,
            otherDisplayFrames: [builtIn]
        ))
    }

    @Test func captureResolutionMismatchIsRejected() {
        // 2294x1490 capture must not be adopted onto a 1024x665 @2x (2048x1330) display.
        #expect(!DisplayContainment.captureMatchesScreen(
            imageWidth: 2294,
            imageHeight: 1490,
            screenSize: CGSize(width: 1024, height: 665),
            pixelScale: 2
        ))
        #expect(DisplayContainment.captureMatchesScreen(
            imageWidth: 2048,
            imageHeight: 1330,
            screenSize: CGSize(width: 1024, height: 665),
            pixelScale: 2
        ))
    }

    @Test func openingLidAfterCloseNeverSpuriouslyActivatesFold() {
        // Reproduces Mac Duo log: lid closes to 1.6°, clamshell releases, then lid opens at +80°/s.
        var tracker = AngleTracker()
        tracker.reset(to: 80, at: 0)
        var decider = FoldDecider(startAngle: 95)
        tracker.ingest(40, at: 0.1)
        tracker.ingest(10, at: 0.2)
        decider.forceIdle()
        // Lid now swings open rapidly within closingMemory (< 1.5s)
        tracker.ingest(22, at: 0.35)
        tracker.ingest(33, at: 0.45)
        #expect(tracker.velocity > 0)
        #expect(decider.update(tracker: tracker, enabled: true, time: 0.45) == .idle)
    }
}
