import Testing
@testable import WeftCore

let stackScreen = Frame(x: 0, y: 0, width: 1000, height: 800)

private func tree(_ ids: WindowID...) -> Tree {
    var t = Tree()
    for id in ids { t = t.inserting(id) }
    return t
}

@Test func stackMembersShareOneFrame() {
    let t = tree(1, 2).focusing(1).togglingStack()
    // 2-window tree is one split container → wrap converts it to a stack.
    let frames = layout(t, in: stackScreen, config: .none)
    #expect(frames.count == 2)
    #expect(frames[1] == frames[2])
    #expect(frames[1]!.width == 1000)
    #expect(frames[1]!.height == 800)
}

@Test func wrapConvertsParent() {
    var t = tree(1, 2, 3)
    // Focus the middle window, wrap: its parent becomes a stack.
    t = t.focusing(2).togglingStack()
    let frames = layout(t, in: stackScreen, config: .none)
    // 2 and 3 shared the east half; now stacked there, 1 keeps the west half.
    #expect(frames[2] == frames[3])
    #expect(frames[1]!.x == 0)
    #expect(frames[2]!.x == 500)
    #expect(frames[2]!.width == 500)
}

@Test func splitEastMergesNeighbour() {
    let t = tree(1, 2)  // 1 west, 2 east, focus 2
    let base = State(tree: t.focusing(1), screen: stackScreen, config: .none)
    let (s1, m1) = Reducer.reduce(base, .stack(.split(.east)))
    let frames = layout(s1.tree, in: stackScreen, config: .none)
    #expect(frames[1] == frames[2])  // stacked over the combined area
    #expect(s1.tree.focus == 1)
    #expect(m1.contains(.raise(1)))
}

@Test func cycleMovesFocusAndRaises() {
    let t = tree(1, 2).focusing(1).togglingStack()
    let base = State(tree: t, screen: stackScreen, config: .none)
    #expect(base.tree.focus == 1)
    let (s1, m1) = Reducer.reduce(base, .stack(.next))
    #expect(s1.tree.focus == 2)
    #expect(m1.contains(.raise(2)))
    let (s2, _) = Reducer.reduce(s1, .stack(.next))
    #expect(s2.tree.focus == 1)  // wraps around
    let (s3, m3) = Reducer.reduce(s2, .stack(.prev))
    #expect(s3.tree.focus == 2)
    #expect(m3.contains(.raise(2)))
}

@Test func unstackRestoresSplit() {
    let t = tree(1, 2).focusing(1).togglingStack()
    let base = State(tree: t, screen: stackScreen, config: .none)
    let (s1, _) = Reducer.reduce(base, .stack(.unstack))
    let frames = layout(s1.tree, in: stackScreen, config: .none)
    #expect(frames[1]!.width == 500)  // side-by-side again
    #expect(frames[2]!.x == 500)
}

@Test func insertJoinsFocusedStack() {
    var t = tree(1, 2).focusing(1).togglingStack()
    t = t.inserting(3)
    #expect(t.windows.count == 3)
    #expect(t.focus == 3)
    let frames = layout(t, in: stackScreen, config: .none)
    #expect(frames[1] == frames[2])
    #expect(frames[2] == frames[3])
}

@Test func directionalFocusEscapesStack() {
    // [1 | stack(2,3)]: from member 2, west leaves the stack and reaches 1.
    let t = tree(1, 2, 3).focusing(2).togglingStack()
    let state = State(tree: t, screen: stackScreen, config: .none)
    let (s2, m2) = Reducer.reduce(state, .focus(.west))
    #expect(s2.tree.focus == 1)
    #expect(m2 == [.focusWindow(1), .raise(1)])
}

@Test func directionalFocusFallsBackToStackCycle() {
    // Nothing east of the stack, so east cycles to the next member instead of
    // doing nothing — the behaviour yabai users hand-write in skhd as
    // `--focus east || --focus stack.next`. West/north cycle backwards.
    let t = tree(1, 2, 3).focusing(2).togglingStack()
    let state = State(tree: t, screen: stackScreen, config: .none)
    let (s1, m1) = Reducer.reduce(state, .focus(.east))
    #expect(s1.tree.focus == 3)
    #expect(m1 == [.focusWindow(3), .raise(3)])
    // And the stack's active index followed, so 3 is the member on top.
    let (s2, _) = Reducer.reduce(s1, .focus(.east))
    #expect(s2.tree.focus == 2)  // wraps
}

@Test func removeFromStackClamps() {
    var t = tree(1, 2).focusing(1).togglingStack()
    t = t.inserting(3)  // stack of 3, focus 3
    t = t.removing(3)
    #expect(t.windows.count == 2)
    #expect(t.focus != 3)
    let frames = layout(t, in: stackScreen, config: .none)
    #expect(frames[1] == frames[2])  // still stacked
}

@Test func stackChainOrdersActiveLast() {
    let t = tree(1, 2).focusing(1).togglingStack()  // stack[1,2], active 0
    // Chain is lower-first, active-last: order 1 above 2, front = 1.
    #expect(stackChain(root: t.root!, containing: 1) == [2, 1])
    let t2 = t.focusing(2)  // active 1 → its child moves last (already last)
    #expect(stackChain(root: t2.root!, containing: 2) == [1, 2])
    #expect(stackChain(root: t2.root!, containing: 9) == nil)  // absent
    let plain = tree(1, 2)  // split, no stack
    #expect(stackChain(root: plain.root!, containing: 1) == nil)
    var t3 = tree(1, 2, 3).focusing(2).togglingStack()  // [1 | stack(2,3)]
    t3 = t3.focusing(2)  // active 0 within the stack
    // Active's child (2) last; chaining 3-above-… wait: children [2,3],
    // active 0 → order [1, 0] → first-windows [3, 2]: front 2 above 3.
    #expect(stackChain(root: t3.root!, containing: 2) == [3, 2])
}

@Test func treeViewShowsStacks() {
    let t = tree(1, 2).focusing(2).togglingStack()
    let view = TreeView.of(t.root)
    #expect(view.kind == "stack")
    #expect(view.active == 1)
    #expect(view.children.map { $0.window } == [1, 2])
    #expect(TreeView.of(nil).kind == "empty")
    #expect(TreeView.of(.window(7)) == TreeView(kind: "window", window: 7, active: nil, children: []))
}

@Test func stackGrammar() throws {
    #expect(try Command.parse("stack toggle") == .stack(.toggle))
    // `wrap` is the name every existing config uses for it.
    #expect(try Command.parse("stack wrap") == .stack(.toggle))
    #expect(try Command.parse("stack split east") == .stack(.split(.east)))
    #expect(try Command.parse("stack split right") == .stack(.split(.east)))
    #expect(try Command.parse("stack next") == .stack(.next))
    #expect(try Command.parse("stack prev") == .stack(.prev))
    #expect(try Command.parse("stack unstack") == .stack(.unstack))
}



@Test func stackToggleUnstacks() {
    // One key in, the same key out. Toggling a window that is already in a
    // stack used to be a no-op, which left stacking with no obvious way back.
    let stacked = tree(1, 2).focusing(1).togglingStack()
    let frames = layout(stacked, in: stackScreen, config: .none)
    #expect(frames[1] == frames[2])

    let out = stacked.togglingStack()
    let unstacked = layout(out, in: stackScreen, config: .none)
    #expect(unstacked[1] != unstacked[2])
    // `unstacking` restores a splitV — a vertical divider, so the two share
    // the width and keep the full height.
    #expect(unstacked[1]!.width == 500)
    #expect(unstacked[2]!.width == 500)
}

@Test func stackMembersAreInsetSoThePileIsVisible() {
    let t = tree(1, 2).focusing(1).togglingStack()
    let config = TilingConfig(
        innerGap: 0, outerGap: .init(top: 0, bottom: 0, left: 0, right: 0), stackOffset: 10
    )
    let frames = layout(t, in: stackScreen, config: config)
    // Identical frames are what made a stack indistinguishable from a single
    // window. The active member sits inset, the one behind it fills the slot.
    #expect(frames[1] != frames[2])
    #expect(frames[2]!.y == 0)
    #expect(frames[1]!.y == 10)
    #expect(frames[1]!.height == 790)
    // Width is shared exactly: a stack occupies one column, so switching
    // members must not jog the content sideways.
    #expect(frames[1]!.x == frames[2]!.x)
    #expect(frames[1]!.width == frames[2]!.width)
    #expect(frames[1]!.width == 1000)
    // Bottom edges stay aligned on the slot.
    #expect(frames[1]!.y + frames[1]!.height == frames[2]!.y + frames[2]!.height)
}

@Test func stackInsetIsCappedSoDeepStacksDoNotShrinkAway() {
    var t = tree(1, 2).focusing(1).togglingStack()
    for id in [3, 4, 5, 6] { t = t.inserting(WindowID(id)) }
    let config = TilingConfig(
        innerGap: 0, outerGap: .init(top: 0, bottom: 0, left: 0, right: 0), stackOffset: 10
    )
    let frames = layout(t, in: stackScreen, config: config)
    // Three layers of offset, whatever the depth: a six-window stack must not
    // shrink its slot by sixty points.
    let maxInset = frames.values.map(\.y).max() ?? 0
    #expect(maxInset == 30)
    // And the inset never touches the horizontal axis.
    #expect(Set(frames.values.map(\.x)) == [0])
}
