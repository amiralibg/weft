// WeftCore/Spaces.swift — per-space state (M4, layouts M5).
//
// macOS owns spaces natively; weft keeps one layout per space id and a label
// layer on top (sids are NOT stable across reboot — config persists by label,
// assigned by ordinal at startup, DESIGN §5.3). Switching a space's layout
// preserves window membership and converts (DESIGN §4.3): tree → columns in
// left-to-right leaf order; columns → tree by successive right splits.

public enum LayoutKind: String, Codable, Sendable, Equatable {
    case bsp
    case scroll
    case float
}

public enum SpaceLayout: Sendable, Equatable {
    case tiling(Tree)
    case scroll(ScrollState)
    case float(FloatState)

    public var kind: LayoutKind {
        switch self {
        case .tiling: return .bsp
        case .scroll: return .scroll
        case .float: return .float
        }
    }

    public var windows: [WindowID] {
        switch self {
        case .tiling(let t): return t.windows
        case .scroll(let s): return s.windows
        case .float(let f): return f.windows
        }
    }

    public var focus: WindowID? {
        switch self {
        case .tiling(let t): return t.focus
        case .scroll(let s): return s.focusedWindow
        case .float(let f): return f.focus
        }
    }

    public var fullscreen: WindowID? {
        switch self {
        case .tiling(let t): return t.fullscreen
        case .scroll(let s): return s.fullscreen
        case .float: return nil
        }
    }
}

/// tree → scroll: leaves left-to-right, one window per column, default width.
/// Viewport starts at 0; the daemon ensures visibility with the real screen
/// width on every apply (idempotent when already visible).
public func scrollFromTree(_ tree: Tree) -> ScrollState {
    let cols = tree.windows.map { Column(windows: [$0]) }
    var state = ScrollState(columns: cols)
    if let focus = tree.focus {
        state = state.focusing(focus)
    }
    return state
}

/// scroll → tree: successive right splits in column order (DESIGN §4.3).
/// Column rows flatten into the sequence (row grouping is the documented
/// approximation — scroll rows have no tree equivalent).
public func treeFromScroll(_ scroll: ScrollState) -> Tree {
    treeFromOrder(scroll.columns.flatMap({ $0.windows }), focus: scroll.focusedWindow)
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

/// tiling/scroll → float: membership in order, actual frames remembered so
/// re-entering float restores the user's arrangement.
public func floatFromWindows(_ order: [WindowID], actuals: [WindowID: Frame], focus: WindowID?) -> FloatState {
    var remembered: [WindowID: Frame] = [:]
    for wid in order {
        if let f = actuals[wid] { remembered[wid] = f }
    }
    return FloatState(order: order, remembered: remembered, focus: order.contains(focus ?? 0) ? focus : order.first)
}

/// float → scroll: one window per column in order.
public func scrollFromFloat(_ float: FloatState) -> ScrollState {
    let cols = float.order.map { Column(windows: [$0]) }
    var state = ScrollState(columns: cols)
    if let focus = float.focus {
        state = state.focusing(focus)
    }
    return state
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

    /// Layout overrides by ordinal, ready to persist as `["", "scroll", ""]`.
    ///
    /// Persisting by ordinal rather than by space id lets the choices survive
    /// a daemon restart (macOS hands out fresh space ids on reboot) while
    /// remaining independent of whether spaces are labelled.
    public func persistedOverrides(sids: [SpaceID]) -> [String] {
        sids.map { overrides[$0]?.rawValue ?? "" }
    }

    /// Re-apply a previously persisted list of layout overrides by ordinal.
    public mutating func assignOverrides(sids: [SpaceID], kinds: [String]) {
        for (i, sid) in sids.enumerated() where i < kinds.count {
            let raw = kinds[i]
            if let kind = LayoutKind(rawValue: raw) {
                overrides[sid] = kind
            }
        }
    }
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
            case .scroll: initialLayout = .scroll(ScrollState())
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
        case .scroll(var sc):
            let have = Set(sc.windows)
            for id in ids.sorted() where !have.contains(id) {
                sc = sc.inserting(id)
                fresh.insert(id)
            }
            for id in sc.windows where !ids.contains(id) {
                sc = sc.removing(id)
            }
            next.layouts[sid] = .scroll(sc)
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
