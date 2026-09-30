import Testing

@testable import WeftCore

/// Directional focus across a tiling workspace that holds a float.
///
///     +--------+--------+
///     |        |        |
///     |   1  +-9-+  2   |
///     |      +---+      |
///     +--------+--------+
///
/// Tiles 1 and 2 split the screen; float 9 sits over the seam.
private let left = Frame(x: 0, y: 0, width: 500, height: 800)
private let right = Frame(x: 500, y: 0, width: 500, height: 800)
private let float = Frame(x: 400, y: 300, width: 200, height: 200)
private let tiles: [WindowID: Frame] = [1: left, 2: right]

@Test func aFloatBetweenTwoTilesIsAStepBetweenThem() {
    #expect(Reducer.focusTarget(from: 1, tiles: tiles, floats: [9: float], towards: .east) == 9)
    #expect(Reducer.focusTarget(from: 9, tiles: tiles, floats: [9: float], towards: .east) == 2)
    #expect(Reducer.focusTarget(from: 2, tiles: tiles, floats: [9: float], towards: .west) == 9)
    #expect(Reducer.focusTarget(from: 9, tiles: tiles, floats: [9: float], towards: .west) == 1)
}

@Test func aFloatFurtherThanTheTileNeighbourWaitsItsTurn() {
    let farFloat = Frame(x: 850, y: 300, width: 100, height: 100)
    #expect(Reducer.focusTarget(from: 1, tiles: tiles, floats: [9: farFloat], towards: .east) == 2)
    #expect(Reducer.focusTarget(from: 2, tiles: tiles, floats: [9: farFloat], towards: .east) == 9)
}

@Test func nothingThatWayIsNil() {
    // The float clips tile 1 but sits on tile 2: west of tile 1 is the edge.
    #expect(Reducer.focusTarget(from: 1, tiles: tiles, floats: [9: float], towards: .west) == nil)
    #expect(Reducer.focusTarget(from: 9, tiles: [:], floats: [9: float], towards: .north) == nil)
}

/// Nothing above the float: north leaves it for the tile it sits on.
@Test func nothingThatWayFromAFloatIsTheTileItSitsOn() {
    #expect(Reducer.focusTarget(from: 9, tiles: tiles, floats: [9: float], towards: .north) == 2)
}

@Test func withoutFloatsItIsTheTileNeighbour() {
    #expect(Reducer.focusTarget(from: 1, tiles: tiles, floats: [:], towards: .east) == 2)
}

@Test func aFloatAloneOnTheWorkspaceCanBeLeftForAnother() {
    let other = Frame(x: 700, y: 300, width: 200, height: 200)
    #expect(Reducer.focusTarget(from: 9, tiles: [:], floats: [9: float, 8: other], towards: .east) == 8)
}

/// A float centred over a single tile — where floating puts it — shares the
/// tile's centre, so nothing lies any way of either. Every direction then
/// changes layer: out of the float to the tile, and back in.
@Test func aFloatCentredOverATileIsReachedAndLeftByAnyDirection() {
    let whole = Frame(x: 8, y: 46, width: 1694, height: 1058)
    let centred = Frame(x: 256, y: 199, width: 1197, height: 752)
    for dir in [Direction.west, .east, .north, .south] {
        #expect(Reducer.focusTarget(from: 9, tiles: [1: whole], floats: [9: centred], towards: dir) == 1)
        #expect(Reducer.focusTarget(from: 1, tiles: [1: whole], floats: [9: centred], towards: dir) == 9)
    }
}

/// A tile whose stack can cycle keeps cycling; the float waits.
@Test func aStackThatCanCycleIsNotLeftForAFloat() {
    let whole = Frame(x: 0, y: 0, width: 1000, height: 800)
    let over = Frame(x: 300, y: 200, width: 400, height: 400)
    #expect(Reducer.focusTarget(from: 1, tiles: [1: whole], floats: [9: over], towards: .east, stackCycles: true) == nil)
}

/// Changing layer goes to the window under the float, not just any tile.
@Test func leavingAFloatGoesToTheTileUnderIt() {
    let small = Frame(x: 420, y: 100, width: 60, height: 60)
    // Over tile 1 near the seam; nothing lies north of it.
    #expect(Reducer.focusTarget(from: 9, tiles: tiles, floats: [9: small], towards: .north) == 1)
}
