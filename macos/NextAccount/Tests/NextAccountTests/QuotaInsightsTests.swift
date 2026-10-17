import Foundation
import Testing
@testable import CodexRoster

@Test func resetClockCountdownUsesCompactUnits() {
    let inThreeHours = Date().addingTimeInterval(3 * 3600 + 30)
    let label = ResetClockFormat.compact(inThreeHours, asClock: false, language: .english)
    #expect(label == "3H")
}

@Test func resetClockAbsoluteUsesTodayTime() {
    let calendar = Calendar.current
    var components = calendar.dateComponents([.year, .month, .day], from: Date())
    components.hour = 15
    components.minute = 20
    let date = calendar.date(from: components) ?? Date().addingTimeInterval(3600)
    let label = ResetClockFormat.compact(date, asClock: true, language: .english)
    #expect(label.contains("15") || label.contains("3:"))
}

@Test func notchVerificationMarksStaleUsage() {
    let fetched = Date().addingTimeInterval(-20 * 60)
    let verification: NotchQuotaVerification = .stale(ageSeconds: 20 * 60)
    #expect(verification.isStale)
    let caption = verification.caption(in: .english)
    #expect(caption?.contains("Stale") == true)
    #expect(fetched < Date())
}

@Test func activitySummaryCompactLabelIncludesWorking() {
    let activity = CodexActivitySummary(
        working: 2,
        waiting: 1,
        idle: 0,
        desktopRunning: true,
        entries: []
    )
    #expect(activity.compactLabel.contains("▶2"))
    #expect(activity.compactLabel.contains("?1"))
}
