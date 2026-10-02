import Foundation
import Testing
@testable import CodexRoster

@Test func passiveRefreshCoalescesRapidNavigationButEventuallyRefreshes() {
    var gate = PassiveRefreshGate(interval: 60)
    let first = gate.request(at: 100)
    let duplicate = gate.request(at: 100)
    let recent = gate.request(at: 159.999)
    let expired = gate.request(at: 160)
    let rollback = gate.request(at: 20)
    #expect(first && !duplicate && !recent && expired && rollback)
}

@Test func claudeCompactQuotaUsesClaudeWindowsAndResets() {
    let fiveReset = Date(timeIntervalSince1970: 2_000_000_000)
    let weekReset = fiveReset.addingTimeInterval(86_400)
    func window(_ key: String, remaining: Int, reset: Date) -> ProviderUsageWindow {
        .init(key: key, label: key, usedPercent: 100 - remaining,
              remainingPercent: remaining, resetAt: .init(value: reset), used: nil,
              limit: nil, unit: nil, expectedUsedPercent: nil, aheadOfPace: nil,
              projectedExhaustionAt: nil, willLastToReset: nil)
    }
    let account = ProviderAccount(id: UUID(), provider: .claude, email: "test@example.com",
        subject: nil, name: nil, customLabel: nil, planLabel: "Pro", isActive: true,
        updatedAt: .init(value: fiveReset), lastActivatedAt: nil,
        usage: .init(fetchedAt: .init(value: fiveReset), status: "ok", headlineWindow: nil,
            windows: [window("seven_day", remaining: 49, reset: weekReset),
                      window("five_hour", remaining: 73, reset: fiveReset),
                      window("seven_day_opus", remaining: 8, reset: weekReset)], detail: nil),
        usageError: nil, canActivate: true, activationBlockReason: nil)
    let quota = NotchQuotaSnapshot(claude: account)
    #expect(quota.providerName == "Claude Code")
    #expect(quota.fivePercent == 73)
    #expect(quota.weekPercent == 49)
    #expect(quota.fiveResetDate == fiveReset)
    #expect(quota.weeklyResetDate == weekReset)
    #expect(quota.bankedCount == 0)
}

@Test func compactQuotaKeepsProviderWhenThereIsNoAccount() {
    let claude = NotchQuotaSnapshot(claude: nil)
    #expect(claude.providerName == "Claude Code")
    #expect(claude.fivePercent == nil && claude.weekPercent == nil)
    #expect(claude.bankedCount == 0)
    let codex = NotchQuotaSnapshot(codex: nil)
    #expect(codex.providerName == "Codex")
    #expect(codex.fivePercent == nil && codex.weekPercent == nil)
}
