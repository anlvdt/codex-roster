import Foundation
import Testing
@testable import CodexRoster

@Test func claudeScopedRunnerKeepsLoginWritesOutOfTheLiveDirectory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let live = root.appendingPathComponent("live")
    let isolated = root.appendingPathComponent("isolated")
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let credential = live.appendingPathComponent("fixture-login")
    try Data("original-account".utf8).write(to: credential)
    let env = ClaudeCLIEnrollment.environment(config: isolated, base: ["CLAUDE_CONFIG_DIR": live.path])
    _ = try await ClaudeLiveDetection.run(URL(fileURLWithPath: "/bin/zsh"),
        ["-c", "printf isolated-account > \"$CLAUDE_CONFIG_DIR/fixture-login\""], timeout: 2, environment: env)
    #expect(try String(contentsOf: credential, encoding: .utf8) == "original-account")
    #expect(try String(contentsOf: isolated.appendingPathComponent("fixture-login"), encoding: .utf8) == "isolated-account")
}

@Test func claudeCardLoginStatusUsesAuthInsteadOfSelectionOrQuota() throws {
    let signedIn = try ClaudeLiveAuthStatus.parse(Data(#"{"loggedIn":true,"authMethod":"claude.ai","email":"a@example.com"}"#.utf8))
    let signedOut = try ClaudeLiveAuthStatus.parse(Data(#"{"loggedIn":false}"#.utf8))
    #expect(ClaudeAccountLoginState.resolve(status: signedIn, email: "A@example.com") == .signedIn)
    #expect(ClaudeAccountLoginState.resolve(status: signedIn, email: "b@example.com") == .otherSession)
    #expect(ClaudeAccountLoginState.resolve(status: signedOut, email: "a@example.com") == .signedOut)
    let apiKey = ClaudeLiveAuthStatus(loggedIn: true, authMethod: "api_key", email: "a@example.com")
    #expect(ClaudeAccountLoginState.resolve(status: apiKey, email: "a@example.com") == .unverified)
    for email in [nil, "", "  "] as [String?] {
        let incomplete = ClaudeLiveAuthStatus(loggedIn: true, authMethod: "claude.ai", email: email)
        #expect(ClaudeAccountLoginState.resolve(status: incomplete, email: "a@example.com") == .unverified)
    }
    #expect(ClaudeAccountLoginState.resolve(status: nil, email: "a@example.com") == .unverified)
}

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

@Test func claudeAccountSignInVerifiesTheSelectedEmail() throws {
    let signedIn = ClaudeLiveAuthStatus(loggedIn: true, authMethod: "claude.ai", email: "A@example.com")
    #expect(try signedIn.requireSubscriptionEmail(expected: "a@example.com") == "A@example.com")
    #expect(throws: (any Error).self) { try signedIn.requireSubscriptionEmail(expected: "b@example.com") }
    let signedOut = ClaudeLiveAuthStatus(loggedIn: false, authMethod: "none", email: nil)
    #expect(throws: (any Error).self) { try signedOut.requireSubscriptionEmail(expected: "a@example.com") }
}
