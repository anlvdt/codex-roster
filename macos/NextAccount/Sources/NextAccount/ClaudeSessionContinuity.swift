import AppKit
import Foundation

/// Claude Code keeps conversation history under ~/.claude/projects independently
/// of the OAuth credential. Manual switches open a fresh process with the saved
/// conversation; automatic continuation requires a recent rate-limit error.
enum ClaudeSessionContinuity {
    struct InterruptedSession: Sendable {
        let id: UUID
        let cwd: String
    }

    private static let lookback: TimeInterval = 10 * 60
    private static let markerKey = "claudeResumedRateLimitedSessions"

    static func recentInterruptedSession(
        requireRateLimit: Bool = true,
        projectsRoot: URL? = nil,
        now: Date = Date()
    ) -> InterruptedSession? {
        let root = projectsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let cutoff = now.addingTimeInterval(-lookback)
        var recent: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff else { continue }
            recent.append((url, modified))
        }
        for (url, _) in recent.sorted(by: { $0.1 > $1.1 }) {
            if let session = interruptedSession(in: url, requireRateLimit: requireRateLimit) { return session }
        }
        return nil
    }

    static func interruptedSession(in url: URL, requireRateLimit: Bool = true) -> InterruptedSession? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > 262_144 ? size - 262_144 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let event = object as? [String: Any],
                  event["isSidechain"] as? Bool != true,
                  let type = event["type"] as? String else { continue }
            guard type == "user" || type == "assistant" else { continue }
            if requireRateLimit {
                guard type == "assistant",
                      event["error"] as? String == "rate_limit",
                      event["apiErrorStatus"] as? Int == 429 else { return nil }
            }
            guard let rawID = event["sessionId"] as? String,
                  let id = UUID(uuidString: rawID),
                  let cwd = event["cwd"] as? String,
                  FileManager.default.fileExists(atPath: cwd) else { return nil }
            return InterruptedSession(id: id, cwd: cwd)
        }
        return nil
    }

    @MainActor
    static func resume(_ session: InterruptedSession, automaticallyContinue: Bool = true,
                       expectedEmail: String? = nil, inDesktop: Bool = false) async throws {
        var resumed = UserDefaults.standard.stringArray(forKey: markerKey) ?? []
        guard inDesktop || !automaticallyContinue || !resumed.contains(session.id.uuidString) else { return }
        try await launch(session: session, automaticallyContinue: automaticallyContinue, expectedEmail: expectedEmail,
                         inDesktop: inDesktop)
        if automaticallyContinue && !inDesktop {
            resumed.append(session.id.uuidString)
            UserDefaults.standard.set(Array(resumed.suffix(50)), forKey: markerKey)
        }
    }

    @MainActor
    static func openResumePicker(expectedEmail: String? = nil) async throws {
        try await launch(session: nil, automaticallyContinue: false, expectedEmail: expectedEmail, inDesktop: false)
    }

    static func commandScript(
        session: InterruptedSession?,
        automaticallyContinue: Bool,
        expectedEmail: String? = nil,
        inDesktop: Bool = false,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let arguments = inDesktop
            ? session.map { "--desktop --resume \(shellQuote($0.id.uuidString))" } ?? "--desktop"
            : session.map { "--resume \(shellQuote($0.id.uuidString)) --fork-session" } ?? "--resume"
        let prompt = !inDesktop && session != nil && automaticallyContinue
            ? " " + shellQuote("Continue the task interrupted by the Claude Code usage limit.") : ""
        let verification = expectedEmail.map { email in
            """
            expected_email=\(shellQuote(email))
            if [[ -n "$ANTHROPIC_API_KEY" || -n "$ANTHROPIC_AUTH_TOKEN" || -n "$CLAUDE_CODE_OAUTH_TOKEN" ]]; then
                print -r -- 'A shell credential overrides the saved Claude login. Remove the override before resuming.'
                read -r '?Press Enter to close.'
                exit 1
            fi
            if [[ -n "$ANTHROPIC_BASE_URL" || "$CLAUDE_CODE_USE_BEDROCK" == 1 || "$CLAUDE_CODE_USE_VERTEX" == 1 || "$CLAUDE_CODE_USE_FOUNDRY" == 1 ]]; then
                print -r -- 'A provider or gateway override is active. Remove it before resuming with the selected Claude account.'
                read -r '?Press Enter to close.'
                exit 1
            fi
            auth_json="$(claude auth status)"
            auth_result=$?
            actual_email="$(print -r -- "$auth_json" | /usr/bin/plutil -extract email raw -o - - 2>/dev/null)"
            logged_in="$(print -r -- "$auth_json" | /usr/bin/plutil -extract loggedIn raw -o - - 2>/dev/null)"
            if (( auth_result != 0 )) || [[ "$logged_in" != true || "${(L)actual_email}" != "${(L)expected_email}" ]]; then
                print -r -- 'Claude CLI did not confirm the selected account. The conversation has not been resumed. Check claude auth status and retry.'
                read -r '?Press Enter to close.'
                exit 1
            fi
            """
        } ?? ""
        return """
        #!/bin/zsh -l
        trap 'rm -f -- "$0"; rmdir -- "${0:h}"' EXIT
        cd -- \(shellQuote(session?.cwd ?? home.path)) || exit 1
        export PATH=\(shellQuote(home.appendingPathComponent(".local/bin").path)):\(shellQuote(home.appendingPathComponent(".npm-global/bin").path)):/opt/homebrew/bin:/usr/local/bin:$PATH
        if ! command -v claude >/dev/null 2>&1; then
            print -r -- 'Claude Code was not found. Install the CLI, then reopen the session.'
            read -r '?Press Enter to close.'
            exit 1
        fi
        \(verification)
        print -r -- \(shellQuote(inDesktop ? "Opening the saved Code session in Desktop. Check the Desktop account before continuing." : "A fresh Claude Code process will load the saved login. Check /status before continuing. Close the previous session."))
        claude \(arguments)\(prompt)
        result=$?
        if (( result != 0 )); then
            print -r -- 'Claude Code could not resume. The original conversation is still saved; use claude --resume to retry.'
            read -r '?Press Enter to close.'
        fi
        exit $result
        """
    }

    @MainActor
    private static func launch(session: InterruptedSession?, automaticallyContinue: Bool,
                               expectedEmail: String?, inDesktop: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-roster-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let script = directory.appendingPathComponent("resume.command")
        do {
            try commandScript(session: session, automaticallyContinue: automaticallyContinue, expectedEmail: expectedEmail,
                              inDesktop: inDesktop)
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            if inDesktop {
                try await runDesktopScript(script)
                try? FileManager.default.removeItem(at: directory)
                return
            }
            // Explicitly choose Terminal: .command may be associated with an editor.
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw NSError(domain: "ClaudeSessionContinuity", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Terminal is not installed"])
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: .init()) { application, error in
                    if let error { continuation.resume(throwing: error) }
                    else if application != nil { continuation.resume() }
                    else {
                        continuation.resume(throwing: NSError(domain: "ClaudeSessionContinuity", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Could not open Claude Code continuation in Terminal"]))
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Run the official Desktop handoff without opening a Terminal window.
    static func runDesktopScript(_ script: URL, timeout: TimeInterval = 60) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Task.isCancelled || Date() >= deadline {
                    process.terminate()
                    throw NSError(domain: "ClaudeDesktop", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "Desktop Code did not finish opening the saved session. Check Desktop and retry; the transcript is still saved."])
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "ClaudeDesktop", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey:
                    "Could not open the saved Code session in Desktop. Check the selected login and Claude Code version (2.1.285 or newer), then retry. The transcript is still saved."])
            }
        }.value
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
