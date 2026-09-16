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

    private static let carryLock = NSLock()
    private nonisolated(unsafe) static var carrying = false

    /// True while a window is being held and carried to another desktop.
    ///
    /// The carry looks exactly like a user dragging a window and changing
    /// desktop, because that is what it is — so weft's own reactions fire:
    /// `scheduleDragSettleApply` re-applies the layout 150ms after a move
    /// notification, and each desktop change during the carry schedules a
    /// sweep. Either one writes an AX frame to the window being dragged, and an
    /// AX move mid-drag ends the drag session — the window is dropped where it
    /// stands and the remaining keypresses change desktop carrying nothing.
    ///
    /// That is why this works from a standalone harness and failed in a running
    /// daemon: nothing was there to fight it. Callers that re-apply layouts
    /// check this and stand down until the carry finishes.
    public static var isCarrying: Bool { carryLock.withLock { carrying } }

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
        // Every exit below used to be a bare `return false`, so a failed move
        // said only "nothing changed" — true, and useless. Each one now names
        // itself under WEFT_TRACE.
        func no(_ why: String) -> Bool {
            if Trace.logging { fputs("weftd: carry \(wid) -> \(sid) refused: \(why)\n", stderr) }
            return false
        }
        guard AXIsProcessTrusted() else { return no("not trusted for Accessibility") }
        let keys = shortcuts
        guard let right = keys.right, let left = keys.left else {
            return no("no 'move a space' shortcut bound (left=\(String(describing: keys.left)) right=\(String(describing: keys.right)))")
        }
        guard let windowSpace = SpaceControl.spacesForWindow(wid).first else {
            return no("the WindowServer places it on no space")
        }
        guard let display = DockSwipe.managedDisplays().first(where: { $0.ids.contains(sid) }),
              display.ids.contains(windowSpace)
        else {
            return no("target \(sid) and window space \(windowSpace) are not on one display")
        }
        if Trace.logging {
            fputs(
                "weftd: carry \(wid) from \(windowSpace) to \(sid) on \(display.uuid.prefix(8)) "
                    + "showing \(display.current); keys L=\(left.keyCode)/\(left.modifiers) "
                    + "R=\(right.keyCode)/\(right.modifiers); order=\(display.ids)\n",
                stderr
            )
        }

        let userStartedOn = display.current
        // Held for the whole operation, including the desktop changes at either
        // end: every one of them would otherwise trigger a sweep that re-applies
        // frames to the window being dragged.
        carryLock.withLock { carrying = true }
        defer { carryLock.withLock { carrying = false } }

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
        let key = steps > 0 ? right : left

        /// Has the window left where it started? The only proof a drag began.
        func moved() -> Bool {
            WorldReader.frame(of: wid).map {
                abs($0.x - frame.x) > 0.5 || abs($0.y - frame.y) > 0.5
            } ?? false
        }

        // Where a window can be picked up.
        //
        // A title bar is the obvious answer, and the only one that works for a
        // standard window. Borderless windows have none — on a terminal, 11pt
        // below the top edge is content, where a drag selects text and moves
        // nothing. Measured: an Electron window with a real title bar held on
        // the first point; a borderless terminal held on none of them, and the
        // keystroke then switched the desktop carrying nothing. That was the
        // whole bug, and it is why every point is verified before any key is
        // sent: a window that cannot be picked up must not cost the user a
        // desktop switch.
        //
        // The second point is the empty strip a tabbed window leaves to the
        // right of its tabs, which is draggable where the middle is not.
        let candidates = [
            CGPoint(x: frame.x + frame.width / 2, y: frame.y + 11),
            CGPoint(x: frame.x + frame.width - 50, y: frame.y + 11),
            CGPoint(x: frame.x + 80, y: frame.y + 11),
            CGPoint(x: frame.x + frame.width / 2, y: frame.y + 24),
        ]
        var held: CGPoint?
        for point in candidates {
            mouse(.leftMouseDown, point)
            // macOS starts a window drag on movement, not on the press alone.
            for dy in stride(from: 2.0, through: 8.0, by: 2.0) {
                mouse(.leftMouseDragged, CGPoint(x: point.x, y: point.y + dy))
                usleep(12_000)
            }
            let ok = moved()
            if Trace.logging {
                fputs(
                    "weftd: carry grab at \(Int(point.x)),\(Int(point.y)) — "
                        + "\(ok ? "held" : "not held")\n", stderr)
            }
            if ok {
                held = point
                break
            }
            // Let go before trying elsewhere. Released as a drag rather than a
            // click, so a control under the pointer is not activated.
            mouse(.leftMouseUp, CGPoint(x: point.x, y: point.y + 8))
            usleep(60_000)
        }
        guard let grab = held else {
            if Trace.logging {
                fputs(
                    "weftd: carry \(wid) — nothing draggable in its top edge; "
                        + "not sending the shortcut\n", stderr)
            }
            return false
        }

        var landed = true
        for i in 0..<abs(steps) {
            let before = current(of: uuid)
            press(key)
            let ok = waitForChange(on: uuid, from: before)
            if Trace.logging {
                fputs(
                    "weftd: carry press \(i + 1)/\(abs(steps)) key=\(key.keyCode) "
                        + "desktop \(before ?? 0) -> \(current(of: uuid) ?? 0) "
                        + "\(ok ? "landed" : "DID NOT LAND in \(settle)s")\n",
                    stderr
                )
            }
            if !ok {
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
