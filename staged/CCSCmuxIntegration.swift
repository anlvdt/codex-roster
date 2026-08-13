import Foundation

enum CCSCmuxIntegration {
    struct IntegrationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct CommandResult: Sendable {
        let output: String
        let error: String
        let status: Int32
    }

    static func prepareForAccountSwitch(email: String) async throws {
        try await ensureNoActiveSessions()
        let ccs = try resolveCCSExecutable()
        let accounts = try await run(ccs, arguments: ["codex", "--accounts"])
        guard accounts.status == 0, accountList(accounts.output + "\n" + accounts.error, contains: email) else {
            throw IntegrationError(message: localized(
                "Không thể liên kết tự động tài khoản \(email) với CCS. Hãy thử chuyển lại; nếu lỗi lặp lại, credential của tài khoản này có thể đã hết hạn.",
                "Could not automatically link account \(email) with CCS. Try switching again; if the error repeats, this account's credential may have expired."
            ))
        }
    }

    static func ensureNoActiveSessions() async throws {
        let ccs = try resolveCCSExecutable()
        let status = try await run(ccs, arguments: ["cliproxy", "status"])
        guard status.status == 0 else {
            throw commandError(
                vietnamese: "Không thể kiểm tra trạng thái CCS trước khi chuyển tài khoản.",
                english: "Could not check CCS status before switching accounts.",
                result: status
            )
        }
        guard let sessions = activeSessionCount(in: status.output + "\n" + status.error) else {
            throw IntegrationError(message: localized(
                "Không thể xác minh CCS có đang xử lý yêu cầu hay không. Hãy chạy `ccs cliproxy status` rồi thử lại.",
                "Could not verify whether CCS is processing a request. Run `ccs cliproxy status`, then try again."
            ))
        }
        guard sessions == 0 else {
            throw IntegrationError(message: localized(
                "CCS đang có \(sessions) phiên hoạt động. Hãy chờ các yêu cầu trong cmux hoàn tất rồi chuyển tài khoản.",
                "CCS has \(sessions) active session(s). Wait for the requests in cmux to finish before switching accounts."
            ))
        }

    }

    static func persistDiscoveredAccounts() async throws {
        let ccs = try resolveCCSExecutable()
        let resolvedCCS = URL(fileURLWithPath: ccs).resolvingSymlinksInPath()
        let registry = resolvedCCS
            .deletingLastPathComponent()
            .appendingPathComponent("cliproxy/accounts/registry.js")
            .path
        guard FileManager.default.isReadableFile(atPath: registry) else {
            throw IntegrationError(message: localized(
                "CCS đã nhận credential nhưng không tìm thấy module đăng ký account tương thích. Hãy cập nhật CCS rồi thử lại.",
                "CCS received the credential, but its compatible account-registration module was not found. Update CCS and try again."
            ))
        }
        let nodeCandidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        guard let node = nodeCandidates.first(where: isExecutable) else {
            throw IntegrationError(message: localized(
                "Không tìm thấy Node.js để hoàn tất đăng ký account CCS.",
                "Node.js was not found to finish CCS account registration."
            ))
        }
        let result = try await run(
            node,
            arguments: [
                "-e",
                "require(process.argv[1]).discoverExistingAccounts()",
                registry
            ]
        )
        guard result.status == 0 else {
            throw commandError(
                vietnamese: "Không thể hoàn tất registry account CCS.",
                english: "Could not finish the CCS account registry.",
                result: result
            )
        }
    }

    static func selectAccountAndLaunchCmux(email: String) async throws {
        let ccs = try resolveCCSExecutable()
        let selected = try await run(
            ccs,
            arguments: ["cliproxy", "default", email, "--provider", "codex"]
        )
        guard selected.status == 0 else {
            throw commandError(
                vietnamese: "Codex Roster đã chuyển phiên, nhưng CCS không chọn được tài khoản \(email).",
                english: "Codex Roster switched sessions, but CCS could not select account \(email).",
                result: selected
            )
        }

        let cmux = try resolveCmuxExecutable()
        try await ensureCmuxRunning(cmux)
        let command = try interactiveClaudeCommand()
        var launched = try await run(
            cmux,
            arguments: [
                "new-workspace",
                "--name", "CCS Codex · \(email)",
                "--cwd", FileManager.default.homeDirectoryForCurrentUser.path,
                "--command", command,
                "--focus", "true"
            ]
        )
        // cmux may accept the launch request a fraction before its socket is
        // ready. Re-probe and retry once rather than surfacing a transient
        // socket-not-found error to the user.
        if launched.status != 0, isSocketMissing(launched) {
            try await ensureCmuxRunning(cmux)
            launched = try await run(
                cmux,
                arguments: [
                    "new-workspace",
                    "--name", "CCS Codex · \(email)",
                    "--cwd", FileManager.default.homeDirectoryForCurrentUser.path,
                    "--command", command,
                    "--focus", "true"
                ]
            )
        }
        guard launched.status == 0 else {
            let detail = (launched.error + "\n" + launched.output).lowercased()
            if detail.contains("access denied") {
                throw IntegrationError(message: localized(
                    "CCS đã chuyển sang \(email), nhưng cmux đang chặn điều khiển từ app ngoài. Chạy `launchctl setenv CMUX_SOCKET_MODE allowAll`, thoát hẳn cmux rồi mở lại.",
                    "CCS switched to \(email), but cmux blocks external automation. Run `launchctl setenv CMUX_SOCKET_MODE allowAll`, fully quit cmux, then reopen it."
                ))
            }
            throw commandError(
                vietnamese: "CCS đã chuyển sang \(email), nhưng không mở được workspace cmux.",
                english: "CCS switched to \(email), but the cmux workspace could not be opened.",
                result: launched
            )
        }
    }

    /// Prevent CLIProxy's round-robin pool from routing a Claude session through
    /// a Free Codex account after Roster has selected a paid account.
    static func pauseFreeAccounts(_ emails: [String]) async throws {
        let ccs = try resolveCCSExecutable()
        for email in Set(emails.map { $0.lowercased() }) where !email.isEmpty {
            let result = try await run(
                ccs,
                arguments: ["cliproxy", "pause", email, "--provider", "codex"]
            )
            guard result.status == 0 else {
                let detail = (result.error + "\n" + result.output).lowercased()
                if detail.contains("already paused") {
                    continue
                }
                throw commandError(
                    vietnamese: "Không thể loại tài khoản Free \(email) khỏi pool CCS.",
                    english: "Could not exclude Free account \(email) from the CCS pool.",
                    result: result
                )
            }
        }
    }

    private static func ensureCmuxRunning(_ cmux: String) async throws {
        let initial = try await run(cmux, arguments: ["ping"])
        guard initial.status != 0 else { return }
        guard isSocketMissing(initial) else {
            throw commandError(
                vietnamese: "Không thể kết nối với cmux trước khi mở workspace.",
                english: "Could not connect to cmux before opening the workspace.",
                result: initial
            )
        }

        let app = try resolveCmuxApplication()
        let open = try await run("/usr/bin/open", arguments: [app])
        guard open.status == 0 else {
            throw commandError(
                vietnamese: "Không thể khởi động cmux.",
                english: "Could not start cmux.",
                result: open
            )
        }

        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(100))
            let probe = try await run(cmux, arguments: ["ping"])
            if probe.status == 0 {
                return
            }
        }
        throw IntegrationError(message: localized(
            "cmux đã được mở nhưng socket chưa sẵn sàng. Hãy thử lại sau vài giây.",
            "cmux was opened but its socket is not ready yet. Try again in a few seconds."
        ))
    }

    private static func isSocketMissing(_ result: CommandResult) -> Bool {
        let detail = (result.error + "\n" + result.output).lowercased()
        return detail.contains("socket not found") || detail.contains("cmux.sock")
    }

    private static func interactiveClaudeCommand() throws -> String {
        let ccs = try resolveCCSExecutable()
        return "\(shellQuote(ccs)) codex"
    }

    static func activeSessionCount(in output: String) -> Int? {
        if output.localizedCaseInsensitiveContains("not running") {
            return 0
        }
        for line in output.split(whereSeparator: \Character.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("Sessions") == .orderedSame else {
                continue
            }
            return parts[1]
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
                .first
        }
        return nil
    }

    static func accountList(_ output: String, contains email: String) -> Bool {
        let target = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return false }
        let plainOutput = output.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        return plainOutput
            .split(whereSeparator: \Character.isWhitespace)
            .map { token in
                token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}<>,;\"'"))
                    .lowercased()
            }
            .contains(target)
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func resolveCCSExecutable() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["CODEX_ROSTER_CCS_PATH"],
            "\(NSHomeDirectory())/.local/bin/ccs",
            "/opt/homebrew/bin/ccs",
            "/usr/local/bin/ccs"
        ]
        guard let executable = candidates.compactMap({ $0 }).first(where: isExecutable) else {
            throw IntegrationError(message: localized(
                "Không tìm thấy CCS. Hãy cài `npm install -g @kaitranntt/ccs` hoặc đặt CODEX_ROSTER_CCS_PATH.",
                "CCS was not found. Install `npm install -g @kaitranntt/ccs` or set CODEX_ROSTER_CCS_PATH."
            ))
        }
        return executable
    }

    private static func resolveCCSSettings() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["CODEX_ROSTER_CCS_SETTINGS_PATH"],
            "\(NSHomeDirectory())/.ccs/codex.settings.json"
        ]
        guard let settings = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.isReadableFile(atPath: $0)
        }) else {
            throw IntegrationError(message: localized(
                "Không tìm thấy ~/.ccs/codex.settings.json để mở Claude CLI qua CCS.",
                "~/.ccs/codex.settings.json was not found for launching Claude CLI through CCS."
            ))
        }
        return settings
    }

    private static func resolveClaudeExecutable() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["CODEX_ROSTER_CLAUDE_PATH"],
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        guard let executable = candidates.compactMap({ $0 }).first(where: isExecutable) else {
            throw IntegrationError(message: localized(
                "Không tìm thấy Claude CLI. Hãy cài Claude Code hoặc đặt CODEX_ROSTER_CLAUDE_PATH.",
                "Claude CLI was not found. Install Claude Code or set CODEX_ROSTER_CLAUDE_PATH."
            ))
        }
        return executable
    }

    private static func resolveCmuxExecutable() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["CODEX_ROSTER_CMUX_PATH"],
            "\(NSHomeDirectory())/.local/bin/cmux",
            "/usr/local/bin/cmux",
            "/opt/homebrew/bin/cmux",
            "/Applications/cmux.app/Contents/Resources/bin/cmux"
        ]
        guard let executable = candidates.compactMap({ $0 }).first(where: isExecutable) else {
            throw IntegrationError(message: localized(
                "Không tìm thấy cmux. Hãy cài cmux hoặc đặt CODEX_ROSTER_CMUX_PATH.",
                "cmux was not found. Install cmux or set CODEX_ROSTER_CMUX_PATH."
            ))
        }
        return executable
    }

    private static func resolveCmuxApplication() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["CODEX_ROSTER_CMUX_APP_PATH"],
            "/Applications/cmux.app",
            "\(NSHomeDirectory())/Applications/cmux.app"
        ]
        guard let app = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) else {
            throw IntegrationError(message: localized(
                "Không tìm thấy cmux.app để khởi động tự động.",
                "cmux.app was not found for automatic startup."
            ))
        }
        return app
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    private static func run(_ executable: String, arguments: [String]) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = error
            do {
                try process.run()
            } catch {
                throw IntegrationError(message: error.localizedDescription)
            }
            process.waitUntilExit()
            return CommandResult(
                output: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                error: String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                status: process.terminationStatus
            )
        }.value
    }

    private static func commandError(
        vietnamese: String,
        english: String,
        result: CommandResult
    ) -> IntegrationError {
        let detail = (result.error.isEmpty ? result.output : result.error)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = localized(vietnamese, english)
        return IntegrationError(message: detail.isEmpty ? prefix : "\(prefix) \(detail)")
    }

    private static func localized(_ vietnamese: String, _ english: String) -> String {
        AppLanguage.current == .vietnamese ? vietnamese : english
    }
}
