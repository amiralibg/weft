import Testing
@testable import WeftCore

@Test func labelsAssignByOrdinal() {
    var s = SpaceState()
    s.assignLabels(sids: [5, 3, 7], names: ["code", "web"])
    // `sids` arrives in Mission Control order and is honoured verbatim: the
    // first desktop on screen is "code" whatever its space id happens to be.
    // Sorting the ids here (the old behaviour) put every label on the wrong
    // desktop as soon as a desktop was removed and re-added, because macOS
    // hands out space ids in creation order, not left-to-right order.
    #expect(s.labels == [5: "code", 3: "web", 7: "3"])
    #expect(s.order == [5, 3, 7])
    #expect(s.persistedNames(sids: [5, 3, 7]) == ["code", "web", "3"])
    #expect(s.ordinal(of: 3) == 2)
}

@Test func resolveLabelSidOrdinal() {
    var s = SpaceState(layouts: [3: .tiling(Tree()), 5: .tiling(Tree()), 7: .tiling(Tree())])
    s.assignLabels(sids: [3, 5, 7], names: ["code"])
    #expect(s.resolveSpace("code") == 3)   // label
    #expect(s.resolveSpace("5") == 5)      // raw sid
    #expect(s.resolveSpace("3") == 7)      // label "3" wins over sid/ordinal
    #expect(s.resolveSpace("1") == 3)      // ordinal 1 → first sid
    #expect(s.resolveSpace("nope") == nil)
}

@Test func membershipSyncPerSpace() {
    let s0 = SpaceState()
    let (s1, fresh1) = syncMembership(s0, spaces: [3: [1, 2], 5: [3]])
    #expect(s1.layouts[3]?.windows.sorted() == [1, 2])
    #expect(s1.layouts[5]?.windows == [3])
    #expect(fresh1 == [1, 2, 3])
    // Window 2 moves 3 → 5; window 1 closes.
    let (s2, fresh2) = syncMembership(s1, spaces: [3: [], 5: [2, 3]])
    #expect(s2.layouts[3]?.windows == [])
    #expect(s2.layouts[5]?.windows.sorted() == [2, 3])
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
    let s0 = SpaceState(layouts: [5: .float(FloatState())])
    let (s1, fresh) = syncMembership(s0, spaces: [5: [1, 2]])
    #expect(s1.layouts[5]?.kind == .float)
    #expect(s1.layouts[5]?.windows == [1, 2])
    #expect(fresh == [1, 2])
    let (s2, _) = syncMembership(s1, spaces: [5: [2]])
    #expect(s2.layouts[5]?.windows == [2])
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
    var s = SpaceState()
    s.assignLabels(sids: [10, 20, 30], names: [])
    s.assignOverrides(sids: [10, 20, 30], kinds: ["", "scroll", "float"])
    #expect(s.overrides[20] == nil)
    #expect(s.overrides[30] == .float)
    let (s1, _) = syncMembership(s, spaces: [20: [7]], live: [10, 20, 30])
    #expect(s1.layouts[20]?.kind == .bsp)
    #expect(s1.layouts[30]?.kind == .float)
}

@Test func recentSpaceResolution() {
    var s = SpaceState(layouts: [3: .tiling(Tree()), 5: .tiling(Tree())], recentSpace: 3)
    #expect(s.resolveSpace("recent") == 3)
    s.recentSpace = 5
    #expect(s.resolveSpace("recent") == 5)
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
    let state = SpaceState(
        currentByDisplay: ["A": 3, "B": 9],
        displays: ["A", "B"],
        displayBySpace: [3: "A", 9: "B"]
    )
    // Same two windows on each space; only the display shape differs.
    let (synced, fresh) = syncMembership(
        state,
        spaces: [3: [1, 2], 9: [1, 2]],
        screens: [3: builtIn, 9: external]
    )
    #expect(fresh == [1, 2])

    guard case .tiling(let onBuiltIn)? = synced.layouts[3],
          case .tiling(let onExternal)? = synced.layouts[9]
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
    let state = SpaceState(displayBySpace: [3: "A", 9: "B"])
    let (synced, _) = syncMembership(
        state, spaces: [3: [1, 2], 9: [1, 2]], screens: [3: builtIn, 9: tall]
    )
    guard case .tiling(let wide)? = synced.layouts[3],
          case .tiling(let narrow)? = synced.layouts[9]
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
    let s0 = SpaceState(layouts: [7: .float(FloatState())])
    // Sweep with the space present but holding nothing.
    let (s1, _) = syncMembership(s0, spaces: [:], live: [7])
    #expect(s1.layouts[7]?.kind == .float)
    #expect(s1.layouts[7]?.windows == [])
    // And it is still float when the first window lands on it.
    let (s2, fresh) = syncMembership(s1, spaces: [7: [11]], live: [7])
    #expect(s2.layouts[7]?.kind == .float)
    #expect(s2.layouts[7]?.windows == [11])
    #expect(fresh == [11])
}

/// A space that is genuinely gone — an unplugged display — still loses its
/// layout, which is the behaviour the dropping was there for.
@Test func aVanishedSpaceLosesItsLayout() {
    let s0 = SpaceState(layouts: [7: .float(FloatState()), 8: .tiling(Tree())])
    let (s1, _) = syncMembership(s0, spaces: [7: [1]], live: [7])
    #expect(s1.layouts[7] != nil)
    #expect(s1.layouts[8] == nil)
}

@Test func layoutOverridesRoundTripByOrdinal() {
    var s = SpaceState()
    s.assignLabels(sids: [10, 20, 30], names: ["main", "web", "code"])
    s.overrides[20] = .float
    let saved = s.persistedOverrides(sids: [10, 20, 30])
    #expect(saved == ["", "float", ""])
    // A restart hands out different sids for the same desktops.
    var next = SpaceState()
    next.assignLabels(sids: [11, 21, 31], names: ["main", "web", "code"])
    next.assignOverrides(sids: [11, 21, 31], kinds: saved)
    #expect(next.overrides[21] == .float)
    #expect(next.overrides[11] == nil)
}

/// Unplugging a display must not leave a stale override behind to be applied
/// to whatever space inherits that id later.
@Test func overridesDieWithTheirSpace() {
    var s = SpaceState()
    s.assignLabels(sids: [10, 20], names: ["main", "web"])
    s.overrides[20] = .float
    s.assignLabels(sids: [10], names: ["main"])
    #expect(s.overrides[20] == nil)
}

@Test func spaceWithOverrideFloatKeepsFloatWhenNewWindowOpens() {
    let s0 = SpaceState(
        layouts: [1: .float(FloatState(order: [1], remembered: [:], focus: 1))],
        overrides: [1: .float]
    )
    // A second window opens on space 1
    let (s1, fresh) = syncMembership(s0, spaces: [1: [1, 2]], live: [1])
    #expect(s1.layouts[1]?.kind == .float)
    #expect(s1.layouts[1]?.windows == [1, 2])
    #expect(fresh == [2])
}

@Test func spaceEmptyWithOverrideFloatKeepsFloatWhenFirstWindowOpens() {
    // Space 2 starts with no layout but has an override of float
    let s0 = SpaceState(overrides: [2: .float])
    let (s1, fresh) = syncMembership(s0, spaces: [2: [100]], live: [2])
    #expect(s1.layouts[2]?.kind == .float)
    #expect(s1.layouts[2]?.windows == [100])
    #expect(fresh == [100])
}
