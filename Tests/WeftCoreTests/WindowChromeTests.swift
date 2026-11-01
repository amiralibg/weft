import Testing
@testable import WeftCore

private func chrome(
    _ w: Double, _ h: Double, close: Bool = true, minimize: Bool = true,
    fullScreen: Bool = true, modal: Bool = false
) -> WindowChrome {
    WindowChrome(width: w, height: h, hasClose: close, canMinimize: minimize, hasFullScreen: fullScreen, modal: modal)
}

@Test func documentWindowTiles() {
    #expect(chrome(1200, 800).verdict == .window)
    // A small one with real chrome is still a window.
    #expect(chrome(400, 300).verdict == .window)
    // Either working button is enough.
    #expect(chrome(500, 400, fullScreen: false).verdict == .window)
    #expect(chrome(500, 400, minimize: false).verdict == .window)
}

@Test func modalWindowFloatsAtAnySize() {
    #expect(chrome(1400, 900, modal: true).verdict == .modal)
}

/// A browser's passkey or sign-in prompt: standard subrole, resizable, a
/// close button, and no way to minimise it or take it full screen.
@Test func passkeyPromptFloats() {
    #expect(chrome(460, 520, minimize: false, fullScreen: false).verdict == .dialog)
}

@Test func largeChromelessWindowTiles() {
    #expect(chrome(1600, 1000, close: false, minimize: false, fullScreen: false).verdict == .window)
    #expect(chrome(1000, 700, minimize: false, fullScreen: false).verdict == .window)
}

/// A terminal with its title bar turned off has no buttons at all. It is
/// not a dialog, however small it opens.
@Test func titlebarlessTerminalTiles() {
    #expect(chrome(720, 480, close: false, minimize: false, fullScreen: false).verdict == .window)
}

@Test func smallButtonlessPopupIsAPanel() {
    #expect(chrome(470, 180, close: false, minimize: false, fullScreen: false).verdict == .panel)
}
