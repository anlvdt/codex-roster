import AppKit
import CoreGraphics

/// Measured MacBook camera-notch geometry from AppKit screen APIs.
///
/// Has-notch requires **both** a positive `safeAreaInsets.top` and a positive
/// camera gap from `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`. Either
/// alone is treated as non-notch so ear layout is never half-applied.
struct NotchGeometry: Equatable {
    /// Camera housing width in points (`right.minX - left.maxX`), or 0.
    var cameraWidth: CGFloat
    /// Menu-bar / notch band height (`safeAreaInsets.top`).
    var inset: CGFloat
    /// Horizontal center of the camera gap in **screen** coordinates.
    var centerX: CGFloat
    /// Preferred screen frame (also used for non-notch top-edge placement).
    var screenFrame: CGRect
    var backingScaleFactor: CGFloat

    var hasNotch: Bool { cameraWidth > 0 && inset > 0 }

    /// Compact ear-to-ear clearance: exact measured camera width (no fudge).
    var physicalClearance: CGFloat { hasNotch ? cameraWidth : 0 }

    /// Detect the best screen for notch chrome: largest `safeAreaInsets.top`,
    /// falling back to `main` / first screen for non-notch machines.
    static func detect(fallbackScreen: NSScreen? = nil) -> NotchGeometry {
        let screens = NSScreen.screens
        let preferred = screens.max { $0.safeAreaInsets.top < $1.safeAreaInsets.top }
            ?? fallbackScreen
            ?? NSScreen.main
            ?? screens.first

        guard let screen = preferred else {
            return NotchGeometry(
                cameraWidth: 0,
                inset: 0,
                centerX: 0,
                screenFrame: .zero,
                backingScaleFactor: 2
            )
        }

        let inset = screen.safeAreaInsets.top
        let frame = screen.frame
        let scale = max(screen.backingScaleFactor, 1)

        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let camera = max(0, right.minX - left.maxX)
            // Require both signals before committing to ear layout.
            if camera > 0, inset > 0 {
                let notchMidX = (left.maxX + right.minX) / 2
                return NotchGeometry(
                    cameraWidth: camera,
                    inset: inset,
                    centerX: notchMidX,
                    screenFrame: frame,
                    backingScaleFactor: scale
                )
            }
        }

        // Non-notch (external display, older Mac, lid-closed laptop):
        // centered pill under the top edge of the preferred screen.
        return NotchGeometry(
            cameraWidth: 0,
            inset: 0,
            centerX: frame.midX,
            screenFrame: frame,
            backingScaleFactor: scale
        )
    }

    /// Snap a point value to the pixel grid for the screen's backing scale.
    static func align(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let s = max(scale, 1)
        return (value * s).rounded() / s
    }

    /// Top-centered window frame, pixel-aligned, anchored on `centerX`.
    func windowFrame(width: CGFloat, height: CGFloat) -> NSRect {
        let scale = backingScaleFactor
        let w = Self.align(width, scale: scale)
        let h = Self.align(height, scale: scale)
        let x = Self.align(centerX - w / 2, scale: scale)
        let y = Self.align(screenFrame.maxY - h, scale: scale)
        return NSRect(x: x, y: y, width: w, height: h)
    }
}
