// WeftCore/Spaces.swift — weft's workspaces: one per macOS desktop.
//
// A workspace IS a desktop (docs/NATIVE.md). macOS owns which desktops exist,
// their order and which display each is on, and which desktop every window is
// on; weft owns each desktop's layout, its label and its focus history. weft
// switches desktops and moves windows between them through SkyLight's bridged
// operations, verified by read-back (WeftPlatform/Bridge.swift); nothing here
// touches the Mac.
//
// Identity in memory is the SpaceID. On disk it is (display uuid, position),
// because SpaceIDs do not survive a logout. Labels attach by global number.
// Switching a workspace between bsp and float preserves membership: float
// remembers each window's real frame, and coming back out rebuilds a tree in
// that order.

public enum LayoutKind: String, Codable, Sendable, Equatable {
    case bsp
    case float
}

/// One display as the WindowServer reports it: its desktops in Mission
/// Control order (fullscreen and Split View spaces excluded) and the space
/// showing now, which is one of them or a fullscreen space.
public struct DisplayDesktops: Sendable, Equatable {
    public var uuid: String
    public var desktops: [SpaceID]
    public var current: SpaceID
    /// The display with the menu bar at rest. Its desktops are numbered first.
    public var isMain: Bool
    /// The display's left edge, in global coordinates: the others are
    /// numbered west to east.
    public var originX: Double

    public init(uuid: String, desktops: [SpaceID], current: SpaceID, isMain: Bool = false, originX: Double = 0) {
        self.uuid = uuid
        self.desktops = desktops
        self.current = current
        self.isMain = isMain
        self.originX = originX
    }
}

/// The displays in the order their desktops are numbered: the main display
/// first, then the others west to east (NATIVE.md, "Numbering and labels").
/// Mission Control reads the same way, so ⌥3 is the third desktop the user
/// can see in the overview. With no display marked main, the first reported
/// one is.
public func numberingOrder(_ displays: [DisplayDesktops]) -> [DisplayDesktops] {
    let main = displays.firstIndex(where: \.isMain) ?? displays.indices.first
    guard let main else { return [] }
    let rest = displays.enumerated().filter { $0.offset != main }
        .sorted { $0.element.originX == $1.element.originX ? $0.offset < $1.offset : $0.element.originX < $1.element.originX }
        .map(\.element)
    return [displays[main]] + rest
}

/// Where a desktop is, as it survives a logout: its display, and its 1-based
/// place among that display's desktops in Mission Control order. SpaceIDs are
/// handed out afresh at login; this is not.
public struct DesktopKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public var display: String
    public var position: Int

    public init(display: String, position: Int) {
        self.display = display
        self.position = position
    }

    /// "uuid#2", for a JSON object key.
    public var description: String { "\(display)#\(position)" }

    public init?(_ text: String) {
        guard let hash = text.lastIndex(of: "#"), let n = Int(text[text.index(after: hash)...]) else { return nil }
        self.init(display: String(text[..<hash]), position: n)
    }
}

public enum SpaceLayout: Sendable, Equatable {
    case tiling(Tree)
    case float(FloatState)

    public var kind: LayoutKind {
        switch self {
        case .tiling: return .bsp
        case .float: return .float
        }
    }

    public var windows: [WindowID] {
        switch self {
        case .tiling(let t): return t.windows
        case .float(let f): return f.windows
        }
    }

    public var focus: WindowID? {
        switch self {
        case .tiling(let t): return t.focus
        case .float(let f): return f.focus
        }
    }

    public var fullscreen: WindowID? {
        switch self {
        case .tiling(let t): return t.fullscreen
        case .float: return nil
        }
    }
}

/// Any window sequence → tree by successive right splits.
public func treeFromOrder(_ order: [WindowID], focus: WindowID? = nil) -> Tree {
    var node: Node?
    for wid in order {
        if let n = node {
            node = .container(Container(layout: .splitV, children: [n, .window(wid)]))
        } else {
            node = .window(wid)
        }
    }
    let resolved = (focus != nil && order.contains(focus!)) ? focus : order.first
    return Tree(root: node, focus: resolved, insertion: .bsp)
}

/// tiling → float: membership in order, actual frames remembered so
/// re-entering float restores the user's arrangement.
public func floatFromWindows(_ order: [WindowID], actuals: [WindowID: Frame], focus: WindowID?) -> FloatState {
    var remembered: [WindowID: Frame] = [:]
    for wid in order {
        if let f = actuals[wid] { remembered[wid] = f }
    }
    return FloatState(order: order, remembered: remembered, focus: order.contains(focus ?? 0) ? focus : order.first)
}

/// weft's own handle for a workspace, handed out within a launch and never
/// persisted. One workspace per desktop, for as long as the desktop exists.
///
/// A struct rather than a bare integer so that a window id (`UInt32` too) or
/// a desktop id cannot stand in for one in an expression that compiles.
///
/// Deliberately NOT `Codable`. `labels.json` is keyed by number and
/// `layouts.json` by `DesktopKey`, and `query spaces` and `query bar-state`
/// speak in desktop ids, which is what weft-bar and weftctl resolve against.
/// Withholding the conformance means a workspace id put on the wire by
/// accident is a build error rather than a number that decodes and means
/// nothing.
public struct WorkspaceID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let raw: UInt32

    public init(_ raw: UInt32) { self.raw = raw }

    public static func < (a: WorkspaceID, b: WorkspaceID) -> Bool { a.raw < b.raw }

    public var description: String { "ws\(raw)" }
}

/// One macOS desktop's layout and the windows on it.
///
/// No `display` field: macOS decides a desktop's display, and
/// `SpaceState.displayBySpace` is where that answer lives.
public struct Workspace: Sendable, Equatable {
    public var id: WorkspaceID
    /// The name `space focus <label>` and `[[rule]] space = "..."` resolve to:
    /// the label at this desktop's number, or the number itself.
    public var label: String
    /// The desktop it is. Never changes.
    public var desktop: SpaceID
    public var layout: SpaceLayout
    /// The kind the user asked for with `space layout <kind>`, as opposed to
    /// the one the layout happens to be. Kept apart from `layout` so the
    /// intent survives the workspace emptying, and so it can be persisted:
    /// without the record, the next config reload, the next empty sweep and
    /// the next restart all quietly undo the choice.
    public var overrideKind: LayoutKind?
    /// Members that are not laid out: floated by hand, unmanaged by a rule,
    /// struck out as a quirk, or an app weft always floats. They are on this
    /// desktop all the same, and focus follows them here; only the layout
    /// ignores them. Panels and popovers are not here: a menu-bar extra's
    /// popover belongs to the menu bar.
    public var loose: Set<WindowID>
    /// The window last focused on this desktop, laid out or loose: what a
    /// switch here focuses (NATIVE.md, "Switching").
    public var lastFocused: WindowID?
    /// Where the desktop was when last numbered, so its layout can be stashed
    /// there if it goes away (`SpaceState.stash`).
    public var keyHint: DesktopKey?

    public init(
        id: WorkspaceID,
        label: String,
        desktop: SpaceID,
        layout: SpaceLayout,
        overrideKind: LayoutKind? = nil,
        loose: Set<WindowID> = [],
        lastFocused: WindowID? = nil
    ) {
        self.id = id
        self.label = label
        self.desktop = desktop
        self.layout = layout
        self.overrideKind = overrideKind
        self.loose = loose
        self.lastFocused = lastFocused
    }

    /// Every window in the workspace: the laid-out ones in layout order, then
    /// the loose ones by id.
    public var members: [WindowID] {
        let tiled = layout.windows
        let placed = Set(tiled)
        return tiled + loose.subtracting(placed).sorted()
    }

    public func contains(_ wid: WindowID) -> Bool {
        loose.contains(wid) || layout.windows.contains(wid)
    }

    /// The window a switch here should focus: the last one focused, while it
    /// is still here, else the layout's focus, else any member. Nil for an
    /// empty desktop, which takes focus itself.
    public var focusTarget: WindowID? {
        if let w = lastFocused, contains(w) { return w }
        return layout.focus ?? members.first
    }
}

public struct SpaceState: Sendable, Equatable {
    /// Every workspace, by id: one per ordinary desktop that exists.
    public var workspaces: [WorkspaceID: Workspace]
    /// The workspace of each desktop. Every ordinary desktop has one, and only
    /// ordinary desktops do: a fullscreen or Split View space is not a
    /// workspace.
    public var active: [SpaceID: WorkspaceID]
    /// Labels by global number (index 0 is desktop 1), from `[[space]]` or
    /// `labels.json`. May be longer than the desktops that exist: a label with
    /// no desktop yet waits for one (NATIVE.md, "Desktop count").
    public var names: [String]
    /// Workspaces in global number order: what `space focus N` counts.
    public var wsOrder: [WorkspaceID]
    /// Next id to hand out. Unique within a launch, never persisted.
    public var nextWorkspaceID: UInt32
    /// display uuid → the space showing there now: a desktop, or a fullscreen
    /// space. Re-read from the WindowServer, never inferred.
    public var currentByDisplay: [String: SpaceID]
    /// Display uuids in numbering order: main first, then west to east.
    public var displays: [String]
    /// Desktop → its display uuid. A desktop's layout is computed in that
    /// display's rect.
    public var displayBySpace: [SpaceID: String]
    /// Desktop → where it is as a logout leaves it: (display, position).
    public var keyBySpace: [SpaceID: DesktopKey]
    /// The display holding the active menu bar, i.e. the one keyboard focus
    /// is on. Nil = fall back to `displays.first`.
    public var focusedDisplay: String?
    /// Desktops in global number order.
    public var order: [SpaceID]
    /// The workspace to go back to for `space focus recent`.
    public var recentWorkspace: WorkspaceID?
    /// Layouts of desktops that went away — a display unplugged, a desktop
    /// removed — by where they were. A desktop that appears at the same
    /// place takes its layout back, so docking does not cost an arrangement.
    public var stash: [DesktopKey: Workspace]

    public init(
        workspaces: [WorkspaceID: Workspace] = [:],
        active: [SpaceID: WorkspaceID] = [:],
        names: [String] = [],
        wsOrder: [WorkspaceID] = [],
        nextWorkspaceID: UInt32 = 1,
        currentByDisplay: [String: SpaceID] = [:],
        displays: [String] = [],
        displayBySpace: [SpaceID: String] = [:],
        keyBySpace: [SpaceID: DesktopKey] = [:],
        focusedDisplay: String? = nil,
        order: [SpaceID] = [],
        recentWorkspace: WorkspaceID? = nil,
        stash: [DesktopKey: Workspace] = [:]
    ) {
        self.workspaces = workspaces
        self.active = active
        self.names = names
        self.wsOrder = wsOrder
        self.nextWorkspaceID = nextWorkspaceID
        self.currentByDisplay = currentByDisplay
        self.displays = displays
        self.displayBySpace = displayBySpace
        self.keyBySpace = keyBySpace
        self.focusedDisplay = focusedDisplay
        self.order = order
        self.recentWorkspace = recentWorkspace
        self.stash = stash
    }

    /// The space the user is on: the focused display's current space. Falls
    /// back to the first display's, which is exact on a single display.
    public var currentSpace: SpaceID? {
        if let uuid = focusedDisplay, let sid = currentByDisplay[uuid] { return sid }
        return displays.first.flatMap { currentByDisplay[$0] }
    }

    /// The space showing on each display — a desktop, or a fullscreen space.
    /// These are the spaces a sweep may bind AX elements for and apply
    /// frames to; a fullscreen one has no workspace, so nothing is applied.
    public var visibleSpaces: [SpaceID] {
        displays.compactMap { currentByDisplay[$0] }
    }

    // MARK: - Reading a workspace
    //
    // Every accessor below is a method on the state rather than on the daemon,
    // and that is load-bearing: call sites read these from inside an
    // `updateSpaces` closure, which already holds `spaces` for writing. A
    // daemon method that went back through `readSpaces()` would be an
    // exclusivity violation and Swift aborts the process on the spot.

    /// The workspace of a desktop.
    public func workspace(on desktop: SpaceID) -> Workspace? {
        active[desktop].flatMap { workspaces[$0] }
    }

    /// The layout of a desktop.
    public func layout(on desktop: SpaceID) -> SpaceLayout? {
        workspace(on: desktop)?.layout
    }

    /// The desktop a workspace is.
    public func desktop(of id: WorkspaceID) -> SpaceID? {
        workspaces[id]?.desktop
    }

    /// The display a workspace's desktop is on.
    public func display(of id: WorkspaceID) -> String? {
        desktop(of: id).flatMap { displayBySpace[$0] }
    }

    public func label(of id: WorkspaceID) -> String? {
        workspaces[id]?.label
    }

    /// The workspace showing on each display that shows a desktop.
    public var visibleWorkspaces: [WorkspaceID] {
        visibleSpaces.compactMap { active[$0] }
    }

    /// The workspace the user is in. Nil while the focused display shows a
    /// fullscreen space.
    public var currentWorkspace: WorkspaceID? {
        currentSpace.flatMap { active[$0] }
    }

    /// The global number of a workspace, 1-based.
    public func number(of id: WorkspaceID) -> Int? {
        wsOrder.firstIndex(of: id).map { $0 + 1 }
    }

    public func id(forLabel label: String) -> WorkspaceID? {
        wsOrder.first { workspaces[$0]?.label == label }
    }

    /// The desktop next to the focused display's current one, by `step`
    /// within that display's desktops, the way ⌃←/⌃→ go. No wrap: stepping
    /// off the end is nil, as it is for macOS.
    public func workspace(steppingBy step: Int) -> WorkspaceID? {
        guard step != 0, let display = focusedDisplay ?? displays.first,
              let current = currentByDisplay[display]
        else { return nil }
        let mine = order.filter { displayBySpace[$0] == display }
        guard let at = mine.firstIndex(of: current) else { return nil }
        let next = at + step.signum()
        return mine.indices.contains(next) ? active[mine[next]] : nil
    }

    /// Resolve a `space focus` / `move-window` target: `recent`, `next`,
    /// `prev`, a label, a global number, or a raw desktop id out of `query
    /// spaces`. Nil when it names no desktop that exists — see
    /// `missingDesktop` for the ones that could exist.
    public func resolveWorkspace(_ text: String) -> WorkspaceID? {
        switch text {
        case "recent": return recentWorkspace.flatMap { workspaces[$0] != nil ? $0 : nil }
        case "next": return workspace(steppingBy: 1)
        case "prev": return workspace(steppingBy: -1)
        default: break
        }
        if let id = id(forLabel: text) { return id }
        // A bare integer is a number first (that is what the user types on
        // ⌥3) and a raw desktop id only when it is far too large to be one.
        if let n = Int(text), n >= 1, n <= wsOrder.count { return wsOrder[n - 1] }
        if let raw = UInt64(text), let id = active[raw] { return id }
        return nil
    }

    /// The number of the desktop `text` names but that does not exist yet:
    /// a label past the desktops there are, or a small number past the end.
    /// What `space focus` answers with "desktop N does not exist".
    public func missingDesktop(_ text: String) -> Int? {
        guard resolveWorkspace(text) == nil else { return nil }
        if let i = names.firstIndex(of: text), i >= wsOrder.count { return i + 1 }
        if let n = Int(text), n > wsOrder.count, n <= 99 { return n }
        return nil
    }

    /// Whether a display is showing something that is not a workspace: a
    /// native fullscreen or Split View space. weft does no work there until
    /// the display shows a desktop again.
    public func isPaused(_ display: String) -> Bool {
        guard let current = currentByDisplay[display] else { return true }
        return active[current] == nil
    }

    /// The display a workspace is showing on right now, or nil when its
    /// desktop is not the one its display shows.
    public func showingDisplay(of id: WorkspaceID) -> String? {
        guard let desktop = desktop(of: id), let display = displayBySpace[desktop],
              currentByDisplay[display] == desktop
        else { return nil }
        return display
    }

    /// The workspace a window is a member of, laid out or loose.
    public func workspace(holding wid: WindowID) -> WorkspaceID? {
        wsOrder.first { workspaces[$0]?.contains(wid) == true }
    }

    // MARK: - Writing a workspace

    public mutating func setLayout(_ layout: SpaceLayout, of id: WorkspaceID) {
        workspaces[id]?.layout = layout
    }

    /// Take a window out of every workspace but `keep`: out of each layout and
    /// out of each loose set.
    public mutating func removeWindow(_ wid: WindowID, except keep: WorkspaceID? = nil) {
        for (id, ws) in workspaces where id != keep {
            switch ws.layout {
            case .tiling(let t) where t.windows.contains(wid):
                workspaces[id]?.layout = .tiling(t.removing(wid))
            case .float(let f) where f.windows.contains(wid):
                workspaces[id]?.layout = .float(f.removing(wid))
            default:
                break
            }
            workspaces[id]?.loose.remove(wid)
        }
    }

    /// Make `target` the one workspace holding `wid`: in its layout when weft
    /// lays the window out, in its loose set when it does not. A move between
    /// desktops ends here, so a floating window sent somewhere arrives
    /// floating instead of being tiled by the move.
    ///
    /// `screen` decides the split axis of a tree insertion, as it does in a
    /// sweep; `focus` makes the window the layout's focus when it is laid out.
    public mutating func file(
        _ wid: WindowID,
        in target: WorkspaceID,
        laidOut: Bool,
        screen: Frame? = nil,
        config: TilingConfig = TilingConfig(),
        focus: Bool = false
    ) {
        guard var ws = workspaces[target] else { return }
        removeWindow(wid, except: target)
        switch (laidOut, ws.layout) {
        case (false, .tiling(let t)):
            if t.windows.contains(wid) { ws.layout = .tiling(t.removing(wid)) }
            ws.loose.insert(wid)
        case (false, .float(let f)):
            if f.windows.contains(wid) { ws.layout = .float(f.removing(wid)) }
            ws.loose.insert(wid)
        case (true, .tiling(var t)):
            ws.loose.remove(wid)
            if !t.windows.contains(wid) {
                t = screen.map { t.inserting(wid, in: $0, config: config) } ?? t.inserting(wid)
            }
            if focus { t = t.focusing(wid) }
            ws.layout = .tiling(t)
        case (true, .float(var f)):
            ws.loose.remove(wid)
            if !f.windows.contains(wid) { f = f.inserting(wid) }
            if focus { f = f.focusing(wid) }
            ws.layout = .float(f)
        }
        if focus { ws.lastFocused = wid }
        workspaces[target] = ws
    }

    /// Edit the layout of a desktop. A no-op on a space with no workspace.
    public mutating func setLayout(_ layout: SpaceLayout, on desktop: SpaceID) {
        if let id = active[desktop] { workspaces[id]?.layout = layout }
    }

    /// Record that `wid` took focus on its desktop: what a later switch there
    /// focuses again.
    public mutating func noteFocus(_ wid: WindowID) {
        guard let id = workspace(holding: wid) else { return }
        workspaces[id]?.lastFocused = wid
    }

    /// Make the workspace set match the desktops that exist: one workspace
    /// per ordinary desktop, numbered main display first, then west to east.
    ///
    /// - A desktop that was here keeps its workspace (identity is the
    ///   SpaceID).
    /// - A desktop that is new takes the layout stashed at its place
    ///   (display, position), if a desktop there went away earlier, and is
    ///   otherwise empty.
    /// - A desktop that went away has its workspace stashed at the place it
    ///   was. Its windows are macOS's to move; the next sweep files them
    ///   wherever they land.
    /// - Labels are re-attached by number.
    ///
    /// `names`, when given, replaces the labels (`[[space]]`, else
    /// `labels.json`). No displays at all is a transient (sleep, a
    /// reconfiguration mid-flight) and leaves everything as it is.
    public mutating func adoptDisplays(_ reported: [DisplayDesktops], names: [String]? = nil) {
        if let names { self.names = names }
        let numbered = numberingOrder(reported)
        guard numbered.contains(where: { !$0.desktops.isEmpty }) else { return }
        displays = numbered.map(\.uuid)
        currentByDisplay = Dictionary(uniqueKeysWithValues: reported.map { ($0.uuid, $0.current) })
        order = numbered.flatMap(\.desktops)
        displayBySpace = [:]
        keyBySpace = [:]
        for d in numbered {
            for (i, sid) in d.desktops.enumerated() {
                displayBySpace[sid] = d.uuid
                keyBySpace[sid] = DesktopKey(display: d.uuid, position: i + 1)
            }
        }
        let live = Set(order)
        for (sid, id) in active where !live.contains(sid) {
            if let ws = workspaces.removeValue(forKey: id), let key = ws.keyHint {
                stash[key] = ws
            }
            active.removeValue(forKey: sid)
            if recentWorkspace == id { recentWorkspace = nil }
        }
        for sid in order where active[sid] == nil {
            let id = WorkspaceID(nextWorkspaceID)
            nextWorkspaceID += 1
            var ws = Workspace(id: id, label: "", desktop: sid, layout: .tiling(Tree()))
            if let key = keyBySpace[sid], let saved = stash.removeValue(forKey: key) {
                ws.layout = saved.layout
                ws.overrideKind = saved.overrideKind
                ws.loose = saved.loose
                ws.lastFocused = saved.lastFocused
            }
            workspaces[id] = ws
            active[sid] = id
        }
        // Where each workspace is, for the stash should its desktop go.
        for sid in order { if let id = active[sid] { workspaces[id]?.keyHint = keyBySpace[sid] } }
        wsOrder = order.compactMap { active[$0] }
        relabel()
    }

    /// Labels by number: the configured name at each position, else the
    /// number itself.
    private mutating func relabel() {
        for (i, id) in wsOrder.enumerated() {
            let name = i < names.count ? names[i] : ""
            workspaces[id]?.label = name.isEmpty ? "\(i + 1)" : name
        }
    }

    /// Replace the labels (an edited `[[space]]` list). No window moves.
    public mutating func relabel(_ names: [String]) {
        self.names = names
        relabel()
    }

    /// Name the desktop with number `n` (1-based): `space label`.
    public mutating func setLabel(_ name: String, number n: Int) {
        guard n >= 1 else { return }
        while names.count < n { names.append("") }
        names[n - 1] = name
        relabel()
    }

    /// Labels for `labels.json`: every configured name, and every desktop's
    /// label, by number.
    public func persistedNames() -> [String] {
        (0..<max(names.count, wsOrder.count)).map { i in
            i < wsOrder.count ? (workspaces[wsOrder[i]]?.label ?? "") : names[i]
        }
    }

    // MARK: - Layouts on disk, by DesktopKey

    /// Each desktop's chosen layout and, for a restart within one boot, its
    /// tree and its hand-floated windows. Keyed by place, not SpaceID.
    public func persistedLayouts() -> [DesktopKey: SavedDesktop] {
        var out: [DesktopKey: SavedDesktop] = [:]
        for id in wsOrder {
            guard let ws = workspaces[id], let key = keyBySpace[ws.desktop] else { continue }
            var saved = SavedDesktop(override: ws.overrideKind?.rawValue)
            if case .tiling(let tree) = ws.layout, !tree.windows.isEmpty { saved.tree = SavedTree(tree) }
            if saved.override != nil || saved.tree != nil { out[key] = saved }
        }
        return out
    }

    /// Put saved layouts back, by place, after `adoptDisplays`. An override
    /// always comes back. A tree comes back only when `trees` (the file is
    /// from this boot — window ids last as long as the window) and only into
    /// a desktop holding no layout yet; the sweep then drops the windows that
    /// are not there.
    public mutating func restore(_ saved: [DesktopKey: SavedDesktop], trees: Bool) {
        for (sid, key) in keyBySpace {
            guard let s = saved[key], let id = active[sid] else { continue }
            if let kind = s.override.flatMap(LayoutKind.init(rawValue:)) {
                workspaces[id]?.overrideKind = kind
                if workspaces[id]?.layout.windows.isEmpty == true {
                    workspaces[id]?.layout = kind == .float ? .float(FloatState()) : .tiling(Tree())
                }
            }
            if trees, let tree = s.tree?.tree, case .tiling(let current)? = workspaces[id]?.layout,
               current.windows.isEmpty {
                workspaces[id]?.layout = .tiling(tree)
            }
        }
    }

    /// 0.9.21's `layouts.json`: overrides by number. Read once on upgrade.
    /// A kind this build does not recognise (`scroll`) is dropped.
    public mutating func assignOverrides(kinds: [String]) {
        for (i, id) in wsOrder.enumerated() where i < kinds.count {
            guard let kind = LayoutKind(rawValue: kinds[i]) else { continue }
            workspaces[id]?.overrideKind = kind
            if workspaces[id]?.layout.windows.isEmpty == true {
                workspaces[id]?.layout = kind == .float ? .float(FloatState()) : .tiling(Tree())
            }
        }
    }
}

/// One desktop's entry in `layouts.json`.
public struct SavedDesktop: Codable, Sendable, Equatable {
    /// `space layout`'s choice, if one was made.
    public var override: String?
    /// The tiling tree, believed only within the boot it was written in.
    public var tree: SavedTree?

    public init(override: String? = nil, tree: SavedTree? = nil) {
        self.override = override
        self.tree = tree
    }
}

/// Which workspace each window is in: the one of the single desktop macOS
/// reports it on (NATIVE.md, "The model": macOS owns membership).
///
/// - On exactly one desktop with a workspace: that workspace.
/// - On several (Dock › Options › All Desktops): no workspace. It is in
///   `everywhere`, and weft floats it and never moves it.
/// - On none with a workspace (a fullscreen space): no workspace. When it
///   leaves fullscreen macOS puts it back on its desktop, and the next call
///   files it there.
///
/// Output arrays are sorted, so a sweep does not depend on dictionary order.
public func membershipByDesktop(
    _ windowDesktops: [WindowID: [SpaceID]], active: [SpaceID: WorkspaceID]
) -> (members: [WorkspaceID: [WindowID]], everywhere: Set<WindowID>) {
    var members: [WorkspaceID: [WindowID]] = [:]
    var everywhere: Set<WindowID> = []
    for (wid, desktops) in windowDesktops {
        let ours = Set(desktops).filter { active[$0] != nil }
        if ours.count > 1 {
            everywhere.insert(wid)
        } else if let only = ours.first, let id = active[only] {
            members[id, default: []].append(wid)
        }
    }
    return (members.mapValues { $0.sorted() }, everywhere)
}

/// Pure membership sync per layout kind: insert new windows (id order),
/// drop windows that left. Unbound windows (S0 cold-start gap) join like any
/// other — layout is computed, application waits until the desktop shows.
/// Returns the ids that are new anywhere (need AX binding).
///
/// `membershipByDesktop` has already decided which workspace each window
/// belongs to; this only grows and shrinks the trees.
public func syncMembership(
    _ state: SpaceState,
    membership: [WorkspaceID: [WindowID]],
    live: Set<WorkspaceID>? = nil,
    screens: [WorkspaceID: Frame] = [:],
    config: TilingConfig = TilingConfig()
) -> (SpaceState, Set<WindowID>) {
    var next = state
    var fresh: Set<WindowID> = []
    // Every workspace that exists, not just the ones holding a window, so an
    // emptied workspace keeps its layout kind (with empty membership).
    let ids = live ?? Set(membership.keys)
    for wsid in ids {
        guard next.workspaces[wsid] != nil else { continue }
        let wids = membership[wsid] ?? []
        switch next.workspaces[wsid]?.layout ?? .tiling(Tree()) {
        case .tiling(var tree):
            let have = Set(tree.windows)
            for id in wids.sorted() where !have.contains(id) {
                // With a screen the split axis follows the slot's shape
                // (yabai's split_type auto); without one, fall back to the
                // alternating flag. The rect is per workspace, because the
                // workspace may live on a display of an entirely different
                // shape.
                tree = screens[wsid].map { tree.inserting(id, in: $0, config: config) }
                    ?? tree.inserting(id)
                fresh.insert(id)
            }
            for id in tree.windows where !wids.contains(id) {
                tree = tree.removing(id)
            }
            next.setLayout(.tiling(tree), of: wsid)
        case .float(var fl):
            let have = Set(fl.windows)
            for id in wids.sorted() where !have.contains(id) {
                fl = fl.inserting(id)
                fresh.insert(id)
            }
            for id in fl.windows where !wids.contains(id) {
                fl = fl.removing(id)
            }
            next.setLayout(.float(fl), of: wsid)
        }
    }
    return (next, fresh)
}

/// A frame on one display, moved to the same relative place on another.
///
/// "Same place" means the same share of the free space around it: a window
/// pushed into the top-right corner of one display lands in the top-right
/// corner of the next, whatever the two sizes. It shrinks to fit a smaller
/// display rather than hanging off it. For floats, which have no layout slot
/// to be re-tiled into when their workspace moves between displays.
public func translate(_ f: Frame, from source: Frame, to target: Frame) -> Frame {
    let width = min(f.width, target.width)
    let height = min(f.height, target.height)
    func share(_ offset: Double, _ free: Double) -> Double {
        free > 0 ? min(max(offset / free, 0), 1) : 0.5
    }
    let sx = share(f.x - source.x, source.width - f.width)
    let sy = share(f.y - source.y, source.height - f.height)
    return Frame(
        x: target.x + (target.width - width) * sx,
        y: target.y + (target.height - height) * sy,
        width: width,
        height: height
    )
}
