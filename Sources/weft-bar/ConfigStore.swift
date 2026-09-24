import AppKit
import Foundation
import WeftBarConfig
import SwiftUI
import WeftConfig

// The Settings window's model: a typed, bindable view of weft.toml.
//
// Everything the form owns is read out of the document on load and written
// back into the *same lines* on save (see TomlDocument). Everything else is
// carried through untouched, so an unrecognised key or a comment survives a
// round trip through a UI that has never heard of it.

// MARK: - Rows

struct SpaceRow: Identifiable, Equatable {
    var id = UUID()
    var label: String = ""
    var layout: String = "bsp"
    /// The `[[space]]` section this row came from, so any comment inside the
    /// block survives an edit to the label next to it.
    var origin: TomlSection?
}

struct RuleRow: Identifiable, Equatable {
    var id = UUID()
    var app: String = ""
    var title: String = ""
    var bundleID: String = ""
    var space: String = ""
    /// nil = unset, which is what `[[rule]]` means by "managed": leaving the
    /// key out and writing `manage = true` are the same thing to weftd, and
    /// only the first keeps a hand-written file looking hand-written.
    var manage: Bool? = nil
    var origin: TomlSection?

    var isValid: Bool { !(app.isEmpty && title.isEmpty && bundleID.isEmpty) }
}

struct KeyRow: Identifiable, Equatable {
    var id = UUID()
    var chord: String = ""
    var command: String = ""
}

struct KeyMode: Identifiable, Equatable {
    var id = UUID()
    /// "default" is `[keys]`; anything else is `[mode.<name>]`.
    var name: String
    var rows: [KeyRow]

    var header: String { name == "default" ? "[keys]" : "[mode.\(name)]" }
    var isDefault: Bool { name == "default" }
}

// MARK: - Store

@MainActor
final class ConfigStore: ObservableObject {
    enum Status: Equatable {
        case idle(String)
        case ok(String)
        case problem(String)

        var text: String {
            switch self {
            case .idle(let s), .ok(let s), .problem(let s): return s
            }
        }
    }

    // General
    @Published var innerGap = 8
    /// How far each stacked window peeks out from the one in front of it.
    @Published var stackOffset = 8
    @Published var outerTop = 8
    @Published var outerBottom = 8
    @Published var outerLeft = 8
    @Published var outerRight = 8
    @Published var linkOuterGaps = true
    @Published var reserveTop = 0
    @Published var reserveBottom = 0
    @Published var reserveLeft = 0
    @Published var reserveRight = 0
    @Published var defaultLayout = "bsp"
    @Published var mouseModifier = "alt"
    @Published var mouseBorderResize = true
    @Published var mouseFollowsFocus = true
    @Published var focusFollowsMouse = false
    /// Whether a rule's `space = "…"` also switches to that workspace. The
    /// window is placed either way; this is only whether the screen follows.
    @Published var followSpaceRules = false
    @Published var manageMenubarApps = false
    @Published var checkForUpdates = true

    // Integrations
    @Published var bordersEnabled = false
    /// `native` (weft draws them) or `janky` (JankyBorders does).
    @Published var bordersBackend = "native"
    @Published var bordersWidth = 2.0
    /// JankyBorders' `style`: `round` follows each window's own corners,
    /// `square` squares them off. It replaced a "Corner radius" slider that
    /// wrote `radius =`, which JankyBorders rejects outright — see
    /// `BordersIntegrationConfig.resolvedArgs`.
    @Published var bordersStyle = "round"
    /// The focused border's colour, read from `active-color`. Written back
    /// only when changed here: the file may hold a per-layout table the one
    /// colour picker cannot represent, and opening Settings must not
    /// flatten it.
    @Published var bordersActiveColor = "0xff7aa2f7"
    private var activeColorEdited = false
    @Published var bordersInactiveColor = ""
    @Published var bordersShowInactive = true
    @Published var bordersSupervise = true
    @Published var bordersArgs = ""
    /// Set when `args` is spread over several lines in the file — the text
    /// field cannot represent that, so it goes read-only rather than lossy.
    @Published var bordersArgsLocked = false
    @Published var sketchybarEnabled = false
    @Published var sketchybarBarName = "sketchybar"
    @Published var sketchybarCoalesceMs = 16

    // Collections
    @Published var spaces: [SpaceRow] = []
    @Published var rules: [RuleRow] = []
    @Published var modes: [KeyMode] = []

    @Published var status: Status = .idle("")
    @Published var isDirty = false
    /// When the last save landed — what the window's "Saved" tick follows.
    @Published var lastSavedAt: Date?
    /// Changes apply as they are made; this is the pending write.
    private var autosave: Task<Void, Never>?
    /// Line-numbered validation failure from the last save attempt.
    @Published var validationError: String?

    private var document = TomlDocument("")
    private var loading = false

    static var configPath: String { ("~/.config/weft/weft.toml" as NSString).expandingTildeInPath }

    var spaceLabels: [String] { spaces.map(\.label).filter { !$0.isEmpty } }

    // MARK: Load

    func load() {
        loading = true
        defer { loading = false; isDirty = false; validationError = nil }

        guard let text = try? String(contentsOfFile: Self.configPath, encoding: .utf8) else {
            document = TomlDocument(defaultSkeleton)
            readAll()
            status = .idle("No config yet — showing defaults. Save to create the file.")
            return
        }
        document = TomlDocument(text)
        readAll()

        // Report a file that weftd would reject, but still show it: refusing
        // to open is how a small typo turns into hand-editing TOML, which is
        // the thing this window exists to avoid.
        do {
            let validated = try WeftConfig.loadConfig(text)
            status = Self.loadedStatus(validated, verb: "Loaded \(Self.configPath)")
        } catch let e as ConfigError {
            status = .problem("Line \(e.line): \(e.message) — weftd is running the last valid version")
        } catch {
            status = .problem(error.localizedDescription)
        }
    }

    private func readAll() {
        // Before the panes read anything: several of them pick their nouns
        // from it, and one frame drawn with the other mode's words is a flicker
        // that reads as a bug.
        WorkspaceVocabulary.refresh(from: document)
        readGeneral()
        readIntegrations()
        readSpaces()
        readRules()
        readKeys()
    }

    private func readGeneral() {
        let g = document.firstIndex(ofHeader: "[general]").map { document.sections[$0] }
        innerGap = g?.int("inner-gap") ?? 8
        stackOffset = g?.int("stack-offset") ?? 8
        if let o = TomlValue.sides(g?.rawValue("outer-gap")) {
            outerTop = o.top; outerBottom = o.bottom; outerLeft = o.left; outerRight = o.right
        }
        if let r = TomlValue.sides(g?.rawValue("reserve")) {
            reserveTop = r.top; reserveBottom = r.bottom; reserveLeft = r.left; reserveRight = r.right
        }
        linkOuterGaps = outerTop == outerBottom && outerBottom == outerLeft && outerLeft == outerRight
        defaultLayout = g?.string("default-layout") ?? "bsp"
        mouseModifier = g?.string("mouse-modifier") ?? "alt"
        mouseBorderResize = g?.bool("mouse-border-resize") ?? true
        mouseFollowsFocus = g?.bool("mouse-follows-focus") ?? true
        focusFollowsMouse = g?.bool("focus-follows-mouse") ?? false
        followSpaceRules = g?.bool("follow-space-rules") ?? false
        manageMenubarApps = g?.bool("manage-menubar-apps") ?? false
        checkForUpdates = g?.bool("check-for-updates") ?? true
    }

    private func readIntegrations() {
        let b = document.firstIndex(ofHeader: "[integrations.borders]").map { document.sections[$0] }
        bordersEnabled = b?.bool("enabled") ?? false
        bordersBackend = b?.string("backend") == "janky" ? "janky" : "native"
        bordersWidth = b?.double("width")
            ?? Self.argValue(b?.rawValue("args"), "width").flatMap(Double.init)
            ?? 2
        bordersStyle = b?.string("style")
            ?? Self.argValue(b?.rawValue("args"), "style")
            // A file still carrying the old numeric radius reads as the shape
            // that radius meant, which is what weftd makes of it too.
            ?? (b?.double("radius")).map { $0 <= 0 ? "square" : "round" }
            ?? "round"
        bordersActiveColor = Self.firstColor(in: b?.rawValue("active-color")) ?? "0xff7aa2f7"
        activeColorEdited = false
        bordersInactiveColor = b?.string("inactive-color")
            ?? Self.argValue(b?.rawValue("args"), "inactive_color")
            ?? ""
        bordersShowInactive = b?.bool("show-inactive") ?? true
        bordersSupervise = b?.bool("supervise") ?? true
        bordersArgsLocked = b?.isMultiline("args") ?? false
        bordersArgs = bordersArgsLocked
            ? "(spread over several lines — edit in Advanced)"
            : Self.readArray(b?.rawValue("args")).joined(separator: " ")

        let s = document.firstIndex(ofHeader: "[integrations.sketchybar]").map { document.sections[$0] }
        sketchybarEnabled = s?.bool("enabled") ?? false
        sketchybarBarName = s?.string("bar-name") ?? "sketchybar"
        sketchybarCoalesceMs = s?.int("coalesce-ms") ?? 16
    }

    /// One `key=value` out of a JankyBorders argument list, so the native
    /// renderer's fields start out showing what the user already had.
    private static func argValue(_ raw: String?, _ key: String) -> String? {
        for a in readArray(raw) where a.hasPrefix("\(key)=") {
            return String(a.dropFirst(key.count + 1))
        }
        return nil
    }

    private static func readArray(_ raw: String?) -> [String] {
        guard let raw, raw.hasPrefix("[") else { return [] }
        let inner = raw.dropFirst().drop(while: { $0 == " " })
        let body = String(inner.prefix(while: { $0 != "]" }))
        return body.split(separator: ",")
            .map { TomlValue.unquote(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func writeArray(_ items: [String]) -> String {
        "[" + items.map(TomlValue.quote).joined(separator: ", ") + "]"
    }

    private func readSpaces() {
        spaces = document.indices(ofHeader: "[[space]]").map { i in
            let s = document.sections[i]
            return SpaceRow(label: s.string("label") ?? "", layout: s.string("layout") ?? "bsp", origin: s)
        }
    }

    private func readRules() {
        rules = document.indices(ofHeader: "[[rule]]").map { i in
            let s = document.sections[i]
            return RuleRow(
                app: s.string("app") ?? "",
                title: s.string("title") ?? "",
                bundleID: s.string("bundle-id") ?? "",
                space: s.string("space") ?? "",
                manage: s.bool("manage"),
                origin: s
            )
        }
    }

    private func readKeys() {
        var out: [KeyMode] = []
        for (i, section) in document.sections.enumerated() {
            guard let header = section.header else { continue }
            let name: String
            if header == "[keys]" {
                name = "default"
            } else if header.hasPrefix("[mode.") {
                name = String(header.dropFirst(6).dropLast())
            } else {
                continue
            }
            _ = i
            let rows = section.entries.compactMap { entry -> KeyRow? in
                guard case .pair(let k, let v) = entry else { return nil }
                return KeyRow(chord: TomlValue.unquote(k), command: TomlValue.unquote(v))
            }
            out.append(KeyMode(name: name, rows: rows))
        }
        if out.isEmpty { out = [KeyMode(name: "default", rows: [])] }
        modes = out
    }

    /// "Loaded" is only the whole truth when nothing in the file was ignored.
    /// A config written for a layout weft no longer has still loads — the
    /// daemon runs it — but saying so in green would hide that some of it
    /// does nothing. The first warning is named; `weftctl doctor` lists all.
    private static func loadedStatus(_ cfg: ValidatedConfig, verb: String) -> Status {
        guard let first = cfg.warnings.first else { return .idle(verb) }
        let more = cfg.warnings.count > 1 ? " (+\(cfg.warnings.count - 1) more)" : ""
        return .problem("\(verb) — line \(first.line): \(first.message)\(more)")
    }

    // MARK: Save

    /// Fold the form back into the document, validate, then write. Nothing
    /// touches disk unless `WeftConfig.loadConfig` accepts the result — the
    /// daemon parses this file on a watcher, and half a second of broken
    /// config is half a second of a window manager that stopped managing.
    @discardableResult
    func save(reload: Bool = true) -> Bool {
        writeGeneral()
        writeIntegrations()
        writeSpaces()
        writeRules()
        writeKeys()

        let text = document.render()
        let validated: ValidatedConfig
        do {
            validated = try WeftConfig.loadConfig(text)
        } catch let e as ConfigError {
            validationError = "Line \(e.line): \(e.message)"
            status = .problem("Not saved — line \(e.line): \(e.message)")
            return false
        } catch {
            validationError = error.localizedDescription
            status = .problem("Not saved — \(error.localizedDescription)")
            return false
        }

        do {
            try FileManager.default.createDirectory(
                atPath: (Self.configPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try text.write(toFile: Self.configPath, atomically: true, encoding: .utf8)
        } catch {
            status = .problem("Save failed — \(error.localizedDescription)")
            return false
        }

        validationError = nil
        isDirty = false
        lastSavedAt = Date()
        // Re-read so every row is anchored to the section it now occupies —
        // except for a save made while the user is still editing. Re-reading
        // rebuilds every row with a new identity, which pulls the cursor out
        // of whatever field they are typing in. Skipping it is safe: the
        // document already holds exactly what was written.
        if reload {
            document = TomlDocument(text)
            loading = true
            readAll()
            loading = false
        }
        status = validated.warnings.isEmpty
            ? .ok("Saved — weftd reloads within 100 ms.")
            : Self.loadedStatus(validated, verb: "Saved")
        // No nudge. This used to post `sync` straight after the write, and the
        // sweep it started usually ran before weftd had reloaded the file — so
        // it re-tiled with the old gaps, and every change showed the one
        // before it. weftd re-tiles when the reload itself changes anything
        // that shapes the layout, which is the only moment that is right.
        return true
    }

    private func writeGeneral() {
        let i = document.ensureSection("[general]")
        var s = document.sections[i]
        s.set("inner-gap", int: innerGap)
        s.set("stack-offset", int: stackOffset)
        s.setRaw("outer-gap", TomlValue.sidesLiteral(
            top: outerTop, bottom: outerBottom, left: outerLeft, right: outerRight))
        s.set("default-layout", string: defaultLayout)
        s.set("mouse-modifier", string: mouseModifier)
        s.set("mouse-border-resize", bool: mouseBorderResize)
        s.set("mouse-follows-focus", bool: mouseFollowsFocus)
        s.set("focus-follows-mouse", bool: focusFollowsMouse)
        // Retired in 0.9.15: one workspace model, so these two only ever
        // produce a warning. Saving from Settings is a good moment to drop them.
        s.remove("workspaces")
        s.remove("workspace-anchor")
        s.set("follow-space-rules", bool: followSpaceRules)
        s.set("manage-menubar-apps", bool: manageMenubarApps)
        s.set("check-for-updates", bool: checkForUpdates)
        s.setRaw("reserve", TomlValue.sidesLiteral(
            top: reserveTop, bottom: reserveBottom, left: reserveLeft, right: reserveRight))
        document.sections[i] = s
    }

    private func writeIntegrations() {
        // Only materialise a section the user actually turned on — an
        // untouched file should not sprout `[integrations.borders]` just
        // because the Settings window was opened once.
        if bordersEnabled || document.firstIndex(ofHeader: "[integrations.borders]") != nil {
            let i = document.ensureSection("[integrations.borders]")
            var s = document.sections[i]
            s.set("enabled", bool: bordersEnabled)
            s.set("supervise", bool: bordersSupervise)
            // Written only when it is not the default, so a file that never
            // chose keeps following it.
            if bordersBackend == "janky" {
                s.set("backend", string: "janky")
            } else {
                s.remove("backend")
            }
            s.set("width", double: bordersWidth)
            s.set("style", string: bordersStyle)
            // `radius` is left as the file has it: weft's renderer draws it,
            // and weftd never hands it to JankyBorders.
            if activeColorEdited {
                s.setRaw(
                    "active-color",
                    #"{ bsp = "\#(bordersActiveColor)", float = "\#(bordersActiveColor)" }"#
                )
            }
            s.set("show-inactive", bool: bordersShowInactive)
            if bordersInactiveColor.isEmpty {
                s.remove("inactive-color")
            } else {
                s.set("inactive-color", string: bordersInactiveColor)
            }

            let args = bordersArgs.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            if s.isMultiline("args") {
                // Hand-wrapped across lines. The form showed only the first
                // line, so writing it back would truncate the list — leave it.
                // (The flag itself is set on load, never here: `previewText`
                // runs this from inside a view update, and publishing there
                // is how you get "Modifying state during view update".)
            } else if args.isEmpty {
                s.remove("args")
            } else {
                s.setRaw("args", Self.writeArray(args))
            }
            document.sections[i] = s
        }
        if sketchybarEnabled || document.firstIndex(ofHeader: "[integrations.sketchybar]") != nil {
            let i = document.ensureSection("[integrations.sketchybar]")
            var s = document.sections[i]
            s.set("enabled", bool: sketchybarEnabled)
            s.set("bar-name", string: sketchybarBarName)
            s.set("coalesce-ms", int: sketchybarCoalesceMs)
            document.sections[i] = s
        }
    }

    private func writeSpaces() {
        syncBlocks(header: "[[space]]", rows: spaces) { row, section in
            section.set("label", string: row.label)
            section.set("layout", string: row.layout)
        }
    }

    private func writeRules() {
        syncBlocks(header: "[[rule]]", rows: rules.filter(\.isValid)) { row, section in
            for (key, value) in [
                ("app", row.app), ("title", row.title),
                ("bundle-id", row.bundleID), ("space", row.space),
            ] {
                if value.isEmpty { section.remove(key) } else { section.set(key, string: value) }
            }
            if let manage = row.manage { section.set("manage", bool: manage) }
            else { section.remove("manage") }
        }
    }

    /// Rewrite every `[[header]]` block from `rows`, in the order the rows are
    /// in now. A row that came from the file keeps its own section — comments
    /// and all — and only the keys the form owns are touched.
    private func syncBlocks<Row: Identifiable>(
        header: String,
        rows: [Row],
        apply: (Row, inout TomlSection) -> Void
    ) where Row: HasOrigin {
        let existing = document.indices(ofHeader: header)
        let anchor = existing.first
        // The banner above the first block ("# Space Configurations") titles
        // the whole group, not the row that happens to be under it. Detach it
        // before rebuilding so reordering rows cannot strand it mid-list.
        let groupBanner = anchor.map { document.sections[$0].leading } ?? [.line("")]
        for i in existing.reversed() { document.sections.remove(at: i) }

        var rebuilt: [TomlSection] = []
        for row in rows {
            var section = row.origin ?? TomlSection(header: header, leading: [.line("")])
            section.header = header
            if rebuilt.isEmpty { section.leading = groupBanner }
            else if section.leading.isEmpty { section.leading = [.line("")] }
            apply(row, &section)
            rebuilt.append(section)
        }
        guard !rebuilt.isEmpty else { return }
        let at = anchor.map { min($0, document.sections.count) } ?? document.sections.count
        document.sections.insert(contentsOf: rebuilt, at: at)
    }

    private func writeKeys() {
        // Modes the user deleted go with their section; the rest are rewritten
        // pair by pair so a comment between two binds stays between them.
        let live = Set(modes.map(\.header))
        document.sections.removeAll { section in
            guard let h = section.header else { return false }
            let isKeySection = h == "[keys]" || h.hasPrefix("[mode.")
            return isKeySection && !live.contains(h)
        }
        for mode in modes {
            let i = document.ensureSection(mode.header)
            var s = document.sections[i]
            let valid = mode.rows.filter { !$0.chord.isEmpty && !$0.command.isEmpty }
            s.removePairs(notIn: Set(valid.map { $0.chord.lowercased() }))
            for row in valid { s.setRaw(TomlValue.quote(row.chord), TomlValue.quote(row.command)) }
            document.sections[i] = s
        }
    }

    // MARK: Edits

    /// Something changed. Save it shortly — changes apply as they are made.
    ///
    /// Debounced, because a slider reports every step of a drag and weftd
    /// reloads on every write. Nothing is written that `loadConfig` rejects:
    /// a half-typed shortcut simply waits, with the reason on screen.
    func markDirty() {
        guard !loading else { return }
        isDirty = true
        autosave?.cancel()
        autosave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !Task.isCancelled, self.isDirty else { return }
            self.save(reload: false)
        }
    }

    /// Write whatever is still waiting on the debounce, now. The window calls
    /// this as it closes, so the last change is never lost.
    func flush() {
        autosave?.cancel()
        autosave = nil
        if isDirty { save(reload: false) }
    }

    /// The colour picker's setter: the only path that rewrites `active-color`.
    func setActiveColor(_ hex: String) {
        guard hex != bordersActiveColor else { return }
        bordersActiveColor = hex
        activeColorEdited = true
        markDirty()
    }

    /// The first colour in an `active-color` value: the bsp entry of a table,
    /// else any 0x-colour in it.
    private static func firstColor(in raw: String?) -> String? {
        guard let raw else { return nil }
        for pattern in [#"bsp\s*=\s*"([^"]+)""#, #""(0x[0-9A-Fa-f]{6,8})""#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let range = Range(match.range(at: 1), in: raw)
            else { continue }
            return String(raw[range])
        }
        return nil
    }

    func setFollowSpaceRules(_ on: Bool) {
        followSpaceRules = on
        markDirty()
    }

    func addSpace() {
        spaces.append(SpaceRow(label: "space\(spaces.count + 1)", layout: defaultLayout))
        markDirty()
    }

    func addRule() {
        rules.append(RuleRow())
        markDirty()
    }

    func addKey(to modeID: KeyMode.ID) {
        guard let i = modes.firstIndex(where: { $0.id == modeID }) else { return }
        modes[i].rows.append(KeyRow())
        markDirty()
    }

    func addMode(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !clean.isEmpty, !modes.contains(where: { $0.name == clean }) else { return }
        modes.append(KeyMode(name: clean, rows: []))
        markDirty()
    }

    func removeMode(_ id: KeyMode.ID) {
        modes.removeAll { $0.id == id && !$0.isDefault }
        markDirty()
    }

    /// The file that gets written, for the Advanced tab's preview. Built from
    /// a copy so previewing never mutates what is on screen.
    func previewText() -> String {
        let snapshot = document
        writeGeneral(); writeIntegrations(); writeSpaces(); writeRules(); writeKeys()
        let text = document.render()
        document = snapshot
        return text
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Self.configPath)])
    }

    func openExternally() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Self.configPath))
    }

    private var defaultSkeleton: String {
        """
        # weft.toml — created by the Weft Settings window.
        # Everything here is hot-reloaded; weftd never needs a restart for it.

        [general]
        inner-gap = 8
        outer-gap = 8
        default-layout = "bsp"
        mouse-modifier = "alt"
        mouse-follows-focus = true
        focus-follows-mouse = false
        reserve = 0

        [keys]
        "alt-h" = "focus west"
        "alt-j" = "focus south"
        "alt-k" = "focus north"
        "alt-l" = "focus east"
        """
    }
}

/// Rows that remember the `[[block]]` they were parsed out of.
protocol HasOrigin {
    var origin: TomlSection? { get }
}

extension SpaceRow: HasOrigin {}
extension RuleRow: HasOrigin {}

extension ConfigStore {
    /// Read `check-for-updates` without loading the whole config.
    ///
    /// The menu bar asks this once at launch, before anything has parsed
    /// weft.toml, and an unreadable or absent config must mean "yes" — the
    /// default — rather than silently disabling the only channel through which
    /// a user learns a fix exists.
    static func readCheckForUpdates() -> Bool {
        let path = ("~/.config/weft/weft.toml" as NSString).expandingTildeInPath
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return true }
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("check-for-updates") else { continue }
            return !line.contains("false")
        }
        return true
    }
}
