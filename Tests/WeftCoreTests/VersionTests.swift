import Testing
@testable import WeftCore

@Test func newerVersionsAreRecognised() {
    #expect(WeftVersion.isNewer("0.2.0", than: "0.1.0"))
    #expect(WeftVersion.isNewer("1.0.0", than: "0.9.9"))
    #expect(WeftVersion.isNewer("0.1.1", than: "0.1.0"))
    #expect(!WeftVersion.isNewer("0.1.0", than: "0.1.0"))
    #expect(!WeftVersion.isNewer("0.1.0", than: "0.2.0"))
}

@Test func versionsCompareNumericallyNotAsText() {
    // The bug every hand-rolled update check ships with: as text, "0.10.0"
    // sorts before "0.9.0", so the tenth release is never offered.
    #expect(WeftVersion.isNewer("0.10.0", than: "0.9.0"))
    #expect(!WeftVersion.isNewer("0.9.0", than: "0.10.0"))
    #expect(WeftVersion.isNewer("1.0.0", than: "0.99.99"))
}

@Test func tagPrefixAndShortFormsAreAccepted() {
    #expect(WeftVersion.isNewer("v0.2.0", than: "0.1.0"))
    #expect(!WeftVersion.isNewer("v0.1", than: "0.1.0"))   // 0.1 == 0.1.0
    #expect(WeftVersion.isNewer("v0.2", than: "0.1.9"))
}

@Test func prereleaseSuffixesDoNotThrowTheComparison() {
    // 0.2.0-beta.1 is treated as 0.2.0: newer than 0.1.0, not newer than 0.2.0.
    #expect(WeftVersion.isNewer("0.2.0-beta.1", than: "0.1.0"))
    #expect(!WeftVersion.isNewer("0.2.0-beta.1", than: "0.2.0"))
    #expect(!WeftVersion.isNewer("garbage", than: "0.1.0"))
}
