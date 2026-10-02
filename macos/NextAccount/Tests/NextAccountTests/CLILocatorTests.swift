import Foundation
import Testing
@testable import CodexRoster

@Test func bundledCLIWinsOverEnvironmentOverride() {
    let bundled = URL(fileURLWithPath: "/Applications/Codex Roster.app/Contents/MacOS/codex-roster")
    let result = CLILocator.invocation(
        bundled: bundled,
        environment: ["CODEX_ROSTER_CLI_PATH": "/bin/ls"]
    )
    #expect(result.executable == bundled)
    #expect(result.prefixArguments.isEmpty)
}

@Test func unbundledRunHonorsAbsoluteExecutableOverride() {
    let result = CLILocator.invocation(
        bundled: nil,
        environment: ["CODEX_ROSTER_CLI_PATH": "/bin/ls"]
    )
    #expect(result.executable.path.hasSuffix("/ls"))
    #expect(result.prefixArguments.isEmpty)
}

@Test func unbundledRunIgnoresLegacyAndInvalidOverrides() {
    for environment in [
        ["ACCOUNT_HUB_CLI_PATH": "/bin/ls"],
        ["NEXT_ACCOUNT_CLI_PATH": "/bin/ls"],
        ["CODEX_ROSTER_CLI_PATH": "relative/codex-roster"],
        ["CODEX_ROSTER_CLI_PATH": "/nonexistent/codex-roster"],
        ["CODEX_ROSTER_CLI_PATH": "/tmp"],
    ] {
        let result = CLILocator.invocation(bundled: nil, environment: environment)
        #expect(result.executable.path == "/usr/bin/env")
        #expect(result.prefixArguments == ["codex-roster"])
    }
}
