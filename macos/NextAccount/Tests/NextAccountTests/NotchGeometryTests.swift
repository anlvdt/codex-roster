import CoreGraphics
import Testing
@testable import CodexRoster

@Test func notchWindowFrameNudgesTopAboveScreenMaxY() {
    let geometry = NotchGeometry(
        cameraWidth: 180,
        inset: 37,
        centerX: 720.25,
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        backingScaleFactor: 2
    )
    let frame = geometry.windowFrame(width: 486.3, height: 37)
    let scale = geometry.backingScaleFactor
    let overscan = 1 / scale
    let h = NotchGeometry.align(37, scale: scale)
    // One physical pixel above the display; height unchanged.
    #expect(frame.height == h)
    #expect(frame.maxY == geometry.screenFrame.maxY + overscan)
    #expect(frame.minY == geometry.screenFrame.maxY - h + overscan)
    #expect(NotchGeometry.align(frame.minX, scale: scale) == frame.minX)
    let expectedMid = NotchGeometry.align(geometry.centerX, scale: scale)
    #expect(abs(frame.midX - expectedMid) < 0.6)
}

@Test func nonNotchWindowFrameStaysFlushWithoutOverscan() {
    let geometry = NotchGeometry(
        cameraWidth: 0,
        inset: 0,
        centerX: 960,
        screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        backingScaleFactor: 2
    )
    let frame = geometry.windowFrame(width: 270, height: 32)
    #expect(frame.maxY == geometry.screenFrame.maxY)
    #expect(frame.height == 32)
    #expect(frame.minY == geometry.screenFrame.maxY - 32)
}

@Test func windowFrameTopIsNotReRoundedIndependently() {
    // Guard: top must equal align(maxY) + overscan, not align(maxY - h) + h.
    let geometry = NotchGeometry(
        cameraWidth: 200,
        inset: 38,
        centerX: 800,
        screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000.25),
        backingScaleFactor: 2
    )
    let frame = geometry.windowFrame(width: 400, height: 38)
    let scale = geometry.backingScaleFactor
    let topFlush = NotchGeometry.align(geometry.screenFrame.maxY, scale: scale)
    let overscan = 1 / scale
    #expect(frame.maxY == topFlush + overscan)
}
