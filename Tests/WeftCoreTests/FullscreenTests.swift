import Testing
@testable import WeftCore

// Native-fullscreen exits (REDESIGN.md): the world skips fullscreen spaces,
// so a window that enters one drops out of every sweep until it leaves. The
// memo is the only thing that can both file it back into its workspace and
// restart its workspace's exact arrangement, and keep a rule from yanking it
// to the app's own desktop at exit.

private func anchor() -> (SpaceState, WorkspaceID) {
    var s = SpaceState()
    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [7], current: 7)], names: ["a"])
    return (s, s.wsOrder[0])
}

private func tiled(_ s: inout SpaceState, _ wsid: WorkspaceID, _ wids: [WindowID]) {
    var tree = Tree()
    for id in wids { tree = tree.inserting(id) }
    s.setLayout(.tiling(tree), of: wsid)
}

@Test func captureRemembersTheWholeTree() {
    var (s, wsid) = anchor()
    tiled(&s, wsid, [10, 20, 30])
    let memo = fullscreenMemo(s, of: 20)
    #expect(memo?.workspace == wsid)
    #expect(memo?.tree?.windows == [10, 20, 30])
    // Still true with the window anywhere in the order.
    let other = fullscreenMemo(s, of: 10)
    #expect(other?.tree?.windows == [10, 20, 30])
}

@Test func captureOfALooseWindowHasNoTree() {
    var (s, wsid) = anchor()
    s.file(10, in: wsid, laidOut: false)
    let memo = fullscreenMemo(s, of: 10)
    #expect(memo?.workspace == wsid)
    #expect(memo?.tree == nil)
}

@Test func captureOfAWindowWeftNeverHeldIsNil() {
    let (s, _) = anchor()
    #expect(fullscreenMemo(s, of: 10) == nil)
}

@Test func settleWaitsWhileStillFullscreen() {
    var (s, wsid) = anchor()
    tiled(&s, wsid, [10, 20])
    let memo = fullscreenMemo(s, of: 20)!
    #expect(fullscreenSettle(stillFullscreen: true, memo: memo, state: s, of: 20) == .fullscreen)
}

@Test func settleAtHomeRestoresTheExactArrangement() {
    var (s, wsid) = anchor()
    tiled(&s, wsid, [10, 20, 30])
    let memo = fullscreenMemo(s, of: 20)!
    // While the window was fullscreen: its desktop is paused, so nothing
    // could change the arrangement. The exit sweep re-files 20 and the sync
    // inserts it wherever; the members still match the remembered tree.
    var reflowed = Tree()
    for id in [10, 30] as [WindowID] { reflowed = reflowed.inserting(id, in: screen, config: .none) }
    reflowed = reflowed.inserting(20, in: screen, config: .none)
    s.setLayout(.tiling(reflowed), of: wsid)
    #expect(fullscreenSettle(stillFullscreen: false, memo: memo, state: s, of: 20) == .home(memo.tree))
}

@Test func settleAtHomeKeepsTheSweepsInsertWhenMembersChanged() {
    var (s, wsid) = anchor()
    tiled(&s, wsid, [10, 20])
    let memo = fullscreenMemo(s, of: 20)!
    // A window opened while the movie was on (a sheet's app, say): the
    // arrangement can no longer be rewound, so the sweep's own insert stays.
    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [7, 8], current: 7)], names: ["a", "b"])
    tiled(&s, wsid, [10, 20, 40])
    #expect(fullscreenSettle(stillFullscreen: false, memo: memo, state: s, of: 20) == .home(nil))
}

@Test func settleWantsOneBridgedMoveWhenTheExitLandedElsewhere() {
    var s = SpaceState()
    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [7, 8], current: 7)], names: ["a", "b"])
    let hidden = s.wsOrder[1]
    tiled(&s, hidden, [10])
    let memo = fullscreenMemo(s, of: 10)!
    // macOS filed the exit on the showing desktop instead: the sync moved
    // the membership there, so the workspace is home but the window is not.
    // Its workspace hidden: the exit was the user's own act, so follow.
    s.file(10, in: s.wsOrder[0], laidOut: false)
    #expect(fullscreenSettle(stillFullscreen: false, memo: memo, state: s, of: 10) == .move(follow: true))
    // Showing right now: nothing needs to be taken over.
    s.currentByDisplay["A"] = s.desktop(of: hidden)
    #expect(fullscreenSettle(stillFullscreen: false, memo: memo, state: s, of: 10) == .move(follow: false))
}

@Test func settleForgetsWhenTheWorkspaceIsGone() {
    var s = SpaceState()
    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [7, 8], current: 7)], names: ["a", "b"])
    let wsid = s.wsOrder[1]
    tiled(&s, wsid, [10])
    let memo = fullscreenMemo(s, of: 10)!
    // The desktop went away (display unplugged): the workspace is stashed,
    // macOS has the window, and the memo points nowhere.
    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [7], current: 7)], names: [])
    #expect(s.workspaces[wsid] == nil)
    #expect(fullscreenSettle(stillFullscreen: false, memo: memo, state: s, of: 10) == .forget)
}

@Test func rulePolicyDropsTheMemoWheresVisibleItWas() {
    var s = SpaceState()
    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [7, 8], current: 7)], names: ["a", "b"])
    let wsid = s.wsOrder[1]
    tiled(&s, wsid, [10])
    let memo = fullscreenMemo(s, of: 10)!
    // The user chose the rule: the exit is the rule's desktop decision to
    // make, so the memo never gets to decide — even when everything looks
    // exactly like the restore-ready case above.
    s.file(10, in: s.wsOrder[0], laidOut: false)
    #expect(fullscreenSettle(
        stillFullscreen: false, memo: memo, state: s, of: 10, policy: .rule) == .forget)
    #expect(fullscreenSettle(
        stillFullscreen: false, memo: memo, state: s, of: 10, policy: .last) != .forget)
}
