import Testing

@testable import WeftCore

/// The predicate that decides whether a border follows a window or ignores
/// where it currently is.
///
/// Every case here is taken from a real failure. The renderer used to accept
/// any frame the WindowServer reported, which made the border follow a window
/// mid-resize and then latch there: correct frames went in and a ring half the
/// width of its window came out, on every pass, permanently.
private func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Frame {
    Frame(x: x, y: y, width: w, height: h)
}

@Test func anExactFrameSettles() {
    let target = frame(8, 46, 1694, 1058)
    #expect(BorderGeometry.settles(target, against: target))
}

@Test func aTerminalRoundingToCharacterCellsSettles() {
    // The case the correction exists for: an app lands a few points short
    // because it only resizes in whole cells, and the border should hug the
    // window rather than the request.
    let target = frame(8, 46, 843, 1058)
    #expect(BorderGeometry.settles(frame(8, 46, 837, 1050), against: target))
    #expect(BorderGeometry.settles(frame(11, 49, 843, 1058), against: target))
}

@Test func aFrameFromMidResizeDoesNotSettle() {
    // The bug, in the numbers it was reported with. Closing one of two tiled
    // windows left the survivor asked for 1694 wide while the WindowServer
    // still reported its old 843 — 851 points out, which is not a rounding.
    let target = frame(8, 46, 1694, 1058)
    #expect(!BorderGeometry.settles(frame(8, 46, 843, 1058), against: target))
}

@Test func theSameReadArrivingEarlyDoesNotSettleEither() {
    // The mirror image, and the other half of the same report: the resize
    // observed before the layout caught up drew one ring across two windows.
    let target = frame(8, 46, 843, 1058)
    #expect(!BorderGeometry.settles(frame(8, 46, 1694, 1058), against: target))
}

@Test func toleranceIsInclusiveAtTheBoundary() {
    let target = frame(0, 0, 1000, 1000)
    let edge = BorderGeometry.settleTolerance
    #expect(BorderGeometry.settles(frame(0, 0, 1000 - edge, 1000), against: target))
    #expect(!BorderGeometry.settles(frame(0, 0, 1000 - edge - 1, 1000), against: target))
}

@Test func everyDimensionIsChecked() {
    // A frame that has drifted on one axis only is still not the frame weft
    // asked for, whichever axis it is.
    let target = frame(100, 100, 500, 500)
    let far = BorderGeometry.settleTolerance + 10
    #expect(!BorderGeometry.settles(frame(100 + far, 100, 500, 500), against: target))
    #expect(!BorderGeometry.settles(frame(100, 100 + far, 500, 500), against: target))
    #expect(!BorderGeometry.settles(frame(100, 100, 500 + far, 500), against: target))
    #expect(!BorderGeometry.settles(frame(100, 100, 500, 500 + far), against: target))
}
