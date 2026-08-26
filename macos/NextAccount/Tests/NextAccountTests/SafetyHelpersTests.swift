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
