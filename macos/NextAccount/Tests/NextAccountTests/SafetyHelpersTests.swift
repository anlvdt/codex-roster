import Foundation
import Testing
@testable import CodexRoster

@Test func trustedTiboSourceURLAcceptsOnlyCanonicalStatusLinks() {
    #expect(
        trustedTiboSourceURL("https://x.com/thsottiaux/status/2090964822422949999")?.absoluteString
            == "https://x.com/thsottiaux/status/2090964822422949999"
    )
    for value in [
        "https://evil.example/phish",
        "file:///etc/passwd",
        "custom-handler://open",
        "https://x.com@evil.example/thsottiaux/status/2090964822422949999",
        "https://x.com/other/status/2090964822422949999",
        "https://x.com/thsottiaux/status/not-a-tweet",
        "https://x.com/thsottiaux/status/2090964822422949999?redirect=1",
    ] {
        #expect(trustedTiboSourceURL(value) == nil)
    }
}

@Test func bankedResetSwitchRequiresPaidUsableAccountMetadata() {
    #expect(bankedResetSwitchIsAllowed(
        planLabel: "Plus",
        usageError: nil,
        availableCount: 1
    ))
    #expect(!bankedResetSwitchIsAllowed(
        planLabel: "Free",
        usageError: nil,
        availableCount: 1
    ))
    #expect(!bankedResetSwitchIsAllowed(
        planLabel: "Go",
        usageError: nil,
        availableCount: 1
    ))
    #expect(!bankedResetSwitchIsAllowed(
        planLabel: nil,
        usageError: nil,
        availableCount: 1
    ))
    #expect(!bankedResetSwitchIsAllowed(
        planLabel: "Pro",
        usageError: "local recovery required",
        availableCount: 1
    ))
    #expect(!bankedResetSwitchIsAllowed(
        planLabel: "Pro",
        usageError: "credential key could not decrypt snapshot payload",
        availableCount: 1
    ))
    #expect(!bankedResetSwitchIsAllowed(
        planLabel: "Pro",
        usageError: "token refresh failed: invalid_grant",
        availableCount: 1
    ))
    #expect(!bankedResetSwitchIsAllowed(
        planLabel: "Pro",
        usageError: nil,
        availableCount: 0
    ))
}

@Test func contextMenuDeleteResolvesByCapturedAccountIDNotListIndex() {
    let first = SavedAccount(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        provider: "open_ai",
        email: "alpha@example.com",
        name: "Alpha",
        customLabel: nil,
        planLabel: "Pro",
        environment: "macos",
        isActive: false,
        archived: false,
        usage: nil,
        usageError: nil
    )
    let second = SavedAccount(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        provider: "open_ai",
        email: "beta@example.com",
        name: "Beta",
        customLabel: nil,
        planLabel: "Pro",
        environment: "macos",
        isActive: true,
        archived: false,
        usage: nil,
        usageError: nil
    )
    let accounts = [first, second]

    // Right-click on Beta must delete Beta even if Alpha is index 0 / "selected".
    let resolved = accountForContextMenuAction(in: accounts, capturedID: second.id)
    #expect(resolved?.id == second.id)
    #expect(resolved?.email == "beta@example.com")
    #expect(accountForContextMenuAction(in: accounts, capturedID: UUID()) == nil)
}

@Test func reloginResolvesByCapturedAccountIDNotFirstRequiresLogin() {
    let firstNeedsLogin = SavedAccount(
        id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
        provider: "open_ai",
        email: "alpha@example.com",
        name: "Alpha",
        customLabel: nil,
        planLabel: "Pro",
        environment: "macos",
        isActive: false,
        archived: false,
        usage: nil,
        usageError: "login required"
    )
    let secondNeedsLogin = SavedAccount(
        id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
        provider: "open_ai",
        email: "beta@example.com",
        name: "Beta",
        customLabel: nil,
        planLabel: "Pro",
        environment: "macos",
        isActive: false,
        archived: false,
        usage: nil,
        usageError: "login required"
    )
    let accounts = [firstNeedsLogin, secondNeedsLogin]

    #expect(firstNeedsLogin.requiresLogin)
    #expect(secondNeedsLogin.requiresLogin)

    // Regression: Login on Beta must not open Alpha (first requiresLogin).
    let buggyFirst = accounts.first { !$0.archived && $0.requiresLogin }?.id
    #expect(buggyFirst == firstNeedsLogin.id)

    let resolved = accountIDForReloginNotification(in: accounts, capturedID: secondNeedsLogin.id)
    #expect(resolved == secondNeedsLogin.id)
    #expect(resolved != buggyFirst)

    // Missing captured ID may fall back; an unknown captured ID must not.
    #expect(accountIDForReloginNotification(in: accounts, capturedID: nil) == firstNeedsLogin.id)
    #expect(accountIDForReloginNotification(in: accounts, capturedID: UUID()) == nil)
}

@Test func accountUsageDecodesSubscriptionPeriodAndLegacyCache() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let current = try decoder.decode(
        AccountUsage.self,
        from: Data(#"{"subscription_active_until":[2026,268,10,31,8,0,0,0,0]}"#.utf8)
    )
    #expect(current.subscriptionActiveUntil?.value.timeIntervalSince1970 == 1_790_332_268)

    let legacy = try decoder.decode(AccountUsage.self, from: Data("{}".utf8))
    #expect(legacy.subscriptionActiveUntil == nil)
}

@Test func deferredAccessTokenUnauthorizedIsNotNeedsAction() {
    let account = SavedAccount(
        id: UUID(),
        provider: "open_ai",
        email: "deferred@example.com",
        name: nil,
        customLabel: nil,
        planLabel: "Pro",
        environment: "macos",
        isActive: false,
        archived: false,
        usage: nil,
        usageError: "Usage unavailable [access_token_unauthorized]: OpenAI rejected the current access token, but the saved refresh token was not proven invalid."
    )

    #expect(account.hasDeferredAccessTokenRefresh)
    #expect(account.triage != .needsAction)
    #expect(account.triage == .resting)
    #expect(account.usageStatus(in: .english).contains("refresh safely on the next switch"))
    #expect(account.usageStatus(in: .vietnamese).contains("làm mới an toàn khi chuyển"))
}

@Test func fiveHourQuotaRemainsPrimaryAndWeeklyStaysIndependent() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let usage = try decoder.decode(
        AccountUsage.self,
        from: Data(#"""
        {
            "five_hour":{"remaining_percent":74,"reset_at":[2099,132,10,0,0,0,0,0,0]},
            "weekly":{"remaining_percent":22,"reset_at":[2099,136,10,0,0,0,0,0,0]}
        }
        """#.utf8)
    )
    let account = SavedAccount(
        id: UUID(),
        provider: "open_ai",
        email: "person@example.com",
        name: nil,
        customLabel: nil,
        planLabel: "Pro",
        environment: "macos",
        isActive: true,
        archived: false,
        usage: usage,
        usageError: nil
    )

    #expect(account.primaryQuotaWindow?.remainingPercent == 74)
    #expect(account.switchQuotaScore == 22)
    #expect(account.usageStatus(in: .vietnamese).contains("5 giờ còn 74%"))
    #expect(account.usageStatus(in: .vietnamese).contains("tuần còn 22%"))
}
