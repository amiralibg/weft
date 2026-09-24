import Foundation
import Testing
@testable import WeftBarConfig

// The shortcut builder writes commands from the blanks a person filled in, and
// reads commands back into the same blanks when they edit. Both directions
// must agree, or opening a shortcut and pressing Save changes what it does.

/// Values a blank can hold, for the round trip. The free-text blanks get
/// something realistic; the rest take every choice they have.
private func samples(_ param: ActionParam) -> [String] {
    if let choices = param.choices { return choices }
    switch param {
    case .workspace: return ["1", "8", "web"]
    case .display: return ["next", "cycle", "west", "2"]
    case .amount: return ["40", "120"]
    case .app: return ["com.apple.Safari"]
    case .mode: return ["resize"]
    case .url: return ["https://example.com/a b"]
    case .path: return ["/Users/me/My Folder", "/Applications", "~/Downloads", "~/My Stuff"]
    case .shell: return ["say \"hi\"; echo done"]
    case .raw: return ["retile"]
    default: return [param.initial]
    }
}

@Test func everyActionReadsBackWhatItWrites() {
    for action in ActionCatalog.all where action.id != "raw" {
        // Every combination of the first two blanks' samples.
        var combos: [[String]] = [[]]
        for param in action.params {
            combos = combos.flatMap { prefix in samples(param).map { prefix + [$0] } }
        }
        for values in combos {
            let command = action.command(values)
            let (read, back) = ActionCatalog.identify(command)
            #expect(read.id == action.id, "'\(command)' read as \(read.id), written by \(action.id)")
            #expect(back == values, "'\(command)' read back \(back), written from \(values)")
        }
    }
}

/// Every shortcut a fresh install gets opens in the builder as what it is,
/// not as a raw command.
@Test func everyDefaultShortcutIsANamedAction() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(contentsOf: root.appendingPathComponent("examples/weft.toml"), encoding: .utf8)
    let doc = TomlDocument(text)
    var seen = 0
    for section in doc.sections {
        guard let header = section.header, header == "[keys]" || header.hasPrefix("[mode.") else { continue }
        for entry in section.entries {
            guard case .pair(_, let value) = entry else { continue }
            for step in TomlValue.steps(value) {
                seen += 1
                #expect(ActionCatalog.identify(step).0.id != "raw", "'\(step)' has no action in the builder")
            }
        }
    }
    #expect(seen > 40)
}

@Test func commandsTheCatalogDoesNotKnowAreKeptAsWritten() {
    let (action, values) = ActionCatalog.identify("insertion manual")
    #expect(action.id == "raw")
    #expect(action.command(values) == "insertion manual")
}

@Test func spellingsOfOneCommandReadAsOneAction() {
    #expect(ActionCatalog.identify("float").0.id == "float")
    #expect(ActionCatalog.identify("stack wrap").0.id == "stack.toggle")
    #expect(ActionCatalog.identify("space focus recent").0.id == "space.recent")
    #expect(ActionCatalog.identify("mode default").0.id == "mode.leave")
    #expect(ActionCatalog.identify("focus display east").0.id == "display.focus")
    #expect(ActionCatalog.identify("move display east --follow").1 == ["east", "follow"])
    #expect(ActionCatalog.identify("exec open -a Terminal ~").0.id == "shell")
    // The tilde stays outside the quotes, where the shell expands it.
    #expect(ActionCatalog.identify("exec open ~/Downloads").1 == ["~/Downloads"])
    #expect(ActionCatalog.action("open")!.command(["~/My Stuff"]) == "exec open ~/'My Stuff'")
}

@Test func aShortcutIsSaidAsOneSentence() {
    #expect(ActionCatalog.sentence(["space focus 3", "space move-window web --no-follow"])
        == "Go to workspace 3, then send the window to “web” and stay here")
}
