import CoreGraphics

/// Pure multi-display containment checks that prevent a fold overlay created for the
/// built-in MacBook display from spilling across a display seam (when Displays Have
/// Separate Spaces is disabled) or relocating onto an external monitor in clamshell mode.
public enum DisplayContainment {
    /// Returns true iff `windowFrame` matches `builtInFrame` within `tolerance` and
    /// does not overlap the interior of any other display in `otherDisplayFrames`.
    public static func isStrictlyContained(
        windowFrame: CGRect,
        builtInFrame: CGRect,
        otherDisplayFrames: [CGRect],
        tolerance: CGFloat = 0.5
    ) -> Bool {
        guard builtInFrame.width > 0, builtInFrame.height > 0,
              windowFrame.width > 0, windowFrame.height > 0 else {
            return false
        }
        let withinBuiltIn =
            abs(windowFrame.minX - builtInFrame.minX) <= tolerance &&
            abs(windowFrame.minY - builtInFrame.minY) <= tolerance &&
            abs(windowFrame.width - builtInFrame.width) <= tolerance &&
            abs(windowFrame.height - builtInFrame.height) <= tolerance
        guard withinBuiltIn else { return false }

        for other in otherDisplayFrames {
            // Skip exact-duplicate frames (hardware display mirroring).
            if abs(other.minX - builtInFrame.minX) <= tolerance &&
               abs(other.minY - builtInFrame.minY) <= tolerance &&
               abs(other.width - builtInFrame.width) <= tolerance &&
               abs(other.height - builtInFrame.height) <= tolerance {
                continue
            }
            let overlap = windowFrame.intersection(other)
            if !overlap.isNull && overlap.width > tolerance && overlap.height > tolerance {
                return false
            }
        }
        return true
    }

    /// Returns true iff a captured pixel buffer matches the expected display dimensions
    /// (guarding against adopting a stale pre-resize capture across 2294x1490 <-> 2048x1330 switches).
    public static func captureMatchesScreen(
        imageWidth: Int,
        imageHeight: Int,
        screenSize: CGSize,
        pixelScale: CGFloat
    ) -> Bool {
        guard imageWidth > 0, imageHeight > 0, screenSize.width > 0, screenSize.height > 0 else {
            return false
        }
        let expectedW = screenSize.width * pixelScale
        let expectedH = screenSize.height * pixelScale
        // Allow modest pixel rounding (up to 4px) while rejecting resolution switches.
        return abs(CGFloat(imageWidth) - expectedW) <= 4 &&
               abs(CGFloat(imageHeight) - expectedH) <= 4
    }
}
