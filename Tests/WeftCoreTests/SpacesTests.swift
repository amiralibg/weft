import Testing
@testable import WeftCore

/// One display per desktop id, each showing its own — so every desktop is a
/// managed one and shows one workspace. `adoptDisplays` is the only thing that
/// creates a workspace, so it is also the only way to build a state to test
/// with.
private func desktops(_ sids: [SpaceID], names: [String] = []) -> SpaceState {
    var s = SpaceState()
    s.adoptDisplays(displays(sids), names: names)
    return s
}

private func displays(_ sids: [SpaceID]) -> [DisplayDesktops] {
    sids.map { DisplayDesktops(uuid: "D\($0)", desktops: [$0], current: $0) }
}

/// The workspace showing on a desktop, for a test that needs to name one.
private func ws(_ s: SpaceState, _ sid: SpaceID) -> WorkspaceID { s.active[sid]! }

@Test func labelsAssignByOrdinal() {
    let s = desktops([5, 3, 7], names: ["code", "web"])
    // `sids` arrives in Mission Control order and is honoured verbatim: the
    // first desktop on screen is "code" whatever its space id happens to be.
    // Sorting the ids here (the old behaviour) put every label on the wrong
    // desktop as soon as a desktop was removed and re-added, because macOS
    // hands out space ids in creation order, not left-to-right order.
    #expect(s.workspace(on: 5)?.label == "code")
    #expect(s.workspace(on: 3)?.label == "web")
    #expect(s.workspace(on: 7)?.label == "3")
    #expect(s.order == [5, 3, 7])
    // `wsOrder` is built from `order` in the same pass, so the persistence
    // files — which are keyed by ordinal — cannot come back scrambled.
    #expect(s.wsOrder == [ws(s, 5), ws(s, 3), ws(s, 7)])
    #expect(s.persistedNames() == ["code", "web", "3"])
}

/// One workspace per desktop, and each one knows where it lives. The identity
/// mapping stated as a test, so the commit that stops it being the identity
/// mapping has to say so here.
@Test func everyDesktopGetsExactlyOneWorkspace() {
    let s = desktops([5, 3, 7], names: [])
    #expect(s.workspaces.count == 3)
    #expect(s.active.count == 3)
    for sid in [5, 3, 7] as [SpaceID] {
        #expect(s.desktop(of: ws(s, sid)) == sid)
    }
    #expect(Set(s.wsOrder).count == 3)
}

/// Re-adopting keeps the workspace a desktop already had, labels and layout
/// intact. A sweep runs this on every pass, so anything it recreates is a tree
/// thrown away several times a second.
@Test func readoptingADesktopKeepsItsWorkspace() {
    var s = desktops([5, 3], names: ["code", "web"])
    let before = ws(s, 5)
    s.setLayout(.float(FloatState()), on: 5)
    s.adoptDisplays(displays([5, 3]), names: nil)
    #expect(ws(s, 5) == before)
    #expect(s.workspace(on: 5)?.label == "code")
    #expect(s.layout(on: 5)?.kind == .float)
}

@Test func resolveLabelSidOrdinal() {
    let s = desktops([3, 5, 7], names: ["code"])
    #expect(s.resolveWorkspace("code") == ws(s, 3))   // label
    // The raw-id escape hatch still names a DESKTOP. Someone typing a number
    // out of `query spaces` means the native space that JSON reports, and a
    // workspace id of the same value would hand them a different desktop.
    #expect(s.resolveWorkspace("5") == ws(s, 5))
    #expect(s.resolveWorkspace("3") == ws(s, 7))      // label "3" wins over id/ordinal
    #expect(s.resolveWorkspace("1") == ws(s, 3))      // ordinal 1 → first workspace
    #expect(s.resolveWorkspace("nope") == nil)
}

@Test func membershipSyncPerSpace() {
    let s0 = desktops([3, 5])
    let (s1, fresh1) = syncMembership(s0, membership: [ws(s0, 3): [1, 2], ws(s0, 5): [3]])
    #expect(s1.layout(on: 3)?.windows.sorted() == [1, 2])
    #expect(s1.layout(on: 5)?.windows == [3])
    #expect(fresh1 == [1, 2, 3])
    // Window 2 moves 3 → 5; window 1 closes.
    let (s2, fresh2) = syncMembership(s1, membership: [ws(s0, 3): [], ws(s0, 5): [2, 3]])
    #expect(s2.layout(on: 3)?.windows == [])
    #expect(s2.layout(on: 5)?.windows.sorted() == [2, 3])
    #expect(fresh2 == [2])  // new to space 5's tree (rebind is idempotent)
}

@Test func spaceGrammar() throws {
    #expect(try Command.parse("space focus code") == .space(.focus("code")))
    #expect(try Command.parse("space focus 2") == .space(.focus("2")))
    // Following is the default: the move is a visible desktop change either
    // way, and coming back is an extra one to end up where the user who just
    // sent a window somewhere usually did not want to be.
    #expect(try Command.parse("space move-window web") == .space(.moveWindow("web", nil, follow: true)))
    #expect(try Command.parse("space move-window 5 139") == .space(.moveWindow("5", 139, follow: true)))
    #expect(
        try Command.parse("space move-window web --no-follow")
            == .space(.moveWindow("web", nil, follow: false)))
    // Flags in either position, and alongside an explicit window id.
    #expect(
        try Command.parse("space move-window 5 --no-follow 139")
            == .space(.moveWindow("5", 139, follow: false)))
    #expect(
        try Command.parse("space move-window 5 139 --follow")
            == .space(.moveWindow("5", 139, follow: true)))
    // Two window ids is a typo, not a second argument.
    #expect(throws: CommandParseError.self) { try Command.parse("space move-window 5 139 140") }
    #expect(try Command.parse("space label code") == .space(.label("code")))
    #expect(try Command.parse("sticky") == .sticky(nil, .toggle))
    #expect(try Command.parse("sticky 139 off") == .sticky(139, .off))
    #expect(try Command.parse("focus display next") == .focusDisplay(.next))
    #expect(try Command.parse("focus display 2") == .focusDisplay(.index(2)))
    #expect(try Command.parse("query capability") == .query(.capability))
}

@Test func floatMembershipSync() {
    var s0 = desktops([5])
    s0.setLayout(.float(FloatState()), on: 5)
    let (s1, fresh) = syncMembership(s0, membership: [ws(s0, 5): [1, 2]])
    #expect(s1.layout(on: 5)?.kind == .float)
    #expect(s1.layout(on: 5)?.windows == [1, 2])
    #expect(fresh == [1, 2])
    let (s2, _) = syncMembership(s1, membership: [ws(s0, 5): [2]])
    #expect(s2.layout(on: 5)?.windows == [2])
}

/// bsp → float → bsp keeps every window and the focus. Float remembers the
/// real frames it was handed; coming back rebuilds a tree in that order.
@Test func layoutConversionsRoundTrip() {
    var tree = Tree()
    for id in [1, 2, 3] as [WindowID] { tree = tree.inserting(id) }
    tree = tree.focusing(2)
    let frames: [WindowID: Frame] = [
        1: Frame(x: 0, y: 0, width: 100, height: 100),
        2: Frame(x: 100, y: 0, width: 100, height: 100),
        3: Frame(x: 200, y: 0, width: 100, height: 100),
    ]
    let fl = floatFromWindows(tree.windows, actuals: frames, focus: tree.focus)
    #expect(fl.focus == 2)
    #expect(fl.remembered == frames)
    let back = treeFromOrder(fl.order, focus: fl.focus)
    #expect(back.windows.sorted() == [1, 2, 3])
    #expect(back.focus == 2)
}

/// A `layouts.json` saved while a space was in scroll comes back as bsp.
/// The layout is gone; an override naming it simply does not survive, and a
/// space with no override tiles bsp — so there is nothing to migrate.
@Test func aPersistedScrollOverrideLoadsAsBsp() {
    // An override belongs to a workspace, so it is restored after the
    // workspaces exist — the order the daemon's first sweep uses too.
    var s = desktops([10, 20, 30], names: [])
    s.assignOverrides(kinds: ["", "scroll", "float"])
    #expect(s.workspace(on: 20)?.overrideKind == nil)
    #expect(s.workspace(on: 30)?.overrideKind == .float)
    let live = s.liveWorkspaces(desktops: [10, 20, 30])
    let (s1, _) = syncMembership(s, membership: [ws(s, 20): [7]], live: live)
    #expect(s1.layout(on: 20)?.kind == .bsp)
    #expect(s1.layout(on: 30)?.kind == .float)
}

@Test func recentWorkspaceResolution() {
    var s = desktops([3, 5])
    s.recentWorkspace = ws(s, 3)
    #expect(s.resolveWorkspace("recent") == ws(s, 3))
    s.recentWorkspace = ws(s, 5)
    #expect(s.resolveWorkspace("recent") == ws(s, 5))
}

@Test func spaceLayoutGrammar() throws {
    #expect(try Command.parse("space layout bsp") == .space(.layout("bsp")))
    #expect(try Command.parse("space layout scroll") == .space(.layout("scroll")))
    #expect(try Command.parse("space layout float") == .space(.layout("float")))
    #expect(try Command.parse("space layout toggle") == .space(.layout("toggle")))
    #expect(try Command.parse("space focus recent") == .space(.focus("recent")))
}

// MARK: - Multi-display

private let builtIn = Frame(x: 0, y: 0, width: 1710, height: 1087)
/// Above and west of the built-in — the arrangement that makes a single
/// machine-wide rect not merely imprecise but off-screen.
private let external = Frame(x: -1063, y: -2160, width: 3840, height: 2135)

@Test func currentSpaceFollowsFocusedDisplay() {
    let state = SpaceState(
        currentByDisplay: ["A": 3, "B": 9],
        displays: ["A", "B"],
        displayBySpace: [3: "A", 9: "B"],
        focusedDisplay: "B"
    )
    #expect(state.currentSpace == 9)
    #expect(state.visibleSpaces == [3, 9])

    // No focused display (single display, or SLS answered "Main"): the first
    // display is the answer, which is what one display makes it anyway.
    var fallback = state
    fallback.focusedDisplay = nil
    #expect(fallback.currentSpace == 3)

    // A display that vanished mid-command must not strand every command on a
    // space that is no longer current.
    var unplugged = state
    unplugged.focusedDisplay = "gone"
    #expect(unplugged.currentSpace == 3)
}

@Test func splitAxisFollowsEachSpacesOwnDisplay() {
    var state = desktops([3, 9])
    state.currentByDisplay = ["A": 3, "B": 9]
    state.displays = ["A", "B"]
    state.displayBySpace = [3: "A", 9: "B"]
    // Same two windows on each space; only the display shape differs.
    let (synced, fresh) = syncMembership(
        state,
        membership: [ws(state, 3): [1, 2], ws(state, 9): [1, 2]],
        screens: [ws(state, 3): builtIn, ws(state, 9): external]
    )
    #expect(fresh == [1, 2])

    guard case .tiling(let onBuiltIn)? = synced.layout(on: 3),
          case .tiling(let onExternal)? = synced.layout(on: 9)
    else { Issue.record("expected tiling layouts"); return }

    let a = layout(onBuiltIn, in: builtIn, config: .none)
    let b = layout(onExternal, in: external, config: .none)
    // Both displays are wider than tall here, so both split side by side —
    // but each within its OWN rect, which is the whole point.
    #expect(a[1]!.width == 855 && a[1]!.height == 1087)
    #expect(b[1]!.width == 1920 && b[1]!.height == 2135)
    // Every frame lands inside the display that owns its space. The external
    // rect straddles x = 0, so "negative x" proves nothing — containment does.
    func inside(_ f: Frame, _ r: Frame) -> Bool {
        f.x >= r.x && f.y >= r.y && f.x + f.width <= r.x + r.width
            && f.y + f.height <= r.y + r.height
    }
    for f in a.values { #expect(inside(f, builtIn)) }
    for f in b.values { #expect(inside(f, external)) }
    // The bug this guards: computing space 9 in the built-in rect put every
    // window on the wrong monitor.
    for f in b.values { #expect(!inside(f, builtIn)) }
}

@Test func splitAxisDiffersWhenDisplayShapesDiffer() {
    // A tall display splits top/bottom where a wide one splits left/right.
    let tall = Frame(x: 2000, y: 0, width: 1080, height: 1920)
    var state = desktops([3, 9])
    state.displayBySpace = [3: "A", 9: "B"]
    let (synced, _) = syncMembership(
        state,
        membership: [ws(state, 3): [1, 2], ws(state, 9): [1, 2]],
        screens: [ws(state, 3): builtIn, ws(state, 9): tall]
    )
    guard case .tiling(let wide)? = synced.layout(on: 3),
          case .tiling(let narrow)? = synced.layout(on: 9)
    else { Issue.record("expected tiling layouts"); return }
    let a = layout(wide, in: builtIn, config: .none)
    let b = layout(narrow, in: tall, config: .none)
    #expect(a[1]!.width < builtIn.width)   // split vertically → half width
    #expect(a[1]!.height == builtIn.height)
    #expect(b[1]!.width == tall.width)     // split horizontally → half height
    #expect(b[1]!.height < tall.height)
}

@Test func displayGrammar() throws {
    #expect(try Command.parse("focus display west") == .focusDisplay(.west))
    #expect(try Command.parse("focus display next") == .focusDisplay(.next))
    #expect(try Command.parse("focus display first") == .focusDisplay(.first))
    #expect(try Command.parse("focus display 2") == .focusDisplay(.index(2)))
    #expect(try Command.parse("move display east") == .moveWindowToDisplay(.east, follow: false))
    #expect(try Command.parse("move display last") == .moveWindowToDisplay(.last, follow: false))
    // yabai needs `window --display east && display --focus east`; one bind here.
    #expect(try Command.parse("move display east --follow") == .moveWindowToDisplay(.east, follow: true))
    #expect(try Command.parse("move display east follow") == .moveWindowToDisplay(.east, follow: true))
    #expect(try Command.parse("move space display next") == .moveSpaceToDisplay(.next))
    // `display` must not shadow the directional forms.
    #expect(try Command.parse("move east") == .move(.east))
    #expect(try Command.parse("focus east") == .focus(.east))
    #expect(throws: (any Error).self) { try Command.parse("move display sideways") }
    #expect(throws: (any Error).self) { try Command.parse("focus display 0") }
    #expect(throws: (any Error).self) { try Command.parse("move space display") }
}

@Test func displayGrammarDirections() throws {
    #expect(try Command.parse("focus display north") == .focusDisplay(.north))
    #expect(try Command.parse("focus display up") == .focusDisplay(.north))
    #expect(try Command.parse("move display south") == .moveWindowToDisplay(.south, follow: false))
    #expect(try Command.parse("move display down") == .moveWindowToDisplay(.south, follow: false))
}

@Test func displayCycleTarget() throws {
    // skhd writes wraparound as `{ … next … } || { … first … }`; one word here.
    #expect(try Command.parse("move display cycle --follow")
        == .moveWindowToDisplay(.cycle, follow: true))
    #expect(try Command.parse("focus display cycle") == .focusDisplay(.cycle))
}

/// The bug: switch a space to float, let it empty, open a window — bsp.
///
/// `syncMembership` keyed "does this space still exist?" off the membership
/// dictionary, which only lists spaces that hold a managed window. An empty
/// desktop therefore looked deleted, its layout was dropped, and the next
/// window to arrive found a space with no layout at all — which the daemon
/// seeds from config.
@Test func anEmptySpaceKeepsItsLayoutKind() {
    var s0 = desktops([7])
    s0.setLayout(.float(FloatState()), on: 7)
    let live = s0.liveWorkspaces(desktops: [7])
    // Sweep with the space present but holding nothing.
    let (s1, _) = syncMembership(s0, membership: [:], live: live)
    #expect(s1.layout(on: 7)?.kind == .float)
    #expect(s1.layout(on: 7)?.windows == [])
    // And it is still float when the first window lands on it.
    let (s2, fresh) = syncMembership(s1, membership: [ws(s0, 7): [11]], live: live)
    #expect(s2.layout(on: 7)?.kind == .float)
    #expect(s2.layout(on: 7)?.windows == [11])
    #expect(fresh == [11])
}

/// A display that goes away takes nothing with it: its workspace moves to the
/// first display, hidden, with its layout, its override and its windows. A
/// workspace is weft's, not the display's, and unplugging a monitor must not
/// be a way to lose a tree.
@Test func anUnpluggedDisplaysWorkspaceMovesToTheFirstDisplay() {
    var s = desktops([7, 8])
    let moved = ws(s, 8)
    s.workspaces[moved]?.overrideKind = .float
    s.file(42, in: moved, laidOut: true)
    s.adoptDisplays(displays([7]), names: nil)
    #expect(s.workspaces[moved]?.desktop == 7)
    #expect(s.workspaces[moved]?.overrideKind == .float)
    #expect(s.workspaces[moved]?.contains(42) == true)
    #expect(s.active[8] == nil)
    // Hidden there: the first display keeps showing what it showed.
    #expect(s.active[7] != moved)
    #expect(s.wsOrder.count == 2)
}

@Test func layoutOverridesRoundTripByOrdinal() {
    var s = desktops([10, 20, 30], names: ["main", "web", "code"])
    s.workspaces[ws(s, 20)]?.overrideKind = .float
    let saved = s.persistedOverrides()
    #expect(saved == ["", "float", ""])
    // A restart hands out different sids for the same desktops, and fresh
    // workspace ids for the same workspaces — which is why the file is keyed
    // by ordinal and neither id is ever written down.
    var next = desktops([11, 21, 31], names: ["main", "web", "code"])
    next.assignOverrides(kinds: saved)
    #expect(next.workspace(on: 21)?.overrideKind == .float)
    #expect(next.workspace(on: 11)?.overrideKind == nil)
    // An empty workspace takes the restored kind outright — nothing to convert.
    #expect(next.layout(on: 21)?.kind == .float)
}

/// Plugging it back in shows something there again without inventing a
/// workspace: an empty hidden one is free to move, so it is the one taken.
@Test func aReturningDisplayTakesAnEmptyHiddenWorkspace() {
    var s = desktops([10, 20], names: ["main", "web"])
    s.adoptDisplays(displays([10]), names: nil)
    #expect(s.wsOrder.count == 2)
    s.adoptDisplays(displays([10, 30]), names: nil)
    #expect(s.wsOrder.count == 2)
    #expect(s.workspace(on: 30)?.label == "web")
}

@Test func spaceWithOverrideFloatKeepsFloatWhenNewWindowOpens() {
    var s0 = desktops([1])
    s0.setLayout(.float(FloatState(order: [1], remembered: [:], focus: 1)), on: 1)
    s0.workspaces[ws(s0, 1)]?.overrideKind = .float
    // A second window opens on space 1
    let (s1, fresh) = syncMembership(
        s0, membership: [ws(s0, 1): [1, 2]], live: s0.liveWorkspaces(desktops: [1])
    )
    #expect(s1.layout(on: 1)?.kind == .float)
    #expect(s1.layout(on: 1)?.windows == [1, 2])
    #expect(fresh == [2])
}

@Test func spaceEmptyWithOverrideFloatKeepsFloatWhenFirstWindowOpens() {
    // Space 2 has an override of float and no windows yet — the state a
    // restart leaves a desktop in before anything opens there.
    var s0 = desktops([2], names: [])
    s0.assignOverrides(kinds: ["float"])
    let (s1, fresh) = syncMembership(
        s0, membership: [ws(s0, 2): [100]], live: s0.liveWorkspaces(desktops: [2])
    )
    #expect(s1.layout(on: 2)?.kind == .float)
    #expect(s1.layout(on: 2)?.windows == [100])
    #expect(fresh == [100])
}

// MARK: - The workspace seam
//
// `reconcileWorkspaces` is where the two owners of membership meet: SLS says
// which desktop a window is on, weft says which workspace it is in. These
// tests are the specification of that rule.

private let ws1 = WorkspaceID(1)
private let ws2 = WorkspaceID(2)
private let ws3 = WorkspaceID(3)

/// Two displays, one workspace each: whatever SLS reports is what comes out.
@Test func oneWorkspacePerDisplayReproducesWhatSLSReports() {
    let out = reconcileWorkspaces(
        windowDesktops: [10: [3], 11: [3], 12: [5]],
        membership: [ws1: [10, 11], ws2: [12]],
        desktopOf: [ws1: 3, ws2: 5],
        activeOn: [3: ws1, 5: ws2]
    )
    #expect(out == [ws1: [10, 11], ws2: [12]])
}

/// A window in a workspace that is showing on display A, reported on display
/// B: the user dragged it across, or the app moved it. It joins B's.
@Test func aWindowDraggedToAnotherDisplayJoinsWhatIsShowingThere() {
    let out = reconcileWorkspaces(
        windowDesktops: [10: [5]],
        membership: [ws1: [10], ws2: []],
        desktopOf: [ws1: 3, ws2: 5],
        activeOn: [3: ws1, 5: ws2]
    )
    #expect(out[ws2] == [10])
    #expect(out[ws1] == nil)
}

/// …unless weft is the one moving it. A workspace shown on another display
/// is marked in flight, and a sweep that lands before the WindowServer
/// catches up must not read the move as a drag back.
@Test func aWindowInFlightKeepsItsWorkspace() {
    let out = reconcileWorkspaces(
        windowDesktops: [10: [5]],
        membership: [ws1: [10], ws2: []],
        desktopOf: [ws1: 3, ws2: 5],
        activeOn: [3: ws1, 5: ws2],
        inFlight: [10]
    )
    #expect(out[ws1] == [10])
}

/// The half that makes a hidden workspace possible at all. Two workspaces on
/// desktop 3, `ws2` showing: SLS reports every window there either way — a
/// parked window is still on its desktop (S9) — and `ws1`'s must not be swept
/// into `ws2` on the next sweep.
@Test func aHiddenWorkspaceKeepsItsWindowsWhileAnotherIsShowing() {
    let out = reconcileWorkspaces(
        windowDesktops: [10: [3], 11: [3], 12: [3]],
        membership: [ws1: [10, 11], ws2: [12]],
        desktopOf: [ws1: 3, ws2: 3],
        activeOn: [3: ws2]
    )
    #expect(out[ws1] == [10, 11])
    #expect(out[ws2] == [12])
}

/// A hidden workspace keeps its windows wherever they are parked. Its windows
/// can be reported on another display's desktop — it last showed there — and
/// that is not the user moving them.
@Test func aHiddenWorkspaceKeepsWindowsParkedOnAnotherDisplay() {
    let out = reconcileWorkspaces(
        windowDesktops: [10: [5]],
        membership: [ws1: [10]],
        desktopOf: [ws1: 3, ws2: 3, ws3: 5],
        activeOn: [3: ws2, 5: ws3]
    )
    #expect(out[ws1] == [10])
}

/// A new window goes to what is showing where it opened, not to the first
/// workspace that happens to live on that desktop.
@Test func aNewWindowLandsInTheShowingWorkspaceNotJustAnyOnThatDesktop() {
    let out = reconcileWorkspaces(
        windowDesktops: [10: [3], 99: [3]],
        membership: [ws1: [10], ws2: []],
        desktopOf: [ws1: 3, ws2: 3],
        activeOn: [3: ws2]
    )
    #expect(out[ws1] == [10])
    #expect(out[ws2] == [99])
}

/// A window on several desktops at once — macOS's own "All Desktops" — is
/// filed once, where it first lands on a managed desktop. Membership is one
/// workspace per window now.
@Test func aWindowOnSeveralDesktopsIsFiledOnce() {
    let out = reconcileWorkspaces(
        windowDesktops: [10: [3, 5]],
        membership: [:],
        desktopOf: [ws1: 3, ws2: 5],
        activeOn: [3: ws1, 5: ws2]
    )
    #expect(out == [ws1: [10]])
}

/// A window on a desktop weft does not manage — another desktop, a
/// fullscreen space — is in no workspace. weft pauses there.
@Test func aWindowOnAnUnmanagedDesktopIsInNoWorkspace() {
    let out = reconcileWorkspaces(
        windowDesktops: [10: [3], 11: [7]],
        membership: [ws1: [10, 11]],
        desktopOf: [ws1: 3],
        activeOn: [3: ws1]
    )
    #expect(out == [ws1: [10]])
}

/// A workspace weft has no desktop for holds nothing back: its windows are
/// reconciled like any others.
@Test func aWorkspaceWithNoDesktopHoldsNothingBack() {
    let out = reconcileWorkspaces(
        windowDesktops: [10: [5]],
        membership: [ws3: [10], ws2: []],
        desktopOf: [ws2: 5],
        activeOn: [5: ws2]
    )
    #expect(out == [ws2: [10]])
}

// MARK: - Displays and their managed desktops

/// Every `[[space]]` is a workspace on the managed desktop, however many
/// macOS desktops the display has. The other desktops get none.
@Test func declaredWorkspacesAllLiveOnTheManagedDesktop() {
    var s = SpaceState()
    s.adoptDisplays(
        [DisplayDesktops(uuid: "A", desktops: [10, 20], current: 10)],
        names: ["term", "web", "code", "chat"]
    )
    #expect(s.wsOrder.count == 4)
    #expect(s.managed == ["A": 10])
    #expect(s.workspaces.values.allSatisfy { $0.desktop == 10 })
    #expect(s.active == [10: s.wsOrder[0]])
    #expect(s.resolveWorkspace("web") == s.wsOrder[1])
    #expect(s.resolveWorkspace("4") == s.wsOrder[3])
}

/// Swiping to another macOS desktop does not move the managed one. The
/// display is paused, and nothing weft shows is on screen there.
@Test func anotherDesktopShowingPausesTheDisplay() {
    var s = SpaceState()
    let one = DisplayDesktops(uuid: "A", desktops: [10, 20], current: 10)
    s.adoptDisplays([one], names: ["a", "b"])
    #expect(!s.isPaused("A"))
    #expect(s.showingDisplay(of: s.wsOrder[0]) == "A")

    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [10, 20], current: 20)], names: nil)
    #expect(s.managed["A"] == 10)
    #expect(s.isPaused("A"))
    #expect(s.showingDisplay(of: s.wsOrder[0]) == nil)
    // And back.
    s.adoptDisplays([one], names: nil)
    #expect(!s.isPaused("A"))
}

/// A launch while a fullscreen app is showing must not manage the
/// fullscreen space: it is not in `desktops`, so the first real one is.
@Test func aFullscreenSpaceIsNeverManaged() {
    var s = SpaceState()
    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [10, 20], current: 99)], names: ["a"])
    #expect(s.managed["A"] == 10)
    #expect(s.isPaused("A"))
}

/// The managed desktop deleted in Mission Control: macOS moves its windows,
/// weft manages what the display shows now, and the workspaces go with it.
@Test func aDeletedManagedDesktopHandsItsWorkspacesToTheNextOne() {
    var s = SpaceState()
    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [10, 20], current: 10)], names: ["a", "b"])
    s.file(42, in: s.wsOrder[1], laidOut: true)
    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [20], current: 20)], names: nil)
    #expect(s.managed["A"] == 20)
    #expect(s.workspaces.values.allSatisfy { $0.desktop == 20 })
    #expect(s.workspaces[s.wsOrder[1]]?.contains(42) == true)
    #expect(s.active[20] == s.wsOrder[0])
}

/// A new display with no hidden workspace free to take gets a numbered one.
@Test func aNewDisplayWithNothingFreeGetsANumberedWorkspace() {
    var s = SpaceState()
    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [10], current: 10)], names: ["a"])
    s.file(42, in: s.wsOrder[0], laidOut: true)
    s.adoptDisplays([
        DisplayDesktops(uuid: "A", desktops: [10], current: 10),
        DisplayDesktops(uuid: "B", desktops: [30], current: 30),
    ], names: nil)
    #expect(s.wsOrder.count == 2)
    #expect(s.workspace(on: 30)?.label == "2")
}

/// No displays at all is a transient — sleep, a reconfiguration in flight —
/// and must leave the workspaces exactly where they were.
@Test func noDisplaysLeavesTheWorkspacesAlone() {
    var s = desktops([10], names: ["a", "b"])
    let before = s.workspaces
    s.adoptDisplays([], names: nil)
    #expect(s.workspaces == before)
}

// MARK: - Showing

@Test func showingAHiddenWorkspaceMakesItActiveThere() {
    var s = desktops([10], names: ["a", "b"])
    let b = s.wsOrder[1]
    s.show(b, on: 10)
    #expect(s.active[10] == b)
    #expect(s.workspaces[b]?.desktop == 10)
}

/// Showing a workspace that is on screen elsewhere swaps the two displays,
/// so neither is left showing nothing: `move space display`.
@Test func showingAWorkspaceFromTheOtherDisplaySwapsThem() {
    var s = desktops([10, 20], names: ["a", "b"])
    let a = s.active[10]!, b = s.active[20]!
    s.show(a, on: 20)
    #expect(s.active[20] == a)
    #expect(s.active[10] == b)
    #expect(s.workspaces[a]?.desktop == 20)
    #expect(s.workspaces[b]?.desktop == 10)
}

// MARK: - Editing the list and restarting

@Test func relabelRenamesAddsAndDropsOnlyWhatIsSafeToDrop() {
    var s = desktops([10], names: ["a", "b", "c", "d"])
    s.file(42, in: s.wsOrder[3], laidOut: true)
    s.relabel(["x", "y"])
    #expect(s.persistedNames() == ["x", "y", "d"])  // "c" was empty and hidden
    s.relabel(["x", "y", "z", "w"])
    #expect(s.persistedNames() == ["x", "y", "z", "w"])
    #expect(s.workspaces[s.wsOrder[2]]?.contains(42) == true)
}

/// What `labels.json` records has to survive being read back: the count is
/// the count, with no desktops folded into it.
@Test func workspaceNamesSurviveARestart() {
    let one = [DisplayDesktops(uuid: "A", desktops: [10, 20, 30], current: 10)]
    var first = SpaceState()
    first.adoptDisplays(one, names: ["one", "two", "three"])
    var second = SpaceState()
    second.adoptDisplays(one, names: first.persistedNames())
    #expect(second.persistedNames() == ["one", "two", "three"])
}

/// Membership survives a daemon restart by ordinal: windows go back into the
/// workspace they were in rather than all into the first.
@Test func membershipSurvivesARestartByOrdinal() {
    var first = desktops([10], names: ["a", "b"])
    first.file(42, in: first.wsOrder[1], laidOut: true)
    first.file(43, in: first.wsOrder[0], laidOut: false)
    let saved = first.persistedMembership()
    var second = desktops([10], names: ["a", "b"])
    second.seedMembership(saved)
    #expect(second.workspace(holding: 42) == second.wsOrder[1])
    #expect(second.workspace(holding: 43) == second.wsOrder[0])
}

@Test func resetWorkspacesClearsTheSetButKeepsTheDesktops() {
    var s = desktops([10, 20], names: ["a", "b", "c"])
    s.recentWorkspace = s.wsOrder.first
    s.resetWorkspaces()
    #expect(s.workspaces.isEmpty)
    #expect(s.active.isEmpty)
    #expect(s.wsOrder.isEmpty)
    #expect(s.recentWorkspace == nil)
    #expect(s.order == [10, 20])
    #expect(s.managed == ["D10": 10, "D20": 20])
    s.adoptDisplays(displays([10, 20]), names: ["a", "b"])
    #expect(s.wsOrder.count == 2)
}

// MARK: - Moving a float between displays

@Test func aFloatKeepsItsPlaceRelativeToTheDisplayItMovesTo() {
    let small = Frame(x: 0, y: 0, width: 1000, height: 800)
    let big = Frame(x: 1000, y: 0, width: 2000, height: 1600)
    // Pushed into the top-right corner of the small display…
    let f = translate(Frame(x: 600, y: 0, width: 400, height: 300), from: small, to: big)
    // …lands in the top-right corner of the big one.
    #expect(f == Frame(x: 2600, y: 0, width: 400, height: 300))
    // Too big for the target: shrinks to fit rather than hanging off it.
    let g = translate(Frame(x: 0, y: 0, width: 1800, height: 1500), from: big, to: small)
    #expect(g.width == 1000 && g.height == 800 && g.x == 0 && g.y == 0)
}

// MARK: - Numbered workspaces on demand

@Test func aNumberPastTheEndCreatesWorkspacesUpToIt() {
    var s = desktops([10])
    #expect(s.wsOrder.count == 1)
    let four = s.resolveOrCreateWorkspace("4")
    #expect(s.persistedNames() == ["1", "2", "3", "4"])
    #expect(four == s.wsOrder[3])
    #expect(s.workspaces[four!]?.desktop == 10)
    // A desktop-id-sized number is not a request for a thousand workspaces.
    #expect(s.resolveOrCreateWorkspace("4242") == nil)
    #expect(s.resolveOrCreateWorkspace("nope") == nil)
    #expect(s.wsOrder.count == 4)
}

/// A restart while another desktop is showing — an update does that — must
/// not make that desktop weft's. The one managed before is restored first,
/// and the display starts paused until the user goes back.
@Test func aRestartOnAnotherDesktopKeepsTheManagedOne() {
    var s = SpaceState()
    s.managed = ["A": 10]   // from membership.json, this boot
    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [10, 20], current: 20)], names: ["a", "b"])
    #expect(s.managed["A"] == 10)
    #expect(s.isPaused("A"))
    #expect(s.workspaces.values.allSatisfy { $0.desktop == 10 })
}

/// Reordering in Settings moves workspaces, not names. By position, every
/// name after the move landed on another workspace's windows.
@Test func relabelFollowsAReorderByName() {
    var s = desktops([10], names: ["a", "b", "c"])
    let b = s.wsOrder[1]
    s.file(42, in: b, laidOut: true)
    s.relabel(["b", "a", "c"])
    #expect(s.persistedNames() == ["b", "a", "c"])
    #expect(s.wsOrder[0] == b)
    #expect(s.workspaces[b]?.contains(42) == true)
}

/// Deleting a workspace in the middle leaves the ones after it alone. By
/// position, "c" was renamed onto the deleted one's windows and the real "c"
/// kept its name too, so two workspaces answered to it.
@Test func relabelDropsTheDeletedWorkspaceNotItsNeighbour() {
    var s = desktops([10], names: ["a", "b", "c"])
    let c = s.wsOrder[2]
    s.file(42, in: c, laidOut: true)
    s.relabel(["a", "c"])
    #expect(s.persistedNames() == ["a", "c"])
    #expect(s.workspaces[c]?.contains(42) == true)
}

/// A name changed in place is a rename: same workspace, same windows.
@Test func relabelTreatsANewNameInPlaceAsARename() {
    var s = desktops([10], names: ["a", "b", "c"])
    let b = s.wsOrder[1]
    s.file(42, in: b, laidOut: true)
    s.relabel(["a", "web", "c"])
    #expect(s.persistedNames() == ["a", "web", "c"])
    #expect(s.wsOrder[1] == b)
    #expect(s.workspaces[b]?.contains(42) == true)
}
