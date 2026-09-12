import ApplicationServices
import CoreGraphics
import Foundation
import SkyLightShim
import WeftConfig
import WeftCore
import WeftIPC
import WeftPlatform

public enum Doctor {
    /// Returns false when the config asks for a helper that is not installed —
    /// the combination that silently does nothing.
    private static func reportHelper(
        name: String, binary: String, found: String?, enabled: Bool,
        install: String, setting: String
    ) -> Bool {
        switch (enabled, found) {
        case (true, .some(let path)):
            print("[\u{2713}] \(name): enabled, found at \(path)")
            return true
        case (true, .none):
            print("[\u{2717}] \(name): ENABLED in weft.toml but \(binary) is not installed.")
            print("    weft will do nothing for it. Either install it:")
            print("      \(install)")
            print("    or turn it off: \(setting) enabled = false")
            return false
        case (false, .some(let path)):
            print("[\u{25CB}] \(name): installed at \(path), but disabled in weft.toml")
            return true
        case (false, .none):
            print("[\u{25CB}] \(name): not installed, not enabled")
            return true
        }
    }

    /// Doctor is read at a terminal. A config with thirty rules should not
    /// print thirty lines to make a point the first six already made.
    private static func summarise(_ items: [String], limit: Int = 6) -> String {
        guard items.count > limit else { return items.joined(separator: ", ") }
        let shown = items.prefix(limit).joined(separator: ", ")
        return "\(shown), and \(items.count - limit) more"
    }

    /// Cross-check the `[[space]]` declarations against the desktops that
    /// actually exist. Labels are assigned by ordinal, so a config written on a
    /// seven-desktop machine and used on a three-desktop one leaves four names
    /// unassigned — and every keybind and rule naming them fails quietly.
    private static func reportSpaces(_ validated: ValidatedConfig) {
        struct LiveSpace: Decodable {
            var label: String
        }
        guard let response = IPCClient.sendCommand(
                  path: IPCPaths.socketPath(), command: "query spaces"
              ),
              response.ok,
              let data = response.output?.data(using: .utf8),
              let live = try? JSONDecoder().decode([LiveSpace].self, from: data)
        else {
            print("    - Desktops: weftd is not running, cannot check the space labels")
            return
        }

        // Ask the daemon which labels actually landed rather than re-deriving
        // the ordinal assignment here. It is the same answer for a fresh
        // launch, and the right one after a runtime rename or a display change
        // — both of which move labels around in ways this cannot predict.
        let declared = validated.spaces.map(\.label)
        let liveLabels = Set(live.map(\.label))
        let unassignedLabels = declared.filter { !liveLabels.contains($0) }

        // A space target is unreachable two ways: a NAME with no desktop behind
        // it, or a NUMBER past the last desktop. The shipped config declares no
        // spaces and binds alt-1..5, so on a two-desktop Mac the second case is
        // the only one that fires — and it is exactly as silent as the first.
        func unreachable(_ target: String) -> Bool {
            if let n = Int(target) { return n < 1 || n > live.count }
            if target == "recent" { return false }
            return !liveLabels.contains(target)
        }

        let orphanedRules = validated.rules.compactMap { rule -> String? in
            guard let space = rule.space, unreachable(space) else { return nil }
            return "\(rule.app ?? rule.bundleID ?? rule.title ?? "rule") -> \(space)"
        }
        let orphanedKeys = Set(
            validated.keymap.modes.values
                .flatMap { $0.values }
                .compactMap { action -> String? in
                    guard case .send(let command) = action else { return nil }
                    let parts = command.split(separator: " ").map(String.init)
                    guard parts.count >= 3, parts[0] == "space",
                          parts[1] == "focus" || parts[1] == "move-window",
                          unreachable(parts[2])
                    else { return nil }
                    return command
                }
        ).sorted()

        guard !unassignedLabels.isEmpty || !orphanedRules.isEmpty || !orphanedKeys.isEmpty else {
            print("    - Desktops: \(live.count) on screen; every space reference resolves")
            return
        }

        if unassignedLabels.isEmpty {
            print("[\u{25CB}] Spaces: \(live.count) desktop(s) exist; some binds point past that.")
        } else {
            print("[\u{25CB}] Spaces: \(declared.count) declared but only \(live.count) desktop(s) exist.")
            print("    Unassigned labels: \(summarise(unassignedLabels, limit: 10))")
        }
        print("    These resolve to nothing, and fail silently when used:")
        if !orphanedRules.isEmpty {
            print("      rules:    \(summarise(orphanedRules))")
        }
        if !orphanedKeys.isEmpty {
            print("      keybinds: \(summarise(orphanedKeys))")
        }
        print("    Add desktops in Mission Control, or drop the references.")
    }

    public static func run() {
        print("=== weft doctor === \(WeftVersion.full)")
        var allOk = true

        // 1. Accessibility
        // Ask the DAEMON, not ourselves. TCC is per binary, so weftctl's own
        // grants say nothing about weftd's — and reporting them as if they did
        // is how a green doctor sat next to a weftd that could not move a
        // single window or receive a single keybind.
        struct DaemonPermissions: Decodable {
            var binary: String
            var accessibility: Bool
            /// The Input Monitoring switch as TCC has it.
            var inputMonitoring: Bool
            /// The live event tap. Optional so a doctor from a newer build
            /// still reads an older daemon, which only reported the tap.
            var keybindsLive: Bool?
            var screenRecording: Bool
            /// Whether a rebuild keeps these grants. Optional for older daemons.
            var stableIdentity: Bool?
            /// What keybinds actually run on.
            var tapLive: Bool { keybindsLive ?? inputMonitoring }
        }
        var daemonPerms: DaemonPermissions?
        if let response = IPCClient.sendCommand(
               path: IPCPaths.socketPath(), command: "query permissions"
           ),
           response.ok,
           let data = response.output?.data(using: .utf8)
        {
            daemonPerms = try? JSONDecoder().decode(DaemonPermissions.self, from: data)
        }

        if let p = daemonPerms {
            print("    Permissions below are weftd's own, read from the running daemon:")
            print("    \(p.binary)")
            // Said before the individual verdicts, because it changes how to
            // read all of them: an unsigned weftd that was rebuilt shows as
            // granted in System Settings while being trusted for nothing.
            if p.stableIdentity == false {
                print("[!] weftd is not signed with a stable identity.")
                print("    macOS ties a permission to the exact program it was granted to, so")
                print("    rebuilding weft invalidates every grant below WITHOUT clearing the")
                print("    switch in System Settings. If a switch reads as on and weft still")
                print("    does not work, turn that switch off and back on.")
                print("    Reinstall with scripts/install.sh to sign it once and stop this")
                print("    happening on future updates.")
            }
            if p.accessibility {
                print("[✓] Accessibility (weftd): Granted")
            } else {
                print("[✗] Accessibility (weftd): MISSING — weftd cannot move any window.")
                print("    System Settings -> Privacy & Security -> Accessibility.")
                print("    weftd asks on launch, so it should already be listed — switch it on.")
                print("    If it is not there, add this (the folder is hidden, so drag it from")
                print("    Finder or use the picker's Cmd-Shift-G):")
                print("      \(p.binary)")
                allOk = false
            }
            if p.tapLive {
                if p.inputMonitoring {
                    print("[✓] Input Monitoring (weftd): granted, event tap installed (keybinds live)")
                } else {
                    // Not a warning. macOS lets an Accessibility-trusted
                    // process open an event tap, so keybinds are genuinely
                    // live with the Input Monitoring switch still off — but
                    // saying "granted" here would credit the user with a
                    // switch they never flipped, and they would go looking
                    // for it.
                    print("[✓] Input Monitoring (weftd): switch off, but the event tap is live")
                    print("    Accessibility covers the tap, so every keybind fires. Turning")
                    print("    Input Monitoring on as well is harmless and makes it explicit.")
                }
            } else {
                print("[✗] Input Monitoring (weftd): tap NOT installed — no keybind will fire.")
                print("    (TCC switch reads \(p.inputMonitoring ? "on" : "off").)")
                print("    System Settings -> Privacy & Security -> Input Monitoring.")
                print("    weftd asks when the tap fails, so it should already be listed —")
                print("    switch it on. If it is not there, add:")
                print("      \(p.binary)")
                print("    The daemon retries the tap on every check, so it goes live as")
                print("    soon as the switch flips — no restart needed. If it stays off")
                print("    after a minute: weftctl service restart")
                allOk = false
            }
        } else {
            // No daemon to ask. Report our own status, and say whose it is.
            print("[○] weftd is not running — cannot read its permissions.")
            print("    The values below are THIS binary's and do not decide whether")
            print("    weft works. Start the daemon and re-run: weftctl service start")
            print("    weftctl Accessibility: \(AXIsProcessTrusted() ? "granted" : "missing")")
            print("    weftctl Input Monitoring: \(CGPreflightListenEventAccess() ? "granted" : "missing")")
        }

        // 1c. Screen Recording. weftd's answer when there is a daemon to ask;
        // the grant that matters is its, not ours.
        //
        // Optional again, on better grounds than the first time. It does make
        // titles cheaper — the window list carries them, no round trip — but
        // macOS will not list an unbundled binary under Screen Recording, so
        // weftd can only get there if someone adds it by hand. weftd reads
        // titles through Accessibility when this is missing, so a config full
        // of title rules works either way.
        if daemonPerms?.screenRecording ?? Permissions.screenRecording() {
            print("[✓] Screen Recording: Granted (window titles read from the window list)")
        } else {
            print("[○] Screen Recording: not granted — titles come from Accessibility instead.")
            print("    Nothing is broken by this. To grant it anyway, macOS needs the")
            print("    binary added by hand (+ in the pane); it does not list it for you:")
            print("      \(daemonPerms?.binary ?? "weftd")")
        }

        // 1d. A newer release. Cache only — `doctor` must work offline and
        // must not hang on a network call; WeftBar refreshes it in the
        // background once a day.
        if let update = UpdateCheck.cached(), update.isNewerThanRunning {
            print("[↑] Update available: weft \(update.latest) (running \(WeftVersion.current))")
            print("    \(UpdateCheck.installCommand)")
        }

        // 2. SkyLight Connection
        let cid = SLSMainConnectionID()
        if cid != 0 {
            print("[\u{2713}] SkyLight WindowServer: Connected (CID \(cid))")
        } else {
            print("[\u{2717}] SkyLight WindowServer: Failed to connect")
            allOk = false
        }

        // 3. Scripting Addition
        if let (ver, attrib) = ScriptingAddition.handshake() {
            print("[\u{2713}] Scripting Addition: Active (version \(ver), attrib 0x\(String(attrib, radix: 16)))")
            print("    - Instant space switching: Available")
            print("    - Non-activating window moves: Available")
            print("    - Sticky window toggle: Available")
        } else {
            print("[\u{25CB}] Scripting Addition: Not active (operating in degraded/fallback mode)")
            print("    - Note: For instant space transitions without Mission Control animations,")
            print("      ensure yabai.osax or weft-sa is loaded into Dock.app.")
        }

        // Stage Manager arranges windows too. With it on, macOS and weft move
        // the same windows and the symptom reads as a weft bug.
        if SystemChecks.stageManagerEnabled() {
            print("[\u{2717}] Stage Manager: ON — macOS will move windows weft has just placed.")
            print("    Turn it off: \(SystemChecks.stageManagerSetting)")
        } else {
            print("[\u{2713}] Stage Manager: off")
        }

        // 4 & 5. Optional helpers. Reported against the config rather than on
        // their own: "borders not found" is fine when it is switched off and a
        // silent no-op when it is switched on, and only the second is a
        // problem the user needs to hear about.
        let bordersFound = ExternalBinary.find("borders")
        let sketchybarFound = ExternalBinary.find("sketchybar")

        // 6. Configuration file
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".config/weft/weft.toml")
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                let text = try String(contentsOf: configURL, encoding: .utf8)
                let validated = try loadConfig(text)
                print("[\u{2713}] Configuration: Valid (\(configURL.path))")
                // Loaded, but naming settings this build no longer honours.
                // Valid is still true — weft is running on this file — but
                // "valid" alone would hide that part of it does nothing.
                for w in validated.warnings {
                    print("    [!] line \(w.line): \(w.message)")
                }
                let keyCount = validated.keymap.modes.values.map(\.count).reduce(0, +)
                print("    - Keybindings: \(keyCount)")
                print("    - Window rules: \(validated.rules.count)")
                print("    - Spaces configured: \(validated.spaces.count)")

                if validated.integrations.borders.enabled && validated.integrations.borders.backend == .native {
                    print("[✓] Borders: Native (in-process)")
                } else if !reportHelper(
                    name: "JankyBorders", binary: "borders", found: bordersFound,
                    enabled: validated.integrations.borders.enabled,
                    install: "brew install FelixKratz/formulae/borders",
                    setting: "[integrations.borders]"
                ) { allOk = false }

                if !reportHelper(
                    name: "Sketchybar", binary: "sketchybar", found: sketchybarFound,
                    enabled: validated.integrations.sketchybar.enabled,
                    install: "brew install FelixKratz/formulae/sketchybar",
                    setting: "[integrations.sketchybar]"
                ) { allOk = false }

                reportSpaces(validated)
            } catch {
                print("[\u{2717}] Configuration: Parse error in \(configURL.path): \(error)")
                allOk = false
            }
        } else {
            print("[\u{25CB}] Configuration: Not found at \(configURL.path) (defaults will be used)")
        }

        // 7. Daemon IPC
        let sockPath = IPCPaths.socketPath()
        if let response = IPCClient.sendCommand(path: sockPath, command: "query state") {
            if response.ok {
                print("[\u{2713}] Daemon (weftd): Running and responsive")
                if let out = response.output {
                    let preview = out.components(separatedBy: "\n").prefix(3).joined(separator: "\n    ")
                    print("    \(preview)")
                }
            } else {
                print("[\u{2717}] Daemon (weftd): Returned error: \(response.error ?? "unknown")")
                allOk = false
            }
        } else {
            print("[\u{25CB}] Daemon (weftd): Not currently running at \(sockPath)")
        }

        print("---")
        if allOk {
            print("System is ready for weft.")
        } else {
            print("Some checks require attention.")
        }
    }
}
