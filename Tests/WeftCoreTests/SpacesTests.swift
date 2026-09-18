import Testing
@testable import WeftCore

/// The identity mapping every test below is written against: one workspace per
/// desktop, in the order given. `adoptDesktops` is the only thing that creates
/// a workspace, so it is also the only way to build a state to test with.
private func desktops(_ sids: [SpaceID], names: [String] = []) -> SpaceState {
    var s = SpaceState()
    s.adoptDesktops(sids, names: names)
    return s
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
    #expect(s.ordinal(of: 3) == 2)
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
    s.adoptDesktops([5, 3], names: nil)
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
    // Overrides are read when a workspace is created, so they are restored
    // first — which is the order the daemon's first sweep uses too.
    var s = SpaceState()
    s.assignOverrides(sids: [10, 20, 30], kinds: ["", "scroll", "float"])
    #expect(s.overrides[20] == nil)
    #expect(s.overrides[30] == .float)
    s.adoptDesktops([10, 20, 30], names: [])
    let live = s.liveWorkspaces(desktops: [10, 20, 30])
    let (s1, _) = syncMembership(s, membership: [ws(s, 20): [7]], live: live)
    #expect(s1.layout(on: 20)?.kind == .bsp)
    #expect(s1.layout(on: 30)?.kind == .float)
}

@Test func recentSpaceResolution() {
    var s = desktops([3, 5])
    s.recentSpace = 3
    #expect(s.resolveWorkspace("recent") == ws(s, 3))
    s.recentSpace = 5
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

/// A space that is genuinely gone — an unplugged display — still loses its
/// layout, which is the behaviour the dropping was there for.
///
/// This used to be `syncMembership`'s job, which knew only that a space was
/// absent from a list. `adoptDesktops` knows the desktop is gone, so it takes
/// what is showing there and the layout override with it. A stale `active`
/// entry is harmless right up until macOS recycles the id, and then a
/// brand-new desktop inherits a dead workspace's tree.
@Test func aVanishedSpaceLosesItsLayout() {
    var s = desktops([7, 8])
    s.overrides[8] = .float
    let dead = ws(s, 8)
    s.adoptDesktops([7], names: nil)
    #expect(s.workspace(on: 7) != nil)
    #expect(s.active[8] == nil)
    #expect(s.workspaces[dead] == nil)
    #expect(s.overrides[8] == nil)
    #expect(s.wsOrder == [ws(s, 7)])
}

@Test func layoutOverridesRoundTripByOrdinal() {
    var s = desktops([10, 20, 30], names: ["main", "web", "code"])
    s.overrides[20] = .float
    let saved = s.persistedOverrides(sids: [10, 20, 30])
    #expect(saved == ["", "float", ""])
    // A restart hands out different sids for the same desktops.
    var next = desktops([11, 21, 31], names: ["main", "web", "code"])
    next.assignOverrides(sids: [11, 21, 31], kinds: saved)
    #expect(next.overrides[21] == .float)
    #expect(next.overrides[11] == nil)
}

/// Unplugging a display must not leave a stale override behind to be applied
/// to whatever space inherits that id later.
@Test func overridesDieWithTheirSpace() {
    var s = desktops([10, 20], names: ["main", "web"])
    s.overrides[20] = .float
    s.adoptDesktops([10], names: ["main"])
    #expect(s.overrides[20] == nil)
}

@Test func spaceWithOverrideFloatKeepsFloatWhenNewWindowOpens() {
    var s0 = desktops([1])
    s0.setLayout(.float(FloatState(order: [1], remembered: [:], focus: 1)), on: 1)
    s0.overrides[1] = .float
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
    var s0 = SpaceState()
    s0.overrides[2] = .float
    s0.adoptDesktops([2], names: [])
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
// which desktop a window is on, weft says which workspace within it. These
// tests are the specification of that one rule, and two of them describe a
// configuration nothing creates yet — several workspaces on one desktop —
// because the whole point of writing the rule now is that it is already right
// when something does.

private let ws1 = WorkspaceID(1)
private let ws2 = WorkspaceID(2)
private let ws3 = WorkspaceID(3)

/// One workspace per desktop — today's model, and the thing Phase 1 must not
/// change. Whatever SLS reports is what comes out, unchanged.
@Test func identityMappingReproducesWhatSLSReports() {
    let out = reconcileWorkspaces(
        windowDesktops: [10: [3], 11: [3], 12: [5]],
        membership: [ws1: [10, 11], ws2: [12]],
        desktopOf: [ws1: 3, ws2: 5],
        activeOn: [3: ws1, 5: ws2]
    )
    #expect(out == [ws1: [10, 11], ws2: [12]])
}

/// The reconciliation rule's second half. A window weft filed on desktop 3
/// that SLS now reports on desktop 5 has been moved by something weft did not
/// do — Mission Control, a rule, the app itself — and it joins whatever is
/// showing where it landed.
@Test func aWindowThatChangedDesktopJoinsTheArrivingDesktopsActiveWorkspace() {
    let out = reconcileWorkspaces(
        windowDesktops: [10: [5]],
        membership: [ws1: [10], ws2: []],
        desktopOf: [ws1: 3, ws2: 5],
        activeOn: [3: ws1, 5: ws2]
    )
    // It joined 5's workspace, and left 3's by simply not being reported there.
    #expect(out[ws2] == [10])
    #expect(out[ws1] == nil)
}

/// The reconciliation rule's first half, and the one that makes a hidden
/// workspace possible at all.
///
/// Two workspaces on desktop 3, `ws2` showing. SLS reports every window on
/// desktop 3 either way — a parked window is still on its desktop, and still
/// in the on-screen window list (S9) — so without this half `ws1`'s windows
/// would be swept into `ws2` on the first sweep after they were hidden, and a
/// workspace switch would be a one-way trip.
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

/// A window that is new to a desktop holding several workspaces goes to the
/// one showing, not to the first one that happens to be on that desktop.
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

/// A sticky window is on every desktop at once, so it is resolved once per
/// desktop and holds a slot in a workspace on each.
@Test func aStickyWindowLandsInOneWorkspacePerDesktop() {
    let out = reconcileWorkspaces(
        windowDesktops: [10: [3, 5]],
        membership: [:],
        desktopOf: [ws1: 3, ws2: 5],
        activeOn: [3: ws1, 5: ws2]
    )
    #expect(out == [ws1: [10], ws2: [10]])
}

/// A desktop with no active workspace has nowhere to put what arrives, and
/// drops it silently — there is nothing else a pure function can do.
///
/// This is the failure the caller has to make impossible: `evictOrderedOut`
/// and `refreshDividerZones` both give up quietly on a desktop whose lookup
/// misses, so the symptom would be closed windows never giving their slot back
/// and borders vanishing, with nothing in the log. Every live desktop gets an
/// active workspace before this is ever called.
@Test func aDesktopWithNoActiveWorkspaceDropsWhatArrivesOnIt() {
    let out = reconcileWorkspaces(
        windowDesktops: [10: [3], 11: [7]],
        membership: [ws1: [10]],
        desktopOf: [ws1: 3],
        activeOn: [3: ws1]
    )
    #expect(out == [ws1: [10]])
}

/// A workspace whose desktop weft no longer knows about contributes nothing —
/// its windows are reconciled against the desktop SLS puts them on, like any
/// others. An unplugged display must not be able to hold windows hostage in a
/// workspace that can never be shown again.
@Test func aWorkspaceWithNoDesktopHoldsNothingBack() {
    let out = reconcileWorkspaces(
        windowDesktops: [10: [5]],
        membership: [ws3: [10], ws2: []],
        desktopOf: [ws2: 5],
        activeOn: [5: ws2]
    )
    #expect(out == [ws2: [10]])
}
