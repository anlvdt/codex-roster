import Foundation
import Testing
@testable import CodexRoster

// All fixtures are in memory: no AccountStore, Desktop app, Keychain, or CLI.
private func uiReviewCodexAccount(archived: Bool, active: Bool = false) -> SavedAccount {
    SavedAccount(id: UUID(), provider: "openai", email: "fixture@example.invalid",
        name: nil, customLabel: nil, planLabel: "Plus", environment: "fixture",
        isActive: active, archived: archived, usage: nil, usageError: nil)
}

private func uiReviewClaudeAccount(
    age: TimeInterval = 10, status: String = "ok", error: String? = nil,
    statusline: Bool = false, resetOffset: TimeInterval = 3_600
) -> ProviderAccount {
    let now = Date()
    let reset = RustDate(value: now.addingTimeInterval(resetOffset))
    func window(_ key: String, remaining: Int) -> ProviderUsageWindow {
        .init(key: key, label: key, usedPercent: 100 - remaining,
            remainingPercent: remaining, resetAt: reset, used: nil, limit: nil,
            unit: nil, expectedUsedPercent: nil, aheadOfPace: nil,
            projectedExhaustionAt: nil, willLastToReset: nil)
    }
    return ProviderAccount(id: UUID(), provider: .claude, email: "fixture@example.invalid",
        subject: nil, name: nil, customLabel: nil, planLabel: "Pro", isActive: true,
        updatedAt: .init(value: now), lastActivatedAt: nil,
        usage: .init(fetchedAt: .init(value: now.addingTimeInterval(-age)), status: status,
            headlineWindow: nil, windows: [window("five_hour", remaining: 61), window("seven_day", remaining: 83)],
            detail: statusline ? "Claude Code statusline" : nil),
        usageError: error, canActivate: true, activationBlockReason: nil)
}

@Test func uiReviewDisabledNotchAlwaysRoutesLauncherToSettings() {
    #expect(RosterLauncherDestination.resolve(notchEnabled: false) == .settings)
    #expect(RosterLauncherDestination.resolve(notchEnabled: true) == .notch)
}

@Test func uiReviewDisplayedRosterIncludesArchivedAccountsInNativeBudget() {
    let accounts = [uiReviewCodexAccount(archived: false, active: true), uiReviewCodexAccount(archived: false)]
        + (0..<8).map { _ in uiReviewCodexAccount(archived: true) }
    let all = NotchDisplayedRoster(accounts: accounts, filter: .all)
    #expect(all.accounts.count == 10)
    #expect(all.sectionCounts == [10])
    #expect(NotchRosterLayout.rosterGridHeight(sectionCounts: all.sectionCounts,
        expanded: true, maximumHeight: 10_000) == 456)
    #expect(NotchRosterLayout.needsRosterScroll(sectionCounts: all.sectionCounts,
        expanded: true, maximumHeight: 300))

    let active = NotchDisplayedRoster(accounts: accounts, filter: .triage(.active))
    #expect(active.accounts.map(\.id) == [accounts[0].id])
    #expect(NotchRosterLayout.rosterGridHeight(sectionCounts: active.sectionCounts,
        expanded: true, maximumHeight: 10_000) == 88)
    let archived = NotchDisplayedRoster(accounts: accounts, filter: .triage(.archived))
    #expect(archived.accounts.count == 8 && archived.sectionCounts == [8])
    let empty = NotchDisplayedRoster(accounts: accounts, filter: .triage(.ready))
    #expect(empty.accounts.isEmpty && empty.sectionCounts.isEmpty)
    #expect(NotchRosterLayout.rosterGridHeight(sectionCounts: empty.sectionCounts,
        expanded: true, maximumHeight: 10_000) == 88)
}

@Test func uiReviewReloginQueueCannotReplaceThePresentedAccount() {
    let first = UUID(), second = UUID(), third = UUID()
    let validIDs: Set<UUID> = [first, second, third]
    var queue = ReloginPresentationQueue()
    queue.enqueue([first, second, first])
    #expect(queue.takeNext(validIDs: validIDs) == first)
    queue.enqueue([second, third, first])
    #expect(queue.activeID == first)
    #expect(queue.pendingIDs == [second, third])
    #expect(queue.takeNext(validIDs: validIDs) == nil)
    queue.didDismiss() // Success and ordinary dismissal use the same transition.
    #expect(queue.takeNext(validIDs: validIDs) == second)
    queue.didDismiss()
    #expect(queue.takeNext(validIDs: validIDs) == third)
    queue.didDismiss()
    #expect(queue.takeNext(validIDs: validIDs) == nil)
}

@Test func uiReviewReloginQueueSkipsDeletedIDsAndCancelsTheRemainder() {
    let first = UUID(), deleted = UUID(), last = UUID()
    var queue = ReloginPresentationQueue()
    queue.enqueue([first, deleted, last])
    #expect(queue.takeNext(validIDs: [first, last]) == first)
    queue.didDismiss()
    #expect(queue.takeNext(validIDs: [first, last]) == last)
    queue.enqueue([first])
    queue.cancelPending()
    #expect(queue.activeID == last && queue.pendingIDs.isEmpty)
    queue.didDismiss()
    #expect(queue.takeNext(validIDs: [first, last]) == nil)
}

@Test func uiReviewFreshClaudeQuotaRemainsVerifiedInBothSnapshots() {
    let account = uiReviewClaudeAccount(statusline: true)
    #expect(account.hasFreshUsage)
    #expect(NotchQuotaSnapshot(claude: account).verification == .verified)
    #expect(NotchCompanionQuota(claude: account)?.verification == .verified)
    #expect(NotchQuotaVerification.verified.caption(in: .english) == nil)
}

@Test func uiReviewClaude429KeepsReadingsButLabelsThemCached() {
    let account = uiReviewClaudeAccount(error: "429 Too Many Requests")
    let primary = NotchQuotaSnapshot(claude: account)
    let companion = NotchCompanionQuota(claude: account)
    #expect(!account.hasFreshUsage)
    #expect(primary.fivePercent == 61 && primary.weekPercent == 83)
    #expect(companion?.fivePercent == 61)
    #expect(primary.verification == .cached && companion?.verification == .cached)
    #expect(primary.verification.caption(in: .english) == "Cached · unverified")
}

@Test(arguments: [
    uiReviewClaudeAccount(age: 121, statusline: true),
    uiReviewClaudeAccount(age: 901),
    uiReviewClaudeAccount(status: "unavailable"),
    uiReviewClaudeAccount(resetOffset: -2),
]) func uiReviewExpiredOrFailedClaudeQuotaCannotLookVerified(account: ProviderAccount) {
    #expect(!account.hasFreshUsage)
    #expect(NotchQuotaSnapshot(claude: account).verification == .cached)
    #expect(NotchCompanionQuota(claude: account)?.verification == .cached)
}

@Test func uiReviewMissingClaudeQuotaIsExplicitlyUnverified() {
    #expect(NotchQuotaSnapshot(claude: nil).verification == .unverified)
    #expect(NotchQuotaSnapshot(claude: nil).verification.caption(in: .english) == "Unverified")
    #expect(NotchCompanionQuota(claude: nil) == nil)
}

@Test func uiReviewUpdateMenuOffersInstallOnlyForAnAvailableRelease() {
    let update = GitHubUpdater.Update(version: "9.9.9",
        assetURL: URL(string: "https://example.invalid/fixture.zip")!, digest: "fixture")
    #expect(RosterUpdateMenuAction.resolve(.available(update)) == .install)
    for state: GitHubUpdater.State in [.idle, .upToDate, .failed("fixture failure")] {
        #expect(RosterUpdateMenuAction.resolve(state) == .check)
    }
    for state: GitHubUpdater.State in [.checking, .downloading, .installing] {
        #expect(RosterUpdateMenuAction.resolve(state) == .none)
    }
}

@Test func uiReviewBusyStoreKeepsLoginIDsPendingUntilIdle() {
    let id = UUID()
    var queue = ReloginPresentationQueue()
    queue.enqueue([id])
    #expect(queue.takeNext(isBusy: true, validIDs: [id]) == nil)
    #expect(queue.activeID == nil && queue.pendingIDs == [id])
    #expect(queue.takeNext(isBusy: false, validIDs: [id]) == id)
}

@Test func uiReviewAuxiliarySheetWaitsForLoginAndDismissal() {
    for busy in [false, true] {
        for auxiliary in [false, true] {
            for relogin in [false, true] {
                #expect(RosterSheetArbitration.canPresentAuxiliary(isBusy: busy,
                    auxiliaryActive: auxiliary, reloginActive: relogin) == (!busy && !auxiliary && !relogin))
            }
        }
    }
}

@MainActor @Test func reloginCompletionCannotTreatBusyStoreAsSuccess() async throws {
    var checks = 0
    try await ReloginActionReadiness.waitUntilIdle(attempts: 3, interval: .milliseconds(1)) {
        checks += 1
        return checks < 3
    }
    #expect(checks == 3)
    do {
        try await ReloginActionReadiness.waitUntilIdle(attempts: 2, interval: .milliseconds(1)) { true }
        Issue.record("A busy store must not report completion")
    } catch {
        #expect(error.localizedDescription.contains("running") || error.localizedDescription.contains("đang chạy"))
    }
}
