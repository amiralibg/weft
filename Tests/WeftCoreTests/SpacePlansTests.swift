import Testing
@testable import WeftCore

// Which desktop shows, where a window ends up, what a command answers —
// decided from a snapshot (NATIVE.md, "Testing Decisions").

/// Two displays: the laptop (main) with desktops 1, 2, 3 showing 1, and a
/// monitor to the east with 7, 8 showing 7. Focus on the laptop.
private func twoDisplays() -> SpaceState {
    var s = SpaceState()
    s.adoptDisplays([
        DisplayDesktops(uuid: "L", desktops: [1, 2, 3], current: 1, isMain: true),
        DisplayDesktops(uuid: "M", desktops: [7, 8], current: 7, originX: 2000),
    ], names: ["mail", "code"])
    s.focusedDisplay = "L"
    return s
}

private func id(_ s: SpaceState, _ sid: SpaceID) -> WorkspaceID { s.active[sid]! }

// MARK: - space focus

@Test func focusingADesktopSwitchesItsDisplayInOneStep() {
    var s = twoDisplays()
    s.file(30, in: id(s, 3), laidOut: true, focus: true)
    #expect(s.planFocus(id(s, 3)) == [.switchDisplay(display: "L", from: 1, to: 3), .focus(30)])
}

@Test func anEmptyDesktopTakesFocusItself() {
    let s = twoDisplays()
    #expect(s.planFocus(id(s, 2)) == [.switchDisplay(display: "L", from: 1, to: 2), .focus(nil)])
}

/// Story 5: ⌥N for a desktop showing on another display moves focus there and
/// switches nothing.
@Test func aDesktopShowingOnAnotherDisplayIsAFocusMove() {
    var s = twoDisplays()
    s.file(70, in: id(s, 7), laidOut: true, focus: true)
    #expect(s.planFocus(id(s, 7)) == [.focusDisplay("M"), .focus(70)])
}

@Test func theDesktopAlreadyHereIsNothing() {
    let s = twoDisplays()
    #expect(s.planFocus(id(s, 1)) == [.nothing("already on mail")])
}

/// A desktop on the other display that is not showing switches that display,
/// not this one.
@Test func aHiddenDesktopOnTheOtherDisplaySwitchesThatDisplay() {
    let s = twoDisplays()
    #expect(s.planFocus(id(s, 8)) == [.switchDisplay(display: "M", from: 7, to: 8), .focus(nil)])
}

/// From a fullscreen app's space, ⌥N switches straight to the desktop (S12).
@Test func focusingFromAFullscreenSpaceSwitchesFromIt() {
    var s = SpaceState()
    s.adoptDisplays([DisplayDesktops(uuid: "L", desktops: [1, 2], current: 425, isMain: true)])
    #expect(s.planFocus(id(s, 1)) == [.switchDisplay(display: "L", from: 425, to: 1), .focus(nil)])
}

@Test func nextPrevAndRecentResolveThenPlan() {
    var s = twoDisplays()
    #expect(s.resolveWorkspace("prev") == nil)
    #expect(s.refusal(for: "prev") == "no desktop before this one on this display")
    let next = s.resolveWorkspace("next")!
    #expect(s.planFocus(next) == [.switchDisplay(display: "L", from: 1, to: 2), .focus(nil)])
    s.recentWorkspace = id(s, 8)
    #expect(s.planFocus(s.resolveWorkspace("recent")!).first == .switchDisplay(display: "M", from: 7, to: 8))
}

@Test func aMissingDesktopIsRefusedWithHowToAddOne() {
    let s = twoDisplays()
    #expect(s.resolveWorkspace("9") == nil)
    #expect(s.refusal(for: "9") == "desktop 9 does not exist; add desktops in Mission Control (weft cannot create them)")
    var labelled = s
    labelled.relabel(["a", "b", "c", "d", "e", "music"])
    #expect(labelled.refusal(for: "music") == "desktop 6 ('music') does not exist; add desktops in Mission Control (weft cannot create them)")
}

// MARK: - space move-window

@Test func movingAWindowStaysPutByDefault() {
    var s = twoDisplays()
    s.file(10, in: id(s, 1), laidOut: true)
    s.file(11, in: id(s, 1), laidOut: true, focus: true)
    #expect(s.planMoveWindow(11, on: [1], to: id(s, 2), follow: false) == [
        .move([11], to: 2), .retile(1), .retile(2), .focus(10),
    ])
}

@Test func movingWithFollowGoesWithIt() {
    var s = twoDisplays()
    s.file(11, in: id(s, 1), laidOut: true, focus: true)
    #expect(s.planMoveWindow(11, on: [1], to: id(s, 3), follow: true) == [
        .move([11], to: 3), .retile(1), .retile(3),
        .switchDisplay(display: "L", from: 1, to: 3), .focus(11),
    ])
}

/// The last window sent away leaves the desktop empty: focus goes to the
/// desktop itself, not the window that just left.
@Test func sendingTheLastWindowAwayFocusesTheDesktop() {
    var s = twoDisplays()
    s.file(11, in: id(s, 1), laidOut: true, focus: true)
    #expect(s.planMoveWindow(11, on: [1], to: id(s, 2), follow: false).last == .focus(nil))
}

/// Across displays: one move to the other display's desktop, both laid out.
@Test func movingToADesktopOnTheOtherDisplay() {
    var s = twoDisplays()
    s.file(11, in: id(s, 1), laidOut: true, focus: true)
    #expect(s.planMoveWindow(11, on: [1], to: id(s, 8), follow: false) == [
        .move([11], to: 8), .retile(1), .retile(8), .focus(nil),
    ])
}

@Test func aWindowOnEveryDesktopIsNeverMoved() {
    let s = twoDisplays()
    let plan = s.planMoveWindow(11, on: [1, 2], to: id(s, 3), follow: false)
    #expect(plan.count == 1)
    guard case .refuse(let why) = plan[0] else { Issue.record("not refused"); return }
    #expect(why.contains("All Desktops"))
}

@Test func movingToTheDesktopItIsOnIsNothingOrAFollow() {
    var s = twoDisplays()
    s.file(30, in: id(s, 3), laidOut: true, focus: true)
    #expect(s.planMoveWindow(30, on: [3], to: id(s, 3), follow: false) == [.nothing("already on 3")])
    #expect(s.planMoveWindow(30, on: [3], to: id(s, 3), follow: true) == [
        .switchDisplay(display: "L", from: 1, to: 3), .focus(30),
    ])
}

/// A rule places a new window with the same plan: a window opening on the
/// desktop showing goes to its rule's desktop, and with follow-space-rules
/// the screen follows.
@Test func aRulePlacesANewWindowAndFollows() {
    var s = twoDisplays()
    s.file(40, in: id(s, 1), laidOut: true)
    let code = s.resolveWorkspace("code")!
    #expect(s.planMoveWindow(40, on: [1], to: code, follow: true) == [
        .move([40], to: 2), .retile(1), .retile(2),
        .switchDisplay(display: "L", from: 1, to: 2), .focus(40),
    ])
}

/// A window in a fullscreen space is on no workspace's desktop: moving it is
/// a move with nothing to re-tile behind it.
@Test func aWindowOnNoDesktopMovesWithNothingLeftBehind() {
    let s = twoDisplays()
    #expect(s.planMoveWindow(50, on: [425], to: id(s, 2), follow: false) == [.move([50], to: 2), .retile(2)])
}
