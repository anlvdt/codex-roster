import Foundation
import Testing
@testable import CodexRoster

@Test func numericSegmentsCompareNumericallyNotLexicographically() {
    #expect(GitHubUpdater.isVersion("1.10.0", newerThan: "1.9.0"))
    #expect(!GitHubUpdater.isVersion("1.9.0", newerThan: "1.10.0"))
    #expect(GitHubUpdater.isVersion("v2.0", newerThan: "1.99.99"))
    #expect(!GitHubUpdater.isVersion("1.2", newerThan: "1.2.0"))
}

@Test func releaseOutranksItsOwnPrereleases() {
    #expect(GitHubUpdater.isVersion("1.2.0", newerThan: "1.2.0-rc1"))
    #expect(!GitHubUpdater.isVersion("1.2.0-rc1", newerThan: "1.2.0"))
    #expect(!GitHubUpdater.isVersion("1.2.0-rc1", newerThan: "1.2.0-rc1"))
}

@Test func prereleaseIdentifiersFollowSemverPrecedence() {
    #expect(GitHubUpdater.isVersion("1.0.0-rc.2", newerThan: "1.0.0-rc.1"))
    #expect(GitHubUpdater.isVersion("1.0.0-rc.10", newerThan: "1.0.0-rc.9"))
    #expect(GitHubUpdater.isVersion("1.0.0-beta", newerThan: "1.0.0-alpha"))
    #expect(GitHubUpdater.isVersion("1.0.0-alpha.1", newerThan: "1.0.0-alpha"))
    #expect(GitHubUpdater.isVersion("1.0.0-alpha", newerThan: "1.0.0-1"))
}

@Test func buildMetadataAndGarbageNeverCountAsNewer() {
    #expect(!GitHubUpdater.isVersion("1.2.0+build5", newerThan: "1.2.0"))
    for bad in ["", "abc", "1..2", "1.2.x", "1.2.0-", "１.２.０"] {
        #expect(!GitHubUpdater.isVersion(bad, newerThan: "1.0.0"))
        #expect(!GitHubUpdater.isVersion("2.0.0", newerThan: bad))
    }
}

@Test func prereleaseTaggedReleaseIsNotOfferedAsStable() {
    let json = """
    {"tag_name":"v9.9.9-rc1","draft":false,"prerelease":false,
     "assets":[{"name":"x-macos.zip","browser_download_url":"https://example.com/x.zip","digest":"sha256:abc"}]}
    """
    #expect(throws: (any Error).self) {
        try GitHubUpdater.decodeLatestUpdate(Data(json.utf8))
    }
}
