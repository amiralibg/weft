import Testing
@testable import WeftCore

let scrollScreen = Frame(x: 0, y: 0, width: 1000, height: 800)
let noGaps = TilingConfig.none

private func strip(_ ids: WindowID...) -> ScrollState {
    var s = ScrollState()
    for id in ids { s = s.inserting(id) }
    return s
}

@Test func insertOpensColumnRightOfFocus() {
    var s = strip(1, 2)  // cols [1],[2], focus col 1 (id 2)
    #expect(s.focusCol == 1)
    s = s.inserting(3)
    #expect(s.columns.count == 3)
    #expect(s.focusCol == 2)  // new column right of focused, focused
    #expect(s.focusedWindow == 3)
}

@Test func removeDropsEmptyColumns() {
    var s = strip(1, 2, 3)
    s = s.removing(2)
    #expect(s.columns.count == 2)
    #expect(s.windows.sorted() == [1, 3])
}

@Test func columnFocusClampsRow() {
    var s = ScrollState(columns: [Column(windows: [1]), Column(windows: [2, 3])])
    s = s.movingFocusByColumn(1)
    #expect(s.focusCol == 1 && s.focusRow == 0)
    // Row 5 clamps into the 1-window first column going back.
    s = ScrollState(columns: [Column(windows: [1]), Column(windows: [2, 3])], focusCol: 1, focusRow: 1)
    s = s.movingFocusByColumn(-1)
    #expect(s.focusCol == 0 && s.focusRow == 0)
}

@Test func moveWindowMergesColumns() {
    var s = strip(1, 2).focusing(1)
    s = s.movingWindowToColumn(1)  // 1 joins 2's column
    #expect(s.columns.count == 1)
    #expect(s.columns[0].windows == [2, 1])
    #expect(s.focusedWindow == 1)
    // Moving past the edge is a no-op.
    let same = s.movingWindowToColumn(1)
    #expect(same == s)
}

@Test func widthCyclesRing() {
    var s = strip(1)  // default 0.5
    s = s.cyclingWidth()
    #expect(abs(s.columns[0].width - 0.667) < 1e-9)
    s = s.cyclingWidth()
    #expect(abs(s.columns[0].width - 1.0) < 1e-9)
    s = s.cyclingWidth()
    #expect(abs(s.columns[0].width - 0.333) < 1e-9)
    s = s.adjustingWidth(0.1)
    #expect(abs(s.columns[0].width - 0.433) < 1e-9)
}

@Test func viewportNeverScrollsForVisible() {
    var s = strip(1, 2)  // both fit in 1000pt at 0.5 each
    s.ensureVisible(1, screen: scrollScreen, config: noGaps)
    #expect(s.viewportX == 0)
}

@Test func viewportMinScrollThenModes() {
    // Four half-width columns: strip is 2000 wide on a 1000 screen.
    var s = strip(1, 2, 3, 4)
    s.centerMode = .never
    s.ensureVisible(3, screen: scrollScreen, config: noGaps)
    #expect(s.viewportX == 1000)  // min scroll: [1500,2000] into [1000,2000]
    // Already-visible stays put under .never.
    s.ensureVisible(2, screen: scrollScreen, config: noGaps)
    #expect(s.viewportX == 1000)  // col 2 = [1000,1500] fully inside
    // .always centers even visible columns.
    var c = strip(1, 2)
    c.centerMode = .always
    c.ensureVisible(0, screen: scrollScreen, config: noGaps)
    #expect(c.viewportX == 0)  // centered would be negative → clamped to 0
    // .onOverflow centers only what can't fit.
    var o = ScrollState(columns: [Column(windows: [1], width: 1.5)])
    o.centerMode = .onOverflow
    o.ensureVisible(0, screen: scrollScreen, config: noGaps)
    #expect(o.viewportX == 250)  // 1500-wide col centered in 1000
}

@Test func viewportAccountsOuterGaps() {
    // Live regression (2026-09-04): strip math runs in usable width (1694)
    // but the visible window is screen width (1710) — mixing them over-
    // scrolled by exactly the outer gaps (16pt).
    let screen = Frame(x: 0, y: 0, width: 1710, height: 1073)
    let config = TilingConfig()  // outer 8s
    var s = ScrollState(columns: [
        Column(windows: [1], width: 0.5),
        Column(windows: [2], width: 0.667),
    ])
    s.ensureVisible(1, screen: screen, config: config)
    // col1 = [847, 1976.898]; the strip window is the USABLE width, so
    // vx = 1976.898 - 1694 = 282.898.
    #expect(abs(s.viewportX - 282.898) < 0.01)
}

@Test func aScrolledToColumnKeepsItsOuterGap() {
    // The old viewport measured the window in screen width, which parked the
    // scrolled-to column flush against the screen edge: the outer gap was
    // there before you scrolled and gone afterwards.
    let screen = Frame(x: 0, y: 0, width: 1710, height: 1073)
    let config = TilingConfig()  // outer 8s
    var s = ScrollState(columns: [
        Column(windows: [1], width: 0.5),
        Column(windows: [2], width: 0.667),
    ])
    s.ensureVisible(1, screen: screen, config: config)
    let (frames, _) = scrollLayout(s, screen: screen, config: config)
    let right = frames[2]!.x + frames[2]!.width
    // Right edge sits on the outer gap, not on the screen edge, and the inner
    // half-gap inset accounts for the rest.
    #expect(abs(right - (1710 - 8 - config.innerGap / 2)) < 0.01)
}

@Test func layoutParksEverythingWithNothingOnScreen() {
    // Six half-width columns: strip 3000 wide, screen 1000. Two fit; the rest
    // have no on-screen overlap at all.
    //
    // Regression: the park test used to allow a full screen width of slack
    // either side, so columns 3 and 4 were handed frames at x = 1000 and
    // 1500 on a 1000-wide screen. AX will not put a window there — it clamps
    // at roughly -(width - 40) — so they snapped back and stacked in the
    // corner on top of the visible ones. Four windows into a scroll space
    // that is the whole bug.
    let s = strip(1, 2, 3, 4, 5, 6)
    let (frames, parked) = scrollLayout(s, screen: scrollScreen, config: noGaps)
    #expect(frames.keys.sorted() == [1, 2])
    #expect(parked == [3, 4, 5, 6])
    #expect(frames[1]!.x == 0)  // gap/2 inset with noGaps → 0
    #expect(frames[1]!.width == 500)
    // Nothing that got a frame is off the screen it was laid out on.
    for f in frames.values {
        #expect(f.x + f.width > scrollScreen.x)
        #expect(f.x < scrollScreen.x + scrollScreen.width)
    }
}

@Test func aSliverTooThinForAXToPlaceIsParked() {
    // AX leaves 40pt of a window on screen whatever you ask for. A column
    // with less than that showing is parked rather than written to a position
    // the WindowServer will quietly overrule.
    var s = strip(1, 2)
    // Scroll so column 1 has 20pt of itself left on screen.
    s.viewportX = 480
    let (frames, parked) = scrollLayout(s, screen: scrollScreen, config: noGaps)
    #expect(parked == [1])
    #expect(frames.keys.sorted() == [2])
}

@Test func aZoomedWindowIsNeverParked() {
    // Zoom covers the screen, so it is visible even when its own column has
    // scrolled out of the strip.
    var s = strip(1, 2, 3, 4, 5, 6)
    s = s.focusing(6).togglingFullscreen()
    let (frames, parked) = scrollLayout(s, screen: scrollScreen, config: noGaps)
    #expect(frames[6] != nil)
    #expect(!parked.contains(6))
}

@Test func aBorderDragResizesTheColumnItWasGrabbedOn() {
    // Dragging a border names the two windows either side of it. The resize
    // has to land on that column — it used to focus the west window first and
    // resize "the focused column", which moved focus as a side effect of a
    // mouse gesture that is documented not to.
    let s = ScrollState(columns: [
        Column(windows: [1]), Column(windows: [2]), Column(windows: [3]),
    ], focusCol: 2)
    let (col, row) = s.position(of: 1)!
    #expect((col, row) == (0, 0))
    let next = s.adjustingWidth(0.1, column: col)
    #expect(abs(next.columns[0].width - 0.6) < 1e-9)
    #expect(next.columns[2].width == s.columns[2].width)
    #expect(next.focusCol == 2)  // focus did not move
}

@Test func resizingAColumnShiftsEveryColumnRightOfIt() {
    // The rest of the strip follows a resize: column positions are the sum of
    // the widths before them, so growing one moves its neighbours over by
    // exactly the same amount rather than letting them overlap.
    let s = strip(1, 2, 3)
    let (before, _) = scrollLayout(s, screen: scrollScreen, config: noGaps)
    let widened = s.adjustingWidth(0.1, column: 0)
    let (after, _) = scrollLayout(widened, screen: scrollScreen, config: noGaps)
    #expect(abs(after[1]!.width - (before[1]!.width + 100)) < 1e-9)
    #expect(abs(after[2]!.x - (before[2]!.x + 100)) < 1e-9)
    // And they still do not overlap.
    #expect(after[2]!.x >= after[1]!.x + after[1]!.width)
}

@Test func scrollFocusByGeometry() {
    let s = strip(1, 2)
    let base = (s, scrollScreen)
    _ = base
    var state = s
    // East from 1 reaches 2 (visible strip, no parking).
    let (frames, _) = scrollLayout(state, screen: scrollScreen, config: noGaps)
    let next = Reducer.neighbour(of: 1, in: frames, towards: .east)
    #expect(next == 2)
    state = state.focusing(2)
    #expect(state.focusedWindow == 2)
}

@Test func scrollReducerColumnJumpAndCycle() {
    // strip() ends focused on the last column; rewind to the first.
    let s = strip(1, 2, 3).focusing(1)
    let (s1, m1) = Reducer.reduceScroll(s, screen: scrollScreen, config: noGaps, command: .scroll(.focusColumn(1)))
    #expect(s1.focusedWindow == 2)
    #expect(m1.contains(.focusWindow(2)))
    let (s2, _) = Reducer.reduceScroll(s1, screen: scrollScreen, config: noGaps, command: .scroll(.widthCycle))
    #expect(abs(s2.columns[s2.focusCol].width - 0.667) < 1e-9)
    // Tiling-only commands are safe no-ops.
    let (s3, m3) = Reducer.reduceScroll(s2, screen: scrollScreen, config: noGaps, command: .stack(.toggle))
    #expect(s3 == s2 && m3.isEmpty)
}

@Test func scrollGrammar() throws {
    #expect(try Command.parse("scroll focus prev-column") == .scroll(.focusColumn(-1)))
    #expect(try Command.parse("scroll focus next-column") == .scroll(.focusColumn(1)))
    #expect(try Command.parse("scroll move-window prev-column") == .scroll(.moveColumn(-1)))
    #expect(try Command.parse("scroll width cycle") == .scroll(.widthCycle))
}

@Test func scrollDirectionalFocusTraversesAllColumnsAndRows() {
    let s = ScrollState(columns: [
        Column(windows: [1]),
        Column(windows: [2, 3]),
        Column(windows: [4]),
        Column(windows: [5]),
    ], focusCol: 0, focusRow: 0)

    // East to Col 1 (win 2)
    let (s1, m1) = Reducer.reduceScroll(s, screen: scrollScreen, config: noGaps, command: .focus(.east))
    #expect(s1.focusedWindow == 2)
    #expect(s1.focusCol == 1 && s1.focusRow == 0)
    #expect(m1.contains(.focusWindow(2)))

    // South to win 3 in Col 1
    let (s2, m2) = Reducer.reduceScroll(s1, screen: scrollScreen, config: noGaps, command: .focus(.south))
    #expect(s2.focusedWindow == 3)
    #expect(s2.focusCol == 1 && s2.focusRow == 1)
    #expect(m2.contains(.focusWindow(3)))

    // North back to win 2
    let (s3, _) = Reducer.reduceScroll(s2, screen: scrollScreen, config: noGaps, command: .focus(.north))
    #expect(s3.focusedWindow == 2)
    #expect(s3.focusCol == 1 && s3.focusRow == 0)

    // East to Col 2 (win 4)
    let (s4, _) = Reducer.reduceScroll(s3, screen: scrollScreen, config: noGaps, command: .focus(.east))
    #expect(s4.focusedWindow == 4)
    #expect(s4.focusCol == 2)

    // East to Col 3 (win 5)
    let (s5, _) = Reducer.reduceScroll(s4, screen: scrollScreen, config: noGaps, command: .focus(.east))
    #expect(s5.focusedWindow == 5)
    #expect(s5.focusCol == 3)

    // West back to Col 2 (win 4)
    let (s6, _) = Reducer.reduceScroll(s5, screen: scrollScreen, config: noGaps, command: .focus(.west))
    #expect(s6.focusedWindow == 4)
    #expect(s6.focusCol == 2)
}

@Test func scrollDirectionalMoveSwapsColumnsAndRows() {
    let s = ScrollState(columns: [
        Column(windows: [1]),
        Column(windows: [2, 3]),
        Column(windows: [4]),
    ], focusCol: 1, focusRow: 0)

    // In Col 1 (windows [2, 3]), move south swaps rows
    let (s1, _) = Reducer.reduceScroll(s, screen: scrollScreen, config: noGaps, command: .move(.south))
    #expect(s1.columns[1].windows == [3, 2])
    #expect(s1.focusedWindow == 2)
    #expect(s1.focusRow == 1)

    // Move east swaps Col 1 and Col 2
    let (s2, _) = Reducer.reduceScroll(s1, screen: scrollScreen, config: noGaps, command: .move(.east))
    #expect(s2.columns[1].windows == [4])
    #expect(s2.columns[2].windows == [3, 2])
    #expect(s2.focusedWindow == 2)
    #expect(s2.focusCol == 2)
}
