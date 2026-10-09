import Testing
@testable import WeftCore

// Lazy tiling on first visit, and layout before show (NATIVE.md).

private let a = Frame(x: 0, y: 0, width: 500, height: 800)
private let b = Frame(x: 500, y: 0, width: 500, height: 800)

@Test func showingDesktopsAreAlwaysLaidOut() {
    let out = desktopsToLayOut(showing: [1, 7], computed: [:], lastWritten: [:], bound: { _ in false })
    #expect(out == [1, 7])
}

/// A window arrives on a hidden desktop weft holds elements for: laid out now,
/// so it is in its tile when the desktop shows.
@Test func aHiddenDesktopWhoseLayoutChangedIsLaidOutBeforeItShows() {
    let out = desktopsToLayOut(
        showing: [1],
        computed: [2: [10: a, 11: b]],
        lastWritten: [2: [10: Frame(x: 0, y: 0, width: 1000, height: 800)]],
        bound: { _ in true }
    )
    #expect(out == [1, 2])
}

@Test func anUnchangedHiddenDesktopIsLeftAlone() {
    let out = desktopsToLayOut(showing: [1], computed: [2: [10: a]], lastWritten: [2: [10: a]], bound: { _ in true })
    #expect(out == [1])
}

/// Cold start: a desktop with a window weft never held an element for waits
/// until it is shown — no warm-up sweep through the desktops.
@Test func aHiddenDesktopWithAnUnboundWindowWaitsUntilShown() {
    let out = desktopsToLayOut(
        showing: [1], computed: [3: [20: a, 21: b]], lastWritten: [:], bound: { $0 == 20 }
    )
    #expect(out == [1])
}

/// Shown for the first time, the app's window list was empty: look again,
/// a few times at most.
@Test func aDesktopShownBeforeItsAppAnsweredIsLookedAtAgain() {
    #expect(needsAnotherLook(showingWindows: [20, 21], bound: { $0 == 20 }, triesLeft: 3))
    #expect(!needsAnotherLook(showingWindows: [20, 21], bound: { _ in true }, triesLeft: 3))
    #expect(!needsAnotherLook(showingWindows: [20, 21], bound: { _ in false }, triesLeft: 0))
}
