import Foundation
import Testing
@testable import CodexRoster

@Test(arguments: ["none", "HTTP 429", "HTTP 401"])
func cachedClaudeQuotaIsNotVerifiedAfterLatestRequestFailed(error: String) {
    let account = ProviderAccount(id: UUID(), provider: .claude, email: "test@example.com",
        subject: nil, name: nil, customLabel: nil, planLabel: nil, isActive: true,
        updatedAt: .init(value: Date()), lastActivatedAt: nil,
        usage: .init(fetchedAt: .init(value: Date()), status: "ok", headlineWindow: nil, windows: [], detail: nil),
        usageError: error == "none" ? nil : error, canActivate: true, activationBlockReason: nil)
    #expect(account.hasFreshUsage == (error == "none"))
}

@Test func genericClaudeModelCapContributesToDisplayedUtilization() {
    let cap = ProviderUsageWindow(key: "seven_day_fable", label: "7 day Fable",
        usedPercent: 100, remainingPercent: 0, resetAt: nil, used: nil, limit: nil,
        unit: nil, expectedUsedPercent: nil, aheadOfPace: nil,
        projectedExhaustionAt: nil, willLastToReset: nil)
    let account = ProviderAccount(id: UUID(), provider: .claude, email: "test@example.com",
        subject: nil, name: nil, customLabel: nil, planLabel: nil, isActive: true,
        updatedAt: .init(value: Date()), lastActivatedAt: nil,
        usage: .init(fetchedAt: .init(value: Date()), status: "ok", headlineWindow: nil,
            windows: [cap], detail: nil), usageError: nil, canActivate: true, activationBlockReason: nil)
    #expect(account.bindingUtilization == 100)
}
