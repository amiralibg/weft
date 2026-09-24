import Testing
@testable import WeftCore

// Where hidden windows go on a multi-display Mac, and which display a pinned
// workspace means. A hidden window parked into a neighbouring display shows
// up on that display, which is the bug the corner choice exists to prevent.

private let laptop = Frame(x: 0, y: 0, width: 1728, height: 1117)

@Test func aSingleDisplayParksBottomRight() {
    #expect(freeCorner(of: laptop, among: [laptop]) == .bottomRight)
    let o = parkOrigin(width: 800, height: 600, corner: .bottomRight, in: laptop)
    #expect(o.x == 1727 && o.y == 1116)
}

@Test func aMonitorToTheRightMovesTheLaptopsCornerLeft() {
    let right = Frame(x: 1728, y: -200, width: 2560, height: 1440)
    #expect(freeCorner(of: laptop, among: [laptop, right]) == .bottomLeft)
    // And the monitor itself still has its bottom-right.
    #expect(freeCorner(of: right, among: [laptop, right]) == .bottomRight)
}

@Test func aMonitorBelowAndToTheRightStillLeavesATopCorner() {
    let right = Frame(x: 1728, y: 0, width: 1728, height: 1117)
    let below = Frame(x: 0, y: 1117, width: 1728, height: 1117)
    let belowRight = Frame(x: 1728, y: 1117, width: 1728, height: 1117)
    let all = [laptop, right, below, belowRight]
    #expect(freeCorner(of: laptop, among: all) == .topLeft)
}

@Test func aMiddleMonitorBoxedInHasNoFreeCorner() {
    let middle = Frame(x: 0, y: 0, width: 1000, height: 1000)
    let others = [
        Frame(x: -1000, y: -1000, width: 1000, height: 3000),   // left, tall
        Frame(x: 1000, y: -1000, width: 1000, height: 3000),    // right, tall
        Frame(x: 0, y: -1000, width: 1000, height: 1000),       // above
        Frame(x: 0, y: 1000, width: 1000, height: 1000),        // below
    ]
    #expect(freeCorner(of: middle, among: [middle] + others) == nil)
}

/// Displays that only touch are not in each other's way: the park zone may
/// share an edge with a neighbour without covering any of it.
@Test func touchingIsNotOverlapping() {
    let above = Frame(x: 0, y: -1117, width: 1728, height: 1117)
    #expect(freeCorner(of: laptop, among: [laptop, above]) == .bottomRight)
}

@Test func parkingAtATopLeftCornerLeavesOnePointOnScreen() {
    let o = parkOrigin(width: 800, height: 600, corner: .topLeft, in: laptop)
    #expect(o.x + 800 - 1 == laptop.x && o.y + 600 - 1 == laptop.y)
}

// MARK: - Pins

private let displays = [
    DisplayIdentity(uuid: "L", name: "Built-in Retina Display", isMain: false),
    DisplayIdentity(uuid: "S", name: "Studio Display", isMain: true),
    DisplayIdentity(uuid: "R", name: "LG UltraFine", isMain: false),
]

@Test func pinsResolveByRoleNumberAndName() {
    #expect(resolvePin(DisplayPin("main"), among: displays) == "S")
    #expect(resolvePin(DisplayPin("secondary"), among: displays) == "L")
    #expect(resolvePin(DisplayPin("3"), among: displays) == "R")
    #expect(resolvePin(DisplayPin("studio"), among: displays) == "S")
    #expect(resolvePin(DisplayPin("built-in"), among: displays) == "L")
    // Not connected: nil, and the workspace behaves as unpinned.
    #expect(resolvePin(DisplayPin("4"), among: displays) == nil)
    #expect(resolvePin(DisplayPin("Dell"), among: displays) == nil)
}

private func adopt(_ s: inout SpaceState, _ uuids: [String], names: [String]? = nil, pins: [String: String] = [:]) {
    let reported = uuids.enumerated().map { i, u in
        DisplayDesktops(uuid: u, desktops: [SpaceID(10 * (i + 1))], current: SpaceID(10 * (i + 1)))
    }
    s.adoptDisplays(reported, names: names, pins: pins)
}

/// A pinned workspace goes to its display when that display has nothing to
/// show, ahead of the order it is declared in.
@Test func aPinnedWorkspaceShowsOnItsDisplay() {
    var s = SpaceState()
    adopt(&s, ["A", "B"], names: ["main", "chat", "code"], pins: ["code": "B"])
    #expect(s.label(of: s.active[20]!) == "code")
    #expect(s.label(of: s.active[10]!) == "main")
}

/// A display plugged back in shows what it showed before it went.
@Test func aReturningDisplayShowsWhatItLastShowed() {
    var s = SpaceState()
    adopt(&s, ["A", "B"], names: ["main", "chat", "code"])
    let code = s.id(forLabel: "code")!
    s.show(code, on: 20)
    adopt(&s, ["A"])
    #expect(s.active[20] == nil)
    adopt(&s, ["A", "B"])
    #expect(s.active[20] == code)
}

/// A laptop with its lid open under a monitor that has the menu bar: "main"
/// is the monitor, and "built-in" and "external" name the displays by what
/// they are. "external" used to mean "not main", which on this arrangement
/// is the laptop.
@Test func builtInAndExternalNameTheDisplayNotItsRole() {
    let desk = [
        DisplayIdentity(uuid: "M", name: "SAMSUNG", isMain: true),
        DisplayIdentity(uuid: "L", name: "Built-in Retina Display", isMain: false, isBuiltIn: true),
    ]
    #expect(resolvePin(DisplayPin("main"), among: desk) == "M")
    #expect(resolvePin(DisplayPin("built-in"), among: desk) == "L")
    #expect(resolvePin(DisplayPin("external"), among: desk) == "M")
    #expect(resolvePin(DisplayPin("secondary"), among: desk) == "L")
}

/// Asked of the display, so a built-in screen whose name was not read (or is
/// localized) still resolves.
@Test func builtInDoesNotNeedTheName() {
    let ids = [
        DisplayIdentity(uuid: "E", name: "", isMain: false),
        DisplayIdentity(uuid: "L", name: "", isMain: true, isBuiltIn: true),
    ]
    #expect(resolvePin(DisplayPin("built-in"), among: ids) == "L")
    #expect(resolvePin(DisplayPin("external"), among: ids) == "E")
}

/// A Mac with no screen of its own: "external" is the first that is not main.
@Test func externalOnADesktopMacIsTheOneWithoutTheMenuBar() {
    let ids = [
        DisplayIdentity(uuid: "A", name: "Dell", isMain: true),
        DisplayIdentity(uuid: "B", name: "LG", isMain: false),
    ]
    #expect(resolvePin(DisplayPin("external"), among: ids) == "B")
    #expect(resolvePin(DisplayPin("built-in"), among: ids) == nil)
}
