import Foundation
import SQLite3

/// Read-only adapter for the installed Desktop queue. Unknown formats fail closed.
enum CodexResumePolicy {
    enum QueueState: Equatable { case empty, owned, blocked, unavailable }
    static let continuation = "Continue the interrupted task after the account usage-limit switch."
    static func marker(_ threadID: String) -> String { "[Codex Roster auto-resume: \(threadID)]" }
    static func message(_ threadID: String) -> String { continuation + "\n" + marker(threadID) }

    /// Legacy Electron global-state shape (`queued-follow-ups`). Kept for tests
    /// and older Desktop builds.
    static func queueState(data: Data, threadID: String) -> QueueState {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unavailable
        }
        // Missing key means this Desktop build no longer uses JSON queues —
        // callers should fall through to `queue_1.sqlite` via `readQueue`.
        guard let queues = root["queued-follow-ups"] as? [String: Any] else { return .unavailable }
        guard let value = queues[threadID] else { return .empty }
        guard let messages = value as? [[String: Any]] else { return .unavailable }
        return classifyMessages(messages.map { encodeJSON($0) }, threadID: threadID)
    }

    static func readQueue(threadID: String) -> QueueState {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")

        // Preferred: Desktop 26.x+ persists follow-ups in queue_1.sqlite.
        let sqliteState = queueStateFromSQLite(
            dbURL: home.appendingPathComponent("queue_1.sqlite"),
            threadID: threadID
        )
        switch sqliteState {
        case .owned, .blocked, .empty:
            return sqliteState
        case .unavailable:
            break
        }

        // Fallback: older global-state JSON. Treat a missing key as empty only
        // when the file exists and parses; otherwise unavailable.
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".codex-global-state.json")),
              data.count < 16_000_000 else { return .unavailable }
        let jsonState = queueState(data: data, threadID: threadID)
        if jsonState == .unavailable,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           root["queued-follow-ups"] == nil {
            // Modern Desktop with empty/migrated JSON and unreadable sqlite.
            return .unavailable
        }
        return jsonState
    }

    /// SQLite-backed queue (`queued_items.payload_json`).
    static func queueStateFromSQLite(dbURL: URL, threadID: String) -> QueueState {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return .unavailable }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            return .unavailable
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT payload_json FROM queued_items WHERE thread_id = ?1 ORDER BY queue_order ASC, created_at_ms ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return .unavailable
        }
        defer { sqlite3_finalize(stmt) }
        let nsThread = threadID as NSString
        sqlite3_bind_text(stmt, 1, nsThread.utf8String, -1, nil)

        var payloads: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 0) {
                payloads.append(String(cString: cstr))
            } else {
                return .unavailable
            }
        }
        return classifyPayloadTexts(payloads, threadID: threadID)
    }

    /// All queued items must be Roster-owned. Duplicates of our marker are OK
    /// (re-queue after a failed Resume press); any foreign draft blocks.
    static func classifyMessages(_ encodedMessages: [String?], threadID: String) -> QueueState {
        let texts = encodedMessages.compactMap { $0 }
        guard texts.count == encodedMessages.count else { return .unavailable }
        return classifyPayloadTexts(texts, threadID: threadID)
    }

    static func classifyPayloadTexts(_ texts: [String], threadID: String) -> QueueState {
        guard !texts.isEmpty else { return .empty }
        let mark = marker(threadID)
        guard texts.allSatisfy({ $0.contains(mark) }) else { return .blocked }
        return .owned
    }

    static func isResumeLabel(_ label: String) -> Bool {
        ["resume", "tiếp tục"].contains(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func encodeJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}
