import Foundation
import Testing
@testable import WeftCore

/// One display per desktop id, each showing its own. `adoptDisplays` is the
/// only thing that creates a workspace, so it is also the only way to build a
/// state to test with (NATIVE.md, "Testing Decisions").
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
    // `wsOrder` is built from `order` in the same pass, so labels — which
    // attach by number — cannot come back scrambled.
    #expect(s.wsOrder == [ws(s, 5), ws(s, 3), ws(s, 7)])
    #expect(s.persistedNames() == ["code", "web", "3"])
}

/// One workspace per desktop, and each one knows which it is.
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
    #expect(s.resolveWorkspace("3") == ws(s, 7))      // label "3" (the third desktop's number)
    #expect(s.resolveWorkspace("1") == ws(s, 3))      // number 1 → first desktop
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

/// 0.9.21's `layouts.json`, saved while a space was in scroll, comes back as bsp.
/// The layout is gone; an override naming it simply does not survive, and a
/// space with no override tiles bsp — so there is nothing to migrate.
@Test func aPersistedScrollOverrideLoadsAsBsp() {
    // An override belongs to a workspace, so it is restored after the
    // workspaces exist — the order the daemon's first sweep uses too.
    var s = desktops([10, 20, 30], names: [])
    s.assignOverrides(kinds: ["", "scroll", "float"])
    #expect(s.workspace(on: 20)?.overrideKind == nil)
    #expect(s.workspace(on: 30)?.overrideKind == .float)
    let live = Set(s.wsOrder)
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
    let live = Set(s0.wsOrder)
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

@Test func spaceWithOverrideFloatKeepsFloatWhenNewWindowOpens() {
    var s0 = desktops([1])
    s0.setLayout(.float(FloatState(order: [1], remembered: [:], focus: 1)), on: 1)
    s0.workspaces[ws(s0, 1)]?.overrideKind = .float
    // A second window opens on space 1
    let (s1, fresh) = syncMembership(
        s0, membership: [ws(s0, 1): [1, 2]], live: Set(s0.wsOrder)
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
        s0, membership: [ws(s0, 2): [100]], live: Set(s0.wsOrder)
    )
    #expect(s1.layout(on: 2)?.kind == .float)
    #expect(s1.layout(on: 2)?.windows == [100])
    #expect(fresh == [100])
}

// MARK: - Numbering (NATIVE.md, "Numbering and labels")

/// The main display's desktops first, then every other display west to east —
/// whatever order SkyLight lists the displays in.
@Test func desktopsAreNumberedMainFirstThenWestToEast() {
    var s = SpaceState()
    s.adoptDisplays([
        DisplayDesktops(uuid: "east", desktops: [40], current: 40, originX: 3000),
        DisplayDesktops(uuid: "west", desktops: [30, 31], current: 30, originX: -2000),
        DisplayDesktops(uuid: "laptop", desktops: [10, 11], current: 10, isMain: true, originX: 0),
    ], names: ["mail"])
    #expect(s.order == [10, 11, 30, 31, 40])
    #expect(s.displays == ["laptop", "west", "east"])
    #expect(s.workspace(on: 10)?.label == "mail")
    #expect(s.workspace(on: 30)?.label == "3")
    #expect(s.resolveWorkspace("5") == ws(s, 40))
    #expect(s.keyBySpace[31] == DesktopKey(display: "west", position: 2))
}

/// Fullscreen spaces are not in `desktops`, so entering fullscreen shifts no
/// number, and a display showing one is paused.
@Test func aFullscreenSpaceHasNoNumberAndPausesItsDisplay() {
    var s = SpaceState()
    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [3, 76, 78], current: 425, isMain: true)])
    #expect(s.wsOrder.count == 3)
    #expect(s.active[425] == nil)
    #expect(s.isPaused("A"))
    #expect(s.currentWorkspace == nil)
    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [3, 76, 78], current: 76, isMain: true)])
    #expect(!s.isPaused("A"))
    #expect(s.currentWorkspace == ws(s, 76))
}

/// Labels stay with numbers: a desktop added in front of the others takes the
/// first label, as Mission Control's order says it should.
@Test func labelsAttachByNumberWhenDesktopsChange() {
    var s = desktops([10], names: ["mail", "code"])
    #expect(s.workspace(on: 10)?.label == "mail")
    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [10, 20], current: 10)])
    #expect(s.workspace(on: 20)?.label == "code")
    s.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [5, 10, 20], current: 10)])
    #expect(s.workspace(on: 5)?.label == "mail")
    #expect(s.workspace(on: 10)?.label == "code")
    #expect(s.workspace(on: 20)?.label == "3")
}

@Test func aLabelOrNumberWithNoDesktopIsMissingNotUnknown() {
    let s = desktops([10, 20], names: ["mail", "code", "music"])
    #expect(s.resolveWorkspace("music") == nil)
    #expect(s.missingDesktop("music") == 3)
    #expect(s.missingDesktop("7") == 7)
    #expect(s.missingDesktop("code") == nil)
    #expect(s.missingDesktop("nope") == nil)
    // A desktop id out of `query spaces` is not a desktop number.
    #expect(s.missingDesktop("4000") == nil)
}

@Test func spaceLabelNamesTheDesktopByNumber() {
    var s = desktops([10, 20])
    s.setLabel("web", number: 2)
    #expect(s.workspace(on: 20)?.label == "web")
    #expect(s.persistedNames() == ["1", "web"])
    s.setLabel("far", number: 4)
    #expect(s.persistedNames() == ["1", "web", "", "far"])
}

/// `next`/`prev` stay on the focused display and stop at its ends, as ⌃←/⌃→
/// do; empty desktops are not skipped.
@Test func steppingStaysOnTheFocusedDisplayAndDoesNotWrap() {
    var s = SpaceState()
    s.adoptDisplays([
        DisplayDesktops(uuid: "A", desktops: [1, 2, 3], current: 2, isMain: true),
        DisplayDesktops(uuid: "B", desktops: [7, 8], current: 7, originX: 2000),
    ])
    s.focusedDisplay = "A"
    #expect(s.resolveWorkspace("next") == ws(s, 3))
    #expect(s.resolveWorkspace("prev") == ws(s, 1))
    s.focusedDisplay = "B"
    #expect(s.resolveWorkspace("prev") == nil)
    #expect(s.resolveWorkspace("next") == ws(s, 8))
}

// MARK: - Membership (NATIVE.md: macOS owns it)

@Test func eachWindowIsInTheWorkspaceOfItsDesktop() {
    let s = desktops([3, 5])
    let out = membershipByDesktop([10: [3], 11: [5], 12: [3]], active: s.active)
    #expect(out.members[ws(s, 3)] == [10, 12])
    #expect(out.members[ws(s, 5)] == [11])
    #expect(out.everywhere.isEmpty)
}

/// Dock › Options › All Desktops: floats, never moved, in no workspace.
@Test func aWindowOnEveryDesktopIsInNoWorkspace() {
    let s = desktops([3, 5])
    let out = membershipByDesktop([10: [3, 5], 11: [5]], active: s.active)
    #expect(out.everywhere == [10])
    #expect(out.members[ws(s, 3)] == nil)
    #expect(out.members[ws(s, 5)] == [11])
}

/// A window in native fullscreen is on a space with no workspace: in none.
/// Back on its desktop, it is that desktop's again.
@Test func aFullscreenWindowRejoinsItsDesktopWhenItLeaves() {
    var s = desktops([3])
    var (synced, _) = syncMembership(s, membership: membershipByDesktop([10: [3], 11: [3]], active: s.active).members, live: Set(s.wsOrder))
    s = synced
    (synced, _) = syncMembership(s, membership: membershipByDesktop([10: [3], 11: [425]], active: s.active).members, live: Set(s.wsOrder))
    #expect(synced.layout(on: 3)?.windows == [10])
    (synced, _) = syncMembership(synced, membership: membershipByDesktop([10: [3], 11: [3]], active: s.active).members, live: Set(s.wsOrder))
    #expect(synced.layout(on: 3)?.windows.sorted() == [10, 11])
}

// MARK: - Desktops coming and going

/// A desktop removed in Mission Control loses its workspace; the others keep
/// theirs, trees and all, and are numbered again.
@Test func aRemovedDesktopTakesOnlyItsOwnWorkspace() {
    var s = desktops([10], names: [])
    s.adoptDisplays([DisplayDesktops(uuid: "D10", desktops: [10, 20, 30], current: 10)])
    let kept = ws(s, 30)
    s.file(42, in: kept, laidOut: true)
    s.recentWorkspace = ws(s, 20)
    s.adoptDisplays([DisplayDesktops(uuid: "D10", desktops: [10, 30], current: 10)])
    #expect(s.active[20] == nil)
    #expect(ws(s, 30) == kept)
    #expect(s.workspaces[kept]?.contains(42) == true)
    #expect(s.workspace(on: 30)?.label == "2")
    #expect(s.recentWorkspace == nil)
}

/// Unplug a display and plug it back: its desktops come back — with new
/// SpaceIDs, as after a logout — and each takes the layout it had (story 35).
@Test func aDisplayPluggedBackInGetsItsLayoutsBack() {
    var s = SpaceState()
    let laptop = DisplayDesktops(uuid: "L", desktops: [1], current: 1, isMain: true)
    s.adoptDisplays([laptop, DisplayDesktops(uuid: "X", desktops: [7, 8], current: 7, originX: 2000)])
    s.workspaces[ws(s, 8)]?.overrideKind = .float
    s.setLayout(.float(FloatState()), on: 8)
    s.adoptDisplays([laptop])
    #expect(s.wsOrder.count == 1)
    s.adoptDisplays([laptop, DisplayDesktops(uuid: "X", desktops: [17, 18], current: 17, originX: 2000)])
    #expect(s.workspace(on: 18)?.overrideKind == .float)
    #expect(s.layout(on: 18)?.kind == .float)
    #expect(s.workspace(on: 17)?.overrideKind == nil)
}

@Test func noDisplaysIsATransientAndChangesNothing() {
    var s = desktops([10, 20], names: ["a", "b"])
    let before = s
    s.adoptDisplays([])
    #expect(s == before)
}

// MARK: - Layouts on disk, by place

/// A logout hands out new SpaceIDs; the layout comes back by (display,
/// position). The tree only within one boot.
@Test func layoutsSurviveALogoutByPlace() throws {
    let inner = Container(layout: .splitH, children: [.window(2), .window(3)], ratios: [0.4, 0.6])
    let root = Container(layout: .splitV, children: [.window(1), .container(inner)], ratios: [0.7, 0.3])
    var first = SpaceState()
    first.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [10, 20, 30], current: 10)])
    first.workspaces[ws(first, 20)]?.overrideKind = .float
    first.setLayout(.tiling(Tree(root: .container(root), focus: 3)), on: 30)
    let saved = first.persistedLayouts()
    #expect(saved[DesktopKey(display: "A", position: 1)] == nil)
    let data = try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: saved.map { ($0.key.description, $0.value) }))
    let decoded = try JSONDecoder().decode([String: SavedDesktop].self, from: data)
    let byKey = Dictionary(uniqueKeysWithValues: decoded.compactMap { k, v in DesktopKey(k).map { ($0, v) } })

    var restarted = SpaceState()
    restarted.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [11, 21, 31], current: 11)])
    restarted.restore(byKey, trees: true)
    #expect(restarted.workspace(on: 21)?.overrideKind == .float)
    #expect(restarted.layout(on: 21)?.kind == .float)
    guard case .tiling(let tree)? = restarted.layout(on: 31) else { Issue.record("not tiling"); return }
    #expect(tree.root == .container(root))
    #expect(tree.focus == 3)

    var nextBoot = SpaceState()
    nextBoot.adoptDisplays([DisplayDesktops(uuid: "A", desktops: [12, 22, 32], current: 12)])
    nextBoot.restore(byKey, trees: false)
    #expect(nextBoot.workspace(on: 22)?.overrideKind == .float)
    #expect(nextBoot.layout(on: 32)?.windows == [])
}

@Test func aDesktopKeyRoundTripsThroughText() {
    let key = DesktopKey(display: "37D8832A-2D66-02CA-B9F7-8F30A301B230", position: 3)
    #expect(DesktopKey(key.description) == key)
    #expect(DesktopKey("no-hash") == nil)
}

// MARK: - Focus history

/// A switch focuses the window last used there — a float included — not the
/// layout's own idea of focus.
@Test func theLastFocusedWindowIsWhatASwitchFocuses() {
    var s = desktops([3])
    let id = ws(s, 3)
    s.file(10, in: id, laidOut: true)
    s.file(11, in: id, laidOut: true)
    s.file(12, in: id, laidOut: false)
    s.noteFocus(12)
    #expect(s.workspaces[id]?.focusTarget == 12)
    s.removeWindow(12)
    #expect(s.workspaces[id]?.focusTarget == s.layout(on: 3)?.focus)
    #expect(desktops([4]).workspace(on: 4)?.focusTarget == nil)
}

@Test func workspaceNamesSurviveARestart() {
    let one = [DisplayDesktops(uuid: "A", desktops: [10, 20, 30], current: 10)]
    var first = SpaceState()
    first.adoptDisplays(one, names: ["one", "two", "three"])
    var second = SpaceState()
    second.adoptDisplays(one, names: first.persistedNames())
    #expect(second.persistedNames() == ["one", "two", "three"])
}

/// A saved tree is repaired, not trusted: a container left with one child
/// collapses, bad ratios even out, and a focus that is not in it moves.
@Test func aDamagedSavedTreeIsRepaired() {
    let saved = SavedTree.SavedNode.container(layout: .splitV, ratios: [1], active: 0, children: [
        .window(1),
        .container(layout: .splitH, ratios: [0.5], active: 0, children: [.window(2)]),
        .window(3),
    ])
    var s = SavedTree(Tree())
    s.root = saved
    s.focus = 99
    let tree = s.tree
    #expect(tree.windows == [1, 2, 3])
    #expect(tree.focus == 1)
    guard case .container(let c)? = tree.root else { Issue.record("no container"); return }
    #expect(c.children == [.window(1), .window(2), .window(3)])
    #expect(c.ratios.count == 3 && abs(c.ratios[0] - 1.0 / 3) < 1e-9)
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

