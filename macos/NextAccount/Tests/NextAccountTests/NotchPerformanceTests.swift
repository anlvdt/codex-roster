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

@Test func compactQuotaKeepsCodexWhenThereIsNoAccount() {
    let quota = NotchQuotaSnapshot(codex: nil)
    #expect(quota.providerName == "Codex")
    #expect(quota.fivePercent == nil && quota.weekPercent == nil)
}
