import Foundation
import Testing
@testable import CodexRoster

@Test func claudeResetIncludesActualLocalClockAndDoesNotInventRecovery() {
    let future = Date().addingTimeInterval(3600)
    let window = ProviderUsageWindow(key: "five_hour", label: "5h", usedPercent: 100,
        remainingPercent: 0, resetAt: .init(value: future), used: nil, limit: nil, unit: nil,
        expectedUsedPercent: nil, aheadOfPace: nil, projectedExhaustionAt: nil, willLastToReset: nil)
    let clock = DateFormatter()
    clock.locale = AppLanguage.english.locale
    clock.timeZone = .current
    clock.dateFormat = "HH:mm dd/MM"
    #expect(window.resetDescription(in: .english)?.contains(clock.string(from: future)) == true)
    let expired = ProviderUsageWindow(key: "five_hour", label: "5h", usedPercent: 100,
        remainingPercent: 0, resetAt: .init(value: Date().addingTimeInterval(-60)), used: nil,
        limit: nil, unit: nil, expectedUsedPercent: nil, aheadOfPace: nil, projectedExhaustionAt: nil, willLastToReset: nil)
    #expect(expired.resetDescription(in: .english) == "reset pending")
    #expect(expired.remainingPercent == 0)
}

@Test func localClaudeObservationHasShorterFreshnessThanAPIQuota() {
    func account(detail: String?) -> ProviderAccount {
        ProviderAccount(id: UUID(), provider: .claude, email: "test@example.com", subject: "test",
            name: nil, customLabel: nil, planLabel: nil, isActive: true, updatedAt: .init(value: Date()),
            lastActivatedAt: nil, usage: .init(fetchedAt: .init(value: Date().addingTimeInterval(-180)),
                status: "ok", headlineWindow: nil, windows: [], detail: detail), usageError: nil,
            canActivate: true, activationBlockReason: nil)
    }
    #expect(!account(detail: "Claude Code statusline · local observation").hasFreshUsage)
    #expect(account(detail: nil).hasFreshUsage)
}

@Test(arguments: ["loggedOut", "gateway", "bedrock", "vertex", "foundry"])
func claudeResumeRejectsWrongAuthenticationRoute(route: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bin = root.appendingPathComponent(".local/bin")
    let launch = root.appendingPathComponent("launch")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let stub = bin.appendingPathComponent("claude")
    try """
    #!/bin/zsh
    if [[ "$1" == auth ]]; then
        print -r -- '{"loggedIn":\(route == "loggedOut" ? "false" : "true"),"email":"selected@example.com"}'
    else
        touch resumed.txt
    fi
    """.write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
    let script = launch.appendingPathComponent("resume.command")
    try ClaudeSessionContinuity.commandScript(session: .init(id: UUID(), cwd: root.path),
        automaticallyContinue: true, expectedEmail: "selected@example.com", home: root)
        .write(to: script, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path]
    let overrides = ["gateway": "ANTHROPIC_BASE_URL", "bedrock": "CLAUDE_CODE_USE_BEDROCK",
                     "vertex": "CLAUDE_CODE_USE_VERTEX", "foundry": "CLAUDE_CODE_USE_FOUNDRY"]
    if let key = overrides[route] { process.environment?[key] = route == "gateway" ? "https://example.invalid" : "1" }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 1)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("resumed.txt").path))
}
