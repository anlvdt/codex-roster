import Foundation
import Darwin
import Testing
@testable import CodexRoster

@Test func codexLoginWatchdogBoundsFailedAndAbandonedSignIn() {
    let start = Date(timeIntervalSince1970: 100)
    var failed = CodexLoginWatchdog(startedAt: start)
    #expect(failed.failure(exitStatus: 127, now: start)?.contains("127") == true)
    var running = CodexLoginWatchdog(startedAt: start)
    #expect(running.failure(exitStatus: nil, now: start.addingTimeInterval(899)) == nil)
    #expect(running.failure(exitStatus: nil, now: start.addingTimeInterval(900))?.contains("timed out") == true)
    var exited = CodexLoginWatchdog(startedAt: start)
    let exit = start.addingTimeInterval(300)
    #expect(exited.failure(exitStatus: 0, now: exit) == nil)
    #expect(exited.failure(exitStatus: 0, now: exit.addingTimeInterval(4)) == nil)
    #expect(exited.failure(exitStatus: 0, now: exit.addingTimeInterval(5))?.contains("usable account") == true)
}
