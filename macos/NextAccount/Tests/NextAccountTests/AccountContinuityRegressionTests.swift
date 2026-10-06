import Foundation
import Darwin
import Testing
@testable import CodexRoster

@Test func codexLoginWatchdogBoundsFailedAndAbandonedSignIn() {
    let start = Date(timeIntervalSince1970: 100)
    var failed = CodexLoginWatchdog(startedAt: start)
    #expect(failed.failure(exitStatus: 127, now: start)?.contains("127") == true)
    var running = CodexLoginWatchdog(startedAt: start)
    #expect(running.failure(exitStatus: nil, now: start.addingTimeInterval(899)) == nil)
    #expect(running.failure(exitStatus: nil, now: start.addingTimeInterval(900))?.contains("timed out") == true)
    var exited = CodexLoginWatchdog(startedAt: start)
    let exit = start.addingTimeInterval(300)
    #expect(exited.failure(exitStatus: 0, now: exit) == nil)
    #expect(exited.failure(exitStatus: 0, now: exit.addingTimeInterval(4)) == nil)
    #expect(exited.failure(exitStatus: 0, now: exit.addingTimeInterval(5))?.contains("usable account") == true)
}

private func waitForClaudeFixtureExit(_ process: Process, timeout: TimeInterval = 5) throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while process.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        throw NSError(domain: "ClaudeContinuityFixture", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Fixture process exceeded its deadline"])
    }
    process.waitUntilExit()
}

private func claudeFixtureInputPipe() throws -> Pipe {
    let input = Pipe()
    // Cleanup may race a child exiting. Return EPIPE instead of killing the runner.
    guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return input
}

private struct ClaudeContinuityFixture: Sendable {
    let root: URL
    let config: URL
    let transcript: URL
    let session: ClaudeSessionContinuity.InterruptedSession

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Claude ' fixture \(UUID().uuidString)")
        config = root.appendingPathComponent("custom config")
        let projects = config.appendingPathComponent("projects")
        let bin = root.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        transcript = projects.appendingPathComponent("session.jsonl")
        let id = UUID()
        let event: [String: Any] = ["type": "assistant", "sessionId": id.uuidString, "cwd": root.path,
                                   "error": "rate_limit", "apiErrorStatus": 429, "uuid": UUID().uuidString]
        try JSONSerialization.data(withJSONObject: event).write(to: transcript)
        session = try #require(ClaudeSessionContinuity.interruptedSession(in: transcript, configDirectory: config))
        let stub = bin.appendingPathComponent("claude")
        try """
        #!/bin/zsh
        if [[ "$1" == auth && "$2" == status ]]; then
            [[ "$FIXTURE_CASE" == authFailure ]] && exit 7
            if [[ "$FIXTURE_CASE" == changedDuringAuth ]]; then
                print -r -- '{"type":"user"}' >> "$FIXTURE_TRANSCRIPT"
            fi
            if [[ "$FIXTURE_CASE" == staleDuringAuth ]]; then
                /usr/bin/touch -t 200001010000 -- "$FIXTURE_TRANSCRIPT"
            fi
            if [[ "$FIXTURE_CASE" == holdAuth ]]; then
                /usr/bin/touch auth-started.txt
                read -r auth_input
            fi
            if [[ "$FIXTURE_CASE" == wrongAccount ]]; then
                print -r -- '{"loggedIn":true,"email":"old@example.com"}'
            else
                print -r -- '{"loggedIn":true,"email":"selected@example.com"}'
            fi
        else
            print -r -- "$CLAUDE_CONFIG_DIR" > scope.txt
            print -r -- "$*" > resumed.txt
            [[ "$FIXTURE_CASE" == resumeFailure ]] && exit 17
            exit 0
        fi
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
    }

    func run(_ scenario: String, handoff: ClaudeSessionContinuity.ResumeHandoff,
             expectedEmail: String? = "selected@example.com") throws -> Int32 {
        let launch = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
        let script = launch.appendingPathComponent("resume.command")
        try ClaudeSessionContinuity.commandScript(session: session, automaticallyContinue: true,
            expectedEmail: expectedEmail, home: root, handoff: handoff)
            .write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path,
                               "FIXTURE_CASE": scenario, "FIXTURE_TRANSCRIPT": transcript.path,
                               "CLAUDE_CONFIG_DIR": root.appendingPathComponent("wrong scope").path]
        if scenario == "gateway" { process.environment?["ANTHROPIC_BASE_URL"] = "https://example.invalid" }
        if scenario == "credential" { process.environment?["ANTHROPIC_API_KEY"] = "fixture" }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try waitForClaudeFixtureExit(process)
        return process.terminationStatus
    }
}

@Test(arguments: ["success", "authFailure", "wrongAccount", "resumeFailure", "missingIdentity",
                  "changedDuringAuth", "staleDuringAuth", "gateway", "credential"])
func automaticClaudeResumeAcknowledgesOnlyVerifiedSuccessfulHandoff(scenario: String) throws {
    let fixture = try ClaudeContinuityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let receipts = fixture.root.appendingPathComponent("receipts")
    let handoff = try #require(try ClaudeSessionContinuity.ResumeHandoff.claim(fixture.session, root: receipts))
    #expect(try ClaudeSessionContinuity.ResumeHandoff.claim(fixture.session, root: receipts) == nil)
    let status = try fixture.run(scenario, handoff: handoff,
                                expectedEmail: scenario == "missingIdentity" ? nil : "selected@example.com")
    #expect(status == (scenario == "success" ? 0 : scenario == "resumeFailure" ? 17 : 1))
    #expect(!FileManager.default.fileExists(atPath: handoff.pending.path))
    #expect(FileManager.default.fileExists(atPath: handoff.receipt.path) == (scenario == "success"))
    let attemptedResume = scenario == "success" || scenario == "resumeFailure"
    #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("resumed.txt").path) == attemptedResume)
    if scenario == "success" {
        #expect(try ClaudeSessionContinuity.ResumeHandoff.claim(fixture.session, root: receipts) == nil)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("scope.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == fixture.config.path)
    } else {
        let retry = try #require(try ClaudeSessionContinuity.ResumeHandoff.claim(fixture.session, root: receipts))
        retry.release()
    }
}

@Test func automaticClaudeResumeRevalidatesExactTurnAndRequiresIdentity() throws {
    let fixture = try ClaudeContinuityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try ClaudeSessionContinuity.validateAutomaticResume(fixture.session, expectedEmail: "selected@example.com")
    #expect(throws: NSError.self) {
        try ClaudeSessionContinuity.validateAutomaticResume(fixture.session, expectedEmail: nil)
    }
    #expect(throws: NSError.self) {
        try ClaudeSessionContinuity.validateAutomaticResume(fixture.session, expectedEmail: "  ")
    }
    // A later 429 in the same conversation must not resume the captured old event.
    var event = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.transcript)) as? [String: Any])
    event["uuid"] = UUID().uuidString
    try JSONSerialization.data(withJSONObject: event).write(to: fixture.transcript)
    #expect(throws: NSError.self) {
        try ClaudeSessionContinuity.validateAutomaticResume(fixture.session, expectedEmail: "selected@example.com")
    }
}

@Test func claudeDiscoveryAndLaunchUseTheSameCredentialScope() throws {
    let fixture = try ClaudeContinuityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let environment = ["CLAUDE_CONFIG_DIR": fixture.config.path]
    let session = try #require(ClaudeSessionContinuity.recentInterruptedSession(environment: environment, home: fixture.root))
    #expect(session.id == fixture.session.id)
    #expect(session.configDirectory?.path == fixture.config.path)
    #expect(ClaudeSessionContinuity.recentInterruptedSession(environment: [:], home: fixture.root) == nil)
    #expect(ClaudeSessionContinuity.configDirectory(environment: [:], home: fixture.root)
        == fixture.root.appendingPathComponent(".claude", isDirectory: true))
    let defaultScript = ClaudeSessionContinuity.commandScript(session: nil, automaticallyContinue: false, home: fixture.root)
    #expect(defaultScript.contains("unset CLAUDE_CONFIG_DIR"))
}

@Test func undeliveredClaudeHandoffExpiresWithoutPermanentlyClaimingSession() throws {
    let fixture = try ClaudeContinuityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let receipts = fixture.root.appendingPathComponent("receipts")
    let handoff = try #require(try ClaudeSessionContinuity.ResumeHandoff.claim(fixture.session, root: receipts))
    let expired = try #require(try ClaudeSessionContinuity.ResumeHandoff.claim(fixture.session, root: receipts,
                                                                         now: Date().addingTimeInterval(61)))
    #expect(expired.pending == handoff.pending)
    #expect(!FileManager.default.fileExists(atPath: handoff.receipt.path))
    handoff.release()
    #expect(FileManager.default.fileExists(atPath: expired.pending.path))
    expired.release()
}

@Test func failedClaudeVerificationReleasesClaimBeforeWaitingForInput() async throws {
    let fixture = try ClaudeContinuityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let receipts = fixture.root.appendingPathComponent("receipts")
    let handoff = try #require(try ClaudeSessionContinuity.ResumeHandoff.claim(fixture.session, root: receipts))
    let launch = fixture.root.appendingPathComponent("blocking-launch")
    try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
    let script = launch.appendingPathComponent("resume.command")
    try ClaudeSessionContinuity.commandScript(session: fixture.session, automaticallyContinue: true,
        expectedEmail: "selected@example.com", home: fixture.root, handoff: handoff)
        .write(to: script, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path, "ANTHROPIC_API_KEY": "fixture"]
    let input = try claudeFixtureInputPipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? waitForClaudeFixtureExit(process)
    }
    for _ in 0..<100 where FileManager.default.fileExists(atPath: handoff.pending.path) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(process.isRunning, "The fixture is waiting for Enter")
    #expect(!FileManager.default.fileExists(atPath: handoff.pending.path))
    #expect(!FileManager.default.fileExists(atPath: handoff.receipt.path))
    let retry = try #require(try ClaudeSessionContinuity.ResumeHandoff.claim(fixture.session, root: receipts))
    try input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
    try input.fileHandleForWriting.close()
    try waitForClaudeFixtureExit(process)
    #expect(FileManager.default.fileExists(atPath: retry.pending.path), "An old failure must not release a newer retry")
    retry.release()
}

private final class ClaudeClaimResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<ClaudeSessionContinuity.ResumeHandoff?, any Error>] = []

    func append(_ result: Result<ClaudeSessionContinuity.ResumeHandoff?, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        values.append(result)
    }

    func snapshot() -> [Result<ClaudeSessionContinuity.ResumeHandoff?, any Error>] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite(.serialized) struct ClaudeHandoffLockTests {
@Test func claudeHandoffExpirationSerializesThreadsAndKeepsTheLockInode() throws {
    let fixture = try ClaudeContinuityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let receipts = fixture.root.appendingPathComponent("receipts")
    let old = try #require(try ClaudeSessionContinuity.ResumeHandoff.claim(fixture.session, root: receipts))
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-61)],
                                         ofItemAtPath: old.pending.path)
    let inode = try FileManager.default.attributesOfItem(atPath: old.lockURL.path)[.systemFileNumber] as? NSNumber
    let results = ClaudeClaimResults()
    let started = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    try ClaudeSessionContinuity.ResumeHandoff.withLock(at: old.lockURL) {
        for _ in 0..<12 {
            group.enter()
            Thread {
                defer { group.leave() }
                started.signal()
                results.append(Result { try ClaudeSessionContinuity.ResumeHandoff.claim(fixture.session, root: receipts) })
            }.start()
        }
        for _ in 0..<12 { #expect(started.wait(timeout: .now() + 2) == .success) }
        #expect(group.wait(timeout: .now() + 0.1) == .timedOut)
        #expect(results.snapshot().isEmpty)
    }
    try #require(group.wait(timeout: .now() + 5) == .success)
    let claims = try results.snapshot().compactMap { try $0.get() }
    #expect(claims.count == 1, "Only one thread may replace an expired launch")
    let winner = try #require(claims.first)
    old.release()
    #expect(try String(contentsOf: winner.pending, encoding: .utf8) == winner.token + ":launching")
    winner.release()
    #expect(try FileManager.default.attributesOfItem(atPath: winner.lockURL.path)[.systemFileNumber] as? NSNumber == inode)
}

@Test func claudeHandoffExpirationAndShellAdoptionShareTheSameRecordLock() throws {
    let fixture = try ClaudeContinuityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let receipts = fixture.root.appendingPathComponent("receipts")
    let old = try #require(try ClaudeSessionContinuity.ResumeHandoff.claim(fixture.session, root: receipts))
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-61)],
                                         ofItemAtPath: old.pending.path)
    let launch = fixture.root.appendingPathComponent("locked-launch")
    try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
    let script = launch.appendingPathComponent("resume.command")
    try ClaudeSessionContinuity.commandScript(session: fixture.session, automaticallyContinue: true,
        expectedEmail: "selected@example.com", home: fixture.root, handoff: old)
        .write(to: script, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    // The wrapper reports delivery before the production script attempts adoption.
    process.arguments = ["-c", "print -r -- ready > \"$1\"; exec /bin/zsh \"$2\"", "fixture",
                         fixture.root.appendingPathComponent("delivered.txt").path, script.path]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path,
                           "FIXTURE_CASE": "holdAuth", "FIXTURE_TRANSCRIPT": fixture.transcript.path]
    let input = try claudeFixtureInputPipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    defer {
        try? input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? waitForClaudeFixtureExit(process)
    }
    let results = ClaudeClaimResults()
    let started = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    try ClaudeSessionContinuity.ResumeHandoff.withLock(at: old.lockURL) {
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("delivered.txt").path),
              ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        try #require(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("delivered.txt").path))
        group.enter()
        Thread {
            defer { group.leave() }
            started.signal()
            results.append(Result { try ClaudeSessionContinuity.ResumeHandoff.claim(fixture.session, root: receipts) })
        }.start()
        #expect(started.wait(timeout: .now() + 2) == .success)
        #expect(group.wait(timeout: .now() + 0.1) == .timedOut)
        #expect(process.isRunning)
        #expect(try String(contentsOf: old.pending, encoding: .utf8) == old.token + ":launching",
                "Shell PID adoption must wait for Swift's fcntl lock")
    }
    try #require(group.wait(timeout: .now() + 5) == .success)
    let outcome = try #require(results.snapshot().first)
    let result: ClaudeSessionContinuity.ResumeHandoff?
    switch outcome {
    case .success(let claim): result = claim
    case .failure(let error):
        // Shell adoption may own the OS lock when the competing Swift claim runs.
        #expect(error.localizedDescription.contains("busy"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("auth-started.txt").path),
              ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        try #require(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("auth-started.txt").path))
        result = nil
    }
    if let replacement = result {
        try waitForClaudeFixtureExit(process)
        #expect(process.terminationStatus == 1)
        #expect(try String(contentsOf: replacement.pending, encoding: .utf8) == replacement.token + ":launching")
        #expect(!FileManager.default.fileExists(atPath: old.receipt.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("resumed.txt").path))
        replacement.release()
    } else {
        #expect(try String(contentsOf: old.pending, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                == old.token + ":" + String(process.processIdentifier))
        #expect(try ClaudeSessionContinuity.ResumeHandoff.claim(fixture.session, root: receipts) == nil)
        try input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
        try waitForClaudeFixtureExit(process)
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: old.receipt.path))
    }
    #expect(FileManager.default.fileExists(atPath: old.lockURL.path))
}

@MainActor @Test func claudeHandoffContentionFailsImmediatelyWithoutChangingTheClaim() throws {
    let fixture = try ClaudeContinuityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let receipts = fixture.root.appendingPathComponent("receipts")
    let old = try #require(try ClaudeSessionContinuity.ResumeHandoff.claim(fixture.session, root: receipts))
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-61)],
                                         ofItemAtPath: old.pending.path)
    let ready = fixture.root.appendingPathComponent("lock-held.txt")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", """
        zmodload zsh/system || exit 1
        zsystem flock -t 2 -i 0.01 -f lock_fd "$1" || exit 1
        print -r -- ready > "$2"
        read -r fixture_input
        zsystem flock -u "$lock_fd"
        """, "fixture", old.lockURL.path, ready.path]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path]
    let input = try claudeFixtureInputPipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        try? input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? waitForClaudeFixtureExit(process)
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    try #require(FileManager.default.fileExists(atPath: ready.path))
    let started = ContinuousClock.now
    do {
        _ = try ClaudeSessionContinuity.ResumeHandoff.claim(fixture.session, root: receipts)
        Issue.record("A foreign OS lock must return a retryable error")
    } catch {
        #expect(error.localizedDescription.contains("busy") && error.localizedDescription.contains("Retry"))
    }
    old.release() // Best effort also returns immediately without mutating locked state.
    #expect(started.duration(to: .now) < .seconds(1))
    #expect(process.isRunning, "The fixture still owns the foreign record lock")
    #expect(try String(contentsOf: old.pending, encoding: .utf8) == old.token + ":launching")
    try input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
    try waitForClaudeFixtureExit(process)
    #expect(process.terminationStatus == 0)
    let replacement = try #require(try ClaudeSessionContinuity.ResumeHandoff.claim(fixture.session, root: receipts))
    old.release()
    #expect(try String(contentsOf: replacement.pending, encoding: .utf8) == replacement.token + ":launching")
    replacement.release()
    #expect(FileManager.default.fileExists(atPath: old.lockURL.path))
}
}
