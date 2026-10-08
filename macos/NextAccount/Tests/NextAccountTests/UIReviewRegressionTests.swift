import Foundation
import Testing
@testable import CodexRoster

// All fixtures are in memory: no AccountStore, Desktop app, Keychain, or CLI.
private func uiReviewCodexAccount(archived: Bool, active: Bool = false) -> SavedAccount {
    SavedAccount(id: UUID(), provider: "openai", email: "fixture@example.invalid",
        name: nil, customLabel: nil, planLabel: "Plus", environment: "fixture",
        isActive: active, archived: archived, usage: nil, usageError: nil)
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
