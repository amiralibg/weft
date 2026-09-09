import AppKit
import Foundation

public enum Migrate {
    /// skhd chord spelling → weft chord spelling. Hardware keycodes are
    /// spelled out because skhd writes the ones with no ASCII name in hex.
    static func normalizeChord(_ raw: String) -> String {
        raw.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "lctrl", with: "ctrl")
            .replacingOccurrences(of: "rctrl", with: "ctrl")
            .replacingOccurrences(of: "0x2A", with: "backslash")
            .replacingOccurrences(of: "0x2B", with: "comma")
            .replacingOccurrences(of: "0x2C", with: "slash")
            .replacingOccurrences(of: "0x30", with: "tab")
            .replacingOccurrences(of: "0x1B", with: "minus")
            .replacingOccurrences(of: "0x18", with: "equal")
    }

    /// Bundle id for an app's display name, via LaunchServices. `open -a` takes
    /// the same name, so whatever the user's skhdrc launches resolves here.
    static func bundleID(forAppNamed name: String) -> String? {
        guard !name.isEmpty else { return nil }
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: name
        ) { return Bundle(url: url)?.bundleIdentifier }
        for dir in ["/Applications", "/System/Applications",
                    NSHomeDirectory() + "/Applications"] {
            let candidate = URL(fileURLWithPath: dir)
                .appendingPathComponent(name + ".app")
            if let b = Bundle(url: candidate)?.bundleIdentifier { return b }
        }
        return nil
    }

    public static func run(writeOutput: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let yabaircPath = home.appendingPathComponent(".config/yabai/yabairc").path
        let skhdrcPath = home.appendingPathComponent(".config/skhd/skhdrc").path

        var innerGap = 8
        var outerGap = 8
        var mouseFollowsFocus = true
        var mouseModifier = "alt"
        var defaultLayout = "bsp"
        var spaces: [(index: Int, label: String, layout: String?)] = []
        var rules: [(app: String, manage: Bool?, space: String?)] = []
        var bindings: [(chord: String, cmd: String)] = []
        // skhd modes: `:: resize @` declares one, `alt + shift - r ; resize`
        // enters it, `resize < h : …` binds inside it, `resize < escape ;
        // default` leaves. Dropping all of that — which this used to do —
        // silently deleted the user's entire resize layer.
        var modeBindings: [String: [(chord: String, cmd: String)]] = [:]
        var declaredModes: Set<String> = []

        // 1. Parse yabairc if present
        if let yabairc = try? String(contentsOfFile: yabaircPath, encoding: .utf8) {
            fputs("weftctl: reading \(yabaircPath)...\n", stderr)
            var inSpaceLabels = false
            for rawLine in yabairc.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.contains("SPACE_LABELS=(") {
                    inSpaceLabels = true
                    continue
                }
                if inSpaceLabels {
                    if line.hasPrefix(")") {
                        inSpaceLabels = false
                        continue
                    }
                    let word = line.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
                    if !word.isEmpty {
                        spaces.append((spaces.count + 1, word, nil))
                    }
                    continue
                }
                guard !line.hasPrefix("#"), !line.isEmpty else { continue }

                if line.contains("window_gap") {
                    let parts = line.components(separatedBy: .whitespaces)
                    if let idx = parts.firstIndex(of: "window_gap"), idx + 1 < parts.count, let v = Int(parts[idx + 1]) {
                        innerGap = v
                    }
                }
                if line.contains("top_padding") {
                    let parts = line.components(separatedBy: .whitespaces)
                    if let idx = parts.firstIndex(of: "top_padding"), idx + 1 < parts.count, let v = Int(parts[idx + 1]) {
                        outerGap = v
                    }
                }
                if line.contains("mouse_follows_focus") {
                    mouseFollowsFocus = line.contains("on")
                }
                if line.contains("mouse_modifier") {
                    let parts = line.components(separatedBy: .whitespaces)
                    if let idx = parts.firstIndex(of: "mouse_modifier"), idx + 1 < parts.count {
                        mouseModifier = parts[idx + 1]
                    }
                }
                if line.contains("default_layout") {
                    let parts = line.components(separatedBy: .whitespaces)
                    if let idx = parts.firstIndex(of: "default_layout"), idx + 1 < parts.count {
                        defaultLayout = parts[idx + 1]
                    }
                }
                if line.contains("space") && line.contains("--label") {
                    // yabai -m space 1 --label main
                    let parts = line.components(separatedBy: .whitespaces)
                    if let sIdx = parts.firstIndex(of: "space"), sIdx + 1 < parts.count, let num = Int(parts[sIdx + 1]),
                       let lIdx = parts.firstIndex(of: "--label"), lIdx + 1 < parts.count {
                        let label = parts[lIdx + 1]
                        spaces.append((num, label, nil))
                    }
                }
                if line.contains("space") && line.contains("--layout") {
                    // yabai -m space 1 --layout bsp
                    let parts = line.components(separatedBy: .whitespaces)
                    if let sIdx = parts.firstIndex(of: "space"), sIdx + 1 < parts.count, let num = Int(parts[sIdx + 1]),
                       let lIdx = parts.firstIndex(of: "--layout"), lIdx + 1 < parts.count {
                        let layout = parts[lIdx + 1]
                        if let existing = spaces.firstIndex(where: { $0.index == num }) {
                            spaces[existing].layout = layout
                        }
                    }
                }
                if line.contains("rule --add") {
                    // yabai -m rule --add app="^System Settings$" manage=off
                    var appName = ""
                    var manage: Bool? = nil
                    var spaceTarget: String? = nil

                    if let r = line.range(of: #"app="([^"]+)""#, options: .regularExpression) {
                        let m = String(line[r])
                        appName = m.replacingOccurrences(of: "app=\"", with: "").replacingOccurrences(of: "\"", with: "")
                        appName = appName.replacingOccurrences(of: "^", with: "").replacingOccurrences(of: "$", with: "")
                    }
                    if line.contains("manage=off") {
                        manage = false
                    }
                    if let r = line.range(of: #"space=([^\s]+)"#, options: .regularExpression) {
                        let m = String(line[r])
                        spaceTarget = m.replacingOccurrences(of: "space=", with: "").replacingOccurrences(of: "\"", with: "")
                    }

                    if !appName.isEmpty {
                        rules.append((appName, manage, spaceTarget))
                    }
                }
            }
        }

        // 2. Parse skhdrc if present
        if let skhdrc = try? String(contentsOfFile: skhdrcPath, encoding: .utf8) {
            fputs("weftctl: reading \(skhdrcPath)...\n", stderr)
            for rawLine in skhdrc.components(separatedBy: "\n") {
                var line = rawLine.trimmingCharacters(in: .whitespaces)
                if let hash = line.firstIndex(of: "#"), !line.hasPrefix("::") {
                    line = String(line[..<hash]).trimmingCharacters(in: .whitespaces)
                }
                // `:: name` / `:: name @` — a mode declaration.
                if line.hasPrefix("::") {
                    let name = line.dropFirst(2)
                        .components(separatedBy: .whitespaces)
                        .first(where: { !$0.isEmpty }) ?? ""
                    if !name.isEmpty, name != "default" { declaredModes.insert(name) }
                    continue
                }
                // `chord ; mode` — enter a mode. `;` binds tighter than `:`
                // here, so this must be tested before the `:` split below.
                if let semi = line.firstIndex(of: ";"), !line.contains(":") {
                    let lhs = String(line[..<semi]).trimmingCharacters(in: .whitespaces)
                    let target = String(line[line.index(after: semi)...])
                        .trimmingCharacters(in: .whitespaces)
                    guard !lhs.isEmpty, !target.isEmpty else { continue }
                    if let lt = lhs.firstIndex(of: "<") {
                        // `resize < escape ; default` — leaving a mode.
                        let owner = String(lhs[..<lt]).trimmingCharacters(in: .whitespaces)
                        let key = String(lhs[lhs.index(after: lt)...])
                            .trimmingCharacters(in: .whitespaces)
                        modeBindings[owner, default: []].append(
                            (normalizeChord(key), "mode \(target)")
                        )
                    } else {
                        bindings.append((normalizeChord(lhs), "mode \(target)"))
                    }
                    continue
                }
                guard !line.hasPrefix("#"), line.contains(":") else { continue }
                let parts = line.components(separatedBy: ":")
                guard parts.count >= 2 else { continue }
                var chordRaw = parts[0].trimmingCharacters(in: .whitespaces)
                let actionRaw = parts[1...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
                // `resize < h : …` binds inside a mode.
                var owningMode: String? = nil
                if let lt = chordRaw.firstIndex(of: "<") {
                    owningMode = String(chordRaw[..<lt]).trimmingCharacters(in: .whitespaces)
                    chordRaw = String(chordRaw[chordRaw.index(after: lt)...])
                        .trimmingCharacters(in: .whitespaces)
                }

                // Normalize chord
                let chord = normalizeChord(chordRaw)

                // Map yabai command to weft command
                var weftCmd: String? = nil
                if actionRaw.contains("window --focus west") { weftCmd = "focus west" }
                else if actionRaw.contains("window --focus east") { weftCmd = "focus east" }
                else if actionRaw.contains("window --focus north") { weftCmd = "focus north" }
                else if actionRaw.contains("window --focus south") { weftCmd = "focus south" }
                else if actionRaw.contains("window --swap west") || actionRaw.contains("window --warp west") { weftCmd = "move west" }
                else if actionRaw.contains("window --swap east") || actionRaw.contains("window --warp east") { weftCmd = "move east" }
                else if actionRaw.contains("window --swap north") || actionRaw.contains("window --warp north") { weftCmd = "move north" }
                else if actionRaw.contains("window --swap south") || actionRaw.contains("window --warp south") { weftCmd = "move south" }
                else if actionRaw.contains("window --toggle zoom-fullscreen") { weftCmd = "window toggle zoom-fullscreen" }
                else if actionRaw.contains("window --toggle split") { weftCmd = "window toggle split" }
                // `--toggle float --grid 6:6:1:1:4:4` is the standard yabai
                // "float this one window and centre it" bind, and it used to
                // fall through every branch here and be dropped without a
                // word — leaving a migrated config with no way to float a
                // single window at all. weft centres a freshly floated window
                // itself, so the grid needs no translation.
                else if actionRaw.contains("window --toggle float") { weftCmd = "float toggle" }
                else if actionRaw.contains("window --toggle sticky") { weftCmd = "sticky toggle" }
                else if actionRaw.contains("space --layout") {
                    // The `if [ … = float ]; then bsp; else float; fi` shell
                    // one-liner names both layouts; matching "bsp" first turned
                    // a toggle into a one-way trip.
                    if actionRaw.contains("bsp") && actionRaw.contains("float") {
                        weftCmd = "space layout toggle"
                    }
                    else if actionRaw.contains("bsp") { weftCmd = "space layout bsp" }
                    else if actionRaw.contains("float") { weftCmd = "space layout float" }
                    else if actionRaw.contains("scroll") { weftCmd = "space layout scroll" }
                    else if actionRaw.contains("stack") { weftCmd = "stack toggle" }
                }
                else if actionRaw.contains("space --balance") { weftCmd = "balance" }
                else if actionRaw.contains("window --resize") {
                    // yabai names an EDGE and a signed delta
                    // (`right:-60:0` = pull the right edge left = shrink).
                    // weft names a DIRECTION to grow/shrink toward, so the
                    // sign, not the edge, picks the direction. The `|| left:…`
                    // fallback in these binds is the same gesture against the
                    // opposite edge, so only the first clause is read.
                    if let r = actionRaw.range(of: #"(right|left|top|bottom):-?\d+:-?\d+"#,
                                               options: .regularExpression) {
                        let f = actionRaw[r].components(separatedBy: ":")
                        let dx = Int(f[1]) ?? 0
                        let dy = Int(f[2]) ?? 0
                        let horizontal = dx != 0
                        let delta = abs(horizontal ? dx : dy)
                        let dir: String
                        if horizontal { dir = dx > 0 ? "right" : "left" }
                        else { dir = dy > 0 ? "down" : "up" }
                        if delta > 0 { weftCmd = "resize \(dir) \(delta)" }
                    }
                }
                else if actionRaw.contains("space --focus recent") { weftCmd = "space focus recent" }
                else if actionRaw.contains("space --focus") {
                    let words = actionRaw.components(separatedBy: .whitespaces)
                    if let idx = words.firstIndex(of: "--focus"), idx + 1 < words.count {
                        weftCmd = "space focus \(words[idx + 1])"
                    }
                }
                else if actionRaw.contains("window --space") {
                    let words = actionRaw.components(separatedBy: .whitespaces)
                    if let idx = words.firstIndex(of: "--space"), idx + 1 < words.count {
                        weftCmd = "space move-window \(words[idx + 1])"
                    }
                }
                else if actionRaw.hasPrefix("open -a") {
                    // `open -a 'Ghostty'` relaunches every press; weft's
                    // app-toggle focuses a running app and hides it if it is
                    // already frontmost. Bundle id is resolved at parse time
                    // so an unknown app fails loudly in the config, not later.
                    let name = actionRaw
                        .replacingOccurrences(of: "open -a", with: "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                    if let bundle = bundleID(forAppNamed: name) {
                        weftCmd = "app toggle \(bundle)"
                    } else {
                        fputs("weftctl: no bundle id for '\(name)' — skipping that bind\n", stderr)
                    }
                }
                // Checked before `display --focus`: the common skhd binding is
                // `window --display east && yabai -m display --focus east`,
                // which contains both, and the move is the part that matters.
                else if actionRaw.contains("window --display") {
                    let words = actionRaw.components(separatedBy: .whitespaces)
                    if let idx = words.firstIndex(of: "--display"), idx + 1 < words.count {
                        let follow = actionRaw.contains("display --focus") ? " --follow" : ""
                        var target = words[idx + 1]
                        // `{ … next … } || { … first … }` is how skhd spells
                        // "next, wrapping" — weft has one word for it. Keep a
                        // bare `next` as next, which does not wrap, like yabai.
                        if target == "next", actionRaw.contains("--display first") {
                            target = "cycle"
                        }
                        weftCmd = "move display \(target)\(follow)"
                    }
                }
                else if actionRaw.contains("display --focus") {
                    let words = actionRaw.components(separatedBy: .whitespaces)
                    if let idx = words.firstIndex(of: "--focus"), idx + 1 < words.count {
                        weftCmd = "focus display \(words[idx + 1])"
                    }
                }

                if let cmd = weftCmd {
                    if let mode = owningMode, mode != "default" {
                        modeBindings[mode, default: []].append((chord, cmd))
                    } else {
                        bindings.append((chord, cmd))
                    }
                }
            }
        }

        // Generate TOML
        var toml = ""
        toml += "# Generated by weftctl migrate\n\n"
        toml += "[general]\n"
        toml += "inner-gap = \(innerGap)\n"
        toml += "outer-gap = \(outerGap)\n"
        toml += "default-layout = \"\(defaultLayout)\"\n"
        let effectiveMouseMod = mouseModifier.isEmpty ? "alt" : mouseModifier
        toml += "mouse-modifier = \"\(effectiveMouseMod)\"\n"
        toml += "mouse-follows-focus = \(mouseFollowsFocus)\n\n"

        toml += "[integrations.borders]\n"
        toml += "enabled = true\n"
        toml += "supervise = true\n"
        toml += "args = [\"width=5.0\", \"active_color=0xff7aa2f7\", \"inactive_color=0x40414868\"]\n"
        toml += "active-color = { bsp = \"0xff7aa2f7\", scroll = \"0xff9ece6a\", float = \"0xffe0af68\" }\n\n"

        toml += "[integrations.sketchybar]\n"
        toml += "enabled = true\n\n"

        if !spaces.isEmpty {
            for s in spaces.sorted(by: { $0.index < $1.index }) {
                toml += "[[space]]\n"
                toml += "label = \"\(s.label)\"\n"
                if let l = s.layout {
                    toml += "layout = \"\(l)\"\n"
                }
                toml += "\n"
            }
        }

        if !rules.isEmpty {
            for r in rules {
                toml += "[[rule]]\n"
                toml += "app = \"\(r.app)\"\n"
                if let m = r.manage {
                    toml += "manage = \(m)\n"
                }
                if let sp = r.space {
                    toml += "space = \"\(sp)\"\n"
                }
                toml += "\n"
            }
        }

        toml += "[keys]\n"
        if !bindings.isEmpty {
            for b in bindings {
                toml += "\"\(b.chord)\" = \"\(b.cmd)\"\n"
            }
            // Floating one window is not optional equipment — every dialog an
            // app insists on tiling needs it — and a skhdrc that never bound
            // it produced a weft with no way to reach it at all. Added only if
            // the chord and the command are both still free.
            if !bindings.contains(where: { $0.cmd == "float toggle" }),
               !bindings.contains(where: { $0.chord == "alt-shift-space" })
            {
                toml += "\"alt-shift-space\" = \"float toggle\"\n"
            }
        } else {
            // Include sensible defaults
            toml += "\"alt-h\" = \"focus west\"\n"
            toml += "\"alt-j\" = \"focus south\"\n"
            toml += "\"alt-k\" = \"focus north\"\n"
            toml += "\"alt-l\" = \"focus east\"\n"
            toml += "\"alt-shift-h\" = \"move west\"\n"
            toml += "\"alt-shift-j\" = \"move south\"\n"
            toml += "\"alt-shift-k\" = \"move north\"\n"
            toml += "\"alt-shift-l\" = \"move east\"\n"
            toml += "\"alt-f\" = \"window toggle zoom-fullscreen\"\n"
            toml += "\"alt-backslash\" = \"window toggle split\"\n"
            toml += "\"alt-shift-space\" = \"float toggle\"\n"
            toml += "\"alt-tab\" = \"space focus recent\"\n"
        }

        // Mode layers last, so `[mode.<name>]` closes the file rather than
        // swallowing the [keys] table that follows it in TOML.
        for mode in declaredModes.sorted() {
            guard let binds = modeBindings[mode], !binds.isEmpty else { continue }
            toml += "\n[mode.\(mode)]\n"
            for b in binds {
                toml += "\"\(b.chord)\" = \"\(b.cmd)\"\n"
            }
            // skhd's `@` capture modes need a way out even when the user only
            // bound one; weft has no implicit escape.
            if !binds.contains(where: { $0.cmd == "mode default" }) {
                toml += "\"escape\" = \"mode default\"\n"
            }
        }

        if writeOutput {
            let outURL = home.appendingPathComponent(".config/weft/weft.toml")
            let dir = outURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                try toml.write(to: outURL, atomically: true, encoding: .utf8)
                print("weftctl: successfully wrote migrated configuration to \(outURL.path)")
            } catch {
                fputs("weftctl: failed to write to \(outURL.path): \(error)\n", stderr)
                exit(1)
            }
        } else {
            print(toml)
            print("# Run 'weftctl migrate --write' to save this to ~/.config/weft/weft.toml")
        }
    }
}
