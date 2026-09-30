import Testing
@testable import WeftCore

// Why the order matters is on `axWriteOrder`. These pin the rule itself: a
// frame write that asks the app to hold an impossible intermediate frame is a
// correction write later, and on a Chromium window that is a second relayout.

@Test func growingIntoTheGapWritesPositionFirst() {
    // The survivor of a close: moves left and doubles in width.
    let from = Frame(x: 500, y: 0, width: 500, height: 800)
    let to = Frame(x: 0, y: 0, width: 1000, height: 800)
    #expect(axWriteOrder(from: from, to: to) == .positionThenSize)
}

@Test func makingRoomForANewWindowWritesSizeFirst() {
    // The neighbour of an insert: halves in width and moves right.
    let from = Frame(x: 0, y: 0, width: 1000, height: 800)
    let to = Frame(x: 500, y: 0, width: 500, height: 800)
    #expect(axWriteOrder(from: from, to: to) == .sizeThenPosition)
}

@Test func growingOnOneAxisAndShrinkingOnTheOtherWritesSizeFirst() {
    let from = Frame(x: 0, y: 0, width: 500, height: 800)
    let to = Frame(x: 0, y: 400, width: 1000, height: 400)
    #expect(axWriteOrder(from: from, to: to) == .sizeThenPosition)
}

@Test func aPureTranslationKeepsPositionFirst() {
    let from = Frame(x: 0, y: 0, width: 500, height: 800)
    let to = Frame(x: 500, y: 0, width: 500, height: 800)
    #expect(axWriteOrder(from: from, to: to) == .positionThenSize)
}

@Test func subPointSizeNoiseIsNotAShrink() {
    // Retina rounding: a half-point wobble must not flip the order.
    let from = Frame(x: 0, y: 0, width: 500.4, height: 800)
    let to = Frame(x: 0, y: 0, width: 500, height: 800)
    #expect(axWriteOrder(from: from, to: to) == .positionThenSize)
}

/// A small change is still a change: only a frame already asked for may be
/// off by the snapping slop.
@Test func aSmallResizeIsNotMistakenForSnapping() {
    let target = Frame(x: 8, y: 46, width: 413.75, height: 1058)
    let actual = Frame(x: 8, y: 46, width: 418, height: 1058)
    let before = Frame(x: 8, y: 46, width: 418, height: 1058)
    // Never asked for 413.75: write it.
    #expect(!isSettled(actual, at: target, lastTarget: before, sizeSlop: 8))
    #expect(!isSettled(actual, at: target, lastTarget: nil, sizeSlop: 8))
    // Asked for it and the app snapped 4 points short: leave it.
    #expect(isSettled(actual, at: target, lastTarget: target, sizeSlop: 8))
    // Exact is settled whatever was asked; a wrong position never is.
    #expect(isSettled(target, at: target, lastTarget: nil, sizeSlop: 8))
    #expect(!isSettled(Frame(x: 20, y: 46, width: 413.75, height: 1058), at: target, lastTarget: target, sizeSlop: 8))
}
