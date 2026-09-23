import CoreGraphics
import Testing
@testable import CodexRoster

@Test func intentionalLingerOpensAfterStillnessDwell() {
    var tracker = NotchHoverIntent.Tracker(origin: CGPoint(x: 100, y: 800))
    var opened = false
    // ~280ms of near-still samples
    for _ in 0..<7 {
        let result = tracker.ingest(CGPoint(x: 101, y: 801))
        if result == .open {
            opened = true
            break
        }
        #expect(result == .keepWaiting)
    }
    #expect(opened)
}

@Test func horizontalDriveByAbortsBeforeOpen() {
    var tracker = NotchHoverIntent.Tracker(origin: CGPoint(x: 100, y: 800))
    // Sweep ~60pt horizontally in one sample interval — classic menu-bar drive-by.
    let result = tracker.ingest(CGPoint(x: 160, y: 800))
    #expect(result == .abortDriveBy)
}

@Test func restlessPointerTimesOutWithoutOpening() {
    var tracker = NotchHoverIntent.Tracker(origin: CGPoint(x: 100, y: 800))
    var last: NotchHoverIntent.SampleResult = .keepWaiting
    // Keep jiggling within linger radius so stillness never accumulates.
    for i in 0..<40 {
        let wobble = CGFloat(i % 2 == 0 ? 8 : -8)
        last = tracker.ingest(CGPoint(x: 100 + wobble, y: 800))
        if last == .abortTimeout || last == .open {
            break
        }
    }
    #expect(last == .abortTimeout)
}
