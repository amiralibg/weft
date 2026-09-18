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

    public init(id: WorkspaceID, label: String, desktop: SpaceID, layout: SpaceLayout) {
        self.id = id
        self.label = label
        self.desktop = desktop
        self.layout = layout
    }
}

public struct SpaceState: Sendable, Equatable {
    /// One layout per space id. Missing = not yet visited this launch.
    public var layouts: [SpaceID: SpaceLayout]
    /// sid → label. Rebuilt at startup by ordinal; renamable at runtime.
    public var labels: [SpaceID: String]
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
    /// SLSCopyManagedDisplaySpaces reports within each display). This is the
    /// ordinal every label and every `space focus <n>` resolves against.
    ///
    /// Sorting raw sids instead — which this used to do — is wrong: macOS
    /// hands out space ids in creation order, so as soon as a desktop is
    /// removed and re-added the numeric order stops matching the on-screen
    /// order and every label lands one desktop off.
    public var order: [SpaceID]
    /// The previously focused space ID for back-and-forth space toggle (`space focus recent`).
    public var recentSpace: SpaceID?
    /// Dynamic layout overrides chosen via `space layout <kind>`, keyed by
    /// SpaceID. Distinct from `layouts` so the intent survives an empty-space
    /// sweep and can be persisted across restarts.
    public var overrides: [SpaceID: LayoutKind]

    public init(
        layouts: [SpaceID: SpaceLayout] = [:],
        overrides: [SpaceID: LayoutKind] = [:],
        labels: [SpaceID: String] = [:],
        currentByDisplay: [String: SpaceID] = [:],
        displays: [String] = [],
        displayBySpace: [SpaceID: String] = [:],
        focusedDisplay: String? = nil,
        order: [SpaceID] = [],
        recentSpace: SpaceID? = nil
    ) {
        self.layouts = layouts
        self.overrides = overrides
        self.labels = labels
        self.currentByDisplay = currentByDisplay
        self.displays = displays
        self.displayBySpace = displayBySpace
        self.focusedDisplay = focusedDisplay
        self.order = order
        self.recentSpace = recentSpace
    }

    /// The space the user is on: the focused display's current space. Falls
    /// back to the first display's, which is exact on a single display.
    public var currentSpace: SpaceID? {
        if let uuid = focusedDisplay, let sid = currentByDisplay[uuid] { return sid }
        return displays.first.flatMap { currentByDisplay[$0] }
    }

    /// Every visible space — one per display. These are the spaces a sweep
    /// may bind AX elements for and apply frames to.
    public var visibleSpaces: [SpaceID] {
        displays.compactMap { currentByDisplay[$0] }
    }

    public func id(forLabel label: String) -> SpaceID? {
        labels.first(where: { $0.value == label })?.key
    }

    /// Resolve `space focus <…>` targets: label first, then raw sid, then
    /// 1-based ordinal in sorted-sid order (keeps alt-digit keybinds working
    /// after renames — "1" means the first space even when it isn't named so).
    public func resolveSpace(_ text: String) -> SpaceID? {
        if text == "recent" { return recentSpace }
        if let sid = id(forLabel: text) { return sid }
        // A bare integer is a Mission Control ordinal first (that is what the
        // user types on alt-3) and only falls through to a raw sid when it is
        // too large to be an ordinal — real sids are far outside 1...count.
        if let n = Int(text), (1...order.count).contains(n) { return order[n - 1] }
        if let raw = UInt64(text), layouts[raw] != nil { return raw }
        return nil
    }

    /// 1-based Mission Control number of a space, or nil if it is not on any
    /// display. This is the number the ctrl+N fallback keystroke needs.
    public func ordinal(of sid: SpaceID) -> Int? {
        order.firstIndex(of: sid).map { $0 + 1 }
    }

    /// Assign labels by ordinal from persisted names. `sids` MUST already be in
    /// Mission Control order (display-major) — it is stored verbatim as
    /// `order`. `names[i]` labels the i-th space; extras get numeric defaults.
    public mutating func assignLabels(sids: [SpaceID], names: [String]) {
        order = sids
        labels = [:]
        for (i, sid) in sids.enumerated() {
            if i < names.count, !names[i].isEmpty {
                labels[sid] = names[i]
            } else {
                labels[sid] = "\(i + 1)"
            }
        }
        // Drop layouts for spaces that no longer exist (unplugged display).
        let live = Set(sids)
        for sid in layouts.keys where !live.contains(sid) {
            layouts.removeValue(forKey: sid)
        }
        // Retain only overrides whose spaces still exist
        overrides = overrides.filter { sids.contains($0.key) }
    }

    /// Ordered label names for persistence (ordinal → label).
    public func persistedNames(sids: [SpaceID]) -> [String] {
        let ordered = order.isEmpty ? sids.sorted() : order
        return ordered.map { labels[$0] ?? "" }
    }

    /// Layout overrides by ordinal, ready to persist as `["", "float", ""]`.
    ///
    /// Persisting by ordinal rather than by space id lets the choices survive
    /// a daemon restart (macOS hands out fresh space ids on reboot) while
    /// remaining independent of whether spaces are labelled.
    public func persistedOverrides(sids: [SpaceID]) -> [String] {
        sids.map { overrides[$0]?.rawValue ?? "" }
    }

    /// Re-apply a previously persisted list of layout overrides by ordinal.
    ///
    /// A kind this build does not recognise is dropped rather than rejected,
    /// which is how a `layouts.json` written when `scroll` existed comes back
    /// as bsp: no override survives, and bsp is what a space with no override
    /// gets. Nothing to migrate, and nothing to explain to the user beyond
    /// the space they left in scroll now tiling.
    public mutating func assignOverrides(sids: [SpaceID], kinds: [String]) {
        for (i, sid) in sids.enumerated() where i < kinds.count {
            let raw = kinds[i]
            if let kind = LayoutKind(rawValue: raw) {
                overrides[sid] = kind
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
public func syncMembership(
    _ state: SpaceState,
    spaces: [SpaceID: [WindowID]],
    live: Set<SpaceID>? = nil,
    screens: [SpaceID: Frame] = [:],
    config: TilingConfig = TilingConfig()
) -> (SpaceState, Set<WindowID>) {
    var next = state
    var fresh: Set<WindowID> = []
    // Every space that exists, not just the ones holding a managed window, so
    // an emptied space keeps its layout kind (with empty membership).
    let sids = live ?? Set(spaces.keys)
    for sid in sids {
        let ids = spaces[sid] ?? []
        let initialLayout: SpaceLayout
        if let overrideKind = next.overrides[sid] {
            switch overrideKind {
            case .float: initialLayout = .float(FloatState())
            case .bsp: initialLayout = .tiling(Tree())
            }
        } else {
            initialLayout = .tiling(Tree())
        }
        switch next.layouts[sid] ?? initialLayout {
        case .tiling(var tree):
            let have = Set(tree.windows)
            for id in ids.sorted() where !have.contains(id) {
                // With a screen the split axis follows the slot's shape
                // (yabai's split_type auto); without one, fall back to the
                // alternating flag. The rect is per space, because the space
                // may live on a display of an entirely different shape.
                tree = screens[sid].map { tree.inserting(id, in: $0, config: config) }
                    ?? tree.inserting(id)
                fresh.insert(id)
            }
            for id in tree.windows where !ids.contains(id) {
                tree = tree.removing(id)
            }
            next.layouts[sid] = .tiling(tree)
        case .float(var fl):
            let have = Set(fl.windows)
            for id in ids.sorted() where !have.contains(id) {
                fl = fl.inserting(id)
                fresh.insert(id)
            }
            for id in fl.windows where !ids.contains(id) {
                fl = fl.removing(id)
            }
            next.layouts[sid] = .float(fl)
        }
    }
    // Drop layouts for spaces that are genuinely no longer live.
    if let live {
        next.layouts = next.layouts.filter { live.contains($0.key) }
    } else {
        for sid in next.layouts.keys where spaces[sid] == nil {
            next.layouts.removeValue(forKey: sid)
        }
    }
    return (next, fresh)
}
