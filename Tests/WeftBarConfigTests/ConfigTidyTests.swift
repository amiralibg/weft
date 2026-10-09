import Foundation
import Testing
@testable import WeftBarConfig

// `weftctl config tidy` runs over the user's own, hand-commented weft.toml on
// every install. It must take out exactly the retired keys and nothing else.

@Test func tidyRemovesRetiredKeysAndKeepsEverythingElse() {
    let before = """
    # my config
    [general]
    inner-gap = 8   # snug
    workspace-swipe-fingers = 3
    workspaces = "virtual"

    [[space]]
    label = "mail"
    display = "main"   # was pinned

    [[space]]
    label = "code"
    layout = "float"
    """
    let (after, removed) = ConfigTidy.tidy(before)
    #expect(removed == ["workspaces", "workspace-swipe-fingers", "[[space]] display"])
    #expect(after.trimmingCharacters(in: .newlines) == """
    # my config
    [general]
    inner-gap = 8   # snug

    [[space]]
    label = "mail"

    [[space]]
    label = "code"
    layout = "float"
    """)
}

@Test func aTidyConfigIsLeftByteForByte() {
    let text = "# hi\n[general]\ninner-gap = 8\n\n[[space]]\nlabel = \"a\"\n"
    let (after, removed) = ConfigTidy.tidy(text)
    #expect(removed.isEmpty)
    #expect(after == text)
}
