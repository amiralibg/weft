// WeftCore/Spaces.swift — per-space state (M4).
//
// macOS owns spaces natively; weft keeps one layout per space id and a label
// layer on top (sids are NOT stable across reboot — config persists by label,
// assigned by ordinal at startup, DESIGN §5.3). Switching a space between
// bsp and float preserves window membership: float remembers each window's
// real frame, and coming back out rebuilds a tree in that order.

public enum LayoutKind: String, Codable, Sendable, Equatable {
    case bsp
    case float
}

/// Whether workspaces map 1:1 to native macOS Spaces, or multiple virtual
/// workspaces are hosted on an anchor desktop.
public enum WorkspacesMode: String, Codable, Sendable, Equatable {
    case native
    case virtual
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

/// A named set of windows with a layout, living on exactly one native desktop.
///
/// Today every desktop holds exactly one of these — the identity mapping — and
/// that is the default. What the type buys is that the question "which layout
/// is this window in" stops being the same question as "which desktop is it
/// on", so several workspaces can share a desktop later without every call site
/// changing again.
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
    /// The native Space it lives on. A workspace never spans two.
    public var desktop: SpaceID
    public var layout: SpaceLayout
    /// The kind the user asked for with `space layout <kind>`, as opposed to
    /// the one the layout happens to be. Kept apart from `layout` so the
    /// intent survives the workspace emptying, and so it can be persisted:
    /// without the record, the next config reload, the next empty sweep and
    /// the next restart all quietly undo the choice.
    public var overrideKind: LayoutKind?

    public init(
        id: WorkspaceID,
        label: String,
        desktop: SpaceID,
        layout: SpaceLayout,
        overrideKind: LayoutKind? = nil
    ) {
        self.id = id
        self.label = label
        self.desktop = desktop
        self.layout = layout
        self.overrideKind = overrideKind
    }
}

public struct SpaceState: Sendable, Equatable {
    /// Every workspace weft knows about, by id. Today one per desktop.
    public var workspaces: [WorkspaceID: Workspace]
    /// Which workspace is showing on each desktop — the seam between the two
    /// owners of membership. SLS decides which desktop a window is on; this
    /// decides which workspace on that desktop takes a window that arrives.
    ///
    /// Every live desktop MUST have an entry. A desktop missing one silently
    /// drops what lands there (`reconcileWorkspaces`), and both
    /// `evictOrderedOut` and `refreshDividerZones` give up quietly on a
    /// desktop whose lookup misses.
    public var active: [SpaceID: WorkspaceID]
    /// Workspace ids in the order labels and `space focus <n>` count in.
    ///
    /// Kept apart from `order` because the two are the same list only while
    /// each desktop holds one workspace. `order` is the Mission Control
    /// desktop number that the ctrl+N fallback keystroke posts, which is
    /// macOS's own numbering and can never be anything else; this is weft's.
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
    /// SLSCopyManagedDisplaySpaces reports within each display). The number
    /// macOS itself counts desktops by, and what `ordinal(of:)` answers for
    /// the ctrl+N fallback keystroke.
    ///
    /// Sorting raw sids instead — which this used to do — is wrong: macOS
    /// hands out space ids in creation order, so as soon as a desktop is
    /// removed and re-added the numeric order stops matching the on-screen
    /// order and every label lands one desktop off.
    public var order: [SpaceID]
    /// The workspace to go back to for `space focus recent``.
    public var recentWorkspace: WorkspaceID?

    public init(
        workspaces: [WorkspaceID: Workspace] = [:],
        active: [SpaceID: WorkspaceID] = [:],
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

    /// 1-based Mission Control number of a desktop, or nil if it is not on any
    /// display. This is the number the ctrl+N fallback keystroke needs, and it
    /// counts native desktops because that is what macOS's own shortcut counts.
    public func ordinal(of sid: SpaceID) -> Int? {
        order.firstIndex(of: sid).map { $0 + 1 }
    }

    // MARK: - Writing a workspace

    public mutating func setLayout(_ layout: SpaceLayout, of id: WorkspaceID) {
        workspaces[id]?.layout = layout
    }

    /// Edit the layout showing on a desktop. The replacement for
    /// `layouts[sid] = …`, and a no-op on a desktop with no workspace rather
    /// than a way to create one — creation happens in `adoptDesktops`.
    public mutating func setLayout(_ layout: SpaceLayout, on desktop: SpaceID) {
        if let id = active[desktop] { workspaces[id]?.layout = layout }
    }

    /// Make the workspace set match the desktops that exist:
    /// - In `.native` mode: one workspace per desktop, showing.
    /// - In `.virtual` mode: multiple workspaces on the anchor desktop, one workspace each on others.
    ///
    /// `sids` MUST already be in Mission Control order (display-major) — it is
    /// stored verbatim as `order`, and `wsOrder` is built from it in the same
    /// pass so that the two persistence files, which are keyed by ordinal,
    /// cannot come back scrambled.
    public mutating func adoptDesktops(
        _ sids: [SpaceID],
        names: [String]?,
        mode: WorkspacesMode = .native,
        anchor: Int = 1,
        anchorCount: Int? = nil
    ) {
        order = sids
        let live = Set(sids)
        // A workspace whose desktop is gone goes with it — an unplugged
        // display must not leave a tree behind for whatever inherits the id.
        workspaces = workspaces.filter { live.contains($0.value.desktop) }
        active = active.filter { live.contains($0.key) }
        let previousWsOrder = wsOrder
        wsOrder = []
        guard !sids.isEmpty else { return }

        switch mode {
        case .native:
            for (i, sid) in sids.enumerated() {
                let fallback = "\(i + 1)"
                let name: String? = names.map { i < $0.count && !$0[i].isEmpty ? $0[i] : fallback }
                let id: WorkspaceID
                if let existing = active[sid] {
                    id = existing
                    if let name { workspaces[id]?.label = name }
                } else {
                    id = WorkspaceID(nextWorkspaceID)
                    nextWorkspaceID += 1
                    workspaces[id] = Workspace(
                        id: id, label: name ?? fallback, desktop: sid, layout: .tiling(Tree())
                    )
                    active[sid] = id
                }
                wsOrder.append(id)
            }

        case .virtual:
            let anchorIndex = max(0, min(anchor - 1, sids.count - 1))
            let anchorSid = sids[anchorIndex]

            // Workspaces existing on anchor before this pass, preserved in order:
            var existingAnchorWsIDs = previousWsOrder.filter { workspaces[$0]?.desktop == anchorSid }
            for id in workspaces.keys.sorted() where workspaces[id]?.desktop == anchorSid && !existingAnchorWsIDs.contains(id) {
                existingAnchorWsIDs.append(id)
            }

            var finalAnchorWsIDs: [WorkspaceID] = []

            if let names {
                let count: Int
                if let anchorCount {
                    count = max(1, anchorCount)
                } else {
                    count = max(1, names.count - max(0, sids.count - 1))
                }

                for i in 0..<count {
                    let label = (i < names.count && !names[i].isEmpty) ? names[i] : "\(i + 1)"
                    if i < existingAnchorWsIDs.count {
                        let id = existingAnchorWsIDs[i]
                        workspaces[id]?.label = label
                        finalAnchorWsIDs.append(id)
                    } else {
                        let id = WorkspaceID(nextWorkspaceID)
                        nextWorkspaceID += 1
                        workspaces[id] = Workspace(
                            id: id, label: label, desktop: anchorSid, layout: .tiling(Tree())
                        )
                        finalAnchorWsIDs.append(id)
                    }
                }
                for excessId in existingAnchorWsIDs.dropFirst(count) {
                    workspaces.removeValue(forKey: excessId)
                }
            } else {
                if existingAnchorWsIDs.isEmpty {
                    let id = WorkspaceID(nextWorkspaceID)
                    nextWorkspaceID += 1
                    workspaces[id] = Workspace(
                        id: id, label: "\(anchorIndex + 1)", desktop: anchorSid, layout: .tiling(Tree())
                    )
                    finalAnchorWsIDs.append(id)
                } else {
                    finalAnchorWsIDs = existingAnchorWsIDs
                }
            }

            if let curActive = active[anchorSid], finalAnchorWsIDs.contains(curActive) {
                // keep current active
            } else {
                active[anchorSid] = finalAnchorWsIDs.first
            }

            var nonAnchorIndex = 0
            for sid in sids {
                if sid == anchorSid {
                    wsOrder.append(contentsOf: finalAnchorWsIDs)
                } else {
                    let ordinal = wsOrder.count + 1
                    let fallback = "\(ordinal)"
                    let id: WorkspaceID
                    let label: String
                    if let names {
                        let nameIdx = finalAnchorWsIDs.count + nonAnchorIndex
                        label = (nameIdx < names.count && !names[nameIdx].isEmpty) ? names[nameIdx] : fallback
                    } else {
                        label = fallback
                    }

                    if let existing = active[sid], workspaces[existing]?.desktop == sid {
                        id = existing
                        if names != nil { workspaces[id]?.label = label }
                    } else {
                        id = WorkspaceID(nextWorkspaceID)
                        nextWorkspaceID += 1
                        workspaces[id] = Workspace(
                            id: id, label: label, desktop: sid, layout: .tiling(Tree())
                        )
                        active[sid] = id
                    }
                    nonAnchorIndex += 1
                    wsOrder.append(id)
                }
            }
        }
    }

    /// Throw the whole workspace set away, keeping the desktop facts.
    ///
    /// For one caller: `workspaces` or `workspace-anchor` changed under a
    /// running daemon, so which workspaces exist and which desktop hosts them
    /// is no longer derivable from what is here — an anchor that moved leaves
    /// workspaces on a desktop that no longer hosts any, and `.virtual` →
    /// `.native` leaves the anchor's hidden workspaces holding windows that
    /// nothing will ever unpark again.
    ///
    /// Emptying `workspaces` is what makes the next sweep take its seeding
    /// branch, which re-reads the `[[space]]` names and the saved overrides.
    /// Trees do not survive it, and that is the honest outcome: the set they
    /// described has been replaced.
    ///
    /// `order`, `displays`, `displayBySpace` and `currentByDisplay` are
    /// macOS's facts, not weft's, so they stay.
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
    /// Call it after `adoptDesktops`, which is what builds the order they are
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

/// Split membership between its two owners: the WindowServer says which desktop
/// each window is on, weft says which workspace within that desktop.
///
/// **This function is the seam, and every bug in the workspace model will live
/// in it.** It is written against plain dictionaries rather than `SpaceState`
/// so that it can be read and tested on its own, and so that it cannot reach
/// for a fact it was not handed.
///
/// One rule, in two halves:
///
/// - A window still on the desktop its workspace lives on **keeps that
///   workspace**, whether or not that workspace is the one showing. This is the
///   half that makes a hidden workspace possible: SLS reports its windows on
///   the desktop exactly as it reports the visible ones, and without this they
///   would all be swept into whatever is on screen.
/// - A window whose desktop changed under us **joins the active workspace of
///   the desktop it arrived on**. That covers a user dragging a window in
///   Mission Control, a `[[rule]]` relocating one, and an app opening a window
///   wherever it likes.
///
/// A window SLS reports on two desktops — a sticky window — is resolved once
/// per desktop and so appears in one workspace on each. A window leaves a
/// workspace by simply not being reported on that workspace's desktop any more,
/// which is why nothing here removes anything.
///
/// A desktop with no entry in `activeOn` drops every window that arrives on it.
/// That is not a judgement, it is the absence of anywhere to put them — the
/// caller is responsible for every live desktop having an active workspace
/// before this is called.
///
/// Output arrays are sorted, so a sweep's membership does not depend on
/// dictionary iteration order.
public func reconcileWorkspaces(
    windowDesktops: [WindowID: [SpaceID]],
    membership: [WorkspaceID: [WindowID]],
    desktopOf: [WorkspaceID: SpaceID],
    activeOn: [SpaceID: WorkspaceID]
) -> [WorkspaceID: [WindowID]] {
    // wid → the workspace weft currently files it under on each desktop. Built
    // once: the alternative is scanning every workspace's window list per
    // window, which is the whole model per window per sweep.
    var held: [WindowID: [SpaceID: WorkspaceID]] = [:]
    for (wsid, wids) in membership {
        guard let desktop = desktopOf[wsid] else { continue }
        for wid in wids { held[wid, default: [:]][desktop] = wsid }
    }
    var out: [WorkspaceID: [WindowID]] = [:]
    for (wid, desktops) in windowDesktops {
        for desktop in desktops {
            guard let wsid = held[wid]?[desktop] ?? activeOn[desktop] else { continue }
            out[wsid, default: []].append(wid)
        }
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
