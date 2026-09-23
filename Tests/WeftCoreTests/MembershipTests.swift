import Testing
@testable import WeftCore

// A workspace's members are more than its layout. A window floated by hand, a
// window a rule unmanages, a quirk: each is out of the layout and still in the
// workspace, so it hides and shows with it (REDESIGN.md, phase 2). Before
// this, membership WAS the layout, and every such window stayed on screen
// whichever workspace was showing.

/// Three workspaces on one desktop, the virtual shape: the one case where a
/// window's desktop does not say which workspace it is in.
private func anchor() -> (SpaceState, [WorkspaceID]) {
    var s = SpaceState()
    s.adoptDesktops([9], names: ["a", "b", "c"], mode: .virtual, anchor: 1, anchorCount: 3)
    return (s, s.wsOrder)
}

@Test func membersAreTheLayoutThenTheLooseWindows() {
    var (s, ids) = anchor()
    s.file(20, in: ids[0], laidOut: true)
    s.file(10, in: ids[0], laidOut: true)
    s.file(30, in: ids[0], laidOut: false)
    let ws = s.workspaces[ids[0]]!
    #expect(ws.layout.windows.sorted() == [10, 20])
    #expect(ws.loose == [30])
    #expect(Set(ws.members) == [10, 20, 30])
    #expect(ws.members.last == 30)
    #expect(ws.contains(30))
    #expect(s.workspace(holding: 30) == ids[0])
}

@Test func floatingAWindowKeepsItInItsWorkspace() {
    var (s, ids) = anchor()
    s.file(10, in: ids[1], laidOut: true)
    s.file(10, in: ids[1], laidOut: false)
    #expect(s.workspaces[ids[1]]!.layout.windows.isEmpty)
    #expect(s.workspaces[ids[1]]!.loose == [10])
    // And tiling it again takes it back out of the loose set.
    s.file(10, in: ids[1], laidOut: true)
    #expect(s.workspaces[ids[1]]!.layout.windows == [10])
    #expect(s.workspaces[ids[1]]!.loose.isEmpty)
}

@Test func filingAWindowTakesItOutOfEveryOtherWorkspace() {
    var (s, ids) = anchor()
    s.file(10, in: ids[0], laidOut: true)
    s.file(11, in: ids[1], laidOut: false)
    s.file(10, in: ids[2], laidOut: false)
    s.file(11, in: ids[2], laidOut: true)
    #expect(!s.workspaces[ids[0]]!.contains(10))
    #expect(!s.workspaces[ids[1]]!.contains(11))
    // A float moved to another workspace arrives floating, and a tile tiled.
    #expect(s.workspaces[ids[2]]!.loose == [10])
    #expect(s.workspaces[ids[2]]!.layout.windows == [11])
}

@Test func removingAWindowClearsLayoutAndLooseAlike() {
    var (s, ids) = anchor()
    s.file(10, in: ids[0], laidOut: true)
    s.file(11, in: ids[1], laidOut: false)
    s.removeWindow(10)
    s.removeWindow(11)
    #expect(s.workspace(holding: 10) == nil)
    #expect(s.workspace(holding: 11) == nil)
}

@Test func filingIntoAWorkspaceThatDoesNotExistChangesNothing() {
    var (s, ids) = anchor()
    s.file(10, in: ids[0], laidOut: true)
    let before = s
    s.file(10, in: WorkspaceID(999), laidOut: false)
    #expect(s == before)
}

/// The sweep reconciles laid-out and loose windows together, against the
/// whole membership. A float in a hidden workspace is reported on the anchor
/// desktop like everything else there, and must stay where it is rather than
/// join whichever workspace is showing.
@Test func aFloatInAHiddenWorkspaceStaysInIt() {
    var (s, ids) = anchor()
    s.file(10, in: ids[0], laidOut: true)
    s.file(30, in: ids[1], laidOut: false)
    s.active[9] = ids[0]
    let out = reconcileWorkspaces(
        windowDesktops: [10: [9], 30: [9], 40: [9]],
        membership: s.workspaces.mapValues { $0.members },
        desktopOf: s.workspaces.mapValues { $0.desktop },
        activeOn: s.active
    )
    #expect(out[ids[1]] == [30])
    // A new window joins what is showing.
    #expect(out[ids[0]] == [10, 40])
}
