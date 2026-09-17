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

    /// Where each app's windows can actually be picked up, as an offset from
    /// the window's top-left.
    ///
    /// Keyed by pid, so it is per application rather than per window: a
    /// browser's title bar is in the same place in every window it opens, and
    /// the point of this is that the *second* move of an app costs one attempt
    /// instead of four. A miss is about 110 ms, so a window whose chrome only
    /// yields on the last candidate paid a third of a second before any key
    /// went out, every single time.
    private nonisolated(unsafe) static var grabOffsets: [Int32: CGPoint] = [:]

    private static func grabOffset(for wid: WindowID) -> CGPoint? {
        guard let pid = WorldReader.pid(of: wid) else { return nil }
        return carryLock.withLock { grabOffsets[pid] }
    }

    private static func rememberGrab(_ offset: CGPoint, for wid: WindowID) {
        guard let pid = WorldReader.pid(of: wid) else { return }
        carryLock.withLock {
            // Bounded: a long-lived daemon must not accumulate an entry per
            // process it has ever carried a window for.
            if grabOffsets.count > 128 { grabOffsets.removeAll() }
            grabOffsets[pid] = offset
        }
    }

    /// Drop a remembered point that stopped working — the app changed its
    /// chrome, or the window is a different kind from the one that taught us.
    /// Keeping it would put the same failed attempt first forever.
    private static func forgetGrab(for wid: WindowID) {
        guard let pid = WorldReader.pid(of: wid) else { return }
        carryLock.withLock { _ = grabOffsets.removeValue(forKey: pid) }
    }

    private static let reasonLock = NSLock()
    private nonisolated(unsafe) static var lastFailure: String?

    /// Why the last carry did not happen, in words worth putting in front of
    /// someone. Nil after one that worked.
    public static var failureReason: String? { reasonLock.withLock { lastFailure } }

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

    /// Move `wid` to desktop `sid`.
    ///
    /// - Parameter stayOnDestination: leave the user on `sid` instead of
    ///   returning them. The carry *ends* on `sid`, so this is the cheaper of
    ///   the two — going back is an extra visible desktop change, and it is
    ///   only ever undone on the way to somewhere the user probably wanted to
    ///   be anyway. A failed carry still returns them, whichever is asked for:
    ///   the destination is not where they meant to end up if the window did
    ///   not get there.
    ///
    /// Returns true only once the WindowServer agrees the window is on `sid`.
    @discardableResult
    public static func moveWindow(
        _ wid: WindowID, to sid: SpaceID, stayOnDestination: Bool = false
    ) -> Bool {
        // Every exit below used to be a bare `return false`, so a failed move
        // said only "nothing changed" — true, and useless. Each one names
        // itself, and the reason is kept for the caller rather than only
        // logged: a keybind that does nothing is exactly the case where the
        // person affected is not watching stderr, and telling them to re-run
        // with WEFT_TRACE is asking them to reproduce a bug to find out what
        // it was.
        func no(_ why: String) -> Bool {
            reasonLock.withLock { lastFailure = why }
            if Trace.logging { fputs("weftd: carry \(wid) -> \(sid) refused: \(why)\n", stderr) }
            return false
        }
        reasonLock.withLock { lastFailure = nil }
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
        if windowSpace != display.current, !DockSwipe.focusSpace(windowSpace) {
            return no("could not switch to desktop \(windowSpace), where the window is")
        }

        var moved = false
        guard let count = SpaceShortcuts.steps(from: windowSpace, to: sid, in: display.ids) else {
            return no("desktop \(windowSpace) or \(sid) is not in this display's list \(display.ids)")
        }
        if count == 0 {
            // Already there. Not a failure, and not work either.
            return true
        }
        moved = carry(wid, steps: count, to: sid, on: display.uuid, right: right, left: left)

        let landed = moved && SpaceControl.spacesForWindow(wid).contains(sid)
        if moved && !landed {
            _ = no("the drag and the keypresses went out, but the WindowServer still "
                + "puts the window on \(SpaceControl.spacesForWindow(wid))")
        }
        // Stay only on a move that actually worked. A failed carry leaves the
        // user on a desktop they did not ask for, with the window still where
        // it was — the worst of both, and the one case where going back is
        // unambiguously right.
        if landed && stayOnDestination {
            // The carry ends on `sid` already; this only corrects a carry that
            // over- or under-shot.
            if let now = current(of: display.uuid), now != sid { _ = DockSwipe.focusSpace(sid) }
        } else if let now = current(of: display.uuid), now != userStartedOn {
            _ = DockSwipe.focusSpace(userStartedOn)
        }
        return landed
    }

    // MARK: - The drag

    private static func carry(
        _ wid: WindowID, steps: Int, to target: SpaceID, on uuid: String,
        right: SpaceShortcut, left: SpaceShortcut
    ) -> Bool {
        guard let frame = WorldReader.frame(of: wid) else { return false }
        let key = steps > 0 ? right : left

        /// Is the window following the pointer — by exactly the amount the
        /// pointer has moved, and in no other way?
        ///
        /// "Did it move at all" is not the same question and answering that one
        /// was a bug with teeth. weft writes frames to this very window: the
        /// trailing pass after the *previous* move lands 250 ms later, and any
        /// sweep can retile it. A probe that accepts any movement reads one of
        /// those writes as a successful grab, and then the desktop shortcut
        /// goes out with nothing held — the desktop changes, the window stays,
        /// and the move fails after costing two visible switches. It showed up
        /// as "moved it there, then moving it back did nothing at all",
        /// because the first move is what schedules the write that fools the
        /// second.
        ///
        /// A held window tracks the pointer exactly: down by `dy`, no sideways
        /// travel, no resize. A retile changes x or the size, or moves y by
        /// something other than `dy`. Nothing weft writes can satisfy this by
        /// accident.
        func following(_ dy: Double) -> Bool {
            guard let now = WorldReader.frame(of: wid) else { return false }
            let down = now.y - frame.y
            // Down by *something*, and by no more than the pointer travelled.
            // Not `≈ dy`: macOS needs a few points of movement before it
            // starts a window drag, so a window that was picked up on the
            // third nudge has travelled less than the pointer and an exact
            // match would reject it. The upper bound is what keeps a retile
            // out — those move a window by a slot, not by eight points, and
            // they change x or the size while they do it.
            return abs(now.x - frame.x) < 1.5
                && abs(now.width - frame.width) < 1.5
                && abs(now.height - frame.height) < 1.5
                && down > 0.5 && down <= dy + 3
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
        // Offsets from the window's top-left, so a remembered one still lands
        // on the same part of the chrome when the window is a different size.
        // The one that worked for this app last time goes first: probing costs
        // about 110 ms per miss, and an app's title bar is in the same place
        // every time.
        var offsets: [CGPoint] = [
            CGPoint(x: frame.width / 2, y: 11),
            CGPoint(x: frame.width - 50, y: 11),
            CGPoint(x: 80, y: 11),
            CGPoint(x: frame.width / 2, y: 24),
        ]
        if let remembered = grabOffset(for: wid) {
            offsets.removeAll { abs($0.x - remembered.x) < 1 && abs($0.y - remembered.y) < 1 }
            offsets.insert(remembered, at: 0)
        }
        var held: CGPoint?
        for offset in offsets {
            let point = CGPoint(x: frame.x + offset.x, y: frame.y + offset.y)
            mouse(.leftMouseDown, point)
            // macOS starts a window drag on movement, not on the press alone.
            var travelled = 0.0
            for dy in stride(from: 2.0, through: 8.0, by: 2.0) {
                mouse(.leftMouseDragged, CGPoint(x: point.x, y: point.y + dy))
                usleep(12_000)
                travelled = dy
            }
            let ok = following(travelled)
            if Trace.logging {
                fputs(
                    "weftd: carry grab at \(Int(point.x)),\(Int(point.y)) — "
                        + "\(ok ? "held" : "not held")\n", stderr)
            }
            if ok {
                held = point
                rememberGrab(offset, for: wid)
                break
            }
            // Let go before trying elsewhere. Released where it was pressed,
            // not 8pt below: a release that has travelled is a *drag* to
            // whatever is under it, and on a tab strip that tears the tab out
            // into its own window. Back at the press point it is a click on
            // something that was never activated, because the press and the
            // release cancel out.
            mouse(.leftMouseUp, point)
            usleep(60_000)
        }
        guard let grab = held else {
            forgetGrab(for: wid)
            reasonLock.withLock {
                lastFailure = "nothing along this window's top edge picks it up, so weft "
                    + "cannot carry it. Apps that draw their own title bar sometimes leave "
                    + "no draggable strip at all."
            }
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

        // Let the desktop settle under the held window before letting go.
        //
        // `waitForChange` returns the moment the WindowServer reports the new
        // desktop, which is earlier than the moment the transition is over —
        // and a drop taken during it replays the last movement on the desktop
        // being left, so the window is let go on the old one. The spike this
        // is built from (spikes/dragmove.swift) waits here for exactly that
        // reason and the shipped version never did. It is one wait per move,
        // against a gesture that already pays a full space-switch animation
        // per desktop travelled.
        if landed { usleep(120_000) }

        // Released explicitly on every path. A synthetic press with no release
        // leaves the session dragging, and nothing else can clear it.
        mouse(.leftMouseDragged, CGPoint(x: grab.x, y: grab.y + 10))
        usleep(40_000)
        mouse(.leftMouseUp, CGPoint(x: grab.x, y: grab.y + 10))
        // Polled, not slept. The drop commits in a few milliseconds and the
        // caller re-reads membership immediately afterwards, so a flat 150 ms
        // was 150 ms added to every move to cover the slowest case. Give up at
        // the same deadline, because a drop that has not registered by then is
        // a failure the caller should see rather than wait longer for.
        let deadline = Date().addingTimeInterval(0.15)
        repeat {
            if SpaceControl.spacesForWindow(wid).contains(target) { break }
            usleep(5_000)
        } while Date() < deadline
        return landed
    }

    private static func mouse(_ type: CGEventType, _ at: CGPoint) {
        guard let e = CGEvent(
            mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)
        else { return }
        // No modifiers, whatever the user is still holding.
        //
        // A carry is started from a keybind, and the keybinds people give it
        // are modifier-heavy by nature — `alt-shift-1`. `CGEvent(mouseEventSource:
        // nil, …)` stamps the new event with the modifiers that are physically
        // down at that moment, so the press that is supposed to be "grab this
        // title bar" arrived as an alt-shift-click on it. What a person does to
        // drag a window is press with nothing held, and that is what this has
        // to be: an application is entitled to treat a modified click on its
        // chrome as something else entirely, and weft's own event tap treats
        // one carrying `mouse-modifier` as a window drag it should claim.
        e.flags = []
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
