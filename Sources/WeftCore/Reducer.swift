// WeftCore/Reducer.swift — pure reducer: (State, Command) -> (State, [Mutation]).
//
// The core serial queue owns State; the platform layer applies Mutations.
// No AX here, no I/O — fully unit-testable.

public struct State: Sendable, Equatable {
    public var tree: Tree
    public var screen: Frame
    public var config: TilingConfig

    public init(tree: Tree = Tree(), screen: Frame, config: TilingConfig = TilingConfig()) {
        self.tree = tree
        self.screen = screen
        self.config = config
    }
}

public enum Mutation: Sendable, Equatable {
    case setFrame(WindowID, Frame)
    case focusWindow(WindowID)
    /// Z-order only: front the window without touching its frame (stack
    /// member switch — one SLSOrderWindow, no AX). The platform raises after
    /// applying setFrame mutations, in array order.
    case raise(WindowID)
}

public enum Reducer {
    public static func reduce(_ state: State, _ command: Command) -> (State, [Mutation]) {
        var tree = state.tree
        let state0 = state

        switch command {
        case .insert(let id):
            tree = tree.inserting(id, in: state.screen, config: state.config)
        case .remove(let id):
            tree = tree.removing(id)
        case .setFocus(let id):
            guard tree.windows.contains(id) else { return (state, []) }
            tree.focus = id
            return (State(tree: tree, screen: state.screen, config: state.config), [.focusWindow(id)])
        case .split(let layout):
            // Pins exactly the next insertion; the automatic (aspect-ratio)
            // rule resumes after it (DESIGN §4.1).
            tree.pendingSplit = layout
            return (State(tree: tree, screen: state.screen, config: state.config), [])
        case .insertion(let mode):
            tree.insertion = mode
            return (State(tree: tree, screen: state.screen, config: state.config), [])
        case .balance:
            tree = tree.balanced()
        case .stack(let sub):
            return reduceStack(state, sub)
        case .focus(let dir):
            let frames = layout(tree, in: state.screen, config: state.config)
            guard let focused = tree.focus else { return (state, []) }
            if let next = neighbour(of: focused, in: frames, towards: dir) {
                // `focusing` (not a bare `tree.focus = next`) so every ancestor
                // stack re-points at the child leading to the new window —
                // otherwise focusing into a stack left its active index stale
                // and the wrong member stayed on top.
                tree = tree.focusing(next)
                return (State(tree: tree, screen: state.screen, config: state.config),
                        [.focusWindow(next), .raise(next)])
            }
            // No neighbour that way: cycle within the stack, matching the
            // `--focus east || --focus stack.next` fallback chain that yabai
            // users write by hand in skhd. east/south advance, west/north
            // go back. Outside a stack this is a no-op.
            let cycled = tree.cyclingStack(by: (dir == .east || dir == .south) ? 1 : -1)
            guard cycled != tree, let member = cycled.focus else { return (state, []) }
            return (State(tree: cycled, screen: state.screen, config: state.config),
                    [.focusWindow(member), .raise(member)])
        case .move(let dir):
            let frames = layout(tree, in: state.screen, config: state.config)
            guard let focused = tree.focus,
                  let next = neighbour(of: focused, in: frames, towards: dir)
            else { return (state, []) }
            tree = tree.swapping(focused, next)
            let newState = State(tree: tree, screen: state.screen, config: state.config)
            return (newState, relayoutMutations(state: newState, previous: state0))
        case .resize(let dir, let delta):
            guard let focused = tree.focus else { return (state, []) }
            let total = totalSize(for: dir.axis, screen: state.screen, config: state.config)
            tree = tree.resizing(focused: focused, axis: dir.axis, delta: dir.signed(delta), totalSize: total)
            let newState = State(tree: tree, screen: state.screen, config: state.config)
            return (newState, relayoutMutations(state: newState, previous: state0))
        case .query:
            return (state, [])
        case .toggleFullscreen:
            tree = tree.togglingFullscreen()
            let newState = State(tree: tree, screen: state.screen, config: state.config)
            var mutations = relayoutMutations(state: newState, previous: state0)
            if let fs = tree.fullscreen {
                mutations.append(.raise(fs))
                mutations.append(.focusWindow(fs))
            }
            return (newState, mutations)
        case .toggleSplit:
            tree = tree.togglingSplit()
            let newState = State(tree: tree, screen: state.screen, config: state.config)
            return (newState, relayoutMutations(state: newState, previous: state0))
        case .float:
            // Daemon-level: floating a window is a membership change across
            // every layout kind, not a tree edit.
            return (state, [])
        case .space, .sticky, .focusDisplay, .moveWindowToDisplay, .moveSpaceToDisplay,
             .scroll, .appToggle:
            // Daemon-level verbs (multi-space topology, privileged calls) or
            // scroll-strip commands (reduceScroll owns those). The daemon
            // intercepts them before reduce; reaching here is a programming
            // error, and no-op is the safe response.
            return (state, [])
        }

        let newState = State(tree: tree, screen: state.screen, config: state.config)
        var mutations = relayoutMutations(state: newState, previous: state0)
        // Structural commands that change focus also raise the focused window.
        if let focus = newState.tree.focus, focus != state0.tree.focus {
            mutations.append(.focusWindow(focus))
        }
        return (newState, mutations)
    }

    /// Stack commands: structural op, full relayout (new members need
    /// frames), then raise the focused member so it ends up front.
    static func reduceStack(_ state: State, _ sub: StackCommand) -> (State, [Mutation]) {
        let tree: Tree
        switch sub {
        case .toggle:
            tree = state.tree.togglingStack()
        case .split(let dir):
            let frames = layout(state.tree, in: state.screen, config: state.config)
            tree = state.tree.stackSplitting(towards: dir, frames: frames)
        case .next:
            tree = state.tree.cyclingStack(by: 1)
        case .prev:
            tree = state.tree.cyclingStack(by: -1)
        case .unstack:
            tree = state.tree.unstacking()
        }
        guard tree != state.tree else { return (state, []) }
        let newState = State(tree: tree, screen: state.screen, config: state.config)
        var mutations = relayoutMutations(state: newState, previous: state)
        // Any structural change here re-overlaps frames (wrap/split/unstack)
        // or flips visibility (next/prev) — the focused member ends up front.
        if let focus = tree.focus {
            mutations.append(.raise(focus))
        }
        return (newState, mutations)
    }

    /// Scroll spaces (M5). Geometry focus/warp reuse neighbour() on the
    /// computed strip frames; column jumps move by index (reaching parked
    /// columns — the viewport follows via ensureVisible, and unparking
    /// happens at apply time). Tiling-only commands are safe no-ops.
    public static func reduceScroll(
        _ sc: ScrollState,
        screen: Frame,
        config: TilingConfig,
        command: Command
    ) -> (ScrollState, [Mutation]) {
        let usable = scrollUsable(screen: screen, config: config)
        let usableW = usable.w
        let usableH = usable.h
        var next = sc
        switch command {
        case .insert(let id):
            next = sc.inserting(id)
        case .remove(let id):
            next = sc.removing(id)
        case .setFocus(let id):
            guard sc.windows.contains(id) else { return (sc, []) }
            next = sc.focusing(id)
        case .focus(let dir):
            switch dir {
            case .west:
                next = sc.movingFocusByColumn(-1)
            case .east:
                next = sc.movingFocusByColumn(1)
            case .north:
                next = sc.movingFocusByRow(-1)
            case .south:
                next = sc.movingFocusByRow(1)
            }
        case .move(let dir):
            switch dir {
            case .west:
                next = sc.swappingColumns(-1)
            case .east:
                next = sc.swappingColumns(1)
            case .north:
                next = sc.swappingRowsInFocusedColumn(-1)
            case .south:
                next = sc.swappingRowsInFocusedColumn(1)
            }
        case .resize(let dir, let delta):
            // Column widths on the horizontal axis, row shares on the
            // vertical one. Vertical used to be a no-op, which made the whole
            // resize layer — and mouse border drags — dead on scroll spaces.
            switch dir.axis {
            case .horizontal:
                next = sc.adjustingWidth(dir.signed(delta) / max(usableW, 1))
            case .vertical:
                next = sc.adjustingHeight(dir.signed(delta) / max(usableH, 1))
            }
        case .balance:
            next = ScrollState(
                // Widths back to the default and heights back to equal —
                // balance means "undo every resize on this space".
                columns: sc.columns.map { Column(windows: $0.windows) },
                viewportX: sc.viewportX,
                focusCol: sc.focusCol,
                focusRow: sc.focusRow,
                centerMode: sc.centerMode
            )
        case .scroll(.focusColumn(let d)):
            next = sc.movingFocusByColumn(d)
        case .scroll(.moveColumn(let d)):
            next = sc.movingWindowToColumn(d)
        case .scroll(.widthCycle):
            next = sc.cyclingWidth()
        case .toggleFullscreen:
            next = sc.togglingFullscreen()
            let (frames, _) = scrollLayout(next, screen: screen, config: config)
            var mutations = frames.sorted { $0.key < $1.key }.map { Mutation.setFrame($0.key, $0.value) }
            if let fs = next.fullscreen {
                mutations.append(.raise(fs))
                mutations.append(.focusWindow(fs))
            }
            return (next, mutations)
        case .toggleSplit, .float, .split, .insertion, .stack, .space, .sticky,
             .focusDisplay, .moveWindowToDisplay, .moveSpaceToDisplay, .appToggle, .query:
            return (sc, [])
        }
        guard next != sc else { return (sc, []) }
        next.ensureVisible(next.focusCol, screen: screen, config: config)
        let (frames, _) = scrollLayout(next, screen: screen, config: config)
        var mutations = frames.sorted { $0.key < $1.key }.map { Mutation.setFrame($0.key, $0.value) }
        if next.focusedWindow != sc.focusedWindow, let focus = next.focusedWindow {
            mutations.append(.focusWindow(focus))
        }
        return (next, mutations)
    }

    /// Float spaces (M6): weft never positions these windows, so only
    /// membership/focus commands do anything. Focus changes still raise
    /// (front the focused float) via focusWindow.
    public static func reduceFloat(
        _ fl: FloatState,
        command: Command,
        frames: [WindowID: Frame] = [:]
    ) -> (FloatState, [Mutation]) {
        var next = fl
        switch command {
        case .insert(let id):
            next = fl.inserting(id)
        case .remove(let id):
            next = fl.removing(id)
        case .setFocus(let id):
            guard fl.windows.contains(id) else { return (fl, []) }
            next = fl.focusing(id)
        case .focus(let dir):
            // Directional focus works in float spaces too, scored on the
            // windows' live frames. Overlapping floats have no shared edge, so
            // fall back to the nearest window whose centre lies that way —
            // otherwise alt-h/l simply did nothing on a float space.
            guard let focused = fl.focus, let from = frames[focused] else { return (fl, []) }
            let id = neighbour(of: focused, in: frames, towards: dir)
                ?? nearestByCentre(from: from, in: frames, excluding: focused, towards: dir)
            guard let id else { return (fl, []) }
            next = fl.focusing(id)
        case .move, .resize, .split, .insertion, .balance,
             .stack, .scroll, .space, .sticky, .focusDisplay, .moveWindowToDisplay,
             .moveSpaceToDisplay, .appToggle, .query,
             .toggleFullscreen, .toggleSplit, .float:
            return (fl, [])
        }
        guard next != fl else { return (fl, []) }
        var mutations: [Mutation] = []
        if next.focus != fl.focus, let focus = next.focus {
            mutations.append(.focusWindow(focus))
            mutations.append(.raise(focus))
        }
        return (next, mutations)
    }

    /// Nearest window whose centre lies in `dir`, ranked by distance along that
    /// axis and then by perpendicular offset. Used only where windows can
    /// overlap arbitrarily (float), where edge adjacency does not exist.
    static func nearestByCentre(
        from: Frame,
        in frames: [WindowID: Frame],
        excluding: WindowID,
        towards dir: Direction
    ) -> WindowID? {
        let fx = centerX(from), fy = centerY(from)
        var best: (id: WindowID, along: Double, off: Double)?
        for (id, r) in frames where id != excluding {
            let rx = centerX(r), ry = centerY(r)
            let along: Double
            let off: Double
            switch dir {
            case .west: along = fx - rx; off = abs(ry - fy)
            case .east: along = rx - fx; off = abs(ry - fy)
            case .north: along = fy - ry; off = abs(rx - fx)
            case .south: along = ry - fy; off = abs(rx - fx)
            }
            guard along > 1 else { continue }
            if best == nil || along < best!.along - 1e-9
                || (abs(along - best!.along) <= 1e-9 && off < best!.off)
            {
                best = (id, along, off)
            }
        }
        return best?.id
    }

    /// Full target layout as mutations, sorted by id for determinism.
    /// The platform applier diffs against last-applied frames (§5.2) —
    /// the reducer always emits the complete picture.
    static func relayoutMutations(state: State, previous: State) -> [Mutation] {
        let frames = layout(state.tree, in: state.screen, config: state.config)
        return frames.sorted { $0.key < $1.key }.map { .setFrame($0.key, $0.value) }
    }

    static func totalSize(for axis: ResizeAxis, screen: Frame, config: TilingConfig) -> Double {
        switch axis {
        case .horizontal:
            return max(screen.width - config.outerGap.left - config.outerGap.right, 1)
        case .vertical:
            return max(screen.height - config.outerGap.top - config.outerGap.bottom, 1)
        }
    }

    // MARK: - Directional focus (geometry, not tree walk)

    /// Nearest window sharing an edge in `dir`. Requires perpendicular overlap,
    /// so diagonal windows never steal focus — adjacency in a bsp layout always
    /// shares an edge, so this is exact for tiled spaces.
    static func neighbour(
        of focused: WindowID,
        in frames: [WindowID: Frame],
        towards dir: Direction
    ) -> WindowID? {
        guard let f = frames[focused] else { return nil }
        struct Scored { let id: WindowID; let gap: Double; let off: Double }
        var best: Scored?
        for (id, r) in frames where id != focused {
            // Stackmates share the exact frame — directional keys escape the
            // stack as a unit; cycling (stack next/prev) moves inside it.
            guard r != f else { continue }
            let overlap: Bool
            let gap: Double
            let off: Double
            switch dir {
            case .west:
                overlap = r.y < f.y + f.height - 1 && r.y + r.height > f.y + 1
                gap = f.x - (r.x + r.width)
                off = abs(centerY(r) - centerY(f))
            case .east:
                overlap = r.y < f.y + f.height - 1 && r.y + r.height > f.y + 1
                gap = r.x - (f.x + f.width)
                off = abs(centerY(r) - centerY(f))
            case .north:
                overlap = r.x < f.x + f.width - 1 && r.x + r.width > f.x + 1
                gap = f.y - (r.y + r.height)
                off = abs(centerX(r) - centerX(f))
            case .south:
                overlap = r.x < f.x + f.width - 1 && r.x + r.width > f.x + 1
                gap = r.y - (f.y + f.height)
                off = abs(centerX(r) - centerX(f))
            }
            guard overlap, gap > -2 else { continue }
            if let b = best {
                if gap < b.gap - 1e-9 || (abs(gap - b.gap) <= 1e-9 && off < b.off) {
                    best = Scored(id: id, gap: gap, off: off)
                }
            } else {
                best = Scored(id: id, gap: gap, off: off)
            }
        }
        return best?.id
    }

    private static func centerX(_ f: Frame) -> Double { f.x + f.width / 2 }
    private static func centerY(_ f: Frame) -> Double { f.y + f.height / 2 }
}
