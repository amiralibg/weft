import Foundation
import WeftBarConfig

// `weftctl config tidy` — take settings weft no longer reads out of the user's
// weft.toml, leaving everything else byte for byte.
//
// 0.9.11–0.9.14 chose between two workspace models with `workspaces` and
// `workspace-anchor`. There is one model now, and both keys only produce a
// warning, so every installer runs this over a config it keeps. It is in Swift
// rather than in the install scripts because `TomlDocument` preserves
// comments, key order and everything it does not understand, and it has
// tests; a `sed` editing a file someone hand-commented would not.
//
// `pin-workspaces` is the name older installers call. It does the same thing,
// so an installer fetched from an older release still leaves a tidy config.
enum ConfigCommand {
    static let retiredGeneralKeys = ["workspaces", "workspace-anchor"]

    static func usage() -> Never {
        fputs("usage: weftctl config tidy\n", stderr)
        exit(2)
    }

    static var configPath: String {
        ("~/.config/weft/weft.toml" as NSString).expandingTildeInPath
    }

    static func run(_ args: [String]) -> Never {
        guard args.count >= 2, args[1] == "tidy" || args[1] == "pin-workspaces" else { usage() }

        let path = configPath
        // No config is not a failure: a fresh install has not copied the
        // starter file yet, and the starter file carries neither key.
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("no config at \(path) — nothing to tidy")
            exit(0)
        }

        var doc = TomlDocument(text)
        guard let i = doc.firstIndex(ofHeader: "[general]") else {
            print("nothing to tidy")
            exit(0)
        }
        var section = doc.sections[i]
        let present = retiredGeneralKeys.filter { section.rawValue($0) != nil }
        guard !present.isEmpty else {
            print("nothing to tidy")
            exit(0)
        }
        for key in present { section.remove(key) }
        doc.sections[i] = section

        do {
            try doc.render().write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            fputs("weftctl: could not write \(path): \(error)\n", stderr)
            exit(1)
        }
        print("removed \(present.joined(separator: ", ")) from \(path) — weft keeps its workspaces on one desktop per display")
        exit(0)
    }
}
