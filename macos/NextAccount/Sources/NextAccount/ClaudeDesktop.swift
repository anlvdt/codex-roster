import AppKit
import Foundation

/// Graceful Desktop lifecycle and account-scoped local Code session metadata.
@MainActor
enum ClaudeDesktop {
    static var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
            .contains { !$0.isTerminated }
    }

    static func open() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else {
            throw failure("Claude Desktop is not installed.")
        }
        try await relaunch(at: url)
    }

    static func restart() async throws {
        let url = try await prepareForSwitch()
        try await relaunch(at: url)
    }

    static func prepareForSwitch() async throws -> URL {
        let bundleID = "com.anthropic.claudefordesktop"
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw failure("Claude Desktop is not installed.")
        }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        for application in applications where !application.isTerminated {
            guard application.terminate() else {
                throw failure("Claude Desktop could not quit. Finish the active task and quit the app, then retry.")
            }
        }
        let deadline = Date().addingTimeInterval(10)
        while applications.contains(where: { !$0.isTerminated }) {
            guard Date() < deadline else {
                throw failure("Claude Desktop is still running. Finish the active task and quit the app, then retry.")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        return url
    }

    static func relaunch(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { application, error in
                if let error { continuation.resume(throwing: error) }
                else if application != nil { continuation.resume() }
                else { continuation.resume(throwing: failure("Could not reopen Claude Desktop.")) }
            }
        }
    }

    /// Read metadata only, scoped to Desktop's currently signed-in account.
    /// The engine's transcript stays in ~/.claude/projects and is handed back
    /// through the official `claude --desktop --resume <id>` command.
    nonisolated static func recentCodeSession(userData: URL? = nil) -> ClaudeSessionContinuity.InterruptedSession? {
        let root = (userData ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)).resolvingSymlinksInPath()
        guard let data = try? Data(contentsOf: root.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawAccount = config["lastKnownAccountUuid"] as? String,
              let account = UUID(uuidString: rawAccount) else { return nil }
        let accountRoot = root.appendingPathComponent("claude-code-sessions/\(rawAccount)", isDirectory: true)
        guard UUID(uuidString: accountRoot.lastPathComponent) == account,
              let enumerator = FileManager.default.enumerator(at: accountRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return nil }
        var best: (ClaudeSessionContinuity.InterruptedSession, Double)?
        for case let url as URL in enumerator {
            let relative = url.resolvingSymlinksInPath().pathComponents.dropFirst(accountRoot.pathComponents.count)
            guard relative.count == 2, UUID(uuidString: String(relative.first ?? "")) != nil,
                  url.lastPathComponent.hasPrefix("local_"), url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["isArchived"] as? Bool != true,
                  record["sshConfig"] == nil,
                  let cliID = record["cliSessionId"] as? String, let id = UUID(uuidString: cliID),
                  let cwd = record["cwd"] as? String, cwd.hasPrefix("/"),
                  let focused = (record["lastFocusedAt"] ?? record["lastActivityAt"]) as? Double,
                  focused.isFinite else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if let backend = record["backend"] as? [String: Any],
               let kind = backend["kind"] as? String, kind != "local" { continue }
            if best == nil || focused > best!.1 {
                best = (.init(id: id, cwd: cwd), focused)
            }
        }
        return best?.0
    }

    private nonisolated static func failure(_ message: String) -> NSError {
        NSError(domain: "ClaudeDesktop", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
