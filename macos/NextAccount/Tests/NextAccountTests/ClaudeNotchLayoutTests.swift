import Testing
@testable import CodexRoster

@MainActor @Test func claudeNotchStatusRowsDoNotShrinkAccountViewport() {
    let plain = ClaudeRosterView.notchDeckHeight(accountCount: 2)
    let warning = ClaudeRosterView.notchDeckHeight(accountCount: 2, hasQuotaCaption: true)
    let saved = ClaudeRosterView.notchDeckHeight(accountCount: 2, hasMessage: true)
    let both = ClaudeRosterView.notchDeckHeight(accountCount: 2, hasQuotaCaption: true, hasMessage: true)
    #expect(abs(warning - plain - ClaudeRosterView.notchStatusRowHeight) < 0.01)
    #expect(abs(saved - plain - ClaudeRosterView.notchStatusRowHeight) < 0.01)
    #expect(abs(both - plain - 2 * ClaudeRosterView.notchStatusRowHeight) < 0.01)
    #expect(ClaudeRosterView.notchDeckHeight(accountCount: 50, hasQuotaCaption: true, hasMessage: true)
        == NotchRosterLayout.collapsedDeckHeight)
}
