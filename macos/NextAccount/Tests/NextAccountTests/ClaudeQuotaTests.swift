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
