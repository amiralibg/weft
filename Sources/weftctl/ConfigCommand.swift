import Foundation
import WeftBarConfig

// `weftctl config tidy` — take settings weft no longer reads out of the user's
// weft.toml, leaving everything else byte for byte.
//
// Each of these only produces a warning, so every installer runs this over a
// config it keeps:
// - `workspaces` and `workspace-anchor` (0.9.11–0.9.14 chose between two
//   workspace models);
// - `workspace-swipe-fingers` (weft's own swipe between virtual workspaces;
//   macOS's swipe moves between its desktops now);
// - `display` in a `[[space]]` (macOS decides which display a desktop is on).
// It is in Swift rather than in the install scripts because `TomlDocument`
// preserves comments, key order and everything it does not understand, and it
// has tests; a `sed` editing a file someone hand-commented would not.
//
// `pin-workspaces` is the name older installers call. It does the same thing,
// so an installer fetched from an older release still leaves a tidy config.
enum ConfigCommand {
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

        let (tidied, removed) = ConfigTidy.tidy(text)
        guard !removed.isEmpty else {
            print("nothing to tidy")
            exit(0)
        }

        do {
            try tidied.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            fputs("weftctl: could not write \(path): \(error)\n", stderr)
            exit(1)
        }
        print("removed \(removed.joined(separator: ", ")) from \(path) — weft no longer reads them")
        exit(0)
    }
}
