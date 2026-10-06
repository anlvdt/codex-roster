import Foundation
import Testing
@testable import CodexRoster

private let companionReset = Date(timeIntervalSince1970: 2_000_000_000)

private func companionCodexAccount(remaining: Int?, hasUsage: Bool = true) -> SavedAccount {
    let window = remaining.map { UsageWindow(remainingPercent: $0, resetAt: .init(value: companionReset)) }
    let usage = hasUsage ? AccountUsage(fetchedAt: .init(value: companionReset),
        fiveHour: window, weekly: .init(remainingPercent: 90, resetAt: .init(value: companionReset)),
        credits: nil, bankedResets: nil, subscriptionActiveUntil: nil, lunaReserve: nil) : nil
    return SavedAccount(id: UUID(), provider: "openai", email: "codex@example.com",
        name: nil, customLabel: nil, planLabel: "Plus", environment: "production",
        isActive: true, archived: false, usage: usage, usageError: nil)
}

private func companionClaudeAccount(remaining: Int?, hasUsage: Bool = true) -> ProviderAccount {
    func window(_ key: String, remaining: Int?) -> ProviderUsageWindow {
        .init(key: key, label: key, usedPercent: remaining.map { 100 - $0 },
              remainingPercent: remaining, resetAt: .init(value: companionReset), used: nil,
              limit: nil, unit: nil, expectedUsedPercent: nil, aheadOfPace: nil,
              projectedExhaustionAt: nil, willLastToReset: nil)
    }
    let usage = hasUsage ? ProviderUsage(fetchedAt: .init(value: companionReset), status: "ok",
        headlineWindow: nil, windows: [window("seven_day", remaining: 90),
            window("five_hour", remaining: remaining)], detail: nil) : nil
    return ProviderAccount(id: UUID(), provider: .claude, email: "claude@example.com",
        subject: nil, name: nil, customLabel: nil, planLabel: "Pro", isActive: true,
        updatedAt: .init(value: companionReset), lastActivatedAt: nil, usage: usage,
        usageError: nil, canActivate: true, activationBlockReason: nil)
}

@Test func companionQuotaRequiresFiveHourReading() {
    #expect(NotchCompanionQuota(codex: nil) == nil)
    #expect(NotchCompanionQuota(claude: nil) == nil)
    #expect(NotchCompanionQuota(codex: companionCodexAccount(remaining: nil, hasUsage: false)) == nil)
    #expect(NotchCompanionQuota(claude: companionClaudeAccount(remaining: nil, hasUsage: false)) == nil)
    // Weekly data alone must not replace the single-agent fallback.
    #expect(NotchCompanionQuota(codex: companionCodexAccount(remaining: nil)) == nil)
    #expect(NotchCompanionQuota(claude: companionClaudeAccount(remaining: nil)) == nil)
}

@Test func companionQuotaAcceptsExhaustedReadings() {
    #expect(NotchCompanionQuota(codex: companionCodexAccount(remaining: 0))?.fivePercent == 0)
    #expect(NotchCompanionQuota(codex: companionCodexAccount(remaining: 1))?.fivePercent == 0)
    #expect(NotchCompanionQuota(claude: companionClaudeAccount(remaining: 0))?.fivePercent == 0)
}

@Test func companionQuotaKeepsProviderAndFiveHourTelemetry() {
    let codex = NotchCompanionQuota(codex: companionCodexAccount(remaining: 73))
    #expect(codex?.screen == .codex)
    #expect(codex?.fivePercent == 73)
    #expect(codex?.fiveResetDate == companionReset)
    #expect(codex?.planLabel == "Plus")
    let claude = NotchCompanionQuota(claude: companionClaudeAccount(remaining: 49))
    #expect(claude?.screen == .claude)
    #expect(claude?.fivePercent == 49)
    #expect(claude?.fiveResetDate == companionReset)
    #expect(claude?.planLabel == "Pro")
}
