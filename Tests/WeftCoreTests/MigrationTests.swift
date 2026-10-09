import Testing
@testable import WeftCore

// The migration spread from a 0.9.21 membership file (NATIVE.md,
// "Migration from 0.9.21"): old workspace k's windows to desktop k.

/// 0.9.21 put every workspace on desktop 3 (the managed one); now there are
/// desktops 3, 76, 78 by number.
@Test func oldWorkspacesSpreadToTheDesktopWithTheirNumber() {
    let plan = planSpread(
        old: [[10, 11], [20], [30, 31]],
        desktops: [3, 76, 78],
        windowDesktops: [10: [3], 11: [3], 20: [3], 30: [3], 31: [3]]
    )
    #expect(plan.batches == [
        .init(desktop: 76, windows: [20]),
        .init(desktop: 78, windows: [30, 31]),
    ])
    #expect(plan.complete)
}

/// More old workspaces than desktops: the extras stay put, and say so.
@Test func workspacesWithNoDesktopWaitAndAreNamed() {
    let plan = planSpread(
        old: [[10], [20], [30], [40]],
        desktops: [3, 76],
        windowDesktops: [10: [3], 20: [3], 30: [3], 40: [3]]
    )
    #expect(plan.batches == [.init(desktop: 76, windows: [20])])
    #expect(plan.waiting == [3, 4])
    #expect(!plan.complete)
}

/// Closed windows ask for nothing; an old workspace that is all closed is
/// not waiting for anything.
@Test func closedWindowsAreDropped() {
    let plan = planSpread(old: [[10], [20], [99]], desktops: [3, 76], windowDesktops: [10: [3], 20: [3]])
    #expect(plan.batches == [.init(desktop: 76, windows: [20])])
    #expect(plan.complete)
}

/// Re-runnable: windows already on their desktop stay, and a second run does
/// nothing.
@Test func aSecondSpreadDoesNothing() {
    let plan = planSpread(old: [[10], [20]], desktops: [3, 76], windowDesktops: [10: [3], 20: [76]])
    #expect(plan.batches.isEmpty)
    #expect(plan.complete)
}

/// Windows on every desktop and windows in a fullscreen space are not moved.
@Test func allDesktopAndFullscreenWindowsStay() {
    let plan = planSpread(
        old: [[10], [20, 21]],
        desktops: [3, 76],
        windowDesktops: [10: [3], 20: [3, 76], 21: [425]]
    )
    #expect(plan.batches.isEmpty)
}

/// A window listed twice (a 0.9.21 sticky window was in no workspace, but a
/// damaged file could) moves once, with the first workspace that lists it.
@Test func aWindowListedTwiceMovesOnce() {
    let plan = planSpread(old: [[10], [10, 20]], desktops: [3, 76], windowDesktops: [10: [3], 20: [3]])
    #expect(plan.batches == [.init(desktop: 76, windows: [20])])
}
