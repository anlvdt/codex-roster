import Foundation
import Testing
@testable import CodexRoster

@Test func desktopCodeResumeUsesFocusedLocalSessionFromCurrentAccountOnly() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let account = UUID(), org = UUID(), current = UUID()
    try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": account.uuidString])
        .write(to: root.appendingPathComponent("config.json"))
    func record(_ owner: UUID, _ id: UUID, _ focused: Double, archived: Bool = false) throws {
        let folder = root.appendingPathComponent("claude-code-sessions/\(owner.uuidString)/\(org.uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["cliSessionId": id.uuidString, "cwd": root.path,
            "lastFocusedAt": focused, "isArchived": archived])
            .write(to: folder.appendingPathComponent("local_\(UUID().uuidString).json"))
    }
    try record(account, UUID(), 1)
    try record(account, current, 10)
    try record(account, UUID(), 20, archived: true)
    try record(UUID(), UUID(), 100)
    let session = try #require(ClaudeDesktop.recentCodeSession(userData: root))
    #expect(session.id == current)
    #expect(session.cwd == root.path)
    let script = ClaudeSessionContinuity.commandScript(session: session, automaticallyContinue: true, inDesktop: true)
    #expect(script.contains("--desktop --resume '\(current.uuidString)'"))
    #expect(!script.contains("--fork-session"))
    #expect(!script.contains("Continue the task interrupted"))
}

@Test func desktopHandoffRunsInBackgroundAndReportsCommandFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bin = root.appendingPathComponent(".local/bin")
    let launch = root.appendingPathComponent("launch")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let stub = bin.appendingPathComponent("claude")
    try "#!/bin/zsh\nprintf '%s\\n' \"$@\" > arguments.txt\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
    let id = UUID()
    let script = launch.appendingPathComponent("resume.command")
    try ClaudeSessionContinuity.commandScript(session: .init(id: id, cwd: root.path), automaticallyContinue: false,
        inDesktop: true, home: root).write(to: script, atomically: true, encoding: .utf8)
    try await ClaudeSessionContinuity.runDesktopScript(script)
    let arguments = try String(contentsOf: root.appendingPathComponent("arguments.txt"), encoding: .utf8)
    #expect(arguments.split(separator: "\n").map(String.init) == ["--desktop", "--resume", id.uuidString])
    #expect(!FileManager.default.fileExists(atPath: script.path))
    let failure = root.appendingPathComponent("failure.command")
    try "exit 17\n".write(to: failure, atomically: true, encoding: .utf8)
    do {
        try await ClaudeSessionContinuity.runDesktopScript(failure)
        Issue.record("Expected the failing handoff to throw")
    } catch { #expect((error as NSError).code == 17) }
}
