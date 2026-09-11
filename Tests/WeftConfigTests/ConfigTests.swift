import Foundation
import Testing
@testable import WeftConfig
@testable import WeftCore
@testable import WeftInput

@Test func parsesFullExample() throws {
    let doc = try parseTOML("""
        # comment
        [general]
        inner-gap = 8
        outer-gap = { top = 8, bottom = 8, left = 8, right = 8 }
        default-layout = "bsp"

        [[space]]
        label = "code"
        layout = "bsp"

        [[space]]
        label = "web"
        layout = "float"

        [[rule]]
        bundle-id = "com.apple.finder"
        manage = false

        [keys]
        "alt-h" = "focus west"
        "alt-shift-r" = "mode resize"

        [mode.resize]
        "h" = "resize left -60"
        "escape" = "mode default"
        """)
    #expect(doc.tables["general"]?["inner-gap"] == .int(8))
    #expect(doc.arrays["space"]?.count == 2)
    #expect(doc.arrays["rule"]?.count == 1)
    #expect(doc.tables["keys"]?.count == 2)
    #expect(doc.tables["mode.resize"]?.count == 2)
    // Line numbers tracked for error messages.
    #expect((doc.lines["general.inner-gap"] ?? 0) > 0)
    #expect((doc.lines["space#0.label"] ?? 0) > 0)
}

@Test func rejectsBadSyntax() {
    #expect(throws: TomlError.self) { try parseTOML("[general\ninner-gap = 8\n") }
    #expect(throws: TomlError.self) { try parseTOML("[general]\ninner-gap = 8\ninner-gap = 9\n") }
    #expect(throws: TomlError.self) { try parseTOML("inner-gap = 8\n") }
    #expect(throws: TomlError.self) { try parseTOML("[general]\na.b = 1\n") }
}

@Test func validatesFullConfig() throws {
    let cfg = try loadConfig("""
        [general]
        inner-gap = 4
        outer-gap = 10
        default-layout = "float"

        [[space]]
        label = "web"

        [[rule]]
        app = "^Ghostty$"
        space = "term"

        [keys]
        "alt-h" = "focus west"
        """)
    #expect(cfg.general.innerGap == 4)
    #expect(cfg.general.outerGap == TilingConfig.OuterGap(top: 10, bottom: 10, left: 10, right: 10))
    #expect(cfg.general.defaultLayout == .float)
    #expect(cfg.spaces == [SpaceDecl(label: "web", layout: .float)])
    #expect(cfg.rules.count == 1)
    #expect(cfg.keymap.modes["default"]?.count == 1)
}

@Test func rejectsBadConfig() {
    // Unknown layout.
    #expect(throws: ConfigError.self) {
        try loadConfig("[general]\ndefault-layout = \"waterfall\"\n")
    }
    // Bad chord.
    #expect(throws: ConfigError.self) {
        try loadConfig("[keys]\n\"alt-hyper-h\" = \"focus west\"\n")
    }
    // Bad command.
    #expect(throws: ConfigError.self) {
        try loadConfig("[keys]\n\"alt-h\" = \"frobnicate west\"\n")
    }
    // Rule without matchers.
    #expect(throws: ConfigError.self) {
        try loadConfig("[[rule]]\nmanage = false\n")
    }
    // Bad regex.
    #expect(throws: ConfigError.self) {
        try loadConfig("[[rule]]\napp = \"([\"\n")
    }
    // Duplicate space label.
    #expect(throws: ConfigError.self) {
        try loadConfig("[[space]]\nlabel = \"a\"\n[[space]]\nlabel = \"a\"\n")
    }
    // Unknown section.
    #expect(throws: ConfigError.self) {
        try loadConfig("[teleportation]\nspeed = 9\n")
    }
}

@Test func ruleMatching() {
    let rules = [
        Rule(bundleID: "com.apple.finder", manage: false),
        Rule(app: "^Ghostty$", space: "term"),
        Rule(app: "Brave", title: "Picture.in.Picture", manage: false),
    ]
    #expect(matchRules(rules, app: "Finder", bundleID: "com.apple.finder", title: "x") == RuleOutcome(space: nil, manage: false))
    #expect(matchRules(rules, app: "Ghostty", bundleID: "com.mitchellh.ghostty", title: "") == RuleOutcome(space: "term", manage: true))
    #expect(matchRules(rules, app: "Brave Browser", bundleID: "com.brave.browser", title: "Picture.in.Picture")?.manage == false)
    #expect(matchRules(rules, app: "Zen", bundleID: "app.zen", title: "") == nil)
    // First match wins.
    let ordered = [Rule(app: "^G", space: "first"), Rule(app: "^Ghostty$", space: "second")]
    #expect(matchRules(ordered, app: "Ghostty", bundleID: nil, title: "")?.space == "first")
}

@Test func parsesSpaceLayoutAndReserve() throws {
    let cfg = try loadConfig("""
        [general]
        reserve = { top = 34 }

        [[space]]
        label = "web"
        layout = "float"
        """)
    #expect(cfg.general.reserve == ScreenReserve(top: 34, bottom: 0, left: 0, right: 0))
    #expect(cfg.spaces.count == 1)
    #expect(cfg.spaces[0].layout == .float)
}

@Test func parsesIntegrationsConfig() throws {
    let cfg = try loadConfig("""
        [integrations.sketchybar]
        enabled = true
        bar-name = "sketchybar"
        reserve = { top = 34 }
        coalesce-ms = 20
        events = ["space_changed", "window_focused"]

        [integrations.borders]
        enabled = true
        args = ["style=round", "width=5.0", "hidpi=on"]
        supervise = true
        active-color = { bsp = "0xffe1e3e4", float = "0xfff5a97f" }
        mode-color = { resize = "0xffed8796" }
        """)
    #expect(cfg.integrations.sketchybar.enabled == true)
    #expect(cfg.integrations.sketchybar.barName == "sketchybar")
    #expect(cfg.integrations.sketchybar.reserve == ScreenReserve(top: 34, bottom: 0, left: 0, right: 0))
    #expect(cfg.integrations.sketchybar.coalesceMs == 20)
    #expect(cfg.integrations.sketchybar.events == ["space_changed", "window_focused"])
    #expect(cfg.general.reserve == ScreenReserve(top: 34, bottom: 0, left: 0, right: 0))

    #expect(cfg.integrations.borders.enabled == true)
    #expect(cfg.integrations.borders.args == ["style=round", "width=5.0", "hidpi=on"])
    #expect(cfg.integrations.borders.supervise == true)
    #expect(cfg.integrations.borders.activeColor["bsp"] == "0xffe1e3e4")
    #expect(cfg.integrations.borders.activeColor["float"] == "0xfff5a97f")
    #expect(cfg.integrations.borders.modeColor["resize"] == "0xffed8796")
}

@Test func parsesMigratedConfig() throws {
    guard let text = try? String(contentsOfFile: "/tmp/migrated_clean.toml", encoding: .utf8) else { return }
    let validated = try loadConfig(text)
    #expect(validated.general.innerGap == 8)
    #expect(validated.general.outerGap.top == 8)
    #expect(validated.general.mouseFollowsFocus == true)
    #expect(validated.general.mouseModifier == "alt")
    #expect(validated.spaces.count >= 7)
    #expect(validated.rules.count >= 10)
    #expect(validated.keymap.modes["default"]?.count ?? 0 >= 20)
}

// examples/weft.toml is copied verbatim into ~/.config/weft on a fresh
// install, so it is not just a sample — it is what a first-time user's weft
// actually does. These tests are about it being a *reasonable default for a
// stranger*, not about it containing any particular binding.

/// `loadConfig` is strict — it rejects a bad chord, an unparseable command and
/// (since the mode check below) an undefined mode target — so simply loading
/// the shipped file covers every binding in it.
@Test func exampleConfigParses() throws {
    let validated = try loadConfig(try exampleText())
    #expect(validated.general.innerGap == 8)
    #expect(validated.general.defaultLayout == .bsp)
    #expect(validated.keymap.modes["default"]?.count ?? 0 > 20)
}


/// A mode captures bare keys, so a mode with no way out is a keyboard that has
/// stopped working as far as the user is concerned.
@Test func everyExampleModeHasAnExit() throws {
    let validated = try loadConfig(try exampleText())
    for (mode, binds) in validated.keymap.modes where mode != "default" {
        let exits = binds.values.contains { action in
            if case .mode("default") = action { return true }
            return false
        }
        #expect(exits, "mode '\(mode)' has no binding back to default")
    }
}

/// Both integrations drive a binary weft does not install. On by default they
/// are a silent no-op on any machine without Homebrew — which is the state the
/// old example shipped in.
@Test func exampleDoesNotEnableToolsItCannotInstall() throws {
    let validated = try loadConfig(try exampleText())
    #expect(validated.integrations.borders.enabled == false)
    #expect(validated.integrations.sketchybar.enabled == false)
}

/// Labels are handed out in Mission Control order, so a declared space with no
/// desktop behind it is dead weight — and every rule and keybind naming it dies
/// with it. A shipped default cannot know how many desktops anyone has, so it
/// declares none and lets the numeric fallback do the work.
@Test func exampleDeclaresNoSpacesAndBindsOnlyNumbers() throws {
    let validated = try loadConfig(try exampleText())
    #expect(validated.spaces.isEmpty)

    for binds in validated.keymap.modes.values {
        for case .send(let command) in binds.values {
            let parts = command.split(separator: " ").map(String.init)
            guard parts.count >= 3, parts[0] == "space",
                  parts[1] == "focus" || parts[1] == "move-window"
            else { continue }
            #expect(
                Int(parts[2]) != nil || parts[2] == "recent",
                "'\(command)' names a space the shipped config does not declare"
            )
        }
    }
}

/// weftd rejects a rule that matches nothing, so this is really a check that
/// the file still loads — but it fails with a useful name when someone
/// comments out an `app` line and leaves the block behind.
@Test func exampleRulesAllMatchSomething() throws {
    let validated = try loadConfig(try exampleText())
    #expect(!validated.rules.isEmpty)
    for rule in validated.rules {
        #expect(
            rule.app != nil || rule.title != nil || rule.bundleID != nil,
            "a [[rule]] block has no matcher"
        )
    }
}

@Test func rejectsSwitchToUndefinedMode() throws {
    // The symptom without this check is the worst kind: the config loads, weftd
    // starts, and one key is simply inert with nothing logged anywhere.
    let config = """
        [keys]
        "alt-r" = "mode reisze"

        [mode.resize]
        "escape" = "mode default"
        """
    do {
        _ = try loadConfig(config)
        Issue.record("expected a ConfigError for the undefined mode 'reisze'")
    } catch let error as ConfigError {
        // The message has to carry enough to fix it without opening the docs:
        // which bind, which mode is missing, and what does exist to compare to.
        #expect(error.line == 2)
        #expect(error.message.contains("alt-r"))
        #expect(error.message.contains("reisze"))
        #expect(error.message.contains("defined: resize"))
    }
}

@Test func acceptsModeTargetDefinedLaterInTheFile() throws {
    // `[keys]` binds the mode several sections before `[mode.*]` is parsed, so
    // the check has to be deferred rather than done inline.
    let cfg = try loadConfig("""
        [keys]
        "alt-r" = "mode resize"

        [mode.resize]
        "escape" = "mode default"
        """)
    #expect(cfg.keymap.modes["resize"]?.count == 1)
}

@Test func modeDefaultIsAlwaysAValidTarget() throws {
    #expect(throws: Never.self) {
        try loadConfig("""
            [mode.resize]
            "escape" = "mode default"
            """)
    }
}

/// Located relative to this source file rather than the working directory.
/// The old version read a bare relative path and silently returned when it
/// missed, so running the suite from anywhere but the package root turned
/// every assertion about the shipped config into a no-op that still passed.
private func exampleText() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // WeftConfigTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
    return try String(
        contentsOf: root.appendingPathComponent("examples/weft.toml"), encoding: .utf8
    )
}

/// A config written for the scroll layout still loads.
///
/// The parser is otherwise strict — an unknown key is an error with a line
/// number — but refusing to start over a setting weft itself retired would
/// take the user's desktop away to make a point. Every retired key comes back
/// as a warning naming its line, and the space tiles bsp.
@Test func aScrollConfigLoadsWithWarningsAndTilesBsp() throws {
    let cfg = try loadConfig("""
        [general]
        default-layout = "scroll"
        scroll-animation-ms = 220

        [[space]]
        label = "web"
        layout = "scroll"
        scroll = { preset-column-widths = [0.5, 1.0], center-focused-column = "on-overflow" }
        """)
    #expect(cfg.general.defaultLayout == .bsp)
    #expect(cfg.spaces == [SpaceDecl(label: "web", layout: .bsp)])
    #expect(cfg.warnings.count == 4)
    // Every warning names the line it is about, or it is not actionable.
    #expect(cfg.warnings.allSatisfy { $0.line > 0 })
    #expect(cfg.warnings.map(\.line) == cfg.warnings.map(\.line).sorted())
}

/// A clean config warns about nothing. The warning list is only useful if it
/// is normally empty.
@Test func aCurrentConfigProducesNoWarnings() throws {
    #expect(try loadConfig(try exampleText()).warnings.isEmpty)
}

/// `space layout scroll` still parses, so a stale keybind gets an explanation
/// from the daemon rather than a syntax error from the parser.
@Test func spaceLayoutScrollStillParses() throws {
    #expect(try Command.parse("space layout scroll") == .space(.layout("scroll")))
}

/// A keybind for a scroll command is dropped with a warning, not a load
/// failure — and only that bind. Every other bind in the table still works,
/// and a genuinely bad command is still an error.
@Test func aStaleScrollKeybindIsUnboundWithAWarning() throws {
    let cfg = try loadConfig("""
        [keys]
        "alt-h" = "focus west"
        "alt-n" = "scroll focus next-column"
        """)
    #expect(cfg.warnings.count == 1)
    #expect(cfg.warnings[0].line == 3)
    let binds = cfg.keymap.modes["default"] ?? [:]
    #expect(binds.count == 1)
    #expect(binds[try parseChord("alt-h")] == .send("focus west"))
    #expect(binds[try parseChord("alt-n")] == nil)

    #expect(throws: ConfigError.self) {
        try loadConfig("[keys]\n\"alt-n\" = \"scrol focus next-column\"\n")
    }
}
