import Foundation
import Testing
@testable import WeftCore
@testable import WeftIPC

// What `query spaces` and `query bar-state` put on the socket. weft-bar
// redraws from it on every focus change and weftctl's doctor reads it, and
// neither notices a field that decodes cleanly into the wrong answer — so the
// shape is pinned here rather than left to be discovered from a menu bar
// showing the wrong desktop.

/// Workspace ids that are nowhere near the desktop ids they sit on. Under the
/// identity mapping the two are handed out in step and a mix-up is invisible;
/// these make one show up.
private func state() -> SpaceState {
    var s = SpaceState()
    s.nextWorkspaceID = 900
    s.adoptDesktops([11, 12], names: ["code", "web"])
    s.displayBySpace = [11: "DISPLAY-A", 12: "DISPLAY-A"]
    s.displays = ["DISPLAY-A"]
    s.currentByDisplay = ["DISPLAY-A": 11]
    return s
}

private func status(_ s: SpaceState, _ sid: SpaceID, fallback: [WindowID] = []) -> SpaceStatus {
    SpaceStatus.of(
        desktop: sid,
        in: s,
        display: s.displayBySpace[sid] ?? "",
        current: s.currentByDisplay["DISPLAY-A"] == sid,
        declaredLayout: { _ in nil },
        defaultLayout: .bsp,
        fallbackWindows: fallback
    )
}

/// The one that matters. `SpaceStatus.id` is the native space id, and weft-bar
/// hands it straight back to `space focus` — so a workspace id here names a
/// different desktop and nothing anywhere throws.
@Test func theWireReportsDesktopIdsNotWorkspaceIds() {
    let s = state()
    #expect(s.active[11] == WorkspaceID(900))
    #expect(status(s, 11).id == 11)
    #expect(status(s, 12).id == 12)
    // And nothing on the wire carries a workspace id at all.
    #expect(status(s, 11).id != 900)
}

/// Label, layout kind and membership all come from the workspace showing on
/// the desktop — which is what makes this survive Phase 3 unchanged.
@Test func aDesktopReportsTheWorkspaceShowingOnIt() {
    var s = state()
    s.setLayout(.float(FloatState(order: [7, 3], remembered: [:], focus: 7)), on: 12)
    let out = status(s, 12)
    #expect(out.label == "web")
    #expect(out.layout == "float")
    #expect(out.windows == [3, 7])   // sorted, so a redraw does not reorder
    #expect(out.current == false)
    #expect(out.display == "DISPLAY-A")
    #expect(status(s, 11).current == true)
}

/// A desktop weft has not swept yet has no workspace. It still has to report
/// something, and reporting an empty window list would blank the menu bar for
/// a desktop that plainly has windows on it.
@Test func anUnsweptDesktopFallsBackToTheWindowServer() {
    let s = SpaceState()
    let out = SpaceStatus.of(
        desktop: 99,
        in: s,
        display: "DISPLAY-A",
        current: false,
        declaredLayout: { _ in nil },
        defaultLayout: .bsp,
        fallbackWindows: [4, 5]
    )
    #expect(out.id == 99)
    #expect(out.label == "99")       // its own id, for want of anything better
    #expect(out.layout == "bsp")
    #expect(out.windows == [4, 5])
}

/// An unvisited desktop shows the kind it *would* get, so the menu bar is not
/// claiming bsp for a space declared float in weft.toml.
@Test func anUnsweptDesktopShowsItsDeclaredLayout() {
    let out = SpaceStatus.of(
        desktop: 99,
        in: SpaceState(),
        display: "D",
        current: false,
        declaredLayout: { $0 == "99" ? .float : nil },
        defaultLayout: .bsp
    )
    #expect(out.layout == "float")
}

/// The field names and types weft-bar's own decoder expects. It declares
/// `id: UInt64`, `windows: [Int]` and `spaces: [UInt64]` and does not share
/// these types, so this is the only place the two halves are compared.
@Test func theJSONKeepsTheNamesAndTypesTheBarDecodes() throws {
    var s = state()
    s.setLayout(.tiling(treeFromOrder([42])), on: 11)
    let payload = BarStateStatus(
        spaces: [status(s, 11)],
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
