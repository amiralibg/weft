import Testing
@testable import WeftCore

// A workspace's members are more than its layout. A window floated by hand, a
// window a rule unmanages, a quirk: each is out of the layout and still on its
// desktop's workspace, so focus history and moves treat it as a member.

/// Three desktops, one workspace each.
private func anchor() -> (SpaceState, [WorkspaceID]) {
    var s = SpaceState()
    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [7, 8, 9], current: 9)], names: ["a", "b", "c"])
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
