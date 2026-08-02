import AppKit
import CryptoKit
import Foundation

@MainActor
final class GitHubUpdater: ObservableObject {
    struct Update: Equatable {
        let version: String
        let assetURL: URL
        let digest: String
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Update)
        case downloading
        case installing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing:
                true
            default:
                false
            }
        }
    }

    @Published private(set) var state: State = .idle

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/anlvdt/codex-roster/releases/latest")!
    private var automaticCheckTask: Task<Void, Never>?

    func startAutomaticChecks(currentVersion: String) {
        guard automaticCheckTask == nil else { return }
        automaticCheckTask = Task { [weak self] in
            guard let self else { return }
            await self.performCheck(currentVersion: currentVersion)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(21_600))
                guard !Task.isCancelled else { return }
                await self.performCheck(currentVersion: currentVersion)
            }
        }
    }

    func checkForUpdates(currentVersion: String) {
        guard !state.isBusy else { return }
        Task { [weak self] in
            await self?.performCheck(currentVersion: currentVersion)
        }
    }

    func installAvailableUpdate() {
        guard case let .available(update) = state else { return }
        state = .downloading
        Task { [weak self] in
            do {
                let extractedApp = try await Self.downloadAndExtract(update)
                guard let self else { return }
                try self.scheduleInstall(extractedApp: extractedApp)
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    private func performCheck(currentVersion: String) async {
        guard !state.isBusy else { return }
        state = .checking
        do {
            let update = try await Self.fetchLatestUpdate()
            state = Self.isVersion(update.version, newerThan: currentVersion) ? .available(update) : .upToDate
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func scheduleInstall(extractedApp: URL) throws {
        let installedApp = Bundle.main.bundleURL
        guard installedApp.pathExtension == "app" else {
            throw UpdaterError("Codex Roster must be installed as an app bundle before it can update itself.")
        }
        let installDirectory = installedApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: installDirectory.path) else {
            throw UpdaterError("Codex Roster does not have permission to update \(installedApp.path). Move it to a writable Applications folder and try again.")
        }

        let stagingDirectory = extractedApp.deletingLastPathComponent()
        let helper = stagingDirectory.appendingPathComponent("install-update.sh")
        let appProcessID = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        while /bin/kill -0 \(appProcessID) 2>/dev/null; do
          sleep 0.1
        done
        /usr/bin/ditto \(Self.shellQuote(extractedApp.path)) \(Self.shellQuote(installedApp.path))
        /usr/bin/open \(Self.shellQuote(installedApp.path))
        /bin/rm -rf \(Self.shellQuote(stagingDirectory.path))
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper.path]
        try process.run()
        state = .installing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApplication.shared.terminate(nil)
        }
    }

    private static func fetchLatestUpdate() async throws -> Update {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("codex-roster", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw UpdaterError("GitHub did not return a latest release.")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease else {
            throw UpdaterError("The latest GitHub release is not a stable release.")
        }
        guard let asset = release.assets.first(where: { $0.name.hasSuffix("-macos.zip") }) else {
            throw UpdaterError("The latest GitHub release does not include a macOS ZIP.")
        }
        guard let digest = asset.digest, digest.lowercased().hasPrefix("sha256:") else {
            throw UpdaterError("The latest macOS ZIP does not include a SHA-256 digest.")
        }
        return Update(
            version: release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
            assetURL: asset.browserDownloadURL,
            digest: digest
        )
    }

    private static func downloadAndExtract(_ update: Update) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: update.assetURL)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw UpdaterError("Could not download the macOS update ZIP.")
        }
        let actualDigest = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actualDigest.caseInsensitiveCompare(update.digest) == .orderedSame else {
            throw UpdaterError("The downloaded update did not match GitHub's SHA-256 digest.")
        }

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-roster-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let archive = stagingDirectory.appendingPathComponent("update.zip")
        try data.write(to: archive, options: .atomic)
        try runTool("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, stagingDirectory.path])

        let entries = try FileManager.default.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        guard let app = entries.first(where: { $0.pathExtension == "app" }) else {
            throw UpdaterError("The update ZIP did not contain Codex Roster.app.")
        }
        let bundle = Bundle(url: app)
        guard bundle?.bundleIdentifier == "com.codexroster.app",
              let installedVersion = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              installedVersion == update.version else {
            throw UpdaterError("The update ZIP version does not match the GitHub release.")
        }
        return app
    }

    private static func runTool(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdaterError("Could not unpack the macOS update ZIP.")
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }

    private static func isVersion(_ remote: String, newerThan current: String) -> Bool {
        let remoteParts = versionParts(remote)
        let currentParts = versionParts(current)
        guard !remoteParts.isEmpty, !currentParts.isEmpty else { return false }
        for index in 0..<max(remoteParts.count, currentParts.count) {
            let remotePart = index < remoteParts.count ? remoteParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if remotePart != currentPart { return remotePart > currentPart }
        }
        return false
    }

    private static func versionParts(_ version: String) -> [Int] {
        let parts = version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
        guard !parts.isEmpty else { return [] }
        return parts.allSatisfy { Int($0) != nil } ? parts.map { Int($0)! } : []
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubReleaseAsset]
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let digest: String?
}

private struct UpdaterError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
