import Foundation

enum ClaudeQuotaBridgeInstaller {
    static func install() async throws {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("claude-quota-bridge") else {
            throw NSError(domain: "ClaudeQuotaBridge", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Quota bridge is not bundled"])
        }
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--install"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "ClaudeQuotaBridge", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Could not configure CLI quota. Check ~/.claude/settings.json; existing settings were preserved."])
            }
        }.value
    }
}
