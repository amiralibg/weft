import Testing
@testable import WeftCore

@Test func sharesWithoutMinimumsFollowRatios() {
    let s = constrainedShares(avail: 1000, ratios: [0.5, 0.5], minimums: [0, 0])
    #expect(s == [500, 500])
}

@Test func shareBelowItsMinimumTakesFromTheOthers() {
    // 300 wanted, 500 needed: the 200 comes out of the other two, split by
    // their ratios (0.4 : 0.3).
    let s = constrainedShares(avail: 1000, ratios: [0.3, 0.4, 0.3], minimums: [500, 0, 0])
    #expect(s[0] == 500)
    #expect(abs(s[1] - 500 * 4 / 7) < 1e-9)
    #expect(abs(s[2] - 500 * 3 / 7) < 1e-9)
    #expect(abs(s.reduce(0, +) - 1000) < 1e-9)
}

@Test func takingRoomCanPushASiblingBelowItsOwnMinimum() {
    // Raising the first to 600 leaves the others 200 each; the third needs
    // 300, so it is pinned too and the middle gets what is left.
    let s = constrainedShares(avail: 1000, ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3], minimums: [600, 0, 300])
    #expect(zip(s, [600.0, 100, 300]).allSatisfy { abs($0 - $1) < 1e-9 })
}

@Test func minimumsThatDoNotFitLeaveTheRatiosStanding() {
    let s = constrainedShares(avail: 1000, ratios: [0.5, 0.5], minimums: [700, 400])
    #expect(s == [500, 500])
}

@Test func minimumsThatAreAlreadyMetChangeNothing() {
    let s = constrainedShares(avail: 1000, ratios: [0.6, 0.4], minimums: [300, 300])
    #expect(s == [600, 400])
}

/// 1 on the left, 2 over 3 on the right — what three inserts make.
private func threeWindowTree() -> Tree {
    var tree = Tree()
    for id in [1, 2, 3] as [WindowID] { tree = tree.inserting(id) }
    return tree
}

@Test func layoutGivesATallWindowItsHeightInANestedSplit() {
    let tree = threeWindowTree()
    let plain = layout(tree, in: screen, config: .none)
    // The split shape this test relies on.
    #expect(plain[1]!.height == 800)
    #expect(plain[2]!.x == 500 && plain[3]!.x == 500)
    #expect(plain[2]!.height == 400 && plain[3]!.height == 400)

    var config = TilingConfig.none
    config.minimums = [3: WindowMinimum(width: 0, height: 620)]
    let frames = layout(tree, in: screen, config: config)
    #expect(frames[3]!.height == 620)
    #expect(frames[2]!.height == 180)
    #expect(frames[3]!.y + frames[3]!.height == 800)
    #expect(frames[1] == plain[1])
}

@Test func nestedMinimumsWidenTheSplitThatHoldsThem() {
    // The right column holds a window at least 700 wide: the outer split
    // gives that column 700, and the left window the 300 left.
    let tree = threeWindowTree()
    var config = TilingConfig.none
    config.minimums = [2: WindowMinimum(width: 700, height: 0)]
    let frames = layout(tree, in: screen, config: config)
    #expect(frames[1]!.width == 300)
    #expect(frames[2]!.x == 300 && frames[2]!.width == 700)
    #expect(frames[3]!.width == 700)
}

@Test func nestedMinimumsThatDoNotFitKeepTheRatios() {
    // 2 and 3 stacked need 900 between them, more than the 800 there is.
    let tree = threeWindowTree()
    var config = TilingConfig.none
    config.minimums = [
        2: WindowMinimum(width: 0, height: 450),
        3: WindowMinimum(width: 0, height: 450),
    ]
    let frames = layout(tree, in: screen, config: config)
    #expect(frames[2]!.height == 400 && frames[3]!.height == 400)
}
