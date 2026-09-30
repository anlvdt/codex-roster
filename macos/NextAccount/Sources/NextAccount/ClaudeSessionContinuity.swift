import AppKit
import Foundation

/// Claude Code keeps conversation history under ~/.claude/projects independently
/// of the OAuth credential. Resume only a recent turn whose last message is a
/// rate-limit error; proactive switches should leave the running session alone.
enum ClaudeSessionContinuity {
    struct InterruptedSession: Sendable {
        let id: UUID
        let cwd: String
    }

    private static let lookback: TimeInterval = 10 * 60
    private static let markerKey = "claudeResumedRateLimitedSessions"

    static func recentInterruptedSession() -> InterruptedSession? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let cutoff = Date().addingTimeInterval(-lookback)
        var recent: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff else { continue }
            recent.append((url, modified))
        }
        for (url, _) in recent.sorted(by: { $0.1 > $1.1 }) {
            if let session = interruptedSession(in: url) { return session }
        }
        return nil
    }

    private static func interruptedSession(in url: URL) -> InterruptedSession? {
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
            guard type == "assistant",
                  event["error"] as? String == "rate_limit",
                  event["apiErrorStatus"] as? Int == 429,
                  let rawID = event["sessionId"] as? String,
                  let id = UUID(uuidString: rawID),
                  let cwd = event["cwd"] as? String,
                  FileManager.default.fileExists(atPath: cwd) else { return nil }
            return InterruptedSession(id: id, cwd: cwd)
        }
        return nil
    }

    @MainActor
    static func resume(_ session: InterruptedSession) throws {
        var resumed = UserDefaults.standard.stringArray(forKey: markerKey) ?? []
        guard !resumed.contains(session.id.uuidString) else { return }

        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-roster-resume-\(session.id.uuidString).command")
        let prompt = "Continue the task interrupted by the Claude Code usage limit."
        let contents = """
        #!/bin/zsh -l
        cd -- \(shellQuote(session.cwd)) || exit 1
        claude --resume \(shellQuote(session.id.uuidString)) --fork-session \(shellQuote(prompt))
        rm -- "$0"
        """
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard NSWorkspace.shared.open(script) else {
            throw NSError(domain: "ClaudeSessionContinuity", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not open Claude Code continuation in Terminal"])
        }
        resumed.append(session.id.uuidString)
        UserDefaults.standard.set(Array(resumed.suffix(50)), forKey: markerKey)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
