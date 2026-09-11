import Testing
@testable import WeftCore

private let dScreen = Frame(x: 0, y: 0, width: 1000, height: 800)
private let dGapped = TilingConfig(
    innerGap: 8, outerGap: .init(top: 8, bottom: 8, left: 8, right: 8), stackOffset: 8
)

private func dTree(_ ids: [WindowID]) -> Tree {
    var t = Tree()
    for id in ids { t = t.inserting(id, in: dScreen, config: dGapped) }
    return t
}

@Test func twoWindowsHaveExactlyOneDivider() {
    let frames = layout(dTree([1, 2]), in: dScreen, config: dGapped)
    let ds = dividers(in: frames, innerGap: 8)
    #expect(ds.count == 1)
    let d = try! #require(ds.first)
    // Side by side, so the border is vertical and dragging it is horizontal.
    #expect(d.axis == .horizontal)
    #expect(d.a == 1)
    #expect(d.b == 2)
    // Centred on the gap between them, and at least a finger wide.
    #expect(d.rect.width >= 12)
    let left = frames[1]!
    #expect(abs(d.rect.x + d.rect.width / 2 - (left.x + left.width + 4)) < 0.001)
}

@Test func aLoneWindowHasNoDividers() {
    let frames = layout(dTree([1]), in: dScreen, config: dGapped)
    #expect(dividers(in: frames, innerGap: 8).isEmpty)
}

@Test func stackMembersShareASlotSoTheyHaveNoDividerBetweenThem() {
    let t = dTree([1, 2]).focusing(1).togglingStack()
    let frames = layout(t, in: dScreen, config: dGapped)
    // Both members occupy the same column and overlap, so there is nothing to
    // grab between them.
    let ds = dividers(in: frames, innerGap: 8)
    #expect(!ds.contains { ($0.a == 1 && $0.b == 2) || ($0.a == 2 && $0.b == 1) })
}

@Test func zeroGapLayoutsAreStillGrabbable() {
    let flat = TilingConfig.none
    let frames = layout(dTree([1, 2]), in: dScreen, config: flat)
    let ds = dividers(in: frames, innerGap: 0)
    #expect(ds.count == 1)
    // Touching edges: the strip has to be widened around the seam or the
    // border would be a zero-width target.
    #expect(ds[0].rect.width >= 12)
}

@Test func hitTestPicksTheDividerUnderThePoint() {
    let frames = layout(dTree([1, 2]), in: dScreen, config: dGapped)
    let ds = dividers(in: frames, innerGap: 8)
    let seam = frames[1]!.x + frames[1]!.width + 4
    #expect(divider(at: seam, y: 400, in: ds)?.a == 1)
    // Well inside window 1: not a border.
    #expect(divider(at: 100, y: 400, in: ds) == nil)
}

@Test func draggingADividerMovesTheBorderByExactlyThatMuch() {
    let t = dTree([1, 2])
    let before = layout(t, in: dScreen, config: dGapped)
    let seamBefore = before[1]!.x + before[1]!.width
    let next = t.resizing(divider: 1, 2, axis: .horizontal, deltaPoints: 100, frames: before)
    let after = layout(next, in: dScreen, config: dGapped)
    let seamAfter = after[1]!.x + after[1]!.width
    #expect(abs((seamAfter - seamBefore) - 100) < 0.5)
    // The pair still fills the same span.
    #expect(abs((after[2]!.x + after[2]!.width) - (before[2]!.x + before[2]!.width)) < 0.5)
}

@Test func draggingANestedDividerMovesThatBorderAndNotItsAncestor() {
    // splitV[ splitV[1, 2], 3 ] — the shape a keybind-style resize gets
    // wrong, because the root also matches the horizontal axis.
    var t = Tree()
    t = t.inserting(1, in: dScreen, config: .none)
    t.pendingSplit = .splitV
    t = t.inserting(2, in: dScreen, config: .none)
    t.pendingSplit = .splitV
    t = t.focusing(1)
    t = t.inserting(3, in: dScreen, config: .none)
    let before = layout(t, in: dScreen, config: .none)
    guard before.count == 3 else { return }  // shape guard; insertion is BSP
    let ds = dividers(in: before, innerGap: 0)
    guard let d = ds.first(where: { $0.axis == .horizontal }) else { return }
    let next = t.resizing(divider: d.a, d.b, axis: d.axis, deltaPoints: 40, frames: before)
    let after = layout(next, in: dScreen, config: .none)
    // Whatever the tree shape, the border the drag names moved by 40 and the
    // two windows either side still meet.
    let seamBefore = before[d.a]!.x + before[d.a]!.width
    let seamAfter = after[d.a]!.x + after[d.a]!.width
    #expect(abs((seamAfter - seamBefore) - 40) < 1.0)
    #expect(abs(after[d.b]!.x - seamAfter) < 1.0)
}

@Test func aDividerDragCannotSqueezeAWindowToNothing() {
    let t = dTree([1, 2])
    let before = layout(t, in: dScreen, config: dGapped)
    let next = t.resizing(divider: 1, 2, axis: .horizontal, deltaPoints: 100_000, frames: before)
    let after = layout(next, in: dScreen, config: dGapped)
    #expect(after[2]!.width > 20)
}

// MARK: - Zoom fullscreen

@Test func zoomFullscreenFillsTheTilingAreaNotTheDisplay() {
    var t = dTree([1, 2])
    t = t.focusing(1).togglingFullscreen()
    let frames = layout(t, in: dScreen, config: dGapped)
    // The gaps are the user's setting, not decoration: a zoomed window that
    // ignores them also ignores `reserve`, and slides under the bar they told
    // weft to keep clear.
    #expect(frames[1] == Frame(x: 8, y: 8, width: 984, height: 784))
    #expect(frames[1] != dScreen)
}

@Test func zoomFullscreenOfALoneWindowStillKeepsTheGaps() {
    let t = dTree([1]).focusing(1).togglingFullscreen()
    let frames = layout(t, in: dScreen, config: dGapped)
    #expect(frames[1] == Frame(x: 8, y: 8, width: 984, height: 784))
}
