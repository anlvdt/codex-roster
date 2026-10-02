import Foundation

/// Read-only adapter for the installed Desktop queue. Unknown formats fail closed.
enum CodexResumePolicy {
    enum QueueState: Equatable { case empty, owned, blocked, unavailable }
    static let continuation = "Continue the interrupted task after the account usage-limit switch."
    static func marker(_ threadID: String) -> String { "[Codex Roster auto-resume: \(threadID)]" }
    static func message(_ threadID: String) -> String { continuation + "\n" + marker(threadID) }

    static func queueState(data: Data, threadID: String) -> QueueState {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unavailable }
        guard let queues = root["queued-follow-ups"] as? [String: Any] else { return .unavailable }
        guard let value = queues[threadID] else { return .empty }
        guard let messages = value as? [[String: Any]] else { return .unavailable }
        guard !messages.isEmpty else { return .empty }
        // Resume releases the whole queue: never release unrelated user messages.
        guard messages.count == 1,
              let encoded = try? JSONSerialization.data(withJSONObject: messages[0]),
              let text = String(data: encoded, encoding: .utf8),
              text.contains(marker(threadID)) else { return .blocked }
        return .owned
    }

    static func readQueue(threadID: String) -> QueueState {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".codex-global-state.json")),
              data.count < 16_000_000 else { return .unavailable }
        return queueState(data: data, threadID: threadID)
    }

    static func isResumeLabel(_ label: String) -> Bool {
        ["resume", "tiếp tục"].contains(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
