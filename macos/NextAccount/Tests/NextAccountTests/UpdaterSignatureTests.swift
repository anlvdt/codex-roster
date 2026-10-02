import Foundation
import Testing
@testable import CodexRoster

private func makeFixtureApp(signed: Bool) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("updater-sig-\(UUID().uuidString)", isDirectory: true)
    let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
    let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: macOS.appendingPathComponent("fixture"))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: macOS.appendingPathComponent("fixture").path)
    let plist: [String: Any] = [
        "CFBundleIdentifier": "com.example.fixture",
        "CFBundleExecutable": "fixture",
        "CFBundlePackageType": "APPL",
    ]
    try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
    if signed {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", app.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
    return app
}

@Test func updaterRejectsUnsignedBundle() throws {
    let candidate = try makeFixtureApp(signed: false)
    let installed = try makeFixtureApp(signed: true)
    #expect(throws: (any Error).self) {
        try GitHubUpdater.verifyCodeSignature(of: candidate, matching: installed)
    }
}

@Test func updaterRejectsTamperedBundle() throws {
    let candidate = try makeFixtureApp(signed: true)
    let installed = try makeFixtureApp(signed: true)
    try Data("#!/bin/sh\nexit 1\n".utf8)
        .write(to: candidate.appendingPathComponent("Contents/MacOS/fixture"))
    #expect(throws: (any Error).self) {
        try GitHubUpdater.verifyCodeSignature(of: candidate, matching: installed)
    }
}

@Test func updaterAcceptsValidlySignedBundle() throws {
    let candidate = try makeFixtureApp(signed: true)
    let installed = try makeFixtureApp(signed: true)
    try GitHubUpdater.verifyCodeSignature(of: candidate, matching: installed)
}
