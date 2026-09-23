import Foundation
import WeftBarConfig

// `weftctl config pin-workspaces <native|virtual>` — write the workspaces mode
// into the user's weft.toml, but only if the key is not already there.
//
// It exists because two very different callers need exactly the same edit:
//
//   - The installers. `workspaces` defaults to `virtual` as of 0.9.12, and an
//     upgrade must not silently change what `alt-2` means for someone who has
//     been running weft for months. So when an installer keeps an existing
//     config, it pins that config to `native` explicitly. The user opts in
//     afterwards, from Settings or Setup, rather than being opted in by a
//     release note.
//   - Setup's mode chooser. It asks the question once, on a fresh install, and
//     has to write the answer somewhere.
//
// Doing it in Swift rather than in each of the three install scripts is not
// tidiness: `TomlDocument` preserves comments, key order and everything the
// form does not understand, and it has tests. Three `sed` invocations editing
// a file a user has hand-commented would not.
enum ConfigCommand {
    static func usage() -> Never {
        fputs("usage: weftctl config pin-workspaces <native|virtual>\n", stderr)
        exit(2)
    }

    static var configPath: String {
        ("~/.config/weft/weft.toml" as NSString).expandingTildeInPath
    }

    static func run(_ args: [String]) -> Never {
        guard args.count >= 3, args[1] == "pin-workspaces" else { usage() }
        let mode = args[2]
        guard mode == "native" || mode == "virtual" else { usage() }

        let path = configPath
        // No config is not a failure. A fresh install has not copied the
        // starter file yet, and the starter file already carries the key — so
        // there is nothing to pin and nothing to complain about.
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("no config at \(path) — nothing to pin")
            exit(0)
        }

        var doc = TomlDocument(text)
        // Already answered, by the user or by a previous run. Leave it alone:
        // this command is run by every installer on every upgrade, so
        // overwriting would undo the user's choice once per update.
        if let i = doc.firstIndex(ofHeader: "[general]"),
           doc.sections[i].string("workspaces") != nil
        {
            print("workspaces already set — left alone")
            exit(0)
        }

        let i = doc.ensureSection("[general]")
        var section = doc.sections[i]
        section.set("workspaces", string: mode)
        doc.sections[i] = section

        let rendered = doc.render()
        do {
            try rendered.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            fputs("weftctl: could not write \(path): \(error)\n", stderr)
            exit(1)
        }
        print("pinned workspaces = \"\(mode)\" in \(path)")
        exit(0)
    }
}
