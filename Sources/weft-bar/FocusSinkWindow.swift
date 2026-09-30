import AppKit
import WeftCore

/// The window keyboard focus goes to on an empty workspace (`FocusSink`).
///
/// weftd focuses it like any other window: Accessibility makes it key and
/// WeftBar is activated. It has to be a real window that can be key — an app
/// with nothing key-able can be activated and still leave typing going to the
/// window weft just hid.
///
/// Invisible and inert: clear, 3×3 points in a corner of the main screen,
/// ignores the mouse, on every desktop so it is there whichever one is
/// showing, and out of the window cycle and Exposé. weft tiles nothing
/// smaller than 100×100, so it is never mistaken for a window to lay out.
@MainActor
final class FocusSinkWindow: NSWindow {
    static let shared = FocusSinkWindow()

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private init() {
        let side = CGFloat(FocusSink.side)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        title = "weft focus"
    }

    /// On screen, in the bottom-left corner of the main display, where the
    /// Dock and the menu bar are not.
    func install() {
        let origin = NSScreen.screens.first?.frame.origin ?? .zero
        setFrameOrigin(origin)
        orderFrontRegardless()
    }

    /// Typing into it goes nowhere, quietly — no beep for every key.
    override func keyDown(with event: NSEvent) {}
}
