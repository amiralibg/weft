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

    public init(
        innerGap: Double = 8,
        outerGap: OuterGap = OuterGap(top: 8, bottom: 8, left: 8, right: 8),
        stackOffset: Double = 8
    ) {
        self.innerGap = innerGap
        self.outerGap = outerGap
        self.stackOffset = stackOffset
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
        layoutNode(root, in: inset, innerGap: config.innerGap, stackOffset: config.stackOffset, out: &out)
        out[fs] = inset
        return out
    }
    // Single window: no inner gap (edge-to-edge inside the outer inset).
    if case .window(let id) = root { return [id: inset] }
    var out: [WindowID: Frame] = [:]
    layoutNode(root, in: inset, innerGap: config.innerGap,
               stackOffset: config.stackOffset, out: &out)
    return out
}

/// How many layers of a stack are drawn peeking out behind the active one.
///
/// Without a cap, a six-window stack shrinks its active member by six offsets
/// and the slot visibly shrinks as you add windows. Three edges is enough to
/// read as "there is a pile here"; past that it is just lost space.
private let maxVisibleStackLayers = 3

private func layoutNode(
    _ node: Node, in frame: Frame, innerGap: Double, stackOffset: Double,
    out: inout [WindowID: Frame]
) {
    switch node {
    case .window(let id):
        out[id] = frame
    case .container(let c):
        let n = c.children.count
        guard n > 0 else { return }
        if n == 1 {
            layoutNode(c.children[0], in: frame, innerGap: innerGap,
                       stackOffset: stackOffset, out: &out)
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
                           stackOffset: stackOffset, out: &out)
            }
            return
        }
        let totalGap = innerGap * Double(n - 1)
        switch c.layout {
        case .splitV:
            let avail = max(frame.width - totalGap, 0)
            var x = frame.x
            for (i, child) in c.children.enumerated() {
                let ratio = i < c.ratios.count ? c.ratios[i] : 1.0 / Double(n)
                // Last child takes the remainder so rounding never leaks/loses a pixel.
                let w = (i == n - 1) ? (frame.x + frame.width - x) : avail * ratio
                layoutNode(
                    child,
                    in: Frame(x: x, y: frame.y, width: max(w, 1), height: frame.height),
                    innerGap: innerGap, stackOffset: stackOffset, out: &out
                )
                x += w + innerGap
            }
        case .splitH:
            let avail = max(frame.height - totalGap, 0)
            var y = frame.y
            for (i, child) in c.children.enumerated() {
                let ratio = i < c.ratios.count ? c.ratios[i] : 1.0 / Double(n)
                let h = (i == n - 1) ? (frame.y + frame.height - y) : avail * ratio
                layoutNode(
                    child,
                    in: Frame(x: frame.x, y: y, width: frame.width, height: max(h, 1)),
                    innerGap: innerGap, stackOffset: stackOffset, out: &out
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
            copy.root = .container(Container(layout: .stack, children: [.window(focused)], active: 0))
            return copy.focusing(focused)
        }
        let parentPath = Array(path.dropLast())
        guard let parent = nodeAt(root, path: parentPath),
              case .container(var c) = parent,
              c.layout != .stack
        else { return self }
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
            tree.root = replaceLeaf(
                r, target: focused,
                with: .container(Container(
                    layout: .stack,
                    children: [.window(focused), .window(neighbor)],
                    active: 0
                ))
            )
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

    /// Convert the focused stack back to a vertical split. Not in a
    /// stack → no-op.
    public func unstacking() -> Tree {
        guard let root, let focused = focus,
              let sp = stackPath(in: root, target: focused),
              let node = nodeAt(root, path: sp),
              case .container(var c) = node
        else { return self }
        c.layout = .splitV
        c.ratios = Array(repeating: 1.0 / Double(max(c.children.count, 1)), count: c.children.count)
        var copy = self
        copy.root = replacing(root, at: sp, with: .container(c))
        return copy.focusing(focused)
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
        var fallback: WindowID?
        for child in c.children {
            let (kept, fb) = removeNode(child, id: id)
            if let kept { children.append(kept) }
            // Nearest surviving sibling: last kept leaf before the hole, else first after.
            if kept != nil { fallback = kept?.windows.last ?? fallback }
            else if fallback == nil { fallback = fb }
        }
        if children.isEmpty { return (nil, fallback) }
        if children.count == 1 { return (children[0], fallback ?? children[0].windows.first) }
        var collapsed = c
        collapsed.children = children
        collapsed.ratios = Array(repeating: 1.0 / Double(children.count), count: children.count)
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

private func resizeNode(_ node: Node, target: WindowID, axis: ResizeAxis, deltaPoints: Double, totalSize: Double) -> Node {
    guard case .container(var c) = node else { return node }
    let wantsV = (axis == .horizontal && c.layout == .splitV)
        || (axis == .vertical && c.layout == .splitH)
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
    c.children = c.children.map { resizeNode($0, target: target, axis: axis, deltaPoints: deltaPoints, totalSize: totalSize) }
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
