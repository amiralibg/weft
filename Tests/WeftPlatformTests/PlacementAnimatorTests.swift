import CoreGraphics
import Testing
@testable import WeftPlatform

// The stage's backdrop is the desktop shaped to where moving windows pass,
// with a hole for every other window. A wrong subtraction either paints the
// desktop over a window that is not moving or leaves a gap through which a
// real window is seen jumping into place.

private func area(_ rects: [CGRect]) -> CGFloat {
    rects.reduce(0) { $0 + $1.width * $1.height }
}

@Test func subtractingADisjointRectLeavesTheRectWhole() {
    let r = CGRect(x: 0, y: 0, width: 100, height: 100)
    #expect(PlacementAnimator.subtract(CGRect(x: 200, y: 0, width: 50, height: 50), from: r) == [r])
}

@Test func subtractingACoveringRectLeavesNothing() {
    let r = CGRect(x: 10, y: 10, width: 50, height: 50)
    #expect(PlacementAnimator.subtract(CGRect(x: 0, y: 0, width: 100, height: 100), from: r).isEmpty)
}

@Test func aHoleInTheMiddleLeavesFourNonOverlappingPieces() {
    let r = CGRect(x: 0, y: 0, width: 100, height: 100)
    let hole = CGRect(x: 40, y: 40, width: 20, height: 20)
    let pieces = PlacementAnimator.subtract(hole, from: r)
    #expect(pieces.count == 4)
    #expect(area(pieces) == CGFloat(100 * 100 - 20 * 20))
    for p in pieces { #expect(!p.intersects(hole)) }
    for (i, a) in pieces.enumerated() {
        for b in pieces[(i + 1)...] { #expect(a.intersection(b).isEmpty) }
    }
}

@Test func aNeighbourTileTakesItsEdgeOffThePaddedCover() {
    // A tile's shadow room reaches into the tile beside it; the neighbour,
    // which is not moving, must keep showing.
    let cover = CGRect(x: -40, y: -40, width: 940, height: 1140)
    let neighbour = CGRect(x: 859, y: 0, width: 843, height: 1058)
    let pieces = PlacementAnimator.subtract(neighbour, from: cover)
    for p in pieces { #expect(p.intersection(neighbour).isEmpty) }
    #expect(area(pieces) == cover.width * cover.height - cover.intersection(neighbour).width * cover.intersection(neighbour).height)
}

@Test func deltaSumsEveryEdge() {
    let a = CGRect(x: 0, y: 0, width: 100, height: 100)
    #expect(PlacementAnimator.delta(a, a) == 0)
    #expect(PlacementAnimator.delta(a, CGRect(x: 1, y: 2, width: 103, height: 104)) == 10)
}
