import Testing
@testable import WeftCore

let screen = Frame(x: 0, y: 0, width: 1000, height: 800)

@Test func twoWindowsSplitSideBySide() {
    var tree = Tree()
    tree = tree.inserting(1)
    tree = tree.inserting(2)
    let frames = layout(tree, in: screen, config: .none)
    #expect(frames.count == 2)
    #expect(frames[1]!.x == 0)
    #expect(frames[1]!.width == 500)
    #expect(frames[2]!.x == 500)
    #expect(frames[2]!.width == 500)
    #expect(tree.focus == 2)
}

@Test func fourWindowsBSPAlternates() {
    var tree = Tree()
    for id in [1, 2, 3, 4] as [WindowID] { tree = tree.inserting(id) }
    let frames = layout(tree, in: screen, config: .none)
    #expect(frames.count == 4)
    // BSP alternation: exact tiling, no gaps, no overlap.
    let total = frames.values.reduce(0) { $0 + $1.width * $1.height }
    #expect(abs(total - 1000 * 800) < 1e-6)
    for f in frames.values {
        #expect(f.width >= 1 && f.height >= 1)
    }
}

@Test func gapsInsetAndSplit() {
    var tree = Tree()
    tree = tree.inserting(1)
    tree = tree.inserting(2)
    let config = TilingConfig(
        innerGap: 8,
        outerGap: TilingConfig.OuterGap(top: 8, bottom: 8, left: 8, right: 8)
    )
    let frames = layout(tree, in: screen, config: config)
    // Outer inset shrinks the usable rect.
    #expect(frames[1]!.x == 8)
    #expect(frames[1]!.y == 8)
    // Inner gap between the two halves.
    let rightEdge1 = frames[1]!.x + frames[1]!.width
    #expect(frames[2]!.x - rightEdge1 == 8)
    // Halves are equal inside the inset rect.
    #expect(abs(frames[1]!.width - frames[2]!.width) < 1e-9)
}

@Test func removeCollapsesAndRefocuses() {
    var tree = Tree()
    for id in [1, 2, 3] as [WindowID] { tree = tree.inserting(id) }
    tree = tree.removing(3)
    #expect(!tree.windows.contains(3))
    #expect(tree.windows.count == 2)
    #expect(tree.focus != 3)
    let frames = layout(tree, in: screen, config: .none)
    let total = frames.values.reduce(0) { $0 + $1.width * $1.height }
    #expect(abs(total - 1000 * 800) < 1e-6)
}

@Test func focusMovesByGeometry() {
    var tree = Tree()
    for id in [1, 2] as [WindowID] { tree = tree.inserting(id) }
    // After inserting 1,2 with splitV: 1 west, 2 east, focus 2.
    var state = State(tree: tree, screen: screen, config: .none)
    let (s1, m1) = Reducer.reduce(state, .focus(.west))
    #expect(s1.tree.focus == 1)
    #expect(m1 == [.focusWindow(1), .raise(1)])
    state = s1
    let (s2, m2) = Reducer.reduce(state, .focus(.east))
    #expect(s2.tree.focus == 2)
    #expect(m2 == [.focusWindow(2), .raise(2)])
}

@Test func moveSwapsWindows() {
    var tree = Tree()
    for id in [1, 2] as [WindowID] { tree = tree.inserting(id) }
    let state = State(tree: tree, screen: screen, config: .none)
    // Focus is 2 (east). Move west swaps 1 and 2.
    let (s1, _) = Reducer.reduce(state, .move(.west))
    let frames = layout(s1.tree, in: screen, config: .none)
    #expect(frames[2]!.x == 0)  // moved window now west
    #expect(frames[1]!.x == 500)
    #expect(s1.tree.focus == 2)
}

@Test func resizeGrowsFocused() {
    var tree = Tree()
    for id in [1, 2] as [WindowID] { tree = tree.inserting(id) }
    let state = State(tree: tree, screen: screen, config: .none)
    let before = layout(state.tree, in: screen, config: .none)
    // Focus 2 (east half, 500 wide). Grow it right by 100pt.
    let (s1, _) = Reducer.reduce(state, .resize(.right, 100))
    let after = layout(s1.tree, in: screen, config: .none)
    #expect(after[2]!.width > before[2]!.width)
    #expect(abs(after[2]!.width - 600) < 1e-9)
    #expect(abs(after[1]!.width - 400) < 1e-9)
}

@Test func commandGrammar() throws {
    #expect(try Command.parse("focus west") == .focus(.west))
    #expect(try Command.parse("move north") == .move(.north))
    #expect(try Command.parse("resize right 60") == .resize(.right, 60))
    #expect(try Command.parse("split vertical") == .split(.splitV))
    #expect(try Command.parse("split horizontal") == .split(.splitH))
    #expect(try Command.parse("balance") == .balance)
    #expect(try Command.parse("insert 139") == .insert(139))
    #expect(try Command.parse("query windows") == .query(.windows))
}

@Test func spiralFiveWindows() {
    // Fibonacci spiral on 1000x800, no gaps: master left, then top-right,
    // bottom-right, right-of-that, below-again.
    var tree = Tree()
    for id in [1, 2, 3, 4, 5] as [WindowID] { tree = tree.inserting(id) }
    let f = layout(tree, in: screen, config: .none)
    #expect(f[1] == Frame(x: 0, y: 0, width: 500, height: 800))
    #expect(f[2] == Frame(x: 500, y: 0, width: 500, height: 400))
    #expect(f[3] == Frame(x: 500, y: 400, width: 250, height: 400))
    #expect(f[4] == Frame(x: 750, y: 400, width: 250, height: 200))
    #expect(f[5] == Frame(x: 750, y: 600, width: 250, height: 200))
}

@Test func splitPinsOneInsertion() {
    var tree = Tree()
    for id in [1, 2] as [WindowID] { tree = tree.inserting(id) }
    // Pin the next split horizontal: 3 goes below 2, then spiral resumes.
    tree.nextSplit = .splitH
    tree = tree.inserting(3)
    let f = layout(tree, in: screen, config: .none)
    #expect(f[2] == Frame(x: 500, y: 0, width: 500, height: 400))
    #expect(f[3] == Frame(x: 500, y: 400, width: 500, height: 400))
    // Alternation resumed (was H, now V): 4 splits 3 vertically.
    tree = tree.inserting(4)
    let g = layout(tree, in: screen, config: .none)
    #expect(g[3] == Frame(x: 500, y: 400, width: 250, height: 400))
    #expect(g[4] == Frame(x: 750, y: 400, width: 250, height: 400))
}

@Test func zoomFullscreenTogglesAndRestores() {
    var tree = Tree()
    for id in [1, 2] as [WindowID] { tree = tree.inserting(id) }
    tree = tree.focusing(1)
    
    // Normal layout: half and half
    let f1 = layout(tree, in: screen, config: .none)
    #expect(f1[1] == Frame(x: 0, y: 0, width: 500, height: 800))
    #expect(f1[2] == Frame(x: 500, y: 0, width: 500, height: 800))
    
    // Toggle fullscreen via reducer
    let state0 = State(tree: tree, screen: screen, config: .none)
    let (stateFS, mutsFS) = Reducer.reduce(state0, .toggleFullscreen)
    #expect(stateFS.tree.fullscreen == 1)
    let fFS = layout(stateFS.tree, in: screen, config: .none)
    #expect(fFS[1] == screen)
    #expect(mutsFS.contains(.raise(1)))
    #expect(mutsFS.contains(.setFrame(1, screen)))
    
    // Toggle off: restores tiled geometry
    let (stateRestored, _) = Reducer.reduce(stateFS, .toggleFullscreen)
    #expect(stateRestored.tree.fullscreen == nil)
    let fRestored = layout(stateRestored.tree, in: screen, config: .none)
    #expect(fRestored[1] == Frame(x: 0, y: 0, width: 500, height: 800))
    #expect(fRestored[2] == Frame(x: 500, y: 0, width: 500, height: 800))
}

@Test func splitToggleFlipsOrientation() {
    var tree = Tree()
    for id in [1, 2] as [WindowID] { tree = tree.inserting(id) }
    // Initially side-by-side (splitV)
    let f0 = layout(tree, in: screen, config: .none)
    #expect(f0[1]?.width == 500 && f0[1]?.height == 800)
    
    // Toggle split
    let state0 = State(tree: tree, screen: screen, config: .none)
    let (stateFlipped, _) = Reducer.reduce(state0, .toggleSplit)
    let f1 = layout(stateFlipped.tree, in: screen, config: .none)
    #expect(f1[1] == Frame(x: 0, y: 0, width: 1000, height: 400))
    #expect(f1[2] == Frame(x: 0, y: 400, width: 1000, height: 400))
    
    // Toggle back
    let (stateBack, _) = Reducer.reduce(stateFlipped, .toggleSplit)
    let f2 = layout(stateBack.tree, in: screen, config: .none)
    #expect(f2[1] == Frame(x: 0, y: 0, width: 500, height: 800))
}

@Test func commandGrammarToggles() throws {
    #expect(try Command.parse("fullscreen") == .toggleFullscreen)
    #expect(try Command.parse("zoom-fullscreen") == .toggleFullscreen)
    #expect(try Command.parse("toggle fullscreen") == .toggleFullscreen)
    #expect(try Command.parse("window toggle fullscreen") == .toggleFullscreen)
    #expect(try Command.parse("window toggle zoom-fullscreen") == .toggleFullscreen)
    #expect(try Command.parse("split toggle") == .toggleSplit)
    #expect(try Command.parse("toggle split") == .toggleSplit)
    #expect(try Command.parse("window toggle split") == .toggleSplit)
    #expect(try Command.parse("toggle float") == .toggleFloat)
    #expect(try Command.parse("window toggle float") == .toggleFloat)
    #expect(try Command.parse("float toggle") == .toggleFloat)
}

@Test func frameContainsPoint() {
    let frame = Frame(x: 100, y: 100, width: 200, height: 150)
    #expect(frame.contains(x: 150, y: 150) == true)
    #expect(frame.contains(x: 100, y: 100) == true)
    #expect(frame.contains(x: 300, y: 250) == false)
    #expect(frame.contains(x: 50, y: 50) == false)
}

// MARK: - Geometry-driven split axis (yabai `split_type auto`)

@Test func autoSplitFollowsSlotShape() {
    // The alternating `nextSplit` flag only produces sane shapes while you
    // keep focusing the newest window. Focus an older pane and the flag is
    // out of phase with that pane's shape — which is what made panes come
    // out as slivers. inserting(_:in:config:) picks from the slot instead.
    var tree = Tree()
    tree = tree.inserting(1, in: screen, config: .none)
    tree = tree.inserting(2, in: screen, config: .none)
    // 1 and 2 are each 500x800 — taller than wide, so both split top/bottom.
    tree = tree.focusing(1)
    tree = tree.inserting(3, in: screen, config: .none)
    let f = layout(tree, in: screen, config: .none)
    #expect(f[1] == Frame(x: 0, y: 0, width: 500, height: 400))
    #expect(f[3] == Frame(x: 0, y: 400, width: 500, height: 400))
    #expect(f[2] == Frame(x: 500, y: 0, width: 500, height: 800))
    // 3 is 500x400 — wider than tall, so it splits side-by-side.
    tree = tree.inserting(4, in: screen, config: .none)
    let g = layout(tree, in: screen, config: .none)
    #expect(g[3] == Frame(x: 0, y: 400, width: 250, height: 400))
    #expect(g[4] == Frame(x: 250, y: 400, width: 250, height: 400))
}

@Test func autoSplitStillSpirals() {
    // The spiral is what the aspect-ratio rule produces naturally when focus
    // follows each new window, so §4.1's documented shape is unchanged.
    var tree = Tree()
    for id in [1, 2, 3, 4, 5] as [WindowID] {
        tree = tree.inserting(id, in: screen, config: .none)
    }
    let f = layout(tree, in: screen, config: .none)
    #expect(f[1] == Frame(x: 0, y: 0, width: 500, height: 800))
    #expect(f[2] == Frame(x: 500, y: 0, width: 500, height: 400))
    #expect(f[3] == Frame(x: 500, y: 400, width: 250, height: 400))
    #expect(f[4] == Frame(x: 750, y: 400, width: 250, height: 200))
    #expect(f[5] == Frame(x: 750, y: 600, width: 250, height: 200))
}

@Test func pendingSplitOverridesGeometryOnce() {
    var tree = Tree()
    tree = tree.inserting(1, in: screen, config: .none)
    tree = tree.inserting(2, in: screen, config: .none)
    // 2 is 500x800 (tall) so geometry would stack; pin side-by-side instead.
    tree.pendingSplit = .splitV
    tree = tree.inserting(3, in: screen, config: .none)
    let f = layout(tree, in: screen, config: .none)
    #expect(f[2] == Frame(x: 500, y: 0, width: 250, height: 800))
    #expect(f[3] == Frame(x: 750, y: 0, width: 250, height: 800))
    #expect(tree.pendingSplit == nil)  // consumed
    // Next insert is automatic again: 3 is 250x800, tall → stacks.
    tree = tree.inserting(4, in: screen, config: .none)
    let g = layout(tree, in: screen, config: .none)
    #expect(g[3] == Frame(x: 750, y: 0, width: 250, height: 400))
    #expect(g[4] == Frame(x: 750, y: 400, width: 250, height: 400))
}
