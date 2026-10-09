import Foundation
import Testing
@testable import WeftCore
@testable import WeftIPC

// What `query spaces` and `query bar-state` put on the socket. weft-bar
// redraws from it on every focus change and weftctl's doctor reads it, and
// neither notices a field that decodes cleanly into the wrong answer — so the
// shape is pinned here rather than left to be discovered from a menu bar
// showing the wrong desktop.

/// Workspace ids that are nowhere near the desktop ids they are, so a mix-up
/// between the two shows up. Two desktops, 11 showing.
private func state() -> SpaceState {
    var s = SpaceState()
    s.nextWorkspaceID = 900
    s.adoptDisplays(
        [DisplayDesktops(uuid: "DISPLAY-A", desktops: [11, 12], current: 11)],
        names: ["code", "web"]
    )
    return s
}

private func statuses(_ s: SpaceState, declared: [String: LayoutKind] = [:]) -> [SpaceStatus] {
    SpaceStatus.workspaces(in: s, declaredLayout: { declared[$0] }, defaultLayout: .bsp)
}

/// The one that matters. `SpaceStatus.id` is the desktop id, and weft-bar
/// decodes it as one — so a workspace id here would decode cleanly and mean
/// nothing, and nothing anywhere would throw.
@Test func theWireReportsDesktopIdsNotWorkspaceIds() {
    let out = statuses(state())
    #expect(out.map(\.id) == [11, 12])
    #expect(!out.contains { $0.id == 900 || $0.id == 901 })
    #expect(out.map(\.label) == ["code", "web"])
}

/// Label, layout kind and membership come from each workspace, and `current`
/// is whether it is showing.
@Test func eachWorkspaceReportsItsOwnLayoutAndMembers() {
    var s = state()
    s.workspaces[s.wsOrder[1]]?.layout = .float(FloatState(order: [7, 3], remembered: [:], focus: 7))
    s.file(9, in: s.wsOrder[1], laidOut: false)
    let out = statuses(s)
    #expect(out[1].layout == "float")
    #expect(out[1].windows == [3, 7, 9])   // sorted, floats included
    #expect(out[1].current == false)
    #expect(out[0].current == true)
    #expect(out[0].display == "DISPLAY-A")
}

/// An empty workspace shows the kind it *would* get, so the menu bar is not
/// claiming bsp for a workspace declared float in weft.toml.
@Test func anEmptyWorkspaceShowsItsDeclaredLayout() {
    let out = statuses(state(), declared: ["web": .float])
    #expect(out[1].layout == "float")
    #expect(out[0].layout == "bsp")
}

/// A display showing a fullscreen app is paused, and no desktop on it is
/// current.
@Test func nothingIsCurrentOnAPausedDisplay() {
    var s = state()
    s.adoptDisplays([DisplayDesktops(uuid: "DISPLAY-A", desktops: [11, 12], current: 425)], names: nil)
    #expect(statuses(s).allSatisfy { !$0.current })
}

/// Switching desktops moves `current` with it.
@Test func theShowingDesktopIsCurrent() {
    var s = state()
    s.adoptDisplays([DisplayDesktops(uuid: "DISPLAY-A", desktops: [11, 12], current: 12)], names: nil)
    #expect(statuses(s).map(\.current) == [false, true])
}

/// The field names and types weft-bar's own decoder expects. It declares
/// `id: UInt64`, `windows: [Int]` and `spaces: [UInt64]` and does not share
/// these types, so this is the only place the two halves are compared.
@Test func theJSONKeepsTheNamesAndTypesTheBarDecodes() throws {
    var s = state()
    s.setLayout(.tiling(treeFromOrder([42])), on: 11)
    let payload = BarStateStatus(
        spaces: [statuses(s)[0]],
        windows: [BarWindowStatus(id: 42, app: "Ghostty", title: "t", pid: 7, spaces: [11])]
    )
    let data = try JSONEncoder().encode(payload)
    let json = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let space = try #require((json["spaces"] as? [[String: Any]])?.first)
    #expect(Set(space.keys) == ["id", "label", "layout", "windows", "current", "display"])
    #expect(space["id"] as? UInt64 == 11)
    #expect(space["windows"] as? [Int] == [42])
    #expect(space["layout"] as? String == "bsp")

    let window = try #require((json["windows"] as? [[String: Any]])?.first)
    #expect(Set(window.keys) == ["id", "app", "title", "pid", "spaces"])
    #expect(window["spaces"] as? [UInt64] == [11])

    // And it comes back the way it went out.
    #expect(try JSONDecoder().decode(BarStateStatus.self, from: data) == payload)
}

// MARK: - `query workspaces`

// The Settings window and doctor both decide what to *say* from this, so a
// field that decodes into the wrong answer shows up as confident wrong advice
// rather than as a decode failure.

@Test func workspacesStatusRoundTrips() throws {
    let sent = WorkspacesStatus(workspaces: 5, displays: [
        .init(uuid: "A", index: 1, managedDesktop: 1, desktops: 3, paused: false, showing: "code"),
        .init(uuid: "B", index: 2, managedDesktop: nil, desktops: 1, paused: true, showing: nil),
    ])
    let data = try JSONEncoder().encode(sent)
    #expect(try JSONDecoder().decode(WorkspacesStatus.self, from: data) == sent)
    #expect(sent.displaysWithExtraDesktops.map(\.uuid) == ["A"])
}

/// The menu bar names the workspace on the display focus is on, not the
/// first display's.
@Test func theBarNamesTheWorkspaceOnTheFocusedDisplay() throws {
    func status(_ label: String, _ display: String, current: Bool) -> SpaceStatus {
        SpaceStatus(id: 1, label: label, layout: "bsp", windows: [], current: current, display: display)
    }
    let spaces = [
        status("1", "A", current: false), status("2", "A", current: true),
        status("7", "B", current: true), status("8", "B", current: false),
    ]
    #expect(BarStateStatus.current(in: spaces, focusedDisplay: "B")?.label == "7")
    #expect(BarStateStatus.current(in: spaces, focusedDisplay: "A")?.label == "2")
    // Unknown or missing (an older daemon): the first showing, as before.
    #expect(BarStateStatus.current(in: spaces, focusedDisplay: nil)?.label == "2")
    #expect(BarStateStatus.current(in: spaces, focusedDisplay: "C")?.label == "2")

    let sent = BarStateStatus(spaces: spaces, windows: [], focusedDisplay: "B")
    let data = try JSONEncoder().encode(sent)
    #expect(try JSONDecoder().decode(BarStateStatus.self, from: data) == sent)
}
