import CryptoKit
import Foundation
import Testing
@testable import CodexRoster

private func updaterFixtureIsMainThread() -> Bool { Thread.isMainThread }

private func updaterFixtureTool(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

private func updaterFixtureBundle(root: URL, version: String = "1.2.3", signed: Bool = true) throws -> URL {
    let app = root.appendingPathComponent("AgentDock.app")
    let bin = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let executable = bin.appendingPathComponent("fixture")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let plist: [String: String] = [
        "CFBundleIdentifier": "com.codexroster.app", "CFBundleExecutable": "fixture",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    if signed { try updaterFixtureTool("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) }
    return app
}

private func updaterFixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-preparation-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func updaterFixtureArchive(app: URL, root: URL) throws -> (URL, GitHubUpdater.Update) {
    let archive = root.appendingPathComponent("update.zip")
    try updaterFixtureTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
    let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
    return (archive, GitHubUpdater.Update(version: "1.2.3", assetURL: archive, digest: "sha256:" + digest))
}

@Test func updaterPreparesValidSignedArchiveOnBackgroundWorker() async throws {
    let root = try updaterFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try updaterFixtureBundle(root: root.appendingPathComponent("source"))
    let (archive, update) = try updaterFixtureArchive(app: app, root: root)
    let prepared = try await Task.detached {
        #expect(!updaterFixtureIsMainThread())
        return try GitHubUpdater.prepareArchive(archive, update: update, installedApp: app, stagingRoot: root)
    }.value
    #expect(Bundle(url: prepared)?.bundleIdentifier == "com.codexroster.app")
    let permissions = try FileManager.default.attributesOfItem(atPath: prepared.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o700)
    let staged = try GitHubUpdater.stageUpdate(extractedApp: prepared, installedApp: app)
    #expect(FileManager.default.fileExists(atPath: staged.path))
    #expect(FileManager.default.fileExists(atPath: app.path))
}

@Test(arguments: ["version", "unsigned", "digest"])
func updaterRejectsInvalidArchiveAndLeavesNoPreparation(scenario: String) throws {
    let root = try updaterFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try updaterFixtureBundle(root: root.appendingPathComponent("source"),
        version: scenario == "version" ? "9.0.0" : "1.2.3", signed: scenario != "unsigned")
    let (archive, validUpdate) = try updaterFixtureArchive(app: app, root: root)
    let update = scenario == "digest"
        ? GitHubUpdater.Update(version: "1.2.3", assetURL: archive, digest: "sha256:wrong") : validUpdate
    #expect(throws: (any Error).self) {
        try GitHubUpdater.prepareArchive(archive, update: update, installedApp: app, stagingRoot: root)
    }
    let updates = root.appendingPathComponent("com.codexroster.codex-roster/updates")
    if FileManager.default.fileExists(atPath: updates.path) {
        #expect(try FileManager.default.contentsOfDirectory(atPath: updates.path).isEmpty)
    }
    #expect(FileManager.default.fileExists(atPath: app.path))
}

@Test func updaterFailedStagingPreservesInstalledBundle() throws {
    let root = try updaterFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = try updaterFixtureBundle(root: root.appendingPathComponent("installed"))
    let unsigned = try updaterFixtureBundle(root: root.appendingPathComponent("candidate"), signed: false)
    #expect(throws: (any Error).self) {
        try GitHubUpdater.stageUpdate(extractedApp: unsigned, installedApp: installed)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path) == ["AgentDock.app"])
    try GitHubUpdater.verifyCodeSignature(of: installed, matching: installed)
}

@Test func updaterHelperPreflightFailureCleansStagingOnWorker() async throws {
    let root = try updaterFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = root.appendingPathComponent("staging")
    let extracted = try updaterFixtureBundle(root: staging)
    let installed = root.appendingPathComponent("installed-without-app-extension")
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    await Task.detached {
        #expect(!updaterFixtureIsMainThread())
        #expect(throws: (any Error).self) {
            try GitHubUpdater.startInstallHelper(extractedApp: extracted, installedApp: installed)
        }
    }.value
    #expect(!FileManager.default.fileExists(atPath: staging.path))
    #expect(FileManager.default.fileExists(atPath: installed.path))
}

@Test func updaterRejectsArchiveWithoutAppAndCleansExtraction() throws {
    let root = try updaterFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let contents = root.appendingPathComponent("documentation")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    try Data("readme".utf8).write(to: contents.appendingPathComponent("readme.txt"))
    let (archive, update) = try updaterFixtureArchive(app: contents, root: root)
    #expect(throws: (any Error).self) {
        try GitHubUpdater.prepareArchive(archive, update: update, installedApp: contents, stagingRoot: root)
    }
    let updates = root.appendingPathComponent("com.codexroster.codex-roster/updates")
    #expect(try FileManager.default.contentsOfDirectory(atPath: updates.path).isEmpty)
}

@Test func updaterRejectsOversizedArchiveBeforeExtraction() throws {
    let root = try updaterFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("oversized.zip")
    #expect(FileManager.default.createFile(atPath: archive.path, contents: nil))
    let handle = try FileHandle(forWritingTo: archive)
    try handle.truncate(atOffset: 128 * 1024 * 1024 + 1)
    try handle.close()
    let update = GitHubUpdater.Update(version: "1.2.3", assetURL: archive, digest: "sha256:any")
    do {
        _ = try GitHubUpdater.prepareArchive(archive, update: update, installedApp: root, stagingRoot: root)
        Issue.record("Oversized archive must be rejected")
    } catch {
        #expect(error.localizedDescription.contains("allowed size") || error.localizedDescription.contains("dung lượng"))
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("com.codexroster.codex-roster").path))
}
