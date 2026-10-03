import Foundation

/// Each enrollment gets a private config directory and Keychain namespace.
/// Only the verified snapshot is imported; the user's live login is untouched.
enum ClaudeCLIEnrollment {
    static func environment(config: URL, base: [String: String]) -> [String: String] {
        var result = base
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
                    "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
                    "CLAUDE_CODE_USE_FOUNDRY"] { result.removeValue(forKey: key) }
        result["CLAUDE_CONFIG_DIR"] = config.path
        return result
    }

    static func verifiedEmail(_ data: Data, expected: String) throws -> String {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["loggedIn"] as? Bool == true,
              value["authMethod"] as? String == "claude.ai",
              let email = value["email"] as? String, !email.isEmpty else {
            throw failure("Claude CLI chưa đăng nhập bằng tài khoản Claude subscription.")
        }
        guard expected.isEmpty || email.caseInsensitiveCompare(expected) == .orderedSame else {
            throw failure("Tài khoản đăng nhập khác email đã chọn. Hãy thử lại với đúng tài khoản.")
        }
        return email
    }

    static func login(email: String) async throws -> String {
        guard let roster = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("codex-roster") else { throw failure("Không tìm thấy CLI trong app.") }
        let operation = Task.detached(priority: .userInitiated) {
            let config = FileManager.default.temporaryDirectory
                .appendingPathComponent("roster-claude-login-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let env = environment(config: config, base: ProcessInfo.processInfo.environment)
            defer {
                // Remove the temporary Keychain item after import/cancel.
                let cleanup = Process()
                cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                // The service is computed by the same SHA-256 convention as CLI.
                cleanup.arguments = ["delete-generic-password", "-s", service(config.path)]
                cleanup.standardOutput = FileHandle.nullDevice
                cleanup.standardError = FileHandle.nullDevice
                if (try? cleanup.run()) != nil { cleanup.waitUntilExit() }
                try? FileManager.default.removeItem(at: config)
            }
            let binaryData = try await run(URL(fileURLWithPath: "/bin/zsh"),
                ["-lc", "command -v claude"], env: env, timeout: 15)
            let binary = String(decoding: binaryData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard binary.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: binary) else {
                throw failure("Chưa cài Claude Code CLI. Cài CLI rồi thử lại.")
            }
            var args = ["auth", "login", "--claudeai"]
            if !email.isEmpty { args += ["--email", email] }
            _ = try await run(URL(fileURLWithPath: binary), args, env: env, timeout: 600, capture: false)
            let status = try await run(URL(fileURLWithPath: binary), ["auth", "status"], env: env, timeout: 20)
            let verified = try verifiedEmail(status, expected: email)
            try Task.checkCancellation()
            let saved = try await run(roster, ["providers", "save", "claude", "--json"], env: env, timeout: 30)
            guard let output = try JSONSerialization.jsonObject(with: saved) as? [String: Any],
                  let account = output["account"] as? [String: Any],
                  let imported = account["email"] as? String,
                  imported.caseInsensitiveCompare(verified) == .orderedSame else {
                throw failure("Không xác minh được tài khoản vừa lưu. Hãy làm mới danh sách.")
            }
            return verified
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: { operation.cancel() }
    }

    private static func run(_ executable: URL, _ args: [String], env: [String: String],
                            timeout: TimeInterval, capture: Bool = true) async throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = args
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = capture ? pipe : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw failure("Đăng nhập quá thời gian chờ. Hãy thử lại.") }
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw failure("Claude CLI chưa hoàn tất thao tác. Kiểm tra kết nối, hoàn tất đăng nhập trong trình duyệt rồi thử lại.")
        }
        return capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ClaudeCLIEnrollment", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

import CryptoKit
extension ClaudeCLIEnrollment {
    static func service(_ path: String) -> String {
        "Claude Code-credentials-" + SHA256.hash(data: Data(path.utf8)).prefix(4)
            .map { String(format: "%02x", $0) }.joined()
    }
}
