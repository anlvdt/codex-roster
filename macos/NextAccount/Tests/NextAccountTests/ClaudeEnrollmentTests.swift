import Foundation
import Testing
@testable import CodexRoster

@Test func enrollmentRejectsSignedOutWrongAccountAndAPILogin() throws {
    func payload(_ loggedIn: Bool, _ method: String, _ email: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["loggedIn": loggedIn, "authMethod": method, "email": email])
    }
    #expect(try ClaudeCLIEnrollment.verifiedEmail(payload(true, "claude.ai", "A@example.com"), expected: "a@example.com") == "A@example.com")
    for data in [try payload(false, "none", "a@example.com"),
                 try payload(true, "api_key", "a@example.com"),
                 try payload(true, "claude.ai", "b@example.com")] {
        #expect(throws: (any Error).self) {
            try ClaudeCLIEnrollment.verifiedEmail(data, expected: "a@example.com")
        }
    }
}

@Test func enrollmentIsolatesCredentialsAndRemovesShellOverrides() {
    let path = URL(fileURLWithPath: "/tmp/enrollment-test")
    let env = ClaudeCLIEnrollment.environment(config: path, base: [
        "HOME": "/home/test", "CLAUDE_CONFIG_DIR": "/old", "ANTHROPIC_API_KEY": "override",
        "CLAUDE_CODE_OAUTH_TOKEN": "override", "ANTHROPIC_BASE_URL": "override",
        "CLAUDE_CODE_USE_VERTEX": "1"])
    #expect(env["CLAUDE_CONFIG_DIR"] == path.path)
    #expect(env["HOME"] == "/home/test")
    #expect(env["ANTHROPIC_API_KEY"] == nil)
    #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    #expect(env["ANTHROPIC_BASE_URL"] == nil)
    #expect(env["CLAUDE_CODE_USE_VERTEX"] == nil)
    #expect(ClaudeCLIEnrollment.service("/Users/anle/.claude") == "Claude Code-credentials-f7a953a8")
    #expect(ClaudeCLIEnrollment.service("/tmp/a") != ClaudeCLIEnrollment.service("/tmp/b"))
}
