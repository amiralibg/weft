import Foundation
import Testing
@testable import WeftCore

// A bridged move or switch is judged by what reads back, never by what the
// call returned. These are the judgements.

@Test func aMoveArrivesOnlyOnExactlyTheTarget() {
    let v = MoveVerdict.judge([1, 2, 3, 4], target: 9, readBack: [1: [9], 2: [8], 3: [8, 9]])
    #expect(v.arrived == [1])
    #expect(v.missing == [2, 3, 4])
    #expect(!v.complete)
}

@Test func aMoveOfEveryWindowIsComplete() {
    #expect(MoveVerdict.judge([1, 2], target: 9, readBack: [1: [9], 2: [9]]).complete)
}

@Test func aSwitchThatReadsBackElsewhereDidNotLand() {
    let v = SwitchVerdict.judge(target: 5, currentAfter: 4, expectShown: [], expectHidden: [], onScreen: [])
    #expect(v == .notCurrent(showing: 4))
}

// S11: SetCurrentSpace alone reads back the target and leaves the old
// desktop's windows on the glass.
@Test func aSwitchThatLeavesTheOldDesktopOnScreenDidNotLand() {
    let v = SwitchVerdict.judge(target: 5, currentAfter: 5, expectShown: [10], expectHidden: [20, 21], onScreen: [10, 21])
    #expect(v == .oldStillShown([21]))
}

@Test func aSwitchWhoseTargetWindowsAreNotOnScreenDidNotLand() {
    let v = SwitchVerdict.judge(target: 5, currentAfter: 5, expectShown: [10, 11], expectHidden: [], onScreen: [10])
    #expect(v == .targetNotShown([11]))
}

// The daemon's view of a desktop can hold a window an app hid with ⌘H. One of
// the target's windows on screen is a switch that painted.
@Test func theDaemonNeedsOneTargetWindowOnScreen() {
    let one = SwitchVerdict.judge(target: 5, currentAfter: 5, expectShown: [10, 11], expectHidden: [], onScreen: [11], quorum: .any)
    #expect(one.landed)
    let none = SwitchVerdict.judge(target: 5, currentAfter: 5, expectShown: [10, 11], expectHidden: [], onScreen: [], quorum: .any)
    #expect(none == .targetNotShown([10, 11]))
}

// S12: an ordered-out popover on the target is never on screen. It is not a
// managed window, so the caller does not pass it, and a good switch lands.
@Test func anEmptyTargetLandsOnTheReadBackAlone() {
    let v = SwitchVerdict.judge(target: 5, currentAfter: 5, expectShown: [], expectHidden: [20], onScreen: [99])
    #expect(v.landed)
}

@Test func switchMethodFallsBackInOrder() {
    var r = NativeRoutes(macOSBuild: "26A434")
    #expect(r.switchMethod == .none)
    r[.dockSwipe] = RouteStatus(.passed, "")
    #expect(r.switchMethod == .dockSwipe)
    r[.switchDesktop] = RouteStatus(.passed, "")
    #expect(r.switchMethod == .dockSwipe, "the bridged switch needs the symbol walk too")
    r[.symbols] = RouteStatus(.passed, "")
    #expect(r.switchMethod == .bridged)
}

@Test func movingNeedsBothTheSymbolsAndTheMoveTest() {
    var r = NativeRoutes(macOSBuild: "26A434", routes: [.move: RouteStatus(.passed, "")])
    #expect(!r.canMove)
    r[.symbols] = RouteStatus(.passed, "")
    #expect(r.canMove)
}

@Test func routesRoundTripThroughJSON() throws {
    let r = NativeRoutes(macOSBuild: "26A434", routes: [.switchDesktop: RouteStatus(.failed, "the display still shows desktop 3")])
    let data = try JSONEncoder().encode(r)
    #expect(try JSONDecoder().decode(NativeRoutes.self, from: data) == r)
}
