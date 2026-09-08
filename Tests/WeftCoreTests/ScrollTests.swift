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
    // col1 = [847, 1976.898]; visible [vx-8, vx+1702] → vx = 274.898.
    #expect(abs(s.viewportX - 274.898) < 0.01)
}

@Test func layoutParksDistantColumns() {
    // Six half-width columns: strip 3000 wide, screen 1000, margin 1000.
    // Visible window: [-1000, 2000]. Col 4 starts exactly at the margin edge
    // (kept — boundary-inclusive is the safe direction); col 5 parks.
    let s = strip(1, 2, 3, 4, 5, 6)
    let (frames, parked) = scrollLayout(s, screen: scrollScreen, config: noGaps)
    #expect(frames.keys.sorted() == [1, 2, 3, 4, 5])
    #expect(parked == [6])
    #expect(frames[1]!.x == 0)  // gap/2 inset with noGaps → 0
    #expect(frames[1]!.width == 500)
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
    let (s3, m3) = Reducer.reduceScroll(s2, screen: scrollScreen, config: noGaps, command: .stack(.wrap))
    #expect(s3 == s2 && m3.isEmpty)
}

@Test func scrollGrammar() throws {
    #expect(try Command.parse("scroll focus prev-column") == .scroll(.focusColumn(-1)))
    #expect(try Command.parse("scroll focus next-column") == .scroll(.focusColumn(1)))
    #expect(try Command.parse("scroll move-window prev-column") == .scroll(.moveColumn(-1)))
    #expect(try Command.parse("scroll width cycle") == .scroll(.widthCycle))
}
