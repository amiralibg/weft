import Testing
@testable import WeftCore

// A window closed without being destroyed must give its slot back; a window
// on a desktop nobody is looking at must not lose one. `isTileable` is where
// that line is drawn.

private func win(_ spaces: [SpaceID], onScreen: Bool?) -> WindowInfo {
    WindowInfo(id: 1, app: "a", title: "", pid: 1, spaces: spaces, frame: .zero, bound: false, onScreen: onScreen)
}

@Test func aClosedButKeptWindowOnAShowingDesktopIsNotATile() {
    #expect(!win([7], onScreen: false).isTileable(visibleSpaces: [7]))
}

@Test func aWindowOnADesktopNobodyIsLookingAtKeepsItsSlot() {
    #expect(win([8], onScreen: false).isTileable(visibleSpaces: [7]))
}

@Test func onScreenOrUnreadIsATile() {
    #expect(win([7], onScreen: true).isTileable(visibleSpaces: [7]))
    #expect(win([7], onScreen: nil).isTileable(visibleSpaces: [7]))
}
