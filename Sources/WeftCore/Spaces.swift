// WeftCore/Spaces.swift — weft's workspaces, on one macOS desktop per display.
//
// macOS owns its desktops and weft does not drive them: it cannot move a
// window between them or switch between them without SIP off or simulated
// input (spikes/RESULTS.md S8), and both break on macOS updates. So weft picks
// one desktop per display — the *managed* desktop — and keeps its own
// workspaces there, hiding and showing them by parking windows
// (REDESIGN.md). Other desktops, and native fullscreen spaces, are left to
// macOS entirely; weft pauses on a display while one of them is showing.
//
// Labels persist by ordinal (sids are NOT stable across reboot, DESIGN §5.3).
// Switching a workspace between bsp and float preserves membership: float
// remembers each window's real frame, and coming back out rebuilds a tree in
// that order.

public enum LayoutKind: String, Codable, Sendable, Equatable {
    case bsp
    case float
}

/// One display as the WindowServer reports it: its desktops in Mission
/// Control order (fullscreen spaces excluded) and the one showing now.
public struct DisplayDesktops: Sendable, Equatable {
    public var uuid: String
    public var desktops: [SpaceID]
    public var current: SpaceID

    public init(uuid: String, desktops: [SpaceID], current: SpaceID) {
        self.uuid = uuid
        self.desktops = desktops
        self.current = current
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

/// weft's own id for a workspace, handed out within a launch and never
/// persisted.
///
/// A struct rather than `typealias WorkspaceID = UInt32`, and the reason is the
/// seam this whole type exists to draw. macOS owns which *desktop* a window is
/// on; weft owns which *workspace within that desktop*. Several places derive
/// one from the other in the same expression — the layout holding a window is
/// looked up and then used as the desktop to switch to — and with a bare
/// integer every one of those compiles. `WindowID` is a `UInt32` too, so a bare
/// alias would let a window id stand in for a workspace as well.
///
/// Deliberately NOT `Codable`. Nothing outside the daemon has any use for one:
/// `labels.json` and `layouts.json` are keyed by ordinal, and `query spaces`
/// and `query bar-state` speak in desktop ids because that is what weft-bar and
/// weftctl resolve against. Withholding the conformance means a workspace id
/// put on the wire by accident is a build error rather than a number in the
/// menu bar that decodes cleanly and means nothing.
public struct WorkspaceID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let raw: UInt32

    public init(_ raw: UInt32) { self.raw = raw }

    public static func < (a: WorkspaceID, b: WorkspaceID) -> Bool { a.raw < b.raw }

    public var description: String { "ws\(raw)" }
}

/// A named set of windows with a layout. It lives on one display's managed
/// desktop at a time — showing there, or hidden with its windows parked — and
/// moves to another display's when it is shown there.
///
/// No `display` field. A workspace lives on one desktop and a desktop on one
/// display, so the display is `SpaceState.displayBySpace[desktop]` — already
/// the answer every screen-rect lookup goes through. Storing it here would be a
/// second copy of a fact that has an owner, and the two would drift the first
/// time a display was unplugged.
public struct Workspace: Sendable, Equatable {
    public var id: WorkspaceID
    /// The name `space focus <label>` and `[[rule]] space = "..."` resolve to.
    public var label: String
    /// The managed desktop it lives on: the one its display tiles on.
    public var desktop: SpaceID
    public var layout: SpaceLayout
    /// The kind the user asked for with `space layout <kind>`, as opposed to
    /// the one the layout happens to be. Kept apart from `layout` so the
    /// intent survives the workspace emptying, and so it can be persisted:
    /// without the record, the next config reload, the next empty sweep and
    /// the next restart all quietly undo the choice.
    public var overrideKind: LayoutKind?
    /// Members that are not laid out: floated by hand, unmanaged by a rule,
    /// struck out as a quirk, or an app weft always floats. They belong to the
    /// workspace all the same — hidden with it, shown with it, followed to it
    /// by focus — and only the layout ignores them.
    ///
    /// Membership used to be the layout, so every one of these windows was in
    /// no workspace at all and stayed on screen whichever workspace was
    /// showing (REDESIGN.md, defect 3). Panels and popovers are deliberately
    /// not here: a menu-bar extra's popover belongs to the menu bar, not to
    /// whatever workspace was showing when it opened.
    public var loose: Set<WindowID>

    public init(
        id: WorkspaceID,
        label: String,
        desktop: SpaceID,
        layout: SpaceLayout,
        overrideKind: LayoutKind? = nil,
        loose: Set<WindowID> = []
    ) {
        self.id = id
        self.label = label
        self.desktop = desktop
        self.layout = layout
        self.overrideKind = overrideKind
        self.loose = loose
    }

    /// Every window in the workspace: the laid-out ones in layout order, then
    /// the loose ones by id. What hiding and showing a workspace acts on.
    public var members: [WindowID] {
        let tiled = layout.windows
        let placed = Set(tiled)
        return tiled + loose.subtracting(placed).sorted()
    }

    public func contains(_ wid: WindowID) -> Bool {
        loose.contains(wid) || layout.windows.contains(wid)
    }
}

public struct SpaceState: Sendable, Equatable {
    /// Every workspace weft knows about, by id.
    public var workspaces: [WorkspaceID: Workspace]
    /// Which workspace is showing on each managed desktop. A workspace is
    /// "active" when its display would show it; whether the display is
    /// showing its managed desktop at all is `isPaused`.
    ///
    /// Every managed desktop MUST have an entry, and only managed desktops
    /// have one. A desktop with no entry drops what lands there
    /// (`reconcileWorkspaces`) — which is exactly right for a desktop weft
    /// does not manage, and a silent failure for one it does.
    public var active: [SpaceID: WorkspaceID]
    /// The one desktop per display weft tiles on, by display uuid. Recorded
    /// once and kept while it exists; weft never switches to it or away.
    public var managed: [String: SpaceID]
    /// What each display last showed, by display uuid, kept after the display
    /// goes. A monitor plugged back in shows it again rather than whatever
    /// happened to be free.
    public var lastShown: [String: WorkspaceID] = [:]
    /// Workspace ids in the order labels and `space focus <n>` count in.
    public var wsOrder: [WorkspaceID]
    /// Next id to hand out. Ids are unique within a launch and never
    /// persisted — `labels.json` and `layouts.json` are keyed by ordinal, so
    /// nothing outside the process ever names a workspace by id.
    public var nextWorkspaceID: UInt32
    /// display uuid → current sid (mirrors the WindowServer; read-only copy).
    public var currentByDisplay: [String: SpaceID]
    /// Display uuids in SLS order (stable within a launch; main first).
    public var displays: [String]
    /// sid → display uuid. A space belongs to exactly one display, and its
    /// layout must be computed in *that* display's rect — deriving one rect
    /// from the main display tiled every second-monitor space into the first
    /// monitor's frame (§13.10).
    public var displayBySpace: [SpaceID: String]
    /// The display holding the active menu bar, i.e. the one keyboard focus
    /// is on. With two displays both have a "current" space; only this one
    /// says which space the user means. Nil = fall back to `displays.first`.
    public var focusedDisplay: String?
    /// Space ids in **Mission Control order** (display-major, then the order
    /// SLSCopyManagedDisplaySpaces reports within each display), managed or
    /// not. Only diagnostics read it.
    public var order: [SpaceID]
    /// The workspace to go back to for `space focus recent``.
    public var recentWorkspace: WorkspaceID?

    public init(
        workspaces: [WorkspaceID: Workspace] = [:],
        active: [SpaceID: WorkspaceID] = [:],
        managed: [String: SpaceID] = [:],
        wsOrder: [WorkspaceID] = [],
        nextWorkspaceID: UInt32 = 1,
        currentByDisplay: [String: SpaceID] = [:],
        displays: [String] = [],
        displayBySpace: [SpaceID: String] = [:],
        focusedDisplay: String? = nil,
        order: [SpaceID] = [],
        recentWorkspace: WorkspaceID? = nil
    ) {
        self.workspaces = workspaces
        self.active = active
        self.managed = managed
        self.wsOrder = wsOrder
        self.nextWorkspaceID = nextWorkspaceID
        self.currentByDisplay = currentByDisplay
        self.displays = displays
        self.displayBySpace = displayBySpace
        self.focusedDisplay = focusedDisplay
        self.order = order
        self.recentWorkspace = recentWorkspace
    }

    /// The space the user is on: the focused display's current space. Falls
    /// back to the first display's, which is exact on a single display.
    public var currentSpace: SpaceID? {
        if let uuid = focusedDisplay, let sid = currentByDisplay[uuid] { return sid }
        return displays.first.flatMap { currentByDisplay[$0] }
    }

    /// Every visible desktop — one per display. These are the desktops a sweep
    /// may bind AX elements for and apply frames to.
    public var visibleSpaces: [SpaceID] {
        displays.compactMap { currentByDisplay[$0] }
    }

    // MARK: - Reading a workspace
    //
    // Every accessor below is a method on the state rather than on the daemon,
    // and that is load-bearing: a dozen call sites read one of these from
    // inside an `updateSpaces` closure, which already holds `spaces` for
    // writing. A daemon method that went back through `readSpaces()` would be
    // an exclusivity violation and Swift aborts the process on the spot —
    // `convertLayout` carries the scar.

    /// The workspace showing on a desktop.
    public func workspace(on desktop: SpaceID) -> Workspace? {
        active[desktop].flatMap { workspaces[$0] }
    }

    /// The layout showing on a desktop. The direct replacement for what used
    /// to be `layouts[sid]`.
    public func layout(on desktop: SpaceID) -> SpaceLayout? {
        workspace(on: desktop)?.layout
    }

    /// The desktop a workspace lives on.
    public func desktop(of id: WorkspaceID) -> SpaceID? {
        workspaces[id]?.desktop
    }

    /// The display a workspace's windows must be laid out in. Derived, never
    /// stored: a workspace is on one desktop and a desktop on one display.
    public func display(of id: WorkspaceID) -> String? {
        desktop(of: id).flatMap { displayBySpace[$0] }
    }

    public func label(of id: WorkspaceID) -> String? {
        workspaces[id]?.label
    }

    /// The workspace showing on each visible desktop.
    public var visibleWorkspaces: [WorkspaceID] {
        visibleSpaces.compactMap { active[$0] }
    }

    /// The workspace the user is in.
    public var currentWorkspace: WorkspaceID? {
        currentSpace.flatMap { active[$0] }
    }

    /// Every workspace whose desktop still exists. What a sweep is allowed to
    /// keep — and deliberately not "every visible workspace", which would
    /// delete a hidden one on the next sweep.
    public func liveWorkspaces(desktops: Set<SpaceID>) -> Set<WorkspaceID> {
        Set(workspaces.values.filter { desktops.contains($0.desktop) }.map { $0.id })
    }

    public func id(forLabel label: String) -> WorkspaceID? {
        wsOrder.first { workspaces[$0]?.label == label }
            ?? workspaces.first(where: { $0.value.label == label })?.key
    }

    /// Resolve `space focus <…>` targets: label first, then 1-based ordinal,
    /// then a raw space id (keeps alt-digit keybinds working after renames —
    /// "1" means the first workspace even when it isn't named so).
    public func resolveWorkspace(_ text: String) -> WorkspaceID? {
        if text == "recent" { return recentWorkspace }
        if let id = id(forLabel: text) { return id }
        // A bare integer is an ordinal first (that is what the user types on
        // alt-3) and only falls through to a raw space id when it is too large
        // to be one — real sids are far outside 1...count.
        if let n = Int(text), (1...wsOrder.count).contains(n) { return wsOrder[n - 1] }
        // The escape hatch stays pointed at DESKTOPS. Someone typing a number
        // out of `query spaces` is naming a native space, which is what that
        // JSON reports; answering with a workspace of the same number would
        // hand them a different desktop entirely.
        if let raw = UInt64(text), let id = active[raw] { return id }
        return nil
    }

    /// Whether a display is showing something other than its managed desktop
    /// — another macOS desktop, or a native fullscreen space. weft does no
    /// work there: nothing is tiled, parked or moved on that display until
    /// its managed desktop is back.
    public func isPaused(_ display: String) -> Bool {
        guard let managed = managed[display] else { return true }
        return currentByDisplay[display] != managed
    }

    /// The display a workspace is showing on right now, or nil when it is
    /// hidden — or active on a display that is paused, which shows nothing
    /// of weft's either.
    public func showingDisplay(of id: WorkspaceID) -> String? {
        guard let desktop = desktop(of: id), active[desktop] == id,
              let display = displayBySpace[desktop], !isPaused(display)
        else { return nil }
        return display
    }

    /// The workspace a window is a member of, laid out or loose. Searched in
    /// `wsOrder` so the answer does not depend on dictionary order — a sticky
    /// window can be a member of one workspace per desktop.
    public func workspace(holding wid: WindowID) -> WorkspaceID? {
        wsOrder.first { workspaces[$0]?.contains(wid) == true }
            ?? workspaces.keys.sorted().first { workspaces[$0]?.contains(wid) == true }
    }

    // MARK: - Writing a workspace

    public mutating func setLayout(_ layout: SpaceLayout, of id: WorkspaceID) {
        workspaces[id]?.layout = layout
    }

    /// Take a window out of every workspace but `keep`: out of each layout and
    /// out of each loose set. The one way a window leaves a workspace other
    /// than the sweep noticing it has gone.
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
    /// lays the window out, in its loose set when it does not. Every command
    /// that moves a window between workspaces ends here, so a floating window
    /// sent somewhere arrives floating instead of being tiled by the move.
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
        workspaces[target] = ws
    }

    /// Edit the layout showing on a desktop. The replacement for
    /// `layouts[sid] = …`, and a no-op on a desktop with no workspace rather
    /// than a way to create one — creation happens in `adoptDisplays`.
    public mutating func setLayout(_ layout: SpaceLayout, on desktop: SpaceID) {
        if let id = active[desktop] { workspaces[id]?.layout = layout }
    }

    /// Make the workspace set match the displays that exist.
    ///
    /// - Each display gets a managed desktop: the one it already had, while
    ///   that desktop exists, or else whichever desktop it is showing.
    /// - A workspace whose desktop stopped being managed — its display was
    ///   unplugged, or its desktop deleted in Mission Control — moves to its
    ///   display's new managed desktop, or to the first display's. Workspaces
    ///   are never deleted here: a display going away must not take a tree,
    ///   an override or a label with it.
    /// - Every managed desktop gets a workspace to show. One already living
    ///   there is preferred, then an empty hidden one — both cost nothing to
    ///   show — and only then a new numbered one.
    ///
    /// `names` seeds the set on a fresh start (from `[[space]]`, else
    /// `labels.json`); nil means "keep what is named". `pins` maps a label to
    /// the display uuid its `[[space]] display =` resolved to right now.
    ///
    /// A display with nothing to show takes, in order: a hidden workspace
    /// pinned to it, what it last showed, a hidden workspace already living
    /// on its desktop, an empty hidden one — the last three only if not
    /// pinned to another connected display — and only then a new numbered one.
    public mutating func adoptDisplays(
        _ reported: [DisplayDesktops], names: [String]?, pins: [String: String] = [:]
    ) {
        let previousDisplayBySpace = displayBySpace
        order = reported.flatMap { $0.desktops }
        displays = reported.map { $0.uuid }
        displayBySpace = [:]
        for d in reported { for sid in d.desktops { displayBySpace[sid] = d.uuid } }
        currentByDisplay = Dictionary(uniqueKeysWithValues: reported.map { ($0.uuid, $0.current) })
        // No displays is a transient (sleep, a reconfiguration mid-flight). Leave
        // the workspaces exactly as they are rather than rehoming them onto
        // nothing.
        guard let main = reported.first(where: { !$0.desktops.isEmpty }) else { return }

        var nextManaged: [String: SpaceID] = [:]
        for d in reported {
            if let kept = managed[d.uuid], d.desktops.contains(kept) {
                nextManaged[d.uuid] = kept
            } else if d.desktops.contains(d.current) {
                nextManaged[d.uuid] = d.current
            } else if let first = d.desktops.first {
                // Showing a fullscreen space right now, which is never a
                // desktop weft manages. Its first real desktop is.
                nextManaged[d.uuid] = first
            }
        }
        managed = nextManaged
        let managedDesktops = Set(nextManaged.values)
        guard let mainDesktop = nextManaged[main.uuid] ?? nextManaged.values.first else { return }

        for (id, ws) in workspaces where !managedDesktops.contains(ws.desktop) {
            let display = previousDisplayBySpace[ws.desktop]
            workspaces[id]?.desktop = display.flatMap { nextManaged[$0] } ?? mainDesktop
        }
        active = active.filter { managedDesktops.contains($0.key) && workspaces[$0.value]?.desktop == $0.key }
        wsOrder = wsOrder.filter { workspaces[$0] != nil }
        for id in workspaces.keys.sorted() where !wsOrder.contains(id) { wsOrder.append(id) }

        if let names, workspaces.isEmpty {
            for (i, name) in names.enumerated() {
                makeWorkspace(label: name.isEmpty ? "\(i + 1)" : name, on: mainDesktop)
            }
        }
        let connected = Set(reported.map { $0.uuid })
        func pinnedDisplay(_ id: WorkspaceID) -> String? {
            workspaces[id].flatMap { pins[$0.label] }.flatMap { connected.contains($0) ? $0 : nil }
        }
        for d in reported {
            guard let desktop = nextManaged[d.uuid], active[desktop] == nil else { continue }
            let showing = Set(active.values)
            let hidden = wsOrder.filter { !showing.contains($0) }
            let free = hidden.filter { pinnedDisplay($0) == nil || pinnedDisplay($0) == d.uuid }
            let pick = hidden.first { pinnedDisplay($0) == d.uuid }
                ?? lastShown[d.uuid].flatMap { free.contains($0) ? $0 : nil }
                ?? free.first { workspaces[$0]?.desktop == desktop }
                ?? free.first { workspaces[$0]?.members.isEmpty == true }
                ?? makeWorkspace(label: freshLabel(), on: desktop)
            workspaces[pick]?.desktop = desktop
            active[desktop] = pick
        }
        for d in reported { if let desktop = nextManaged[d.uuid], let id = active[desktop] { lastShown[d.uuid] = id } }
    }

    @discardableResult
    private mutating func makeWorkspace(label: String, on desktop: SpaceID) -> WorkspaceID {
        let id = WorkspaceID(nextWorkspaceID)
        nextWorkspaceID += 1
        workspaces[id] = Workspace(id: id, label: label, desktop: desktop, layout: .tiling(Tree()))
        wsOrder.append(id)
        return id
    }

    /// The next number not already used as a label, counting from the
    /// workspace count — so a display plugged into a machine with three
    /// workspaces gets "4".
    private func freshLabel() -> String {
        let used = Set(workspaces.values.map { $0.label })
        var n = workspaces.count + 1
        while used.contains("\(n)") { n += 1 }
        return "\(n)"
    }

    /// Resolve a target, creating numbered workspaces when it is a small
    /// number past the end — `space focus 4` on a machine with two creates
    /// "3" and "4", hidden on the first display, the way AeroSpace makes a
    /// workspace by naming it. Only 1…99: a larger number is a desktop id
    /// out of `query spaces`, not a workspace someone wants.
    public mutating func resolveOrCreateWorkspace(_ text: String) -> WorkspaceID? {
        if let id = resolveWorkspace(text) { return id }
        guard let n = Int(text), (1...99).contains(n), n > wsOrder.count,
              let first = displays.first(where: { managed[$0] != nil }),
              let desktop = managed[first]
        else { return nil }
        let used = Set(workspaces.values.map { $0.label })
        while wsOrder.count < n {
            let label = "\(wsOrder.count + 1)"
            makeWorkspace(label: used.contains(label) ? "\(label)'" : label, on: desktop)
        }
        return wsOrder[n - 1]
    }

    /// Make the workspace set follow an edited `[[space]]` list without
    /// touching a window.
    ///
    /// Matched by label first: a workspace whose name is still in the list
    /// keeps its windows and moves to its new place in the order. A name that
    /// is new takes over the workspace that used to sit at its position, if
    /// that one's name has gone (a rename), and is otherwise a new, hidden
    /// workspace. A workspace whose name has gone and was not renamed is
    /// dropped when it is hidden and empty; one that still holds windows keeps
    /// its old name at the end of the order, so nothing parked in it is lost.
    ///
    /// Matching by position alone, as this used to, meant reordering cards in
    /// Settings, or deleting one in the middle, handed every name after it —
    /// and its display pin and app rules — to another workspace's windows.
    public mutating func relabel(_ names: [String]) {
        let labels = names.enumerated().map { $0.element.isEmpty ? "\($0.offset + 1)" : $0.element }
        let before = wsOrder
        var byLabel: [String: WorkspaceID] = [:]
        for id in before { if let l = workspaces[id]?.label, byLabel[l] == nil { byLabel[l] = id } }
        var claimed = Set(labels.compactMap { byLabel[$0] })
        var order: [WorkspaceID] = []
        for (i, label) in labels.enumerated() {
            if let id = byLabel[label] {
                if !order.contains(id) { order.append(id) }
            } else if i < before.count, !claimed.contains(before[i]) {
                workspaces[before[i]]?.label = label
                claimed.insert(before[i])
                order.append(before[i])
            } else if let first = displays.first(where: { managed[$0] != nil }), let desktop = managed[first] {
                order.append(makeWorkspace(label: label, on: desktop))
            }
        }
        let showing = Set(active.values)
        for id in before where !claimed.contains(id) {
            if !showing.contains(id), workspaces[id]?.members.isEmpty == true {
                workspaces.removeValue(forKey: id)
                if recentWorkspace == id { recentWorkspace = nil }
            } else {
                order.append(id)
            }
        }
        wsOrder = order.filter { workspaces[$0] != nil }
    }

    /// Show `id` on the display whose managed desktop is `desktop`: it moves
    /// there and becomes what that display shows. Pure state — the caller
    /// parks what was showing and moves the windows.
    public mutating func show(_ id: WorkspaceID, on desktop: SpaceID) {
        guard workspaces[id] != nil, active[desktop] != nil else { return }
        // Showing elsewhere: that display must not be left pointing at a
        // workspace that has left it. It takes what this display showed.
        if let from = workspaces[id]?.desktop, from != desktop, active[from] == id, let other = active[desktop] {
            active[from] = other
            workspaces[other]?.desktop = from
        }
        workspaces[id]?.desktop = desktop
        active[desktop] = id
        if let display = displayBySpace[desktop] { lastShown[display] = id }
    }


    /// Throw the whole workspace set away, keeping the desktop facts.
    ///
    /// For one caller: the `[[space]]` list changed under a running daemon, so
    /// which workspaces exist is no longer derivable from what is here. The
    /// caller unparks every window first.
    ///
    /// Emptying `workspaces` is what makes the next sweep take its seeding
    /// branch, which re-reads the `[[space]]` names and the saved overrides.
    /// Trees do not survive it, and that is the honest outcome: the set they
    /// described has been replaced.
    ///
    /// `order`, `displays`, `displayBySpace`, `currentByDisplay` and `managed`
    /// are facts about the desktops, not about the workspaces, so they stay.
    public mutating func resetWorkspaces() {
        workspaces = [:]
        active = [:]
        wsOrder = []
        recentWorkspace = nil
    }

    /// Ordered label names for persistence (ordinal → label).
    public func persistedNames() -> [String] {
        wsOrder.map { workspaces[$0]?.label ?? "" }
    }

    /// Every workspace's members by ordinal, for `membership.json`. Window ids
    /// are the WindowServer's and last as long as the window, so this is what
    /// lets a daemon restart — an update, a crash — put every window back in
    /// the workspace it was in instead of collapsing them all into the first.
    public func persistedMembership() -> [[WindowID]] {
        wsOrder.map { workspaces[$0]?.members ?? [] }
    }

    /// Put saved members back, by ordinal, before the first sweep reconciles.
    /// They go in as loose members; the sweep moves the ones weft lays out
    /// into the layout, and drops any that no longer exist. A window already
    /// filed somewhere keeps that.
    public mutating func seedMembership(_ saved: [[WindowID]]) {
        for (i, wids) in saved.enumerated() where i < wsOrder.count {
            for wid in wids where workspace(holding: wid) == nil {
                workspaces[wsOrder[i]]?.loose.insert(wid)
            }
        }
    }

    /// Layout overrides by ordinal, ready to persist as `["", "float", ""]`.
    ///
    /// Persisting by ordinal rather than by id lets the choices survive a
    /// daemon restart — macOS hands out fresh space ids on reboot, and weft's
    /// own workspace ids are not persisted at all — while remaining
    /// independent of whether workspaces are labelled.
    public func persistedOverrides() -> [String] {
        wsOrder.map { workspaces[$0]?.overrideKind?.rawValue ?? "" }
    }

    /// Re-apply a previously persisted list of layout overrides by ordinal.
    /// Call it after `adoptDisplays`, which is what builds the order they are
    /// counted in.
    ///
    /// A kind this build does not recognise is dropped rather than rejected,
    /// which is how a `layouts.json` written when `scroll` existed comes back
    /// as bsp: no override survives, and bsp is what a workspace with no
    /// override gets. Nothing to migrate, and nothing to explain to the user
    /// beyond the space they left in scroll now tiling.
    public mutating func assignOverrides(kinds: [String]) {
        for (i, id) in wsOrder.enumerated() where i < kinds.count {
            guard let kind = LayoutKind(rawValue: kinds[i]) else { continue }
            workspaces[id]?.overrideKind = kind
            // Restoring a saved choice onto a workspace that holds nothing is
            // exact — an empty float and an empty tree differ only in kind, so
            // there is nothing to convert and nothing to lose. A workspace that
            // already holds windows is left alone: this runs at startup, and
            // rearranging someone's windows on the strength of a file is the
            // caller's decision to make, through `convertLayout`.
            if workspaces[id]?.layout.windows.isEmpty == true {
                workspaces[id]?.layout = kind == .float ? .float(FloatState()) : .tiling(Tree())
            }
        }
    }
}

/// Decide which workspace each window is in, from where the WindowServer says
/// it is and where weft last filed it.
///
/// **This function is the seam, and every bug in the workspace model will live
/// in it.** It is written against plain dictionaries rather than `SpaceState`
/// so that it can be read and tested on its own, and so that it cannot reach
/// for a fact it was not handed.
///
/// `activeOn` has one entry per **managed** desktop and nothing else, and that
/// is what defines which desktops weft works on. The rule:
///
/// - A window on no managed desktop is in no workspace. It is on a desktop
///   weft pauses on, or in native fullscreen, and weft leaves it to macOS.
/// - A window already filed **keeps its workspace** — whether that workspace
///   is showing or hidden, and whichever managed desktop its parked window is
///   reported on. Membership is weft's fact; a hidden workspace's windows are
///   reported on some desktop exactly like the showing ones, and without this
///   they would be swept into whatever is on screen.
/// - …except when its workspace is **showing on a different managed desktop**
///   from the one the window is on. The workspace is on screen over there and
///   the window is not in it: the user dragged it to another display, or the
///   app moved it. It joins what is showing where it is.
/// - `inFlight` windows keep their workspace regardless. They are being moved
///   between displays by weft itself, and the WindowServer may still report
///   the display they are leaving.
/// - A window filed nowhere joins what is showing on its desktop.
///
/// Output arrays are sorted, so a sweep's membership does not depend on
/// dictionary iteration order.
public func reconcileWorkspaces(
    windowDesktops: [WindowID: [SpaceID]],
    membership: [WorkspaceID: [WindowID]],
    desktopOf: [WorkspaceID: SpaceID],
    activeOn: [SpaceID: WorkspaceID],
    inFlight: Set<WindowID> = []
) -> [WorkspaceID: [WindowID]] {
    var held: [WindowID: WorkspaceID] = [:]
    for (wsid, wids) in membership.sorted(by: { $0.key < $1.key }) where desktopOf[wsid] != nil {
        for wid in wids where held[wid] == nil { held[wid] = wsid }
    }
    var out: [WorkspaceID: [WindowID]] = [:]
    for (wid, desktops) in windowDesktops {
        guard let desktop = desktops.first(where: { activeOn[$0] != nil }) else { continue }
        let target: WorkspaceID?
        if let wsid = held[wid], let home = desktopOf[wsid] {
            let showingElsewhere = activeOn[home] == wsid && !desktops.contains(home)
            target = showingElsewhere && !inFlight.contains(wid) ? activeOn[desktop] : wsid
        } else {
            target = activeOn[desktop]
        }
        if let target { out[target, default: []].append(wid) }
    }
    return out.mapValues { $0.sorted() }
}

/// Pure membership sync per layout kind: insert new windows (id order),
/// drop windows that left. Unbound windows (S0 cold-start gap) join like any
/// other — layout is computed, application waits for space_changed. Returns
/// the ids that are new anywhere (need AX binding).
///
/// Keyed by workspace, not by desktop. `reconcileWorkspaces` has already
/// decided which workspace each window belongs to; this only grows and shrinks
/// the trees.
public func syncMembership(
    _ state: SpaceState,
    membership: [WorkspaceID: [WindowID]],
    live: Set<WorkspaceID>? = nil,
    screens: [WorkspaceID: Frame] = [:],
    config: TilingConfig = TilingConfig()
) -> (SpaceState, Set<WindowID>) {
    var next = state
    var fresh: Set<WindowID> = []
    // Every workspace that exists, not just the ones holding a managed window,
    // so an emptied workspace keeps its layout kind (with empty membership).
    //
    // `live` is every workspace whose DESKTOP still exists — never "every
    // workspace showing". Passing the showing ones would delete every hidden
    // workspace on the next sweep, which is invisible while each desktop holds
    // one and fatal the moment one holds two.
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
