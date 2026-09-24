import Foundation
import Testing

@testable import WeftBarConfig

// The Settings window rewrites the user's weft.toml in place. Every test here
// is about the same promise: a save changes the values the form owns and
// nothing else — not a comment, not a key the editor has never heard of, not
// the order of the file.

/// A deliberately gnarly file — inline tables, a `scroll = { … }` the form does
/// not own, seven `[[space]]` blocks, two `[integrations.*]` sections, comments
/// everywhere. Frozen on purpose: it is a torture test for the round-trip, not
/// a copy of whatever `examples/weft.toml` happens to say today.
private func reference() throws -> String {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/reference", withExtension: "toml"))
    return try String(contentsOf: url, encoding: .utf8)
}

/// The file a fresh install actually gets — read from `examples/` itself, not
/// copied into Fixtures. A copy would drift the moment someone edits the real
/// one, which is precisely when this test needs to run.
private func shippedDefault() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // WeftBarConfigTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
    return try String(
        contentsOf: root.appendingPathComponent("examples/weft.toml"), encoding: .utf8
    )
}

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .newlines) }

@Test func roundTripIsIdentity() throws {
    let original = try reference()
    #expect(trimmed(TomlDocument(original).render()) == trimmed(original))
}

/// The Settings window rewrites this file the first time anyone saves from it.
/// Every comment in it is documentation the user is relying on, and the whole
/// bottom half is commented-out examples that a lossy writer would eat.
@Test func shippedDefaultSurvivesTheSettingsWindow() throws {
    let original = try shippedDefault()
    var doc = TomlDocument(original)
    #expect(trimmed(doc.render()) == trimmed(original))

    // Simulate the smallest real edit: nudge one gap and save.
    let i = try #require(doc.firstIndex(ofHeader: "[general]"))
    doc.sections[i].set("inner-gap", int: 12)
    let saved = doc.render()

    let before = Set(original.components(separatedBy: .newlines))
    let after = Set(saved.components(separatedBy: .newlines))
    #expect(after.subtracting(before) == ["inner-gap = 12"])
    // The commented-out blocks are the part most at risk: they are not TOML,
    // so anything that reconstructs the file from a parsed model loses them.
    #expect(saved.contains("#   \"main\"       the display with the menu bar"))
    #expect(saved.contains("label = \"6\"\ndisplay = \"secondary\""))
    #expect(saved.contains("# app = \"Ghostty|Alacritty|kitty|WezTerm\""))
    #expect(saved.hasPrefix("# ="))
}

@Test func roundTripIsIdentityForSmallFiles() {
    #expect(TomlDocument("[general]\ninner-gap = 4\n").render() == "[general]\ninner-gap = 4\n")
    #expect(TomlDocument("").render() == "\n")
    #expect(TomlDocument("# just a comment\n").render() == "# just a comment\n")
}

@Test func editingAValueTouchesOnlyThatLine() throws {
    let original = try reference()
    var doc = TomlDocument(original)
    let i = try #require(doc.firstIndex(ofHeader: "[general]"))
    doc.sections[i].set("inner-gap", int: 22)

    let before = Set(original.components(separatedBy: .newlines))
    let after = Set(doc.render().components(separatedBy: .newlines))
    #expect(after.subtracting(before) == ["inner-gap = 22"])
    #expect(before.subtracting(after) == ["inner-gap = 8"])
}

@Test func addingAKeyLandsAfterTheLastPairNotAfterTrailingComments() {
    var doc = TomlDocument("[general]\n# a note\ninner-gap = 8\n\n# tail comment\n")
    let i = try! #require(doc.firstIndex(ofHeader: "[general]"))
    doc.sections[i].set("focus-follows-mouse", bool: true)
    #expect(doc.render() == "[general]\n# a note\ninner-gap = 8\nfocus-follows-mouse = true\n\n# tail comment\n")
}

@Test func commentsAndUnknownKeysSurviveAnEdit() throws {
    var doc = TomlDocument(try reference())
    let i = try #require(doc.firstIndex(ofHeader: "[general]"))
    doc.sections[i].set("inner-gap", int: 3)
    let out = doc.render()

    #expect(out.contains("# Inner gap between tiled windows (pixels)"))
    // A `[[space]]` key no form control owns.
    #expect(out.contains("scroll = { preset-column-widths = [0.5, 0.667, 0.8, 1.0], center-focused-column = \"on-overflow\" }"))
    // The banner the file opens with stays on top.
    #expect(out.hasPrefix("# ="))
}

@Test func pruningKeybindingsKeepsTheirComments() throws {
    var doc = TomlDocument(try reference())
    let i = try #require(doc.firstIndex(ofHeader: "[keys]"))
    doc.sections[i].removePairs(notIn: ["alt-h", "alt-j"])
    let out = doc.render()

    #expect(out.contains("# Focus navigation (Vim directional)"))
    #expect(out.contains("\"alt-h\" = \"focus west\""))
    #expect(!out.contains("\"alt-shift-l\""))
}

@Test func pruningAcceptsQuotedOrBareKeys() {
    var section = TomlSection(header: "[keys]", entries: [
        .pair(key: "\"alt-h\"", value: "\"focus west\""),
        .pair(key: "\"alt-j\"", value: "\"focus south\""),
    ])
    section.removePairs(notIn: ["\"ALT-H\""])
    #expect(section.pairKeys == ["\"alt-h\""])
}

@Test func settingAValueFindsTheKeyRegardlessOfQuotingAndCase() {
    var section = TomlSection(header: "[keys]", entries: [
        .pair(key: "\"alt-h\"", value: "\"focus west\"")
    ])
    section.setRaw("\"Alt-H\"", "\"focus east\"")
    #expect(section.entries == [.pair(key: "\"alt-h\"", value: "\"focus east\"")])
}

@Test func multilineValuesAreFlaggedSoTheyAreNeverHalfRewritten() {
    let wrapped = TomlDocument("[integrations.borders]\nargs = [\n  \"width=5.0\",\n]\n")
    let i = try! #require(wrapped.firstIndex(ofHeader: "[integrations.borders]"))
    #expect(wrapped.sections[i].isMultiline("args"))

    let flat = TomlDocument("[integrations.borders]\nargs = [\"width=5.0\"]\n")
    let j = try! #require(flat.firstIndex(ofHeader: "[integrations.borders]"))
    #expect(!flat.sections[j].isMultiline("args"))
}

@Test func unparseableLinesAreCarriedThroughVerbatim() {
    let odd = "[general]\nthis is not toml at all\ninner-gap = 8\n"
    #expect(TomlDocument(odd).render() == odd)
}

@Test func sidesParseBothTheShortAndLongForm() {
    #expect(TomlValue.sides("8")! == (8, 8, 8, 8))
    #expect(TomlValue.sides("{ top = 32 }")! == (32, 0, 0, 0))
    #expect(TomlValue.sides("{ top = 1, bottom = 2, left = 3, right = 4 }")! == (1, 2, 3, 4))
    #expect(TomlValue.sides(nil) == nil)
}

@Test func uniformSidesStayInTheShortForm() {
    // A user who wrote `outer-gap = 8` should not get a four-field table back
    // just because they opened the Settings window.
    #expect(TomlValue.sidesLiteral(top: 8, bottom: 8, left: 8, right: 8) == "8")
    #expect(TomlValue.sidesLiteral(top: 1, bottom: 2, left: 3, right: 4)
            == "{ top = 1, bottom = 2, left = 3, right = 4 }")
}

@Test func quotingRoundTrips() {
    #expect(TomlValue.unquote("\"alt-h\"") == "alt-h")
    #expect(TomlValue.unquote("0  # a trailing note") == "0")
    #expect(TomlValue.unquote(TomlValue.quote("a \"quoted\" \\ path")) == "a \"quoted\" \\ path")
}

@Test func ensureSectionIsIdempotent() {
    var doc = TomlDocument("[general]\ninner-gap = 8\n")
    let a = doc.ensureSection("[general]")
    let b = doc.ensureSection("[general]")
    #expect(a == b)
    #expect(doc.indices(ofHeader: "[general]").count == 1)
}

@Test func newSectionsGroupWithTheirKind() {
    var doc = TomlDocument("[general]\ninner-gap = 8\n\n[[space]]\nlabel = \"a\"\n\n[keys]\n\"alt-h\" = \"focus west\"\n")
    var added = TomlSection(header: "[[space]]", leading: [.line("")])
    added.set("label", string: "b")
    doc.insertSection(added, groupedWith: "[[space]]")

    let lines = doc.render().components(separatedBy: .newlines)
    let lastSpace = lines.lastIndex(of: "[[space]]")!
    let keys = lines.firstIndex(of: "[keys]")!
    #expect(lastSpace < keys)
    #expect(lines[lastSpace + 1] == "label = \"b\"")
}

// MARK: - `weftctl config pin-workspaces`

// The installers run this on every upgrade, over a config the user has
// hand-commented. It is the same edit Setup's mode chooser makes, so these
// pin the document half of it: the read that decides whether to write at all,
// and the write that must not disturb anything around it.

/// An existing config gets the key written, and keeps everything else.
///
/// This is the grandfathering path: `workspaces` defaults to `virtual` as of
/// 0.9.12, and a config that predates the key must be pinned to `native` so an
/// upgrade does not change what alt-2 means under someone mid-session.
@Test func pinningWorkspacesAddsTheKeyAndTouchesNothingElse() throws {
    let before = try reference()
    var doc = TomlDocument(before)

    let i = doc.firstIndex(ofHeader: "[general]")
    #expect(i != nil)
    #expect(doc.sections[i!].string("workspaces") == nil, "fixture must predate the key")

    let index = doc.ensureSection("[general]")
    var section = doc.sections[index]
    section.set("workspaces", string: "native")
    doc.sections[index] = section
    let after = doc.render()

    #expect(after.contains("workspaces = \"native\""))
    // Every non-blank line of the original survives, with one line added.
    let removed = before.split(separator: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .filter { !after.contains($0) }
    #expect(removed.isEmpty, "pinning dropped: \(removed)")
    #expect(after.split(separator: "\n").count == before.split(separator: "\n").count + 1)
}

/// Run twice, it writes once. The installers call it on every upgrade, so a
/// second run that overwrote would undo the user's choice once per update.
@Test func pinningWorkspacesIsIdempotent() throws {
    var doc = TomlDocument(try reference())
    let index = doc.ensureSection("[general]")
    var section = doc.sections[index]
    section.set("workspaces", string: "native")
    doc.sections[index] = section
    let once = doc.render()

    // Second run: the guard sees the key and does nothing.
    let second = TomlDocument(once)
    let j = try #require(second.firstIndex(ofHeader: "[general]"))
    #expect(second.sections[j].string("workspaces") == "native")
    #expect(second.render() == once)
}

/// A config with no `[general]` table at all — the one most likely to be on
/// the new default, and the one `ensureSection` has to build a home in.
@Test func pinningWorkspacesCreatesGeneralWhenAbsent() throws {
    var doc = TomlDocument("# my keys\n[keys]\n\"alt-h\" = \"focus west\"\n")
    let index = doc.ensureSection("[general]")
    var section = doc.sections[index]
    section.set("workspaces", string: "virtual")
    doc.sections[index] = section
    let after = doc.render()

    #expect(after.contains("[general]"))
    #expect(after.contains("workspaces = \"virtual\""))
    #expect(after.contains("# my keys"))
    #expect(after.contains("\"alt-h\" = \"focus west\""))
}
