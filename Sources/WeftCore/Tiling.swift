// WeftCore/Tiling.swift — BSP tiling tree (M2).
//
// Pure: no I/O, no AppKit, no SkyLight. Layout is
// `(Tree, Frame, TilingConfig) -> [WindowID: Frame]`.
//
// Naming: `splitV` = vertical divider, children side-by-side (west/east).
// `splitH` = horizontal divider, children stacked (north/south).

public enum ContainerLayout: String, Codable, Sendable, Equatable {
    case splitV
    case splitH
    /// Stack: every member gets the *same* frame; only z-order changes.
    /// Switching members is one SLSOrderWindow call — no AX, no resize.
    case stack
}

public indirect enum Node: Sendable, Equatable {
    case window(WindowID)
    case container(Container)
}

public struct Container: Sendable, Equatable {
    public var layout: ContainerLayout
    public var children: [Node]
    /// Split ratios, sums to 1. `children.count == ratios.count`, count >= 2.
    /// Unused for stacks (members share one frame) but kept count-matched.
    public var ratios: [Double]
    /// Stack: index of the visible child. Clamped to children on every op.
    public var active: Int
    /// Stack: what it replaced, so unstacking puts that back instead of
    /// inventing an equal side-by-side split. Nil for splits, and for a
    /// stack weft did not build (it then unstacks side by side).
    public var origin: StackOrigin?

    public init(layout: ContainerLayout, children: [Node], ratios: [Double], active: Int = 0) {
        self.layout = layout
        self.children = children
        self.ratios = ratios
        self.active = min(max(active, 0), max(children.count - 1, 0))
    }

    /// Balanced container: equal ratios.
    public init(layout: ContainerLayout, children: [Node], active: Int = 0) {
        self.layout = layout
        self.children = children
        let n = max(children.count, 1)
        self.ratios = Array(repeating: 1.0 / Double(n), count: children.count)
        self.active = min(max(active, 0), max(children.count - 1, 0))
    }
}

/// What a stack replaced when it was made.
///
/// Unstacking used to turn every stack into an equal side-by-side split,
/// whatever it had been: a top/bottom pair came back left/right, a 70/30
/// split came back 50/50, and a neighbour pulled in with `stack split` stayed
/// in the stack's slot instead of going home. Recording the arrangement at
/// the moment of stacking is the only way to know what "back" means.
public struct StackOrigin: Sendable, Equatable {
    public enum Scope: Sendable, Equatable {
        /// The stack took the place of this subtree (`stack toggle`,
        /// `stack all`): restore it in the stack's slot.
        case subtree
        /// The stack pulled a window in from elsewhere (`stack split`,
        /// `stack move`): only the whole tree as it was puts that window back.
        case root
    }

    public var scope: Scope
    public var node: Node

    public init(scope: Scope, node: Node) {
        self.scope = scope
        self.node = node
    }
}

/// A single tiled space (M2: one display, one space).
/// M4 generalizes to `[SpaceID: Tree]`; the tree itself doesn't change.
public struct Tree: Sendable, Equatable {
    public var root: Node?
    public var focus: WindowID?
    /// Orientation for the next bsp insertion when no geometry is available.
    /// Auto-alternates every insert (Fibonacci spiral: master-left,
    /// top-right, bottom-right, …).
    ///
    /// Prefer `inserting(_:in:config:)`, which picks the axis from the shape
    /// of the slot being split — the yabai/`split_type auto` rule, and the
    /// thing that makes a spiral actually look like a spiral. A global
    /// alternating flag only produces the right shape while you keep focusing
    /// the newest window; focus an older, tall pane and insert, and the flag
    /// splits it side-by-side into two slivers.
    public var nextSplit: ContainerLayout
    /// One-shot orientation pinned by the `split` command. Consumed by the
    /// next insertion, after which the automatic rule resumes (DESIGN §4.1).
    public var pendingSplit: ContainerLayout?
    public var insertion: InsertionMode
    /// Fullscreen (zoomed) window. When set, this window covers the screen.
    public var fullscreen: WindowID?

    public enum InsertionMode: Sendable, Equatable {
        /// Split the focused leaf into a 2-child container (default).
        case bsp
        /// Append into the focused container, i3 behaviour.
        case manual
    }

    public init(
        root: Node? = nil,
        focus: WindowID? = nil,
        nextSplit: ContainerLayout = .splitV,
        insertion: InsertionMode = .bsp,
        fullscreen: WindowID? = nil,
        pendingSplit: ContainerLayout? = nil
    ) {
        self.root = root
        self.focus = focus
        self.nextSplit = nextSplit
        self.insertion = insertion
        self.fullscreen = fullscreen
        self.pendingSplit = pendingSplit
    }

    public var isEmpty: Bool { root == nil }
    public var windows: [WindowID] { root?.windows ?? [] }
}

extension Node {
    public var windows: [WindowID] {
        switch self {
        case .window(let id): return [id]
        case .container(let c): return c.children.flatMap { $0.windows }
        }
    }

    public var count: Int {
        switch self {
        case .window: return 1
        case .container(let c): return c.children.reduce(0) { $0 + $1.count }
        }
    }
}

// MARK: - Layout

public struct TilingConfig: Sendable, Equatable {
    public var innerGap: Double
    public var outerGap: OuterGap
    /// How far each stacked window is inset from the one behind it.
    ///
    /// A stack used to give every member the identical frame, which is
    /// correct and unreadable: the slot looks exactly like a single window,
    /// and nothing on screen says the other members are there. Insetting each
    /// layer leaves the ones behind peeking out along two edges — the same
    /// affordance AeroSpace uses, and the reason a stack is discoverable at
    /// all. 0 restores the flat behaviour.
    public var stackOffset: Double

    public struct OuterGap: Sendable, Equatable {
        public var top: Double
        public var bottom: Double
        public var left: Double
        public var right: Double

        public init(top: Double, bottom: Double, left: Double, right: Double) {
            self.top = top
            self.bottom = bottom
            self.left = left
            self.right = right
        }
    }

    /// The smallest size each window has been seen to accept (see
    /// `WindowMinimum`). A split gives a child at least this much along its
    /// axis, taken from siblings with room to spare; the stored ratios are
    /// not touched, so the room goes back when the window does.
    public var minimums: [WindowID: WindowMinimum]

    public init(
        innerGap: Double = 8,
        outerGap: OuterGap = OuterGap(top: 8, bottom: 8, left: 8, right: 8),
        stackOffset: Double = 8,
        minimums: [WindowID: WindowMinimum] = [:]
    ) {
        self.innerGap = innerGap
        self.outerGap = outerGap
        self.stackOffset = stackOffset
        self.minimums = minimums
    }

    /// Every spacing knob at zero — gaps and the stack offset alike. Used by
    /// tests that assert exact geometry, and by anyone who wants windows
    /// edge to edge.
    public static let none = TilingConfig(
        innerGap: 0,
        outerGap: OuterGap(top: 0, bottom: 0, left: 0, right: 0),
        stackOffset: 0
    )
}

/// A size below which a window will not go. Apps do not say; weft learns it
/// when a window settles larger than the frame it was given (T3 Code and
/// other Electron apps refuse to be shorter than a few hundred points), and
/// lays out around it instead of leaving the window hanging off the screen
/// or over its neighbour.
public struct WindowMinimum: Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Compute frames for every window. Single write per window downstream —
/// no interpolation, no animation (hard constraint §1).
public func layout(_ tree: Tree, in screen: Frame, config: TilingConfig) -> [WindowID: Frame] {
    guard let root = tree.root else { return [:] }
    let inset = Frame(
        x: screen.x + config.outerGap.left,
        y: screen.y + config.outerGap.top,
        width: max(screen.width - config.outerGap.left - config.outerGap.right, 1),
        height: max(screen.height - config.outerGap.top - config.outerGap.bottom, 1)
    )
    // Zoom-fullscreen fills the *tiling area*, not the display.
    //
    // It used to be handed the raw screen rect, so a zoomed window went
    // edge to edge while every other window on the space kept its gaps —
    // and, worse, ignored the `reserve` too, sliding under a bar the user had
    // explicitly told weft to keep clear. This is a zoom within the layout,
    // not a native fullscreen: it takes the whole tiling area and nothing
    // more. (Native fullscreen is macOS's own, and weft skips those spaces
    // entirely — §11 risk 6.)
    if let fs = tree.fullscreen, root.windows.contains(fs) {
        var out: [WindowID: Frame] = [:]
        if case .window(let id) = root {
            out[id] = inset
            return out
        }
        layoutNode(root, in: inset, innerGap: config.innerGap, stackOffset: config.stackOffset,
                   minimums: config.minimums, out: &out)
        out[fs] = inset
        return out
    }
    // Single window: no inner gap (edge-to-edge inside the outer inset).
    if case .window(let id) = root { return [id: inset] }
    var out: [WindowID: Frame] = [:]
    layoutNode(root, in: inset, innerGap: config.innerGap,
               stackOffset: config.stackOffset, minimums: config.minimums, out: &out)
    return out
}

/// The least room `node` needs along one axis: a split along that axis needs
/// its children's sum plus the gaps between them; anything else needs its
/// largest child's.
private func minimumExtent(
    _ node: Node, horizontal: Bool, innerGap: Double, minimums: [WindowID: WindowMinimum]
) -> Double {
    switch node {
    case .window(let id):
        guard let m = minimums[id] else { return 0 }
        return horizontal ? m.width : m.height
    case .container(let c):
        let each = c.children.map {
            minimumExtent($0, horizontal: horizontal, innerGap: innerGap, minimums: minimums)
        }
        let along = (horizontal && c.layout == .splitV) || (!horizontal && c.layout == .splitH)
        if along, c.children.count > 1 {
            return each.reduce(0, +) + innerGap * Double(c.children.count - 1)
        }
        return each.max() ?? 0
    }
}

/// Split `avail` by `ratios`, then raise any share below its minimum to it,
/// taking the difference from the shares that stay above theirs, in
/// proportion to their ratios. When the minimums do not all fit, the ratios
/// stand: no arrangement satisfies them, and a predictable split beats a
/// squeezed one.
func constrainedShares(avail: Double, ratios: [Double], minimums: [Double]) -> [Double] {
    let n = ratios.count
    var shares = ratios.map { avail * $0 }
    guard minimums.count == n, minimums.contains(where: { $0 > 0 }),
          minimums.reduce(0, +) <= avail
    else { return shares }
    var pinned = Set<Int>()
    while true {
        let short = (0..<n).filter { !pinned.contains($0) && shares[$0] < minimums[$0] - 0.5 }
        if short.isEmpty { return shares }
        for i in short { pinned.insert(i); shares[i] = minimums[i] }
        let free = (0..<n).filter { !pinned.contains($0) }
        let left = avail - pinned.reduce(0) { $0 + shares[$1] }
        let weight = free.reduce(0) { $0 + ratios[$1] }
        guard !free.isEmpty, weight > 0 else { return shares }
        for i in free { shares[i] = left * ratios[i] / weight }
    }
}

/// How many layers of a stack are drawn peeking out behind the active one.
///
/// Without a cap, a six-window stack shrinks its active member by six offsets
/// and the slot visibly shrinks as you add windows. Three edges is enough to
/// read as "there is a pile here"; past that it is just lost space.
private let maxVisibleStackLayers = 3

private func layoutNode(
    _ node: Node, in frame: Frame, innerGap: Double, stackOffset: Double,
    minimums: [WindowID: WindowMinimum] = [:], out: inout [WindowID: Frame]
) {
    switch node {
    case .window(let id):
        out[id] = frame
    case .container(let c):
        let n = c.children.count
        guard n > 0 else { return }
        if n == 1 {
            layoutNode(c.children[0], in: frame, innerGap: innerGap,
                       stackOffset: stackOffset, minimums: minimums, out: &out)
            return
        }
        // Stack: the members share one slot, so the only thing that can say
        // there is more than one window here is geometry. Each member is
        // inset from the one behind it, deepest at the back, so the active
        // member sits on top with the others showing as title bars along its
        // top edge — a deck of cards rather than a single window that
        // mysteriously swaps contents.
        //
        // The inset is VERTICAL ONLY. Insetting the x as well made every
        // member a different width, so switching members visibly jogged the
        // content sideways and the stack never lined up with the window in
        // the split next to it. A stack occupies one column: every member
        // gets that column's full width, and only the top edge steps down.
        if c.layout == .stack {
            let active = min(max(c.active, 0), n - 1)
            for (i, child) in c.children.enumerated() {
                // Distance from the back of the pile, capped: the active
                // member is frontmost regardless of its index.
                let depth = i == active
                    ? min(n - 1, maxVisibleStackLayers)
                    : min(abs(i - active) - 1, maxVisibleStackLayers - 1)
                let d = stackOffset * Double(max(depth, 0))
                // Full width, inset from the top and shortened to match, so
                // every member's bottom edge stays on the slot's.
                let slot = Frame(
                    x: frame.x,
                    y: frame.y + d,
                    width: frame.width,
                    height: max(frame.height - d, 1)
                )
                layoutNode(child, in: slot, innerGap: innerGap,
                           stackOffset: stackOffset, minimums: minimums, out: &out)
            }
            return
        }
        let totalGap = innerGap * Double(n - 1)
        func ratio(_ i: Int) -> Double { i < c.ratios.count ? c.ratios[i] : 1.0 / Double(n) }
        // Shares bent around minimums, or nil when no window has one: the
        // plain split then reads its ratios in place, allocating nothing —
        // this runs on the core queue for every apply (LayoutBudgetTests).
        func shares(avail: Double, horizontal: Bool) -> [Double]? {
            guard !minimums.isEmpty else { return nil }
            let least = c.children.map {
                minimumExtent($0, horizontal: horizontal, innerGap: innerGap, minimums: minimums)
            }
            guard least.contains(where: { $0 > 0 }) else { return nil }
            return constrainedShares(avail: avail, ratios: (0..<n).map(ratio), minimums: least)
        }
        switch c.layout {
        case .splitV:
            let avail = max(frame.width - totalGap, 0)
            let shares = shares(avail: avail, horizontal: true)
            var x = frame.x
            for (i, child) in c.children.enumerated() {
                // Last child takes the remainder so rounding never leaks/loses a pixel.
                let w = (i == n - 1) ? (frame.x + frame.width - x) : shares?[i] ?? avail * ratio(i)
                layoutNode(
                    child,
                    in: Frame(x: x, y: frame.y, width: max(w, 1), height: frame.height),
                    innerGap: innerGap, stackOffset: stackOffset, minimums: minimums, out: &out
                )
                x += w + innerGap
            }
        case .splitH:
            let avail = max(frame.height - totalGap, 0)
            let shares = shares(avail: avail, horizontal: false)
            var y = frame.y
            for (i, child) in c.children.enumerated() {
                let h = (i == n - 1) ? (frame.y + frame.height - y) : shares?[i] ?? avail * ratio(i)
                layoutNode(
                    child,
                    in: Frame(x: frame.x, y: y, width: frame.width, height: max(h, 1)),
                    innerGap: innerGap, stackOffset: stackOffset, minimums: minimums, out: &out
                )
                y += h + innerGap
            }
        case .stack:
            return  // handled by the early return above; kept for exhaustiveness
        }
    }
}

// MARK: - Structural ops (all return new values; Tree is a value type)

extension Tree {
    /// Set focus and repair stack actives along the path: every ancestor
    /// stack points at the child leading to `id`. Use for every focus change.
    public func focusing(_ id: WindowID) -> Tree {
        guard let root, root.windows.contains(id) else { return self }
        var copy = self
        copy.focus = id
        copy.root = fixActive(root, target: id)
        return copy
    }

    /// Insert a window. A focused stack absorbs the newcomer as a member;
    /// otherwise split the focused leaf (bsp) or append into its parent
    /// container (manual). Focus moves to the new window.
    public func inserting(_ id: WindowID) -> Tree {
        insert(id, split: nil)
    }

    /// Insert with the split axis chosen from the geometry of the slot being
    /// split: a wider-than-tall slot splits side-by-side, a taller-than-wide
    /// slot splits top-and-bottom. This is yabai's `split_type auto` and i3's
    /// default, and it is what keeps every pane usable no matter which window
    /// you had focused when you opened a new one.
    ///
    /// A `split` command still wins for exactly one insertion (`pendingSplit`).
    public func inserting(_ id: WindowID, in screen: Frame, config: TilingConfig) -> Tree {
        if let pendingSplit {
            var copy = insert(id, split: pendingSplit)
            copy.pendingSplit = nil
            return copy
        }
        guard let root, !root.windows.contains(id), let target = focus ?? root.windows.first else {
            return insert(id, split: nil)
        }
        let frames = layout(self, in: screen, config: config)
        guard let slot = frames[target] else { return insert(id, split: nil) }
        // Ties (an exactly square slot) go side-by-side: displays are wide, so
        // that is the orientation with more room to give.
        return insert(id, split: slot.width >= slot.height ? .splitV : .splitH)
    }

    /// Shared insertion core. `split == nil` falls back to the alternating
    /// `nextSplit` flag, which is all a geometry-free caller can do.
    private func insert(_ id: WindowID, split: ContainerLayout?) -> Tree {
        if let root, root.windows.contains(id) {
            return focusing(id)
        }
        guard let root else {
            return Tree(root: .window(id), focus: id, nextSplit: nextSplit, insertion: insertion)
                .focusing(id)
        }
        let target = focus ?? root.windows.first!
        var copy = self
        if stackPath(in: root, target: target) != nil {
            copy.root = appendToStack(root, target: target, newID: id)
        } else {
            switch insertion {
            case .bsp:
                let chosen = split ?? nextSplit
                copy.root = insertBSP(root, target: target, newID: id, split: chosen)
                copy.nextSplit = chosen.toggled
                copy.pendingSplit = nil
            case .manual:
                copy.root = insertManual(root, target: target, newID: id)
            }
        }
        return copy.focusing(id)
    }

    /// Remove a window, collapsing single-child containers and clamping
    /// stack actives. Focus falls back to the nearest surviving sibling.
    public func removing(_ id: WindowID) -> Tree {
        guard let root else { return self }
        var copy = self
        let (node, fallback) = removeNode(root, id: id)
        copy.root = node.map(clampedNode)
        if focus == id {
            copy.focus = nil
            if let fb = fallback ?? copy.root?.windows.first {
                copy = copy.focusing(fb)
            }
        }
        if copy.fullscreen == id {
            copy.fullscreen = nil
        }
        return copy
    }

    /// Toggle zoom-fullscreen on the focused window.
    public func togglingFullscreen() -> Tree {
        guard let root, let focused = focus, root.windows.contains(focused) else { return self }
        var copy = self
        if copy.fullscreen == focused {
            copy.fullscreen = nil
        } else {
            copy.fullscreen = focused
        }
        return copy
    }

    /// Toggle split orientation of the focused window\x27s parent container (splitV <-> splitH).
    /// If focused is the lone root window, flips nextSplit.
    public func togglingSplit() -> Tree {
        guard let root, let focused = focus, root.windows.contains(focused) else {
            var copy = self
            copy.nextSplit = nextSplit.toggled
            return copy
        }
        guard let path = pathTo(root, target: focused), !path.isEmpty else {
            var copy = self
            copy.nextSplit = nextSplit.toggled
            return copy
        }
        let parentPath = Array(path.dropLast())
        guard let parent = nodeAt(root, path: parentPath),
              case .container(var c) = parent,
              c.layout != .stack
        else {
            var copy = self
            copy.nextSplit = nextSplit.toggled
            return copy
        }
        c.layout = c.layout.toggled
        var copy = self
        copy.root = replacing(root, at: parentPath, with: .container(c))
        return copy.focusing(focused)
    }

    /// Swap the positions of two windows in the tree (warp / move).
    public func swapping(_ a: WindowID, _ b: WindowID) -> Tree {
        guard a != b, let root, root.windows.contains(a), root.windows.contains(b) else {
            return self
        }
        var copy = self
        copy.root = swapNodes(root, a: a, b: b)
        return copy.focusing(a)
    }

    /// i3-style `layout stacked`, as a toggle: the focused window's parent
    /// container becomes a stack, and a focused window that is *already* in a
    /// stack comes back out of it.
    ///
    /// The no-op it used to be on an existing stack is what made stacking feel
    /// like a trapdoor — one key in, and no obvious key back out, so the
    /// honest thing for one key to do is undo itself. `stack unstack` is still
    /// there for anyone who wants the one-way version bound separately.
    ///
    /// Lone root leaf → a 1-member stack (setup for future inserts, which
    /// join stacks).
    public func togglingStack() -> Tree {
        guard let root, let focused = focus, root.windows.contains(focused) else { return self }
        if stackPath(in: root, target: focused) != nil { return unstacking() }
        guard let path = pathTo(root, target: focused) else { return self }
        if path.isEmpty {
            var copy = self
            var stack = Container(layout: .stack, children: [.window(focused)], active: 0)
            stack.origin = StackOrigin(scope: .subtree, node: root)
            copy.root = .container(stack)
            return copy.focusing(focused)
        }
        let parentPath = Array(path.dropLast())
        guard let parent = nodeAt(root, path: parentPath),
              case .container(var c) = parent,
              c.layout != .stack
        else { return self }
        c.origin = StackOrigin(scope: .subtree, node: parent)
        c.layout = .stack
        c.active = parentPath.isEmpty ? 0 : path.last ?? 0
        var copy = self
        copy.root = replacing(root, at: parentPath, with: .container(c))
        return copy.focusing(focused)
    }

    /// Pull the nearest neighbour in `dir` into a stack with the focused
    /// window: `stack split right` on the left window stacks the right one
    /// into its slot. Already in a stack → the neighbour joins it.
    public func stackSplitting(towards dir: Direction, frames: [WindowID: Frame]) -> Tree {
        guard root != nil, let focused = focus else { return self }
        guard let neighbor = Reducer.neighbour(of: focused, in: frames, towards: dir) else { return self }
        var tree = removing(neighbor)
        guard let r = tree.root else { return self }
        if let sp = stackPath(in: r, target: focused) {
            tree.root = appendToStack(r, target: focused, newID: neighbor, at: sp)
        } else {
            var stack = Container(
                layout: .stack,
                children: [.window(focused), .window(neighbor)],
                active: 0
            )
            if let original = root { stack.origin = StackOrigin(scope: .root, node: original) }
            tree.root = replaceLeaf(r, target: focused, with: .container(stack))
        }
        return tree.focusing(focused)
    }

    /// Cycle the active member of the focused stack. No stack → no-op.
    /// Focus follows the newly visible member (which the renderer raises).
    public func cyclingStack(by delta: Int) -> Tree {
        guard let root, let focused = focus,
              let sp = stackPath(in: root, target: focused),
              let node = nodeAt(root, path: sp),
              case .container(let c) = node, c.children.count > 1
        else { return self }
        let count = c.children.count
        let next = ((c.active + delta) % count + count) % count
        guard let member = c.children[next].windows.first else { return self }
        return focusing(member)
    }

    /// Undo the focused stack: put back what it replaced. Not in a stack →
    /// no-op.
    ///
    /// Exact when the stack still holds the windows it was made from — the
    /// recorded arrangement comes back, proportions and all. When windows
    /// have joined or left since, the recording describes a different set,
    /// so the stack keeps the *shape* it replaced (top/bottom stays
    /// top/bottom) with even proportions. A stack with no record unstacks
    /// side by side, as it always did.
    ///
    /// A stack that pulled a window in from elsewhere (`stack split`,
    /// `stack move`) restores the whole tree as it was, since that is the
    /// only arrangement that has the window's old slot in it — which means
    /// resizes made elsewhere while it was stacked go back too.
    public func unstacking() -> Tree {
        guard let root, let focused = focus,
              let sp = stackPath(in: root, target: focused)
        else { return self }
        return unstacking(at: sp)
    }

    /// Undo the stack at `sp`, whether or not focus is in it. `unstacking()`
    /// for the stack focus is in; `stack side` for the one on a side.
    private func unstacking(at sp: [Int]) -> Tree {
        guard let root,
              let node = nodeAt(root, path: sp),
              case .container(var c) = node, c.layout == .stack
        else { return self }
        if let origin = c.origin {
            let members = Set(node.windows)
            switch origin.scope {
            case .subtree where Set(origin.node.windows) == members:
                var copy = self
                copy.root = replacing(root, at: sp, with: origin.node)
                return copy.refocused()
            case .root where Set(origin.node.windows) == Set(root.windows):
                var copy = self
                copy.root = origin.node
                return copy.refocused()
            default:
                break
            }
        }
        if let origin = c.origin, case .container(let was) = origin.node, was.layout != .stack {
            c.layout = was.layout
            c.ratios = was.ratios.count == c.children.count
                ? was.ratios
                : Array(repeating: 1.0 / Double(max(c.children.count, 1)), count: c.children.count)
        } else {
            c.layout = .splitV
            c.ratios = Array(repeating: 1.0 / Double(max(c.children.count, 1)), count: c.children.count)
        }
        c.origin = nil
        var copy = self
        copy.root = replacing(root, at: sp, with: .container(c))
        return copy.refocused()
    }

    /// Re-point every stack on the way to the focused window at it, after a
    /// structural change. No focus, nothing to point at.
    private func refocused() -> Tree {
        guard let focus else { return self }
        return focusing(focus)
    }

    /// `stack side <dir>`: every window on that side of the layout in one
    /// stack, and the other side left alone. Again to undo.
    ///
    /// The side is a child of the outermost split that runs along `dir`'s
    /// axis, found on the way down to the focused window: in the default
    /// spiral, `[1 | [2 / [3 | 4]]]`, `stack side east` stacks 2, 3 and 4 and
    /// keeps 1 on the west half. `stack toggle` could not say this — it
    /// stacks the focused window's parent, which on 2 is the pair
    /// "2, and the 3|4 split", so the right half came back as a stack with a
    /// split inside it.
    ///
    /// The side's windows are flattened into one stack, focused one in front
    /// if it is on that side. The subtree it replaced is recorded, so undoing
    /// puts back exactly that arrangement, ratios included.
    public func stackingSide(_ dir: Direction) -> Tree {
        guard let root, let path = sidePath(towards: dir), let side = nodeAt(root, path: path) else {
            return self
        }
        if case .container(let c) = side, c.layout == .stack { return unstacking(at: path) }
        let ids = side.windows
        guard ids.count > 1 else { return self }
        var stack = Container(
            layout: .stack,
            children: ids.map { .window($0) },
            active: focus.flatMap { ids.firstIndex(of: $0) } ?? 0
        )
        stack.origin = StackOrigin(scope: .subtree, node: side)
        var copy = self
        copy.root = replacing(root, at: path, with: .container(stack))
        // A zoomed window on that side would sit over its own stack.
        if let zoomed = fullscreen, ids.contains(zoomed) { copy.fullscreen = nil }
        return copy.refocused()
    }

    /// The path to the `dir` side of the outermost split along its axis,
    /// walking from the root towards focus (the first child when nothing is
    /// focused). Nil when no split on that path runs that way. A stack ends
    /// the walk: its members share one frame, so it has no sides.
    private func sidePath(towards dir: Direction) -> [Int]? {
        guard let root else { return nil }
        let axis: ContainerLayout = (dir == .east || dir == .west) ? .splitV : .splitH
        let toFocus = focus.flatMap { pathTo(root, target: $0) } ?? []
        var path: [Int] = []
        var node = root
        while case .container(let c) = node, c.layout != .stack, !c.children.isEmpty {
            if c.layout == axis {
                return path + [(dir == .east || dir == .south) ? c.children.count - 1 : 0]
            }
            let next = toFocus.count > path.count ? toFocus[path.count] : 0
            guard c.children.indices.contains(next) else { return nil }
            path.append(next)
            node = c.children[next]
        }
        return nil
    }

    /// `stack all`: every window on the space in one stack, the focused one
    /// in front — the "one window at a time here" gesture. Again to undo: a
    /// space that is already one stack goes back to side by side, the same
    /// way `stack toggle` takes a window back out.
    public func stackingAll() -> Tree {
        guard let root, let focused = focus, root.windows.contains(focused) else { return self }
        if case .container(let c) = root, c.layout == .stack { return unstacking() }
        let ids = root.windows
        guard ids.count > 1 else { return self }
        var copy = self
        var stack = Container(
            layout: .stack,
            children: ids.map { .window($0) },
            active: ids.firstIndex(of: focused) ?? 0
        )
        stack.origin = StackOrigin(scope: .subtree, node: root)
        copy.root = .container(stack)
        copy.fullscreen = nil
        return copy.focusing(focused)
    }

    /// `stack move <dir>`: take the focused window out of its slot and put it
    /// in the stack of the neighbour that way, making that neighbour a stack
    /// if it is not one yet. The mirror of `stack split`, which pulls the
    /// neighbour into *your* slot instead.
    public func movingIntoStack(towards dir: Direction, frames: [WindowID: Frame]) -> Tree {
        guard root != nil, let focused = focus else { return self }
        guard let neighbor = Reducer.neighbour(of: focused, in: frames, towards: dir) else { return self }
        var tree = removing(focused)
        guard let r = tree.root else { return self }
        if let sp = stackPath(in: r, target: neighbor) {
            tree.root = appendToStack(r, target: neighbor, newID: focused, at: sp)
        } else {
            var stack = Container(
                layout: .stack,
                children: [.window(neighbor), .window(focused)],
                active: 1
            )
            if let original = root { stack.origin = StackOrigin(scope: .root, node: original) }
            tree.root = replaceLeaf(r, target: neighbor, with: .container(stack))
        }
        return tree.focusing(focused)
    }

    /// Move a window one step in a direction — i3's `move`, AeroSpace's
    /// `move` (the 0.6+ what-you-see-is-what-moves one), yabai's
    /// `window --warp`.
    ///
    /// A step is about position, and position is what the tree exists for:
    /// the tile a window owns. What changes is what the tile holds, not how
    /// many tiles the screen has — putting a third full-height column beside a
    /// two-pane layout redesigned it instead of moving a window. Two readings,
    /// decided by the tree the window is in:
    ///
    /// ```
    ///   +-------+-------+       Within one split — the row pair at top,
    ///   |       |   B   |       the column pair at right — a step is a
    ///   |   A   +-------+       trade: the window takes the neighbour
    ///   |       |   C   |       slot's whole frame, sizes carried over,
    ///   +-------+-------+       because the two already own equivalent
    ///                           space. A told east ends `splitH[B, C] | A`.
    ///
    ///   A step into *another* tile joins it. B told west shares A's
    ///   tall left half — B above A — and the right column is untouched:
    ///   no third full-height column appeared under a one-step command.
    ///   +-------+-------+
    ///   |   B   |       |
    ///   +-------+   A   |
    ///   |   A   |       |
    ///   +-------+-------+
    /// ```
    ///
    /// The rule, in full:
    ///
    /// - The window's **immediate container running along `dir`'s axis with a
    ///   sibling that way** — trade places with the sibling, ratios included,
    ///   so both windows keep their size. A step down a row means "one row
    ///   down", not "one window to the lower row's place".
    /// - **A stack** runs along no axis, so a stacked window walks straight
    ///   out of the stack one press at a time — the one place the climb below
    ///   is still needed. `stack move <dir>` is the verb for putting one in.
    /// - Otherwise the window **joins the nearest tile in `dir`**, split by
    ///   the aspect rule arrival `inserting(_:in:config:)` uses, and it lands
    ///   on the edge it moved towards — west/north taking the first slot of
    ///   the shared tile, east/south the second. The frames of the tree the
    ///   move starts from come in with the call, because the nearest tile is
    ///   found in the layout, not in the structure.
    /// - **No tile that way** — the window is already against that edge, or
    ///   it is the only window — does nothing, deliberately. yabai fails here
    ///   too, and that failure is what lets `{ move east } || { … }` in a
    ///   keybind fall through instead of quietly rearranging something.
    ///
    /// `swapping(_:_:)` is still there, behind `swap <dir>`, for trading
    /// frames across a tile boundary — the literal exchange.
    public func moving(_ id: WindowID, towards dir: Direction, frames: [WindowID: Frame]) -> Tree {
        guard let root, root.windows.contains(id), fullscreen == nil else { return self }
        guard let path = pathTo(root, target: id), !path.isEmpty else { return self }
        let axis: ContainerLayout = (dir == .west || dir == .east) ? .splitV : .splitH
        let forward = (dir == .east || dir == .south)

        // The immediate container decides. Split along `dir`'s axis with a
        // sibling that way: trade — the two windows already own equivalent
        // space, so "one step" means trading slots, sizes carried over.
        if case .container(let parent)? = nodeAt(root, path: Array(path.dropLast())),
           parent.layout == axis
        {
            let idx = path.last!
            let target = idx + (forward ? 1 : -1)
            if parent.children.indices.contains(target) {
                return exchanging(at: Array(path.dropLast()), idx, target).focusing(id)
            }
        }

        // No split that way beside the window. A stack member still walks out
        // FIRST — its container runs along no axis, so the climb below is the
        // only way out; a tile to join would strand one stackmate inside
        // another window's tile, which `stack move <dir>` alone does.
        if case .container(let parent)? = nodeAt(root, path: Array(path.dropLast())),
           parent.layout == .stack
        {
            // Deepest first: the nearest ancestor that can take the step is
            // the one that makes it a *step* rather than a leap across the
            // layout. Off the end of a container: keep climbing — that climb
            // is exactly what "move out of the container you are in" means.
            for depth in stride(from: path.count - 1, through: 0, by: -1) {
                guard case .container(let anc)? = nodeAt(root, path: Array(path.prefix(depth))),
                      anc.layout == axis
                else { continue }
                let idx = path[depth]
                let target = idx + (forward ? 1 : -1)
                guard anc.children.indices.contains(target) else { continue }
                if depth == path.count - 1 {
                    return exchanging(at: Array(path.prefix(depth)), idx, target).focusing(id)
                }
                return lifting(id, toLevel: Array(path.prefix(depth)), beside: idx, forward: forward)
                    .focusing(id)
            }
            return self
        }

        // Between tiles: the tile nearest in `dir`, and join it. The captured
        // slot survives the removal below — the removed window's share is
        // handed to siblings east/south of the containers it lived in, and a
        // join target is never one of those siblings, so its frame does not
        // move under it.
        guard let target = Reducer.neighbour(of: id, in: frames, towards: dir),
              let slot = frames[target]
        else { return self }
        return movingInto(id, onto: target, slot: slot, towards: dir)
    }

    /// Join a tile: `id` leaves its slot and takes the one beside `target`,
    /// the pair splitting `target`'s frame. `slot` is `target`'s frame in the
    /// layout the move starts from — stable under the removal, which only
    /// redistributes area to the east/south of the removed window.
    private func movingInto(
        _ id: WindowID, onto target: WindowID, slot: Frame, towards dir: Direction
    ) -> Tree {
        guard let root, root.windows.contains(id), id != target, root.windows.contains(target)
        else { return self }
        var copy = removing(id)
        guard let pruned = copy.root, pruned.windows.contains(target) else { return self }
        switch insertion {
        case .bsp:
            // The aspect rule arrival `inserting(_:in:config:)` uses: a wider
            // than tall slot goes side-by-side, a taller one top/bottom —
            // whatever leaves both panes usable. A tie (square slot) goes
            // side-by-side: displays are wide, that is where the room is.
            let split: ContainerLayout = slot.width >= slot.height ? .splitV : .splitH
            copy.root = insertBSP(pruned, target: target, newID: id, split: split)
        case .manual:
            // A manual tree stays flat: the newcomer goes beside the leaf it
            // joins with equal shares, matching what arrival does there.
            copy.root = insertManual(pruned, target: target, newID: id)
        }
        // Both insertions put the newcomer *after* the tile it joined. Moving
        // west or north, the window takes the edge it moved towards instead:
        // the pair trade, which for the fresh two-child container this always
        // is (or the flat run a manual insert went into) exchanges the two.
        if dir == .west || dir == .north,
           let path = pathTo(copy.root!, target: id), let idx = path.last, idx > 0
        {
            copy = copy.exchanging(at: Array(path.dropLast()), idx - 1, idx)
        }
        return copy.focusing(id)
    }

    /// Trade two children of one container, carrying their ratios with them —
    /// so the pair swap sides *and* sizes, and neither is resized by having
    /// moved.
    private func exchanging(at containerPath: [Int], _ i: Int, _ j: Int) -> Tree {
        guard let root, case .container(var c)? = nodeAt(root, path: containerPath),
              c.children.indices.contains(i), c.children.indices.contains(j)
        else { return self }
        c.children.swapAt(i, j)
        if c.ratios.indices.contains(i), c.ratios.indices.contains(j) { c.ratios.swapAt(i, j) }
        var copy = self
        copy.root = replacing(root, at: containerPath, with: .container(c))
        return copy
    }

    /// Pull `id` out of wherever it is and insert it as a child of the
    /// container at `levelPath`, immediately beside the child it came from.
    ///
    /// Removal happens first and can collapse containers under it — a
    /// two-member column becomes a bare window — so the insertion index is
    /// resolved against the tree *after* the removal, never before. Working
    /// from the pre-removal indices is how this kind of edit puts the window
    /// one slot off, or off the end.
    private func lifting(
        _ id: WindowID, toLevel levelPath: [Int], beside child: Int, forward: Bool
    ) -> Tree {
        guard let root else { return self }
        // What sits at that level's `child` slot right now. After the removal
        // it may have collapsed into something else, so it is found again by
        // identity rather than by index.
        guard case .container(let before)? = nodeAt(root, path: levelPath),
              before.children.indices.contains(child)
        else { return self }
        let cameFrom = before.children[child].windows.filter { $0 != id }
        let (pruned, _) = removeNode(root, id: id)
        guard let pruned else { return self }
        guard case .container(var c)? = nodeAt(pruned, path: levelPath) else {
            // The level itself collapsed — the window being moved was all that
            // kept it a container. There is nothing left to move it beside.
            return self
        }
        // The slot it left, wherever it ended up after the collapse.
        let landing = c.children.firstIndex { node in
            !Set(node.windows).isDisjoint(with: cameFrom)
        } ?? min(child, c.children.count)
        let at = forward ? landing + 1 : landing
        c.children.insert(.window(id), at: min(max(at, 0), c.children.count))
        c.ratios = Array(repeating: 1.0 / Double(c.children.count), count: c.children.count)
        c.active = min(c.active, max(c.children.count - 1, 0))
        var copy = self
        copy.root = replacing(pruned, at: levelPath, with: .container(c))
        return copy
    }

    /// Resize the focused window along an axis by points (positive grows).
    /// Finds the nearest ancestor container on that axis and shifts the ratio
    /// between the focused child and its neighbour. Clamped to [0.1, 0.9].
    public func resizing(focused id: WindowID, axis: ResizeAxis, delta: Double, totalSize: Double) -> Tree {
        guard totalSize > 0, let root else { return self }
        var copy = self
        copy.root = resizeNode(root, target: id, axis: axis, deltaPoints: delta, totalSize: totalSize)
        return copy
    }

    /// Rebalance every container to equal ratios.
    public func balanced() -> Tree {
        guard let root else { return self }
        var copy = self
        copy.root = balanceNode(root)
        return copy
    }
}

public enum ResizeAxis: Sendable {
    case horizontal  // west/east — needs a splitV ancestor
    case vertical    // north/south — needs a splitH ancestor
}

/// Spiral insertion (dwm Fibonacci style): the focused leaf always splits
/// with the pending orientation, which alternates every insertion — never
/// per depth. With focus-follows-new this nests master-left, top-right,
/// bottom-right, right-of-that, below-again, …
private func insertBSP(_ node: Node, target: WindowID, newID: WindowID, split: ContainerLayout) -> Node {
    switch node {
    case .window(let id) where id == target:
        // New window goes second; focus (set by caller) moves to it.
        let container = Container(layout: split, children: [.window(id), .window(newID)])
        return .container(container)
    case .window:
        return node
    case .container(var c):
        c.children = c.children.map { insertBSP($0, target: target, newID: newID, split: split) }
        return .container(c)
    }
}

private func insertManual(_ node: Node, target: WindowID, newID: WindowID) -> Node {
    switch node {
    case .window(let id) where id == target:
        // Without a parent container we must create one; default to side-by-side.
        return .container(Container(layout: .splitV, children: [.window(id), .window(newID)]))
    case .window:
        return node
    case .container(var c):
        if node.windows.contains(target) && c.children.contains(where: { $0.windows.contains(target) }) {
            // If the target is a direct child leaf, append beside it.
            if let idx = c.children.firstIndex(where: {
                if case .window(let id) = $0 { return id == target }
                return false
            }) {
                c.children.insert(.window(newID), at: idx + 1)
                c.ratios = Array(repeating: 1.0 / Double(c.children.count), count: c.children.count)
                return .container(c)
            }
        }
        c.children = c.children.map { insertManual($0, target: target, newID: newID) }
        return .container(c)
    }
}

/// Returns (surviving node or nil, focus fallback).
private func removeNode(_ node: Node, id: WindowID) -> (Node?, WindowID?) {
    switch node {
    case .window(let wid):
        return wid == id ? (nil, nil) : (node, nil)
    case .container(let c):
        var children: [Node] = []
        var keptRatios: [Double] = []
        let ratios = c.ratios.count == c.children.count
            ? c.ratios : Array(repeating: 1.0 / Double(max(c.children.count, 1)), count: c.children.count)
        var fallback: WindowID?
        for (i, child) in c.children.enumerated() {
            let (kept, fb) = removeNode(child, id: id)
            if let kept {
                children.append(kept)
                keptRatios.append(ratios[i])
            }
            // Nearest surviving sibling: last kept leaf before the hole, else first after.
            if kept != nil { fallback = kept?.windows.last ?? fallback }
            else if fallback == nil { fallback = fb }
        }
        if children.isEmpty { return (nil, fallback) }
        if children.count == 1 { return (children[0], fallback ?? children[0].windows.first) }
        var collapsed = c
        collapsed.children = children
        // The removed child's share goes to the others in proportion, and a
        // container that lost nothing keeps its ratios exactly. Evening out
        // every surviving container — which this used to do — flattened
        // every split the user had dragged or resized, all over the tree,
        // whenever any window closed, floated or moved away.
        let sum = keptRatios.reduce(0, +)
        collapsed.ratios = sum > 0
            ? keptRatios.map { $0 / sum }
            : Array(repeating: 1.0 / Double(children.count), count: children.count)
        return (.container(collapsed), fallback ?? children[0].windows.first)
    }
}

private func swapNodes(_ node: Node, a: WindowID, b: WindowID) -> Node {
    switch node {
    case .window(let id):
        if id == a { return .window(b) }
        if id == b { return .window(a) }
        return node
    case .container(var c):
        c.children = c.children.map { swapNodes($0, a: a, b: b) }
        return .container(c)
    }
}

/// The innermost split along `axis` that holds the window does the resizing:
/// it owns the border next to the window. Resizing the outermost one moved a
/// border across the screen instead and shared the step between everything
/// on that side of it — in a nested layout a 40-point step grew the window by
/// 20 and its neighbour by 20.
private func resizeNode(_ node: Node, target: WindowID, axis: ResizeAxis, deltaPoints: Double, totalSize: Double) -> Node {
    guard case .container(var c) = node else { return node }
    let wantsV = (axis == .horizontal && c.layout == .splitV)
        || (axis == .vertical && c.layout == .splitH)
    if let idx = c.children.firstIndex(where: { $0.windows.contains(target) }) {
        // `totalSize` is this node's extent along the axis; a child of a split
        // along it gets its share, so the step stays in points at any depth.
        let share = wantsV ? normalizedRatios(c.ratios, count: c.children.count)[idx] : 1
        let inner = resizeNode(
            c.children[idx], target: target, axis: axis, deltaPoints: deltaPoints, totalSize: totalSize * share
        )
        // Unchanged below: no split that way, or it is at its limit — this
        // one takes the step.
        if inner != c.children[idx] {
            c.children[idx] = inner
            return .container(c)
        }
    }
    if wantsV, let idx = c.children.firstIndex(where: { $0.windows.contains(target) }) {
        // Grow focused child, shrink the neighbour that shares its edge.
        // Last child grows against the previous sibling, others against next.
        let neighbour = (idx + 1 < c.children.count) ? idx + 1 : idx - 1
        guard neighbour >= 0, neighbour != idx else { return node }
        var ratios = normalizedRatios(c.ratios, count: c.children.count)
        let delta = deltaPoints / totalSize
        let newFocused = min(max(ratios[idx] + delta, 0.1), 0.9)
        let applied = newFocused - ratios[idx]
        ratios[idx] = newFocused
        ratios[neighbour] -= applied
        c.ratios = ratios
        return .container(c)
    }
    return .container(c)
}

private func balanceNode(_ node: Node) -> Node {
    switch node {
    case .window: return node
    case .container(var c):
        c.children = c.children.map { balanceNode($0) }
        c.ratios = Array(repeating: 1.0 / Double(max(c.children.count, 1)), count: c.children.count)
        return .container(c)
    }
}

private func normalizedRatios(_ ratios: [Double], count: Int) -> [Double] {
    guard ratios.count == count, !ratios.isEmpty else {
        return Array(repeating: 1.0 / Double(max(count, 1)), count: count)
    }
    let sum = ratios.reduce(0, +)
    guard sum > 0 else {
        return Array(repeating: 1.0 / Double(count), count: count)
    }
    return ratios.map { $0 / sum }
}

// MARK: - Stack + path helpers

/// Float layout (M6): weft never positions these windows. Membership order
/// (last = front) + the user's own frames, remembered so re-entering float
/// restores the arrangement.
public struct FloatState: Sendable, Equatable {
    public var order: [WindowID]
    public var remembered: [WindowID: Frame]
    public var focus: WindowID?

    public init(order: [WindowID] = [], remembered: [WindowID: Frame] = [:], focus: WindowID? = nil) {
        self.order = order
        self.remembered = remembered
        self.focus = focus
    }

    public var windows: [WindowID] { order }

    public func inserting(_ id: WindowID) -> FloatState {
        if order.contains(id) { return focusing(id) }
        var copy = self
        copy.order.append(id)
        copy.focus = id
        return copy
    }

    public func removing(_ id: WindowID) -> FloatState {
        var copy = self
        copy.order.removeAll(where: { $0 == id })
        copy.remembered.removeValue(forKey: id)
        if focus == id {
            copy.focus = copy.order.first
        }
        return copy
    }

    public func focusing(_ id: WindowID) -> FloatState {
        guard order.contains(id) else { return self }
        var copy = self
        copy.focus = id
        return copy
    }
}

/// A tiling tree as `membership.json` keeps it across a daemon restart: the
/// shape, the ratios, which stack member is in front, and the focus.
///
/// Without it a restart put every window back in its workspace but rebuilt
/// each tree by inserting the windows one by one, so a layout the user had
/// arranged came back as whatever the insertion order made of it. Window ids
/// hold for a boot, which is exactly how long the file is believed.
///
/// Not kept: a stack's record of what it replaced (it unstacks side by side
/// after a restart), and the one-shot split and zoom, which are about the
/// moment rather than the arrangement.
public struct SavedTree: Codable, Sendable, Equatable {
    public indirect enum SavedNode: Codable, Sendable, Equatable {
        case window(WindowID)
        case container(layout: ContainerLayout, ratios: [Double], active: Int, children: [SavedNode])
    }

    public var root: SavedNode?
    public var focus: WindowID?

    public init(_ tree: Tree) {
        func save(_ node: Node) -> SavedNode {
            switch node {
            case .window(let id): return .window(id)
            case .container(let c):
                return .container(layout: c.layout, ratios: c.ratios, active: c.active, children: c.children.map(save))
            }
        }
        root = tree.root.map(save)
        focus = tree.focus
    }

    /// The tree back, repaired rather than trusted: a container left with
    /// fewer than two children collapses into what it holds, and ratios that
    /// do not match the children are evened out.
    public var tree: Tree {
        func load(_ node: SavedNode) -> Node? {
            switch node {
            case .window(let id): return .window(id)
            case .container(let layout, let ratios, let active, let children):
                let kids = children.compactMap(load)
                guard kids.count > 1 else { return kids.first }
                let sum = ratios.reduce(0, +)
                return .container(ratios.count == kids.count && sum > 0 && ratios.allSatisfy { $0 > 0 }
                    ? Container(layout: layout, children: kids, ratios: ratios.map { $0 / sum }, active: active)
                    : Container(layout: layout, children: kids, active: active))
            }
        }
        let root = self.root.flatMap(load)
        let windows = root?.windows ?? []
        return Tree(root: root, focus: focus.flatMap { windows.contains($0) ? $0 : nil } ?? windows.first)
    }
}

/// Codable snapshot of the tiling tree for `query tree` — containers with
/// layout/active, leaves with window ids. The only way to see stacks.
public struct TreeView: Codable, Sendable, Equatable {
    public var kind: String  // "window" | "splitV" | "splitH" | "stack" | "empty"
    public var window: WindowID?
    public var active: Int?
    public var children: [TreeView]

    public static func of(_ node: Node?) -> TreeView {
        guard let node else {
            return TreeView(kind: "empty", window: nil, active: nil, children: [])
        }
        switch node {
        case .window(let id):
            return TreeView(kind: "window", window: id, active: nil, children: [])
        case .container(let c):
            return TreeView(
                kind: c.layout.rawValue,
                window: nil,
                active: c.layout == .stack ? c.active : nil,
                children: c.children.map(TreeView.of)
            )
        }
    }
}

// MARK: - Stack introspection (the indicator and the click targets)

/// Where a stack's front member sits in it. `index` is 1-based: it is the
/// number drawn for the user, not an array subscript.
public struct StackPosition: Sendable, Equatable {
    public var index: Int
    public var count: Int

    public init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }
}

/// The front member of every stack of two or more, and where it sits.
///
/// A stack is invisible otherwise: its slot looks like one window. This says
/// "there are three windows here and this is the first" without cycling
/// through them.
public func stackPositions(in tree: Tree) -> [WindowID: StackPosition] {
    guard let root = tree.root else { return [:] }
    var out: [WindowID: StackPosition] = [:]
    forEachStack(root) { c in
        let active = min(max(c.active, 0), c.children.count - 1)
        if let front = c.children[active].windows.first {
            out[front] = StackPosition(index: active + 1, count: c.children.count)
        }
    }
    return out
}

/// Every stack member that is not the front one.
///
/// The layout gives these a slot inset from the top, so each shows as a strip
/// above the member in front — which is what makes a stack legible and what
/// the peek zones make clickable. What it must not do is put a *border* round
/// them: a border traces a window's bounds, and a window with eight points
/// showing has no bounds worth tracing. All the user sees is the top edge, a
/// hard line above a window that nothing explains — reported, reasonably, as a
/// stray white line over the desktop.
public func hiddenStackMembers(in tree: Tree) -> Set<WindowID> {
    guard let root = tree.root else { return [] }
    var out: Set<WindowID> = []
    forEachStack(root) { c in
        let active = min(max(c.active, 0), c.children.count - 1)
        for (i, child) in c.children.enumerated() where i != active {
            out.formUnion(child.windows)
        }
    }
    return out
}

/// A strip of a hidden stack member that shows behind the front one, and the
/// member it belongs to.
public struct StackPeek: Sendable, Equatable {
    public var rect: Frame
    public var member: WindowID

    public init(rect: Frame, member: WindowID) {
        self.rect = rect
        self.member = member
    }
}

/// Where each stack's hidden members peek out, as click targets.
///
/// The layout insets every member from the top by its distance from the
/// front one (`maxVisibleStackLayers`), so the members behind show as a row
/// of title-bar strips above it. Each distinct top edge up to the front
/// member's is one strip, owned by whichever member is frontmost at that
/// edge — members past the visible-layer cap share an edge, and the one in
/// front of the others is the one a click there actually lands on.
///
/// Nothing is clickable when the offset is too thin to hit, or while a
/// window is zoomed over the whole space.
public func stackPeeks(
    in tree: Tree, frames: [WindowID: Frame], minHeight: Double = 4
) -> [StackPeek] {
    guard let root = tree.root, tree.fullscreen == nil else { return [] }
    var out: [StackPeek] = []
    forEachStack(root) { c in
        let active = min(max(c.active, 0), c.children.count - 1)
        // z mirrors `stackChain`: the front member on top, then later
        // children above earlier ones.
        var ownerByTop: [Double: (wid: WindowID, frame: Frame, z: Int)] = [:]
        for (i, child) in c.children.enumerated() {
            guard let wid = child.windows.first, let f = frames[wid] else { continue }
            let z = i == active ? Int.max : i
            if let cur = ownerByTop[f.y], cur.z >= z { continue }
            ownerByTop[f.y] = (wid, f, z)
        }
        let tops = ownerByTop.keys.sorted()
        // The last edge is the front member's own frame, not a strip.
        for (i, top) in tops.enumerated() where i + 1 < tops.count {
            let height = tops[i + 1] - top
            guard height >= minHeight, let owner = ownerByTop[top] else { continue }
            out.append(StackPeek(
                rect: Frame(x: owner.frame.x, y: top, width: owner.frame.width, height: height),
                member: owner.wid
            ))
        }
    }
    return out
}

private func forEachStack(_ node: Node, _ body: (Container) -> Void) {
    guard case .container(let c) = node else { return }
    if c.layout == .stack, c.children.count > 1 { body(c) }
    for child in c.children { forEachStack(child, body) }
}

/// Order chain for fronting `wid`: first window of each stack child, with the
/// active member's child LAST. The renderer orders each consecutive pair
/// (chain[i+1] above chain[i]), leaving the active member front with the
/// others in stable children order. Nil when `wid` isn't in a multi-member
/// stack (nothing is hidden — no ordering needed).
public func stackChain(root: Node, containing wid: WindowID) -> [WindowID]? {
    guard let sp = stackPath(in: root, target: wid),
          let node = nodeAt(root, path: sp),
          case .container(let c) = node, c.layout == .stack, c.children.count > 1
    else { return nil }
    var idx = Array(c.children.indices)
    let active = min(max(c.active, 0), idx.count - 1)
    idx.remove(at: active)
    idx.append(active)
    let chain = idx.compactMap { c.children[$0].windows.first }
    return chain.count > 1 ? chain : nil
}

/// Point every ancestor stack at the child leading to `target`.
private func fixActive(_ node: Node, target: WindowID) -> Node {
    guard case .container(var c) = node else { return node }
    if c.layout == .stack,
       let idx = c.children.firstIndex(where: { $0.windows.contains(target) })
    {
        c.active = idx
    }
    c.children = c.children.map { fixActive($0, target: target) }
    return .container(c)
}

/// Clamp stack actives and repair ratio counts after structural ops.
private func clampedNode(_ node: Node) -> Node {
    switch node {
    case .window: return node
    case .container(var c):
        c.children = c.children.map(clampedNode)
        if c.ratios.count != c.children.count {
            c.ratios = Array(
                repeating: 1.0 / Double(max(c.children.count, 1)),
                count: c.children.count
            )
        }
        c.active = min(max(c.active, 0), max(c.children.count - 1, 0))
        return .container(c)
    }
}

/// Child-index path from root to the leaf `target`. Nil if absent.
private func pathTo(_ node: Node, target: WindowID, trail: [Int] = []) -> [Int]? {
    switch node {
    case .window(let id):
        return id == target ? trail : nil
    case .container(let c):
        for (i, child) in c.children.enumerated() {
            if let found = pathTo(child, target: target, trail: trail + [i]) {
                return found
            }
        }
        return nil
    }
}

private func nodeAt(_ node: Node, path: [Int]) -> Node? {
    var current = node
    for idx in path {
        guard case .container(let c) = current,
              c.children.indices.contains(idx)
        else { return nil }
        current = c.children[idx]
    }
    return current
}

private func replacing(_ node: Node, at path: [Int], with replacement: Node) -> Node {
    guard let first = path.first else { return replacement }
    guard case .container(var c) = node, c.children.indices.contains(first) else { return node }
    c.children[first] = replacing(c.children[first], at: Array(path.dropFirst()), with: replacement)
    return .container(c)
}

private func replaceLeaf(_ node: Node, target: WindowID, with replacement: Node) -> Node {
    guard let path = pathTo(node, target: target) else { return node }
    return replacing(node, at: path, with: replacement)
}

/// Path of the nearest ancestor `.stack` container of `target`. Nil when the
/// target isn't inside any stack.
private func stackPath(in node: Node, target: WindowID) -> [Int]? {
    guard let leaf = pathTo(node, target: target) else { return nil }
    for len in stride(from: leaf.count - 1, through: 0, by: -1) {
        let prefix = Array(leaf.prefix(len))
        if let n = nodeAt(node, path: prefix),
           case .container(let c) = n, c.layout == .stack
        {
            return prefix
        }
    }
    return nil
}

/// Append a member to the stack containing `target` (found directly, or at
/// the known path). New member becomes active; the caller re-focuses.
private func appendToStack(_ node: Node, target: WindowID, newID: WindowID, at known: [Int]? = nil) -> Node {
    let sp: [Int]?
    if let known {
        sp = known
    } else {
        sp = stackPath(in: node, target: target)
    }
    guard let sp,
          let found = nodeAt(node, path: sp),
          case .container(var c) = found, c.layout == .stack
    else { return node }
    c.children.append(.window(newID))
    c.ratios = Array(repeating: 1.0 / Double(c.children.count), count: c.children.count)
    c.active = c.children.count - 1
    return replacing(node, at: sp, with: .container(c))
}

extension ContainerLayout {
    public var toggled: ContainerLayout { self == .splitV ? .splitH : .splitV }
}
