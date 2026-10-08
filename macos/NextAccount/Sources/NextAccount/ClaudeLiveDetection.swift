import Foundation
import Darwin

/// Claude's own auth status is authoritative; saved config metadata is not a login.
struct ClaudeLiveAuthStatus: Decodable {
    let loggedIn: Bool
    let authMethod: String?
    let email: String?

    static func parse(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    var subscriptionEmail: String? {
        guard loggedIn, authMethod == "claude.ai", let email,
              !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return email
    }

    func requireSubscriptionEmail(expected: String?) throws -> String {
        guard let signedIn = subscriptionEmail,
              expected.map({ signedIn.caseInsensitiveCompare($0) == .orderedSame }) ?? true else {
            throw NSError(domain: "ClaudeLiveDetection", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Claude login does not match the selected account. Sign in again with the selected email."])
        }
        return signedIn
    }

    func verifiesQuota(email: String, fresh: Bool) -> Bool {
        fresh && subscriptionEmail?.caseInsensitiveCompare(email) == .orderedSame
    }
}

enum ClaudeAccountLoginState {
    case signedIn, signedOut, otherSession, unverified

    static func resolve(status: ClaudeLiveAuthStatus?, email: String) -> Self {
        guard let status else { return .unverified }
        guard status.loggedIn else { return .signedOut }
        guard let currentEmail = status.subscriptionEmail else { return .unverified }
        return currentEmail.caseInsensitiveCompare(email) == .orderedSame ? .signedIn : .otherSession
    }
}

enum ClaudeLiveDetection {
    static func status() async throws -> ClaudeLiveAuthStatus {
        let operation = Task.detached(priority: .utility) {
            let executable = try await resolveCLI()
            let data = try await run(executable, ["auth", "status"], timeout: 20, signedOutAllowed: true)
            return try ClaudeLiveAuthStatus.parse(data)
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: { operation.cancel() }
    }

    private static func resolveCLI() async throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/claude"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                          URL(fileURLWithPath: "/usr/local/bin/claude")]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        let data = try await run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v claude"], timeout: 15)
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw failure("Claude Code CLI was not found.")
        }
        return URL(fileURLWithPath: path)
    }

    static func run(_ executable: URL, _ args: [String], timeout: TimeInterval,
                            signedOutAllowed: Bool = false, environment: [String: String]? = nil) async throws -> Data {
        // A file prevents pipe deadlock while Claude waits for browser login.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("claude-detection-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw failure("Could not prepare Claude detection.")
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw failure("Claude detection or sign-in timed out.") }
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch {
            if process.isRunning {
                process.terminate()
                let grace = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < grace { usleep(20_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 || (signedOutAllowed && process.terminationStatus == 1) else {
            throw failure("Claude could not complete detection or sign-in.")
        }
        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        return try reader.read(upToCount: 65_536) ?? Data()
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ClaudeLiveDetection", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
