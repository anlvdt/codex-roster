import AppKit
import CryptoKit
import Foundation
import Security

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
    private static let maximumArchiveBytes = 128 * 1024 * 1024
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
            if case .upToDate = state {
                try? await Task.sleep(for: .seconds(4))
                if case .upToDate = state {
                    state = .idle
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func scheduleInstall(extractedApp: URL) throws {
        let installedApp = Bundle.main.bundleURL
        guard installedApp.pathExtension == "app" else {
            throw UpdaterError(AppLanguage.text("Cần cài AgentDock dưới dạng app bundle trước khi tự cập nhật.", "AgentDock must be installed as an app bundle before it can update itself."))
        }
        let installDirectory = installedApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: installDirectory.path) else {
            throw UpdaterError(AppLanguage.text("AgentDock không có quyền cập nhật \(installedApp.path). Hãy chuyển app vào thư mục Applications có quyền ghi rồi thử lại.", "AgentDock does not have permission to update \(installedApp.path). Move it to a writable Applications folder and try again."))
        }

        let updateBundle = installDirectory
            .appendingPathComponent(".AgentDock.update-\(UUID().uuidString).app")
        try FileManager.default.copyItem(at: extractedApp, to: updateBundle)
        do {
            try Self.verifyCodeSignature(of: updateBundle, matching: installedApp)
        } catch {
            try? FileManager.default.removeItem(at: updateBundle)
            throw error
        }

        let stagingDirectory = extractedApp.deletingLastPathComponent()
        let helper = stagingDirectory.appendingPathComponent("install-update.sh")
        let appProcessID = ProcessInfo.processInfo.processIdentifier
        let backupBundle = installDirectory.appendingPathComponent(".AgentDock.previous.app")
        let bundledTrayPattern = installedApp
            .appendingPathComponent("Contents/MacOS/codex-roster")
            .path + " tray"
        let script = """
        #!/bin/sh
        set -eu
        log_directory="$HOME/Library/Logs/CodexRoster"
        /bin/mkdir -p "$log_directory"
        exec >> "$log_directory/updater.log" 2>&1
        tray_pattern=\(Self.shellQuote(bundledTrayPattern))
        for helper_pid in $(/usr/bin/pgrep -f "$tray_pattern" 2>/dev/null || true); do
          if [ "$helper_pid" != "\(appProcessID)" ]; then
            /bin/kill -TERM "$helper_pid" 2>/dev/null || true
          fi
        done
        sleep 0.3
        for helper_pid in $(/usr/bin/pgrep -f "$tray_pattern" 2>/dev/null || true); do
          if [ "$helper_pid" != "\(appProcessID)" ]; then
            /bin/kill -KILL "$helper_pid" 2>/dev/null || true
          fi
        done
        while /bin/kill -0 \(appProcessID) 2>/dev/null; do
          sleep 0.1
        done
        /bin/rm -rf \(Self.shellQuote(backupBundle.path))
        /bin/mv \(Self.shellQuote(installedApp.path)) \(Self.shellQuote(backupBundle.path))
        if ! /bin/mv \(Self.shellQuote(updateBundle.path)) \(Self.shellQuote(installedApp.path)); then
          /bin/mv \(Self.shellQuote(backupBundle.path)) \(Self.shellQuote(installedApp.path))
          exit 1
        fi
        if ! /usr/bin/open \(Self.shellQuote(installedApp.path)); then
          /bin/rm -rf \(Self.shellQuote(installedApp.path))
          /bin/mv \(Self.shellQuote(backupBundle.path)) \(Self.shellQuote(installedApp.path))
          /usr/bin/open \(Self.shellQuote(installedApp.path))
          exit 1
        fi
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
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("codex-roster", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw UpdaterError(AppLanguage.text("GitHub không trả về bản phát hành mới nhất.", "GitHub did not return a latest release."))
        }
        return try decodeLatestUpdate(data)
    }

    static func decodeLatestUpdate(_ data: Data) throws -> Update {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease else {
            throw UpdaterError(AppLanguage.text("Bản phát hành GitHub mới nhất không phải bản ổn định.", "The latest GitHub release is not a stable release."))
        }
        // A tag like `v1.3.0-rc1` is a prerelease even if GitHub's flag is unset.
        if let version = SemanticVersion(release.tagName), version.isPrerelease {
            throw UpdaterError(AppLanguage.text("Bản phát hành GitHub mới nhất không phải bản ổn định.", "The latest GitHub release is not a stable release."))
        }
        guard let asset = release.assets.first(where: { $0.name.hasSuffix("-macos.zip") }) else {
            throw UpdaterError(AppLanguage.text("Bản phát hành GitHub mới nhất không có file ZIP macOS.", "The latest GitHub release does not include a macOS ZIP."))
        }
        guard let digest = asset.digest, digest.lowercased().hasPrefix("sha256:") else {
            throw UpdaterError(AppLanguage.text("File ZIP macOS mới nhất thiếu mã SHA-256.", "The latest macOS ZIP does not include a SHA-256 digest."))
        }
        return Update(
            version: release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
            assetURL: asset.browserDownloadURL,
            digest: digest
        )
    }

    private static func downloadAndExtract(_ update: Update) async throws -> URL {
        var request = URLRequest(url: update.assetURL)
        request.timeoutInterval = 120
        let (temporaryArchive, response) = try await URLSession.shared.download(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw UpdaterError(AppLanguage.text("Không tải được file ZIP cập nhật macOS.", "Could not download the macOS update ZIP."))
        }
        let archiveSize = try FileManager.default.attributesOfItem(atPath: temporaryArchive.path)[.size] as? NSNumber
        guard let archiveSize, archiveSize.intValue <= maximumArchiveBytes else {
            throw UpdaterError(AppLanguage.text("File ZIP cập nhật macOS vượt quá dung lượng cho phép.", "The macOS update ZIP exceeds the allowed size."))
        }
        let actualDigest = try sha256(of: temporaryArchive)
        guard actualDigest.caseInsensitiveCompare(update.digest) == .orderedSame else {
            throw UpdaterError(AppLanguage.text("Bản cập nhật tải về không khớp mã SHA-256 của GitHub.", "The downloaded update did not match GitHub's SHA-256 digest."))
        }

        let stagingDirectory = try makePrivateStagingDirectory()
        let archive = stagingDirectory.appendingPathComponent("update.zip")
        try FileManager.default.copyItem(at: temporaryArchive, to: archive)
        try runTool("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, stagingDirectory.path])

        let entries = try FileManager.default.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        guard let app = entries.first(where: { $0.pathExtension == "app" }) else {
            throw UpdaterError(AppLanguage.text("File ZIP cập nhật không chứa AgentDock.app.", "The update ZIP did not contain AgentDock.app."))
        }
        let bundle = Bundle(url: app)
        guard bundle?.bundleIdentifier == "com.codexroster.app",
              let installedVersion = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              installedVersion == update.version else {
            throw UpdaterError(AppLanguage.text("Phiên bản trong ZIP cập nhật không khớp bản phát hành GitHub.", "The update ZIP version does not match the GitHub release."))
        }
        try verifyCodeSignature(of: app, matching: Bundle.main.bundleURL)
        return app
    }

    /// The helper script is executed from here, so it must not live in a
    /// location other processes can write to: `$TMPDIR` is replaced by a
    /// 0700 directory under Application Support.
    private static func makePrivateStagingDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let updates = support
            .appendingPathComponent("com.codexroster.codex-roster", isDirectory: true)
            .appendingPathComponent("updates", isDirectory: true)
        let staging = updates.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: updates,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: updates.path)
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return staging
    }

    /// Require the downloaded bundle to carry a valid, untampered signature,
    /// and, when the running app has a real signing identity, to satisfy that
    /// app's designated requirement (same team/identity). Ad-hoc signed
    /// installs have no stable identity to pin, so only validity is enforced.
    static func verifyCodeSignature(of candidate: URL, matching installed: URL) throws {
        let failure = UpdaterError(AppLanguage.text(
            "Chữ ký mã của bản cập nhật không hợp lệ hoặc không khớp bản đang cài.",
            "The update's code signature is invalid or does not match the installed app."
        ))
        var candidateCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess,
              let candidateCode else { throw failure }

        let flags = SecCSFlags(rawValue:
            kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let installedRequirement = installedDesignatedRequirement(installed)
        guard SecStaticCodeCheckValidityWithErrors(candidateCode, flags, installedRequirement, nil) == errSecSuccess else {
            throw failure
        }
    }

    /// Designated requirement of the installed app, or nil when it is ad-hoc
    /// signed (or unsigned) and therefore has no identity to match against.
    private static func installedDesignatedRequirement(_ installed: URL) -> SecRequirement? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(installed as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              dict[kSecCodeInfoTeamIdentifier as String] != nil else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func runTool(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdaterError(AppLanguage.text("Không giải nén được file ZIP cập nhật macOS.", "Could not unpack the macOS update ZIP."))
        }
    }

    private static func shellQuote(_ value: String) -> String {
        // Close the quoted string, escape the apostrophe, then reopen it.
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Semantic-version ordering: numeric core first, then a release outranks
    /// any of its own prereleases (`1.2.0 > 1.2.0-rc1`), and prerelease
    /// identifiers compare per semver (numeric < alphanumeric, shorter < longer).
    /// Build metadata (`+...`) is ignored. Unparseable input is never "newer".
    nonisolated static func isVersion(_ remote: String, newerThan current: String) -> Bool {
        guard let remote = SemanticVersion(remote), let current = SemanticVersion(current) else {
            return false
        }
        return remote > current
    }

    struct SemanticVersion: Comparable {
        let core: [Int]
        let prerelease: [String]

        var isPrerelease: Bool { !prerelease.isEmpty }

        init?(_ value: String) {
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let withoutBuild = trimmed.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let pieces = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let numbers = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
            guard !numbers.isEmpty,
                  numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
            core = numbers.compactMap { Int($0) }
            guard core.count == numbers.count else { return nil }
            if pieces.count == 2 {
                let identifiers = pieces[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else { return nil }
                prerelease = identifiers
            } else {
                prerelease = []
            }
        }

        static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            for index in 0..<max(lhs.core.count, rhs.core.count) {
                let left = index < lhs.core.count ? lhs.core[index] : 0
                let right = index < rhs.core.count ? rhs.core[index] : 0
                if left != right { return left < right }
            }
            switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
            case (true, true): return false
            case (false, true): return true
            case (true, false): return false
            case (false, false): break
            }
            for index in 0..<min(lhs.prerelease.count, rhs.prerelease.count) {
                let left = lhs.prerelease[index]
                let right = rhs.prerelease[index]
                if left == right { continue }
                switch (Int(left), Int(right)) {
                case let (leftNumber?, rightNumber?): return leftNumber < rightNumber
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return left < right
                }
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }

        static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            !(lhs < rhs) && !(rhs < lhs)
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let digest: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}

private struct UpdaterError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
