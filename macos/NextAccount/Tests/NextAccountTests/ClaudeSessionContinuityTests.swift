import Foundation
import Testing
@testable import CodexRoster

private func claudeTranscript(_ type: String, id: UUID, cwd: URL, extra: [String: Any] = [:]) throws -> String {
    var event: [String: Any] = ["type": type, "sessionId": id.uuidString, "cwd": cwd.path]
    event.merge(extra) { _, new in new }
    return String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
}

@Test func manualClaudeSwitchCanResumeWithoutQuotaErrorAndPreservesTranscript() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = UUID()
    let file = directory.appendingPathComponent("session.jsonl")
    let original = try claudeTranscript("user", id: id, cwd: directory) + "\n"
        + claudeTranscript("assistant", id: id, cwd: directory) + "\n"
        + claudeTranscript("assistant", id: UUID(), cwd: directory, extra: ["isSidechain": true]) + "\n"
    try original.write(to: file, atomically: true, encoding: .utf8)
    let session = try #require(ClaudeSessionContinuity.recentInterruptedSession(
        requireRateLimit: false, projectsRoot: directory
    ))
    #expect(session.id == id)
    #expect(session.cwd == directory.path)
    #expect(ClaudeSessionContinuity.recentInterruptedSession(projectsRoot: directory) == nil)
    #expect(try String(contentsOf: file, encoding: .utf8) == original)
}

@Test func automaticClaudeContinuationRequiresLastMainTurnToBeRateLimited() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = UUID()
    let file = directory.appendingPathComponent("session.jsonl")
    let rateLimit = try claudeTranscript("assistant", id: id, cwd: directory,
                                         extra: ["error": "rate_limit", "apiErrorStatus": 429])
    try (rateLimit + "\n{broken\n").write(to: file, atomically: true, encoding: .utf8)
    #expect(ClaudeSessionContinuity.interruptedSession(in: file)?.id == id)
    let laterTurn = try claudeTranscript("user", id: id, cwd: directory)
    try (rateLimit + "\n" + laterTurn).write(to: file, atomically: true, encoding: .utf8)
    #expect(ClaudeSessionContinuity.interruptedSession(in: file) == nil)
    #expect(ClaudeSessionContinuity.interruptedSession(in: file, requireRateLimit: false)?.id == id)
    #expect(ClaudeSessionContinuity.recentInterruptedSession(
        requireRateLimit: false, projectsRoot: directory, now: Date().addingTimeInterval(601)
    ) == nil)
}

@Test func claudeResumeScriptStartsFreshProcessWithExactIDAndNoManualPrompt() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("Claude resume ' space \(UUID().uuidString)")
    let bin = root.appendingPathComponent(".local/bin")
    let launch = root.appendingPathComponent("launch")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let stub = bin.appendingPathComponent("claude")
    try "#!/bin/zsh\nprintf '%s\\n' \"$@\" > arguments.txt\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
    let id = UUID()
    let session = ClaudeSessionContinuity.InterruptedSession(id: id, cwd: root.path)
    let script = launch.appendingPathComponent("resume.command")
    try ClaudeSessionContinuity.commandScript(session: session, automaticallyContinue: false, home: root)
        .write(to: script, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let arguments = try String(contentsOf: root.appendingPathComponent("arguments.txt"), encoding: .utf8)
    #expect(arguments.split(separator: "\n").map(String.init) == ["--resume", id.uuidString, "--fork-session"])
    #expect(!FileManager.default.fileExists(atPath: launch.path))
    let automatic = ClaudeSessionContinuity.commandScript(session: session, automaticallyContinue: true, home: root)
    #expect(automatic.contains("Continue the task interrupted"))
    let picker = ClaudeSessionContinuity.commandScript(session: nil, automaticallyContinue: false, home: root)
    #expect(picker.contains("claude --resume\n"))
    #expect(!picker.contains("--fork-session"))
}

@Test(arguments: ["match", "mismatch", "override"])
func claudeResumeVerifiesLoginBeforeLoadingConversation(scenario: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bin = root.appendingPathComponent(".local/bin")
    let launch = root.appendingPathComponent("launch")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let email = scenario == "mismatch" ? "old@example.com" : "new@example.com"
    let stub = bin.appendingPathComponent("claude")
    let stubContents = """
    #!/bin/zsh
    if [[ "$1" == auth && "$2" == status ]]; then
        print -r -- '{"loggedIn":true,"email":"\(email)"}'
    else
        print -r -- "$*" > resumed.txt
    fi
    """
    try stubContents.write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
    let session = ClaudeSessionContinuity.InterruptedSession(id: UUID(), cwd: root.path)
    let script = launch.appendingPathComponent("resume.command")
    try ClaudeSessionContinuity.commandScript(session: session, automaticallyContinue: false,
                                               expectedEmail: "new@example.com", home: root)
        .write(to: script, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path]
    if scenario == "override" { process.environment?["ANTHROPIC_API_KEY"] = "fixture" }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == (scenario == "match" ? 0 : 1))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("resumed.txt").path)
            == (scenario == "match"))
    #expect(!FileManager.default.fileExists(atPath: launch.path))
}
