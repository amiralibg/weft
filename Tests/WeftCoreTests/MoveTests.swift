import Testing

@testable import WeftCore

/// `move <dir>` — the structural step, i3's `move` and yabai's `window --warp`.
///
/// The property every case here is really checking is that a window which
/// moves does not also change size for no reason. Swapping leaves, which is
/// what this replaced, could not hold that: a half-screen window told to go
/// east came back as a quarter because the window it landed on owned a
/// quarter.
private let moveScreen = Frame(x: 0, y: 0, width: 1000, height: 800)

/// `splitV[A, splitH[B, C]]` — A owns the left half, B and C a quarter each.
///
///     +-------+-------+
///     |       |   2   |
///     |   1   +-------+
///     |       |   3   |
///     +-------+-------+
private func twoOverOne() -> Tree {
    var tree = Tree()
    tree = tree.inserting(1, in: moveScreen, config: .none)
    tree = tree.inserting(2, in: moveScreen, config: .none)
    tree = tree.inserting(3, in: moveScreen, config: .none)
    return tree
}

@Test func theFixtureIsTheShapeTheseTestsAssume() {
    let f = layout(twoOverOne(), in: moveScreen, config: .none)
    #expect(f[1] == Frame(x: 0, y: 0, width: 500, height: 800))
    #expect(f[2] == Frame(x: 500, y: 0, width: 500, height: 400))
    #expect(f[3] == Frame(x: 500, y: 400, width: 500, height: 400))
}

@Test func movingEastKeepsTheWindowsSize() {
    // The whole reason this exists. A half-screen window sent east is a
    // half-screen window on the right — not a quarter in the top corner,
    // which is what swapping it with window 2 produced.
    let moved = twoOverOne().focusing(1).moving(1, towards: .east)
    let f = layout(moved, in: moveScreen, config: .none)
    #expect(f[1] == Frame(x: 500, y: 0, width: 500, height: 800))
    #expect(f[2] == Frame(x: 0, y: 0, width: 500, height: 400))
    #expect(f[3] == Frame(x: 0, y: 400, width: 500, height: 400))
}

@Test func swappingIsStillAvailableAndStillSwaps() {
    // `swap` keeps the old meaning, and the old shape: the two windows take
    // each other's slots, so window 1 really does become a quarter.
    let swapped = twoOverOne().focusing(1).swapping(1, 2)
    let f = layout(swapped, in: moveScreen, config: .none)
    #expect(f[2] == Frame(x: 0, y: 0, width: 500, height: 800))
    #expect(f[1] == Frame(x: 500, y: 0, width: 500, height: 400))
}

@Test func aNestedWindowIsLiftedOutOfItsColumn() {
    // Window 2 is in the right-hand column with 3. West is one step west —
    // out of the column and into the row, which is three columns.
    let moved = twoOverOne().focusing(2).moving(2, towards: .west)
    #expect(moved.windows.sorted() == [1, 2, 3])
    let f = layout(moved, in: moveScreen, config: .none)
    // Left to right: 1, 2, 3 — and it landed *between* them, not at the far end.
    #expect(f[1]!.x < f[2]!.x)
    #expect(f[2]!.x < f[3]!.x)
    // Full height: it is no longer sharing a column with anything.
    #expect(f[2]!.height == 800)
}

@Test func movingInsideAColumnStaysInTheColumn() {
    // South, within the right-hand column: 2 and 3 trade rows and nothing
    // else about the layout changes.
    let moved = twoOverOne().focusing(2).moving(2, towards: .south)
    let f = layout(moved, in: moveScreen, config: .none)
    #expect(f[1] == Frame(x: 0, y: 0, width: 500, height: 800))
    #expect(f[3] == Frame(x: 500, y: 0, width: 500, height: 400))
    #expect(f[2] == Frame(x: 500, y: 400, width: 500, height: 400))
}

@Test func movingOffTheEdgeOfTheTreeDoesNothing() {
    // Nothing is east of window 2, and this is where yabai fails too — which
    // is what lets `{ move east } || { … }` in a keybind fall through.
    let tree = twoOverOne().focusing(2)
    #expect(tree.moving(2, towards: .east) == tree)
    #expect(tree.moving(2, towards: .north) == tree)
    // And the lone-window case, in every direction.
    var single = Tree()
    single = single.inserting(9, in: moveScreen, config: .none).focusing(9)
    for dir in [Direction.west, .east, .north, .south] {
        #expect(single.moving(9, towards: dir) == single)
    }
}

@Test func sizesAreCarriedAcrossASwapOfPlaces() {
    // A 70/30 split, moved. Both windows keep the size they had: the point of
    // `move` is that the window travels, not that it is resized by travelling.
    //
    // Compared with a tolerance, unlike the tests above, because a hand-set
    // ratio is not a power of two — `resizing` leaves 0.30000000000000004 —
    // and every frame downstream of it carries that. A tenth of a point is
    // not a layout difference; asserting exact equality here would be
    // asserting something about Double, not about the window manager.
    var tree = Tree()
    tree = tree.inserting(1, in: moveScreen, config: .none)
    tree = tree.inserting(2, in: moveScreen, config: .none)
    tree = tree.resizing(focused: 1, axis: .horizontal, delta: 200, totalSize: 1000)
    let before = layout(tree, in: moveScreen, config: .none)
    #expect(near(before[1]!.width, 700))
    #expect(near(before[2]!.width, 300))

    let after = layout(tree.focusing(1).moving(1, towards: .east), in: moveScreen, config: .none)
    #expect(near(after[1]!.width, 700))
    #expect(near(after[2]!.width, 300))
    #expect(near(after[2]!.x, 0))
    #expect(near(after[1]!.x, 300))
}

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.1 }

@Test func aStackedWindowWalksOutOfTheStack() {
    // A stack runs along no axis, so a direction takes the window out of it.
    // Putting one *in* is `stack move <dir>`, which is a different verb.
    var tree = twoOverOne().focusing(2)
    tree = tree.togglingStack()
    #expect(hiddenStackMembers(in: tree).count == 1)
    let moved = tree.moving(2, towards: .west)
    #expect(moved.windows.sorted() == [1, 2, 3])
    // Out: nothing is hidden behind anything any more.
    #expect(hiddenStackMembers(in: moved).isEmpty)
    #expect(layout(moved, in: moveScreen, config: .none).count == 3)
}

@Test func theMovedWindowKeepsFocus() {
    // It is the window the user is thinking about; focus following it is what
    // makes a second press move it again rather than move something else.
    let moved = twoOverOne().focusing(1).moving(1, towards: .east)
    #expect(moved.focus == 1)
    let twice = moved.moving(1, towards: .west)
    #expect(twice.focus == 1)
}

@Test func everyWindowSurvivesEveryMove() {
    // The edit removes a node and reinserts it, which is the shape of bug that
    // loses a window. Every direction from every window, on a four-window
    // tree, must come back with all four and with no window in two places.
    var tree = Tree()
    for id in [1, 2, 3, 4] as [WindowID] { tree = tree.inserting(id, in: moveScreen, config: .none) }
    for start in [1, 2, 3, 4] as [WindowID] {
        for dir in [Direction.west, .east, .north, .south] {
            let moved = tree.focusing(start).moving(start, towards: dir)
            #expect(moved.windows.sorted() == [1, 2, 3, 4], "\(start) \(dir)")
            #expect(Set(moved.windows).count == 4, "\(start) \(dir) duplicated a window")
            // Every window still gets exactly one frame, and none is degenerate.
            let f = layout(moved, in: moveScreen, config: .none)
            #expect(f.count == 4, "\(start) \(dir)")
            #expect(f.values.allSatisfy { $0.width > 0 && $0.height > 0 }, "\(start) \(dir)")
        }
    }
}

@Test func movingIsReversibleOnASimpleSplit() {
    // Not a general property — lifting a window out of a column cannot put the
    // column back — but on a flat row it has to hold, and it is the case a
    // user exercises constantly by tapping a key twice.
    let flat = Tree(root: .container(Container(
        layout: .splitV, children: [.window(1), .window(2), .window(3)])), focus: 2)
    #expect(flat.moving(2, towards: .east).moving(2, towards: .west) == flat)
    #expect(flat.moving(2, towards: .west).moving(2, towards: .east) == flat)
}

@Test func fullscreenIsLeftAlone() {
    // A zoomed window covers the space, so there is no neighbour to step
    // towards and rearranging the tree underneath it would only surprise
    // whoever un-zooms it.
    let tree = twoOverOne().focusing(1).togglingFullscreen()
    #expect(tree.fullscreen == 1)
    #expect(tree.moving(1, towards: .east) == tree)
}
