import AppKit
import CryptoKit
import Darwin
import Foundation

/// Claude Code keeps conversation history under its credential scope's projects directory independently
/// of the OAuth credential. Manual switches open a fresh process with the saved
/// conversation; automatic continuation requires a recent rate-limit error.
enum ClaudeSessionContinuity {
    struct InterruptedSession: Sendable {
        let id: UUID
        let cwd: String
        let transcriptURL: URL?
        let transcriptSize: UInt64?
        let tailDigest: String?
        let configDirectory: URL?

        init(id: UUID, cwd: String, transcriptURL: URL? = nil, transcriptSize: UInt64? = nil,
             tailDigest: String? = nil, configDirectory: URL? = nil) {
            self.id = id
            self.cwd = cwd
            self.transcriptURL = transcriptURL
            self.transcriptSize = transcriptSize
            self.tailDigest = tailDigest
            self.configDirectory = configDirectory
        }
    }

    private static let lookback: TimeInterval = 10 * 60

    static func configDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".claude", isDirectory: true)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func recentInterruptedSession(
        requireRateLimit: Bool = true,
        projectsRoot: URL? = nil,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> InterruptedSession? {
        let scope = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let root = projectsRoot ?? configDirectory(environment: environment, home: home)
            .appendingPathComponent("projects", isDirectory: true)
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
            if let session = interruptedSession(in: url, requireRateLimit: requireRateLimit,
                                                configDirectory: scope) { return session }
        }
        return nil
    }

    static func interruptedSession(in url: URL, requireRateLimit: Bool = true,
                                   configDirectory: URL? = nil) -> InterruptedSession? {
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
            return InterruptedSession(id: id, cwd: cwd, transcriptURL: url, transcriptSize: size,
                                      tailDigest: digest(data), configDirectory: configDirectory)
        }
        return nil
    }

    @MainActor
    static func resume(_ session: InterruptedSession, automaticallyContinue: Bool = true,
                       expectedEmail: String? = nil, inDesktop: Bool = false) async throws {
        try await launch(session: session, automaticallyContinue: automaticallyContinue, expectedEmail: expectedEmail,
                         inDesktop: inDesktop)
    }

    static func validateAutomaticResume(_ session: InterruptedSession?, expectedEmail: String?,
                                        now: Date = .now) throws {
        guard let expectedEmail, !expectedEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure("The selected Claude account identity is missing. The conversation has not been resumed.")
        }
        guard let session, let transcript = session.transcriptURL,
              let modified = try? transcript.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              modified >= now.addingTimeInterval(-lookback),
              let current = interruptedSession(in: transcript, configDirectory: session.configDirectory),
              current.id == session.id, current.cwd == session.cwd,
              current.transcriptSize == session.transcriptSize, current.tailDigest == session.tailDigest else {
            throw failure("The interrupted Claude turn has changed. The conversation has not been resumed.")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ClaudeSessionContinuity", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Claim one exact interruption while Terminal starts/runs; persist success only
    /// after the authenticated resume command exits successfully. Failed claims retry.
    struct ResumeHandoff: Sendable {
        let pending: URL
        let receipt: URL
        let token: String
        let lockURL: URL

        // POSIX record locks are per-process, so serialize our threads as well.
        private static let processLock = NSLock()

        static func withLock<T>(at url: URL, _ operation: () throws -> T) throws -> T {
            processLock.lock()
            defer { processLock.unlock() }
            // Never unlink or replace this inode: zsystem flock locks the same file.
            let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw failure("Could not open the Claude handoff lock.") }
            defer { Darwin.close(fd) }
            var record = flock()
            record.l_type = Int16(F_WRLCK)
            record.l_whence = Int16(SEEK_SET)
            // Claim runs on the main actor; never wait for another process.
            while fcntl(fd, F_SETLK, &record) == -1 {
                if errno == EINTR { continue }
                if errno == EACCES || errno == EAGAIN {
                    throw failure("Claude handoff is busy. Retry resuming.")
                }
                throw failure("Could not acquire the Claude handoff lock. Retry resuming.")
            }
            defer {
                record.l_type = Int16(F_UNLCK)
                _ = fcntl(fd, F_SETLK, &record)
            }
            return try operation()
        }

        static func claim(_ session: InterruptedSession, root: URL, now: Date = .now) throws -> ResumeHandoff? {
            guard let transcript = session.transcriptURL, let tailDigest = session.tailDigest else {
                throw failure("The interrupted Claude event could not be identified.")
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let key = digest(Data("\(session.configDirectory?.path ?? "default")|\(transcript.path)|\(tailDigest)".utf8))
            let handoff = ResumeHandoff(pending: root.appendingPathComponent(key + ".pending"),
                                        receipt: root.appendingPathComponent(key + ".success"), token: UUID().uuidString,
                                        lockURL: root.appendingPathComponent(key + ".lock"))
            return try withLock(at: handoff.lockURL) {
                if FileManager.default.fileExists(atPath: handoff.receipt.path) { return nil }
                if let state = try? String(contentsOf: handoff.pending, encoding: .utf8) {
                    if let pid = Int32(state.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").last.map(String.init) ?? ""), pid > 0 {
                        if kill(pid, 0) == 0 || errno == EPERM { return nil }
                    } else {
                        // Read fresh metadata for the inode under this lock. A
                        // missing timestamp must never authorize replacing a claim.
                        let attributes = try FileManager.default.attributesOfItem(atPath: handoff.pending.path)
                        guard let modified = attributes[.modificationDate] as? Date else {
                            throw failure("Could not verify the Claude handoff age. Retry resuming.")
                        }
                        if now.timeIntervalSince(modified) < 60 { return nil }
                    }
                    try FileManager.default.removeItem(at: handoff.pending)
                }
                do { try Data("\(handoff.token):launching".utf8).write(to: handoff.pending, options: .withoutOverwriting) }
                catch let error as NSError where error.code == NSFileWriteFileExistsError { return nil }
                return handoff
            }
        }

        func release() {
            try? Self.withLock(at: lockURL) {
                guard let state = try? String(contentsOf: pending, encoding: .utf8),
                      state.hasPrefix(token + ":") else { return }
                try FileManager.default.removeItem(at: pending)
            }
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
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        configDirectory: URL? = nil,
        handoff: ResumeHandoff? = nil
    ) -> String {
        let arguments = inDesktop
            ? session.map { "--desktop --resume \(shellQuote($0.id.uuidString))" } ?? "--desktop"
            : session.map { "--resume \(shellQuote($0.id.uuidString)) --fork-session" } ?? "--resume"
        let prompt = !inDesktop && session != nil && automaticallyContinue
            ? " " + shellQuote("Continue the task interrupted by the Claude Code usage limit.") : ""
        let handoffSetup = handoff.map {
            """
            zmodload zsh/system || exit 1
            release_handoff() {
                local handoff_fd
                zsystem flock -t 5 -i 0.01 -f handoff_fd \(shellQuote($0.lockURL.path)) || return 1
                if [[ "$(/bin/cat -- \(shellQuote($0.pending.path)) 2>/dev/null)" == \(shellQuote($0.token + ":"))$$ ]]; then
                    if [[ "$1" == success ]]; then /usr/bin/touch -- \(shellQuote($0.receipt.path)); fi
                    /bin/rm -f -- \(shellQuote($0.pending.path))
                fi
                zsystem flock -u "$handoff_fd"
            }
            """
        } ?? ""
        let release = handoff == nil ? "" : "release_handoff; "
        let verification = expectedEmail.map { email in
            """
            expected_email=\(shellQuote(email))
            if [[ -n "$ANTHROPIC_API_KEY" || -n "$ANTHROPIC_AUTH_TOKEN" || -n "$CLAUDE_CODE_OAUTH_TOKEN" ]]; then
                print -r -- 'A shell credential overrides the saved Claude login. Remove the override before resuming.'
                \(release)
                read -r '?Press Enter to close.'
                exit 1
            fi
            if [[ -n "$ANTHROPIC_BASE_URL" || "$CLAUDE_CODE_USE_BEDROCK" == 1 || "$CLAUDE_CODE_USE_VERTEX" == 1 || "$CLAUDE_CODE_USE_FOUNDRY" == 1 ]]; then
                print -r -- 'A provider or gateway override is active. Remove it before resuming with the selected Claude account.'
                \(release)
                read -r '?Press Enter to close.'
                exit 1
            fi
            auth_json="$(claude auth status)"
            auth_result=$?
            actual_email="$(print -r -- "$auth_json" | /usr/bin/plutil -extract email raw -o - - 2>/dev/null)"
            logged_in="$(print -r -- "$auth_json" | /usr/bin/plutil -extract loggedIn raw -o - - 2>/dev/null)"
            if (( auth_result != 0 )) || [[ "$logged_in" != true || "${(L)actual_email}" != "${(L)expected_email}" ]]; then
                print -r -- 'Claude CLI did not confirm the selected account. The conversation has not been resumed. Check claude auth status and retry.'
                \(release)
                read -r '?Press Enter to close.'
                exit 1
            fi
            """
        } ?? ""
        let scope = session?.configDirectory ?? configDirectory
        let config = scope.map { "export CLAUDE_CONFIG_DIR=\(shellQuote($0.path))" } ?? "unset CLAUDE_CONFIG_DIR"
        let identityGuard = !inDesktop && automaticallyContinue
            && (expectedEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            ? "print -r -- 'The selected Claude account identity is missing. The conversation has not been resumed.'; exit 1" : ""
        let eventGuard: String
        if !inDesktop, automaticallyContinue, let session, let transcript = session.transcriptURL,
           let size = session.transcriptSize, let tailDigest = session.tailDigest {
            eventGuard = """
            transcript=\(shellQuote(transcript.path))
            transcript_mtime="$(/usr/bin/stat -f %m -- "$transcript" 2>/dev/null)"
            if [[ "$transcript_mtime" != <-> ]] || (( transcript_mtime < $(/bin/date +%s) - \(Int(lookback)) )) || [[ "$(/usr/bin/stat -f %z -- "$transcript" 2>/dev/null)" != \(shellQuote(String(size))) || "$(/usr/bin/tail -c 262144 -- "$transcript" 2>/dev/null | /usr/bin/shasum -a 256 | /usr/bin/cut -d ' ' -f 1)" != \(shellQuote(tailDigest)) ]]; then
                print -r -- 'The interrupted Claude turn has changed or expired. The conversation has not been resumed.'
                exit 1
            fi
            """
        } else { eventGuard = "" }
        let claim = handoff.map {
            """
            zsystem flock -t 5 -i 0.01 -f handoff_fd \(shellQuote($0.lockURL.path)) || exit 1
            if [[ "$(/bin/cat -- \(shellQuote($0.pending.path)) 2>/dev/null)" != \(shellQuote($0.token + ":launching")) ]]; then
                zsystem flock -u "$handoff_fd"
                exit 1
            fi
            print -r -- \(shellQuote($0.token + ":"))$$ > \(shellQuote($0.pending.path)) || { zsystem flock -u "$handoff_fd"; exit 1; }
            zsystem flock -u "$handoff_fd"
            """
        } ?? ""
        let acknowledge = handoff == nil ? "" : "if (( result == 0 )); then release_handoff success; else release_handoff; fi"
        return """
        #!/bin/zsh -l
        \(handoffSetup)
        trap \(shellQuote(release + "rm -f -- \"$0\"; rmdir -- \"${0:h}\"")) EXIT
        \(claim)
        cd -- \(shellQuote(session?.cwd ?? home.path)) || exit 1
        \(config)
        \(identityGuard)
        export PATH=\(shellQuote(home.appendingPathComponent(".local/bin").path)):\(shellQuote(home.appendingPathComponent(".npm-global/bin").path)):/opt/homebrew/bin:/usr/local/bin:$PATH
        if ! command -v claude >/dev/null 2>&1; then
            print -r -- 'Claude Code was not found. Install the CLI, then reopen the session.'
            \(release)
            read -r '?Press Enter to close.'
            exit 1
        fi
        \(verification)
        \(eventGuard)
        print -r -- \(shellQuote(inDesktop ? "Opening the saved Code session in Desktop. Check the Desktop account before continuing." : "A fresh Claude Code process will load the saved login. Check /status before continuing. Close the previous session."))
        claude \(arguments)\(prompt)
        result=$?
        \(acknowledge)
        if (( result != 0 )); then
            print -r -- 'Claude Code could not resume. The original conversation is still saved; use claude --resume to retry.'
            \(release)
            read -r '?Press Enter to close.'
        fi
        exit $result
        """
    }

    @MainActor
    private static func launch(session: InterruptedSession?, automaticallyContinue: Bool,
                               expectedEmail: String?, inDesktop: Bool) async throws {
        let automatic = automaticallyContinue && !inDesktop
        if automatic { try validateAutomaticResume(session, expectedEmail: expectedEmail) }
        let handoff: ResumeHandoff?
        if automatic, let session {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-roster-resume-receipts")
            guard let claim = try ResumeHandoff.claim(session, root: root) else { return }
            handoff = claim
        } else { handoff = nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-roster-\(UUID().uuidString)", isDirectory: true)
        let script = directory.appendingPathComponent("resume.command")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            try commandScript(session: session, automaticallyContinue: automaticallyContinue, expectedEmail: expectedEmail,
                              inDesktop: inDesktop,
                              configDirectory: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) },
                              handoff: handoff)
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
            if automatic { try validateAutomaticResume(session, expectedEmail: expectedEmail) }
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
            handoff?.release()
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
