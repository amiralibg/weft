import ApplicationServices
import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

/// Moving a window to another desktop, with SIP on and nothing installed.
///
/// The window is held by its title bar, the bound "move a space" shortcut is
/// pressed once per desktop of travel, and the button is released on the far
/// side. This is the gesture a person uses, and on macOS 27 it is the only
/// route that works from an ordinary process: every SkyLight call for it is
/// refused, several of them by returning success and doing nothing
/// (spikes/RESULTS.md §S8). A synthetic Dock *swipe* is refused too while a
/// drag is in flight — verified against weft's own swipe and the spike's — but
/// a keystroke reaches Dock and the held window travels with it.
///
/// What it costs, and what callers must know:
///
/// - **The screen moves.** Two visible desktop changes for a move the user did
///   not ask to follow, and more when the window starts on another desktop.
///   There is no quieter version; the alternative is a scripting addition and
///   SIP switched off.
/// - **Only a window on screen can be grabbed.** A window on another desktop
///   has no coordinate to press, so weft goes to its desktop first and comes
///   back afterwards.
/// - **It is verified.** Success is `SLSCopySpacesForWindows` reporting the
///   target afterwards, never the fact that the keys were posted. Three of the
///   APIs this replaces lie about exactly that.
public enum DragMove {
    /// The "WEFT" marker weft's own input tap lets through, so a synthetic
    /// press does not re-enter weft's keybinds.
    private static let marker: Int64 = 0x5745_4654

    /// How long one desktop change is given to commit before the next press.
    /// Polled rather than slept: a switch lands in ~20ms, and a read taken
    /// before it commits reports the old desktop — which is how an earlier
    /// version of this over-corrected and left the user two desktops away.
    private static let settle: TimeInterval = 0.8

    public static var shortcuts: (left: SpaceShortcut?, right: SpaceShortcut?) {
        guard let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys")
        else { return (SpaceShortcuts.defaultLeft, SpaceShortcuts.defaultRight) }
        return SpaceShortcuts.read(from: hotkeys)
    }

    /// Whether this Mac has what the move needs: Accessibility, and a bound
    /// shortcut in each direction.
    public static var isSupported: Bool {
        guard AXIsProcessTrusted() else { return false }
        let s = shortcuts
        return s.left != nil && s.right != nil
    }

    /// Move `wid` to desktop `sid` without leaving the user there.
    ///
    /// Returns true only once the WindowServer agrees the window is on `sid`.
    @discardableResult
    public static func moveWindow(_ wid: WindowID, to sid: SpaceID) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let keys = shortcuts
        guard let right = keys.right, let left = keys.left else { return false }
        guard let windowSpace = SpaceControl.spacesForWindow(wid).first else { return false }
        guard let display = DockSwipe.managedDisplays().first(where: { $0.ids.contains(sid) }),
              display.ids.contains(windowSpace)
        else { return false }

        let userStartedOn = display.current
        // Only a window on screen can be grabbed, so go to its desktop first.
        if windowSpace != display.current, !DockSwipe.focusSpace(windowSpace) { return false }

        var moved = false
        if let count = SpaceShortcuts.steps(from: windowSpace, to: sid, in: display.ids), count != 0 {
            moved = carry(wid, steps: count, on: display.uuid, right: right, left: left)
        }

        // Back to where the user was, whatever happened above. Leaving them on
        // another desktop is a worse failure than the move not working.
        if let now = current(of: display.uuid), now != userStartedOn {
            DockSwipe.focusSpace(userStartedOn)
        }
        return moved && SpaceControl.spacesForWindow(wid).contains(sid)
    }

    // MARK: - The drag

    private static func carry(
        _ wid: WindowID, steps: Int, on uuid: String, right: SpaceShortcut, left: SpaceShortcut
    ) -> Bool {
        guard let frame = WorldReader.frame(of: wid) else { return false }
        // Below the top edge, mid-width: clear of the traffic lights on the
        // left and of any toolbar control on the right.
        let grab = CGPoint(x: frame.x + frame.width / 2, y: frame.y + 11)
        let key = steps > 0 ? right : left

        mouse(.leftMouseDown, grab)
        // macOS starts a window drag on movement, not on the press alone.
        for dy in stride(from: 2.0, through: 8.0, by: 2.0) {
            mouse(.leftMouseDragged, CGPoint(x: grab.x, y: grab.y + dy))
            usleep(12_000)
        }

        var landed = true
        for _ in 0..<abs(steps) {
            let before = current(of: uuid)
            press(key)
            if !waitForChange(on: uuid, from: before) {
                landed = false
                break
            }
        }

        // Released explicitly on every path. A synthetic press with no release
        // leaves the session dragging, and nothing else can clear it.
        mouse(.leftMouseDragged, CGPoint(x: grab.x, y: grab.y + 10))
        usleep(40_000)
        mouse(.leftMouseUp, CGPoint(x: grab.x, y: grab.y + 10))
        usleep(150_000)
        return landed
    }

    private static func mouse(_ type: CGEventType, _ at: CGPoint) {
        guard let e = CGEvent(
            mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)
        else { return }
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.post(tap: .cgSessionEventTap)
    }

    private static func press(_ shortcut: SpaceShortcut) {
        let flags = CGEventFlags(rawValue: shortcut.modifiers)
        for down in [true, false] {
            guard let k = CGEvent(
                keyboardEventSource: nil, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: down)
            else { return }
            k.flags = flags
            k.setIntegerValueField(.eventSourceUserData, value: marker)
            k.post(tap: .cgSessionEventTap)
            usleep(20_000)
        }
    }

    private static func current(of uuid: String) -> SpaceID? {
        DockSwipe.managedDisplays().first { $0.uuid == uuid }?.current
    }

    private static func waitForChange(on uuid: String, from before: SpaceID?) -> Bool {
        let deadline = Date().addingTimeInterval(settle)
        repeat {
            if let now = current(of: uuid), now != before { return true }
            usleep(5_000)
        } while Date() < deadline
        return false
    }
}
