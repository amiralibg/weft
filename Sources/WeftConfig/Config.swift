import Foundation
import WeftCore
import WeftInput

// MARK: - Typed schema

public struct ScreenReserve: Sendable, Equatable {
    public var top: Double
    public var bottom: Double
    public var left: Double
    public var right: Double

    public init(top: Double = 0, bottom: Double = 0, left: Double = 0, right: Double = 0) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }
}

public struct GeneralConfig: Sendable, Equatable {
    public var innerGap: Double
    /// How far each window in a stack is inset from the one behind it, so the
    /// pile is visible rather than looking like one window. 0 = flat.
    public var stackOffset: Double
    /// Whether to ask GitHub, once a day, if a newer weft has been released.
    ///
    /// weft installs from a curl script or a clone, so nothing else will ever
    /// tell a user a fix exists. The check sends no identifying information
    /// beyond a `weft/<version>` user agent, downloads nothing and installs
    /// nothing — it surfaces a version number and the command to run.
    public var checkForUpdates: Bool
    /// Whether to manage windows belonging to menu-bar-only apps.
    ///
    /// Off by default: their windows are dropdown panels, and tiling one takes
    /// a slot in the layout and steals the focus that clicking away would
    /// otherwise use to dismiss it. On for anyone running a real app as an
    /// agent who wants it tiled anyway.
    public var manageMenubarApps: Bool
    public var outerGap: TilingConfig.OuterGap
    public var defaultLayout: LayoutKind
    public var mouseModifier: String
    /// Whether a plain click-and-drag on the border between two tiled windows
    /// resizes them.
    ///
    /// On, because it is what every other tiling window manager does and the
    /// alternative — hold a modifier, or enter a resize mode — is something
    /// you have to be told about. weft claims a bare click only when it lands
    /// inside a border's grab strip, so with this on every other click still
    /// reaches the app untouched.
    public var mouseBorderResize: Bool
    public var mouseFollowsFocus: Bool
    public var focusFollowsMouse: Bool
    /// How long a scroll space takes to pan between columns, in milliseconds.
    /// **0 (the default) turns it off** and keeps the single-write behaviour
    /// `docs/DESIGN.md` §1 describes.
    ///
    /// Off by default because the first version of it was not survivable: it
    /// drove the border overlays at frame rate, which made the WindowServer
    /// create and release an overlay window every frame a column spent off
    /// screen, and it defeated echo suppression so every frame of a pan came
    /// back as "the user moved a window". The GPU pegged and the whole desktop
    /// — not just weft — lagged. Both are fixed, but a motion feature that can
    /// take the machine down with it has to be opted into, not opted out of.
    ///
    /// The strip is the one layout where a frame change is *motion* rather
    /// than a rearrangement: every window keeps its size and slides the same
    /// distance, so there is a real direction to read and jumping loses it —
    /// which column went where is left for the eye to work out. Nothing else
    /// weft does has that property, which is why this is a scroll setting and
    /// not a global one. A pan costs one WindowServer transaction per frame
    /// (no AX, no app IPC); the AX write that keeps each app's own idea of its
    /// position honest happens once, when the pan lands.
    public var scrollAnimationMs: Int
    public var reserve: ScreenReserve

    public init(
        innerGap: Double = 8,
        stackOffset: Double = 8,
        manageMenubarApps: Bool = false,
        checkForUpdates: Bool = true,
        outerGap: TilingConfig.OuterGap = TilingConfig.OuterGap(top: 8, bottom: 8, left: 8, right: 8),
        defaultLayout: LayoutKind = .bsp,
        mouseModifier: String = "alt",
        mouseBorderResize: Bool = true,
        mouseFollowsFocus: Bool = true,
        focusFollowsMouse: Bool = false,
        scrollAnimationMs: Int = 0,
        reserve: ScreenReserve = ScreenReserve()
    ) {
        self.innerGap = innerGap
        self.stackOffset = stackOffset
        self.manageMenubarApps = manageMenubarApps
        self.checkForUpdates = checkForUpdates
        self.outerGap = outerGap
        self.defaultLayout = defaultLayout
        self.mouseModifier = mouseModifier
        self.mouseBorderResize = mouseBorderResize
        self.mouseFollowsFocus = mouseFollowsFocus
        self.focusFollowsMouse = focusFollowsMouse
        self.scrollAnimationMs = scrollAnimationMs
        self.reserve = reserve
    }

    public func asTilingConfig() -> TilingConfig {
        TilingConfig(innerGap: innerGap, outerGap: outerGap, stackOffset: stackOffset)
    }
}

public struct SpaceScrollDecl: Sendable, Equatable {
    public var presetColumnWidths: [Double]?
    public var centerFocusedColumn: String?

    public init(presetColumnWidths: [Double]? = nil, centerFocusedColumn: String? = nil) {
        self.presetColumnWidths = presetColumnWidths
        self.centerFocusedColumn = centerFocusedColumn
    }
}

public struct SpaceDecl: Sendable, Equatable {
    public var label: String
    public var layout: LayoutKind
    public var scroll: SpaceScrollDecl?

    public init(label: String, layout: LayoutKind, scroll: SpaceScrollDecl? = nil) {
        self.label = label
        self.layout = layout
        self.scroll = scroll
    }
}

public struct SketchybarIntegrationConfig: Sendable, Equatable {
    public var enabled: Bool
    public var barName: String
    public var reserve: ScreenReserve?
    public var coalesceMs: Int
    public var events: [String]

    public init(
        enabled: Bool = false,
        barName: String = "sketchybar",
        reserve: ScreenReserve? = nil,
        coalesceMs: Int = 16,
        events: [String] = []
    ) {
        self.enabled = enabled
        self.barName = barName
        self.reserve = reserve
        self.coalesceMs = coalesceMs
        self.events = events
    }
}

/// Which code draws the borders.
public enum BordersBackend: String, Sendable, Equatable {
    /// Weft's own renderer, in-process. Borders only around windows weft is
    /// managing, placed from the same frames weft applies, with no second
    /// process and no `fork` per colour change.
    case native
    /// The external `borders` binary (JankyBorders). Kept because it has
    /// options weft's renderer does not, and because a config that already
    /// worked should keep working.
    case janky
}

public struct BordersIntegrationConfig: Sendable, Equatable {
    public var enabled: Bool
    public var backend: BordersBackend
    public var args: [String]
    public var supervise: Bool
    public var activeColor: [String: String]
    public var modeColor: [String: String]
    /// Native renderer only. Nil means "take it from `args`", so a config
    /// written for JankyBorders needs no edits to work with the native one.
    public var width: Double?
    public var radius: Double?
    public var inactiveColor: String?
    public var showInactive: Bool

    public init(
        enabled: Bool = false,
        backend: BordersBackend = .native,
        args: [String] = [],
        supervise: Bool = true,
        activeColor: [String: String] = [:],
        modeColor: [String: String] = [:],
        width: Double? = nil,
        radius: Double? = nil,
        inactiveColor: String? = nil,
        showInactive: Bool = true
    ) {
        self.enabled = enabled
        self.backend = backend
        self.args = args
        self.supervise = supervise
        self.activeColor = activeColor
        self.modeColor = modeColor
        self.width = width
        self.radius = radius
        self.inactiveColor = inactiveColor
        self.showInactive = showInactive
    }

    /// A `key=value` from JankyBorders' argument list, so `args = ["width=5.0"]`
    /// keeps meaning what it meant.
    public func arg(_ key: String) -> String? {
        for a in args where a.hasPrefix("\(key)=") {
            return String(a.dropFirst(key.count + 1))
        }
        return nil
    }

    /// Stroke width the native renderer should use.
    public var resolvedWidth: Double {
        width ?? arg("width").flatMap(Double.init) ?? 4
    }

    /// Colour for everything that is not focused.
    public var resolvedInactiveColor: String {
        inactiveColor ?? arg("inactive_color") ?? "0x40414868"
    }

    /// Fallback active colour, for a layout with no entry in `active-color`.
    public var resolvedActiveColor: String {
        arg("active_color") ?? "0xff7aa2f7"
    }
}

public struct IntegrationsConfig: Sendable, Equatable {
    public var sketchybar: SketchybarIntegrationConfig
    public var borders: BordersIntegrationConfig

    public init(
        sketchybar: SketchybarIntegrationConfig = SketchybarIntegrationConfig(),
        borders: BordersIntegrationConfig = BordersIntegrationConfig()
    ) {
        self.sketchybar = sketchybar
        self.borders = borders
    }
}

public struct ValidatedConfig: Sendable, Equatable {
    public var general: GeneralConfig
    public var spaces: [SpaceDecl]
    public var rules: [Rule]
    public var keymap: Keymap
    public var integrations: IntegrationsConfig

    public init(
        general: GeneralConfig,
        spaces: [SpaceDecl],
        rules: [Rule],
        keymap: Keymap,
        integrations: IntegrationsConfig = IntegrationsConfig()
    ) {
        self.general = general
        self.spaces = spaces
        self.rules = rules
        self.keymap = keymap
        self.integrations = integrations
    }

    public static var `default`: ValidatedConfig {
        ValidatedConfig(
            general: GeneralConfig(
                innerGap: 8,
                stackOffset: 8,
                manageMenubarApps: false,
                checkForUpdates: true,
                outerGap: TilingConfig.OuterGap(top: 8, bottom: 8, left: 8, right: 8),
                defaultLayout: .bsp,
                mouseModifier: "alt",
                mouseFollowsFocus: true,
                focusFollowsMouse: false,
                reserve: ScreenReserve()
            ),
            spaces: [],
            rules: [],
            keymap: .default,
            integrations: IntegrationsConfig()
        )
    }
}

public struct ConfigError: Error, Sendable, Equatable {
    public var line: Int
    public var message: String
}

// MARK: - Loader (strict: typos fail loudly with line numbers)

/// Load + validate weft.toml. Unknown sections/keys are errors — except
/// [integrations.*], which parses now and activates in M6.5 (warned, kept so
/// copy-pasted DESIGN examples don't break).
public func loadConfig(_ input: String) throws -> ValidatedConfig {
    let doc: TomlDocument
    do {
        doc = try parseTOML(input)
    } catch let e as TomlError {
        throw ConfigError(line: e.line, message: e.message)
    }
    func err(_ path: String, _ message: String) -> ConfigError {
        ConfigError(line: doc.lines[path] ?? 0, message: "\(path): \(message)")
    }

    // Unknown sections check.
    for name in doc.tables.keys {
        if name == "general" || name == "keys" || name.hasPrefix("mode.") { continue }
        if name == "integrations" || name == "integrations.sketchybar" || name == "integrations.borders" {
            continue
        }
        throw ConfigError(line: doc.lines[name] ?? 0, message: "unknown section [\(name)]")
    }
    for name in doc.arrays.keys where name != "space" && name != "rule" {
        throw ConfigError(line: doc.lines["\(name)#0"] ?? 0, message: "unknown [[\(name)]]")
    }

    // [general]
    var general = ValidatedConfig.default.general
    if let g = doc.tables["general"] {
        for (k, v) in g {
            let path = "general.\(k)"
            switch k {
            case "inner-gap":
                guard case .int(let n) = v, n >= 0 else {
                    throw err(path, "expected non-negative int")
                }
                general.innerGap = Double(n)
            case "stack-offset":
                guard case .int(let n) = v, n >= 0 else {
                    throw err(path, "expected non-negative int")
                }
                general.stackOffset = Double(n)
            case "check-for-updates":
                guard case .bool(let b) = v else { throw err(path, "expected bool") }
                general.checkForUpdates = b
            case "manage-menubar-apps":
                guard case .bool(let b) = v else { throw err(path, "expected bool") }
                general.manageMenubarApps = b
            case "outer-gap":
                general.outerGap = try parseOuterGap(v, path: path, lines: doc.lines)
            case "default-layout":
                guard case .string(let s) = v, let kind = LayoutKind(rawValue: s) else {
                    throw err(path, "expected bsp|scroll|float")
                }
                general.defaultLayout = kind
            case "mouse-modifier":
                guard case .string(let s) = v else { throw err(path, "expected string") }
                general.mouseModifier = s
            case "mouse-border-resize":
                guard case .bool(let b) = v else { throw err(path, "expected bool") }
                general.mouseBorderResize = b
            case "mouse-follows-focus":
                guard case .bool(let b) = v else { throw err(path, "expected bool") }
                general.mouseFollowsFocus = b
            case "focus-follows-mouse":
                guard case .bool(let b) = v else { throw err(path, "expected bool") }
                general.focusFollowsMouse = b
            case "scroll-animation-ms":
                guard case .int(let n) = v, n >= 0, n <= 2000 else {
                    throw err(path, "expected int between 0 and 2000 (0 = off)")
                }
                general.scrollAnimationMs = n
            case "reserve":
                general.reserve = try parseReserve(v, path: path, lines: doc.lines)
            default:
                throw err(path, "unknown general key")
            }
        }
    }

    // [[space]]
    var spaces: [SpaceDecl] = []
    var seenLabels = Set<String>()
    for (i, elem) in (doc.arrays["space"] ?? []).enumerated() {
        let at = { (k: String) in doc.lines["space#\(i).\(k)"] ?? 0 }
        guard case .string(let label) = elem["label"], !label.isEmpty else {
            throw ConfigError(line: at("label"), message: "space#\(i): label is required")
        }
        guard seenLabels.insert(label).inserted else {
            throw ConfigError(line: at("label"), message: "duplicate space label '\(label)'")
        }
        var layout = general.defaultLayout
        if let lv = elem["layout"] {
            guard case .string(let s) = lv, let kind = LayoutKind(rawValue: s) else {
                throw ConfigError(line: at("layout"), message: "expected bsp|scroll|float")
            }
            layout = kind
        }
        var scrollDecl: SpaceScrollDecl? = nil
        if let sv = elem["scroll"] {
            guard case .table(let tbl) = sv else {
                throw ConfigError(line: at("scroll"), message: "expected inline table for scroll")
            }
            var widths: [Double]?
            if let wv = tbl["preset-column-widths"] {
                guard case .array(let arr) = wv else {
                    throw ConfigError(line: at("scroll"), message: "expected array of numbers for preset-column-widths")
                }
                var ws: [Double] = []
                for item in arr {
                    switch item {
                    case .float(let f): ws.append(f)
                    case .int(let n): ws.append(Double(n))
                    default:
                        throw ConfigError(line: at("scroll"), message: "expected number in preset-column-widths")
                    }
                }
                // Range-checked, now that the key is actually read: a width is
                // a fraction of the usable width, and `cyclingWidth` sets it
                // straight onto the column without a clamp of its own. An
                // unchecked 99 in this list is a column ninety-nine screens
                // wide and every other column parked off the edge.
                guard !ws.isEmpty else {
                    throw ConfigError(
                        line: at("scroll"),
                        message: "preset-column-widths must not be empty"
                    )
                }
                guard ws.allSatisfy({ $0 > 0 && $0 <= 1 }) else {
                    throw ConfigError(
                        line: at("scroll"),
                        message: "preset-column-widths must be fractions in (0, 1]"
                    )
                }
                widths = ws
            }
            var center: String?
            if let cv = tbl["center-focused-column"] {
                guard case .string(let s) = cv else {
                    throw ConfigError(line: at("scroll"), message: "expected string for center-focused-column")
                }
                guard ["always", "never", "on-overflow"].contains(s) else {
                    throw ConfigError(line: at("scroll"), message: "expected always|never|on-overflow")
                }
                center = s
            }
            for sk in tbl.keys where sk != "preset-column-widths" && sk != "center-focused-column" {
                throw ConfigError(line: at("scroll"), message: "unknown scroll key '\(sk)'")
            }
            scrollDecl = SpaceScrollDecl(presetColumnWidths: widths, centerFocusedColumn: center)
        }
        for k in elem.keys where k != "label" && k != "layout" && k != "scroll" {
            throw ConfigError(line: at(k), message: "unknown space key '\(k)'")
        }
        spaces.append(SpaceDecl(label: label, layout: layout, scroll: scrollDecl))
    }

    // [[rule]]
    var rules: [Rule] = []
    for (i, elem) in (doc.arrays["rule"] ?? []).enumerated() {
        let at = { (k: String) in doc.lines["rule#\(i).\(k)"] ?? 0 }
        func str(_ k: String) throws -> String? {
            guard let v = elem[k] else { return nil }
            guard case .string(let s) = v else {
                throw ConfigError(line: at(k), message: "expected string")
            }
            return s
        }
        let rule = Rule(
            bundleID: try str("bundle-id"),
            app: try str("app"),
            title: try str("title"),
            space: try str("space"),
            manage: try {
                guard let v = elem["manage"] else { return nil }
                guard case .bool(let b) = v else {
                    throw ConfigError(line: at("manage"), message: "expected bool")
                }
                return b
            }()
        )
        guard rule.bundleID != nil || rule.app != nil || rule.title != nil else {
            throw ConfigError(
                line: doc.lines["rule#\(i)"] ?? 0,
                message: "rule#\(i): at least one of bundle-id/app/title is required"
            )
        }
        for pattern in [rule.app, rule.title].compactMap({ $0 }) {
            guard (try? NSRegularExpression(pattern: pattern)) != nil else {
                throw ConfigError(line: at("app"), message: "bad regex: \(pattern)")
            }
        }
        for k in elem.keys
            where k != "bundle-id" && k != "app" && k != "title" && k != "space" && k != "manage"
        {
            throw ConfigError(line: at(k), message: "unknown rule key '\(k)'")
        }
        rules.append(rule)
    }

    // [keys] + [mode.*] — values use the shared command grammar (§7), so
    // typos fail here with line numbers instead of silently never firing.
    var modes: [String: [Chord: KeyAction]] = [:]
    /// Deferred `mode <name>` targets: (target, chord, line). Checked once every
    /// section has been parsed.
    var modeTargets: [(target: String, chord: String, line: Int)] = []
    var keyTables: [(mode: String, table: [String: TomlValue], prefix: String)] = []
    if let keys = doc.tables["keys"] {
        keyTables.append(("default", keys, "keys"))
    }
    for name in doc.tables.keys where name.hasPrefix("mode.") {
        keyTables.append((String(name.dropFirst(5)), doc.tables[name]!, name))
    }
    for (mode, table, prefix) in keyTables {
        guard !mode.isEmpty else { throw ConfigError(line: 0, message: "empty mode name") }
        var binds: [Chord: KeyAction] = [:]
        for (chordText, cmdValue) in table {
            let path = "\(prefix).\(chordText)"
            let line = doc.lines[path] ?? 0
            let chord: Chord
            do {
                chord = try parseChord(chordText)
            } catch {
                throw ConfigError(line: line, message: "bad chord '\(chordText)': \(error)")
            }
            guard case .string(let cmdText) = cmdValue else {
                throw ConfigError(line: line, message: "keybind value must be a string")
            }
            let action: KeyAction
            if cmdText.split(separator: " ").first == "mode" {
                // Mode switches resolve locally in the input layer.
                let parts = cmdText.split(separator: " ").map(String.init)
                guard parts.count == 2 else {
                    throw ConfigError(line: line, message: "bad mode command: \(cmdText)")
                }
                action = .mode(parts[1])
                modeTargets.append((target: parts[1], chord: chordText, line: line))
            } else {
                do {
                    let cmd = try Command.parse(cmdText)
                    _ = cmd
                } catch {
                    throw ConfigError(line: line, message: "bad command '\(cmdText)': \(error)")
                }
                action = .send(cmdText)
            }
            if binds[chord] != nil {
                throw ConfigError(line: line, message: "duplicate chord '\(chordText)'")
            }
            binds[chord] = action
        }
        modes[mode] = binds
    }
    // Mode targets, now that every [mode.*] section has been seen. This cannot
    // be checked inline above: `[keys]` may bind `mode resize` several sections
    // before `[mode.resize]` is parsed.
    //
    // The input layer already ignores a switch to an undefined mode, so without
    // this the symptom of a typo is a key that does nothing at all, with no
    // error anywhere — the config loads, weftd runs, the bind is simply inert.
    for pending in modeTargets where pending.target != "default" && modes[pending.target] == nil {
        let known = modes.keys.sorted().filter { $0 != "default" }.joined(separator: ", ")
        throw ConfigError(
            line: pending.line,
            message: "'\(pending.chord)' switches to mode '\(pending.target)', which has no "
                + "[mode.\(pending.target)] section (defined: \(known.isEmpty ? "none" : known))"
        )
    }

    let keymap = modes.isEmpty ? Keymap.default : Keymap(
        modes: modes,
        initialMode: modes["default"] != nil ? "default" : modes.keys.sorted().first!
    )

    var integrations = ValidatedConfig.default.integrations
    if let sb = doc.tables["integrations.sketchybar"] {
        for (k, v) in sb {
            let path = "integrations.sketchybar.\(k)"
            switch k {
            case "enabled":
                guard case .bool(let b) = v else { throw err(path, "expected bool") }
                integrations.sketchybar.enabled = b
            case "bar-name":
                guard case .string(let s) = v else { throw err(path, "expected string") }
                integrations.sketchybar.barName = s
            case "reserve":
                let res = try parseReserve(v, path: path, lines: doc.lines)
                integrations.sketchybar.reserve = res
                if general.reserve == ScreenReserve() {
                    general.reserve = res
                }
            case "coalesce-ms":
                guard case .int(let n) = v, n >= 0 else { throw err(path, "expected non-negative int") }
                integrations.sketchybar.coalesceMs = n
            case "events":
                guard case .array(let arr) = v else { throw err(path, "expected array of strings") }
                var evs: [String] = []
                for item in arr {
                    guard case .string(let s) = item else { throw err(path, "expected string in array") }
                    evs.append(s)
                }
                integrations.sketchybar.events = evs
            default:
                throw err(path, "unknown key")
            }
        }
    }
    if let bd = doc.tables["integrations.borders"] {
        for (k, v) in bd {
            let path = "integrations.borders.\(k)"
            switch k {
            case "enabled":
                guard case .bool(let b) = v else { throw err(path, "expected bool") }
                integrations.borders.enabled = b
            case "supervise":
                guard case .bool(let b) = v else { throw err(path, "expected bool") }
                integrations.borders.supervise = b
            case "backend":
                guard case .string(let sv) = v else { throw err(path, "expected string") }
                guard let backend = BordersBackend(rawValue: sv) else {
                    throw err(path, "expected native|janky")
                }
                integrations.borders.backend = backend
            case "width":
                guard let d = v.asDouble else { throw err(path, "expected number") }
                integrations.borders.width = d
            case "radius":
                guard let d = v.asDouble else { throw err(path, "expected number") }
                integrations.borders.radius = d
            case "inactive-color":
                guard case .string(let sv) = v else { throw err(path, "expected string hex") }
                integrations.borders.inactiveColor = sv
            case "show-inactive":
                guard case .bool(let b) = v else { throw err(path, "expected bool") }
                integrations.borders.showInactive = b
            case "args":
                guard case .array(let arr) = v else { throw err(path, "expected array of strings") }
                var args: [String] = []
                for item in arr {
                    guard case .string(let s) = item else { throw err(path, "expected string in array") }
                    args.append(s)
                }
                integrations.borders.args = args
            case "active-color":
                guard case .table(let t) = v else { throw err(path, "expected table") }
                var map: [String: String] = [:]
                for (ck, cv) in t {
                    guard case .string(let cs) = cv else { throw err("\(path).\(ck)", "expected string hex") }
                    map[ck] = cs
                }
                integrations.borders.activeColor = map
            case "mode-color":
                guard case .table(let t) = v else { throw err(path, "expected table") }
                var map: [String: String] = [:]
                for (ck, cv) in t {
                    guard case .string(let cs) = cv else { throw err("\(path).\(ck)", "expected string hex") }
                    map[ck] = cs
                }
                integrations.borders.modeColor = map
            default:
                throw err(path, "unknown key")
            }
        }
    }

    return ValidatedConfig(general: general, spaces: spaces, rules: rules, keymap: keymap, integrations: integrations)
}

private func parseOuterGap(_ v: TomlValue, path: String, lines: [String: Int]) throws -> TilingConfig.OuterGap {
    func err(_ message: String) -> ConfigError {
        ConfigError(line: lines[path] ?? 0, message: "\(path): \(message)")
    }
    switch v {
    case .int(let n):
        guard n >= 0 else { throw err("expected non-negative int") }
        let d = Double(n)
        return TilingConfig.OuterGap(top: d, bottom: d, left: d, right: d)
    case .table(let t):
        func side(_ k: String) throws -> Double {
            guard let sv = t[k] else {
                throw err("outer-gap missing '\(k)' (or use a single int)")
            }
            guard case .int(let n) = sv, n >= 0 else {
                throw err("outer-gap.\(k): expected non-negative int")
            }
            return Double(n)
        }
        return TilingConfig.OuterGap(
            top: try side("top"), bottom: try side("bottom"),
            left: try side("left"), right: try side("right")
        )
    default:
        throw err("expected int or { top, bottom, left, right }")
    }
}

private func parseReserve(_ v: TomlValue, path: String, lines: [String: Int]) throws -> ScreenReserve {
    func err(_ message: String) -> ConfigError {
        ConfigError(line: lines[path] ?? 0, message: "\(path): \(message)")
    }
    switch v {
    case .table(let tbl):
        func side(_ name: String) throws -> Double {
            guard let val = tbl[name] else { return 0 }
            switch val {
            case .int(let n):
                guard n >= 0 else { throw err("\(name) must be non-negative") }
                return Double(n)
            case .float(let f):
                guard f >= 0 else { throw err("\(name) must be non-negative") }
                return f
            default:
                throw err("\(name) must be a number")
            }
        }
        for k in tbl.keys where k != "top" && k != "bottom" && k != "left" && k != "right" {
            throw err("unknown reserve key '" + k + "'")
        }
        return ScreenReserve(
            top: try side("top"),
            bottom: try side("bottom"),
            left: try side("left"),
            right: try side("right")
        )
    case .int(let n):
        guard n >= 0 else { throw err("expected non-negative int") }
        let d = Double(n)
        return ScreenReserve(top: d, bottom: d, left: d, right: d)
    default:
        throw err("expected int or inline table { top = ..., bottom = ..., left = ..., right = ... }")
    }
}
