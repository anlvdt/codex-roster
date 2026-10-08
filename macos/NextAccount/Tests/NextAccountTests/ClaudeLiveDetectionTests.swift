import Foundation
import Testing
@testable import CodexRoster

@Test func claudeLiveDetectionRejectsMetadataWithoutSubscriptionAuthentication() throws {
    func status(_ value: [String: Any]) throws -> ClaudeLiveAuthStatus {
        try ClaudeLiveAuthStatus.parse(JSONSerialization.data(withJSONObject: value))
    }
    #expect(try status(["loggedIn": false, "email": "old@example.com"]).subscriptionEmail == nil)
    #expect(try status(["loggedIn": true, "authMethod": "api_key", "email": "a@example.com"]).subscriptionEmail == nil)
    #expect(try status(["loggedIn": true, "authMethod": "claude.ai"]).subscriptionEmail == nil)
    #expect(try status(["loggedIn": true, "authMethod": "claude.ai", "email": "A@example.com"]).subscriptionEmail == "A@example.com")
    #expect(throws: (any Error).self) { try ClaudeLiveAuthStatus.parse(Data("{}".utf8)) }
}

@Test func claudeLiveLabelRequiresBothAuthenticatedAccountAndFreshQuota() {
    #expect(!ClaudeLiveAuthStatus(loggedIn: false, authMethod: "none", email: "a@example.com")
        .verifiesQuota(email: "a@example.com", fresh: true))
    let status = ClaudeLiveAuthStatus(loggedIn: true, authMethod: "claude.ai", email: "A@example.com")
    #expect(status.verifiesQuota(email: "a@example.com", fresh: true))
    #expect(!status.verifiesQuota(email: "b@example.com", fresh: true))
    #expect(!status.verifiesQuota(email: "a@example.com", fresh: false))
}

@Test func claudeDetectionTimeoutStopsATerminationResistantProcess() async {
    let started = Date()
    do {
        _ = try await ClaudeLiveDetection.run(URL(fileURLWithPath: "/bin/zsh"),
            ["-c", "trap '' TERM; while true; do :; done"], timeout: 0.2)
        Issue.record("Expected detection timeout")
    } catch {
        #expect(Date().timeIntervalSince(started) < 3)
    }
}
