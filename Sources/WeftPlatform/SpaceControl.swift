import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

/// M4: privileged window/space operations from a REGULAR connection.
///
/// Probe results (2026-09-04, macOS 26.5.2 — see M4 notes):
/// - SLSMoveWindowsToManagedSpace: silently ignored (spacesFor unchanged).
/// - SLSSetWindowTags sticky bit: silently ignored (rc=0, no effect).
/// - SLSOrderWindow: rc=1000 (see AXApply).
/// All three need a Dock-injected connection (weft-sa, M4-SA slice). Every
/// mutating call below therefore VERIFIES via re-read and returns Bool —
/// callers only change state on verified success, and report
/// "needs weft-sa" otherwise. No silent no-ops, ever.
public enum SpaceControl {
    // MARK: - Reads (unprivileged, always work)

    public static func spacesForWindow(_ wid: WindowID) -> [SpaceID] {
        let cid = WorldReader.cid
        let arr = [NSNumber(value: wid)] as CFArray
        guard let result = SLSCopySpacesForWindows(cid, 0x7, arr) as? [NSNumber] else {
            return []
        }
        return result.map { $0.uint64Value }
    }

    /// Per-display geometry, west→east. One place matches AppKit's screens to
    /// the UUIDs SLS reports, because it is the only fiddly part: `visible`
    /// comes from `NSScreen.visibleFrame` (menu bar + Dock already excluded)
    /// but in AppKit's bottom-left space, and only the *primary* screen sits
    /// at AppKit's origin — so the flip to the top-left space AX and SLS share
    /// must go through the primary's height, never each screen's own.
    ///
    /// Active, not online: a mirrored secondary would otherwise contribute a
    /// duplicate rect for the same pixels.
    public struct DisplayFrames: Sendable, Equatable {
        /// Matches `SLSCopyManagedDisplaySpaces`'s "Display Identifier".
        public var uuid: String
        /// Full CG bounds, top-left origin. Used for off-screen park targets.
        public var frame: Frame
        /// Menu bar and Dock excluded. This is what layouts tile into.
        public var visible: Frame

        public init(uuid: String, frame: Frame, visible: Frame) {
            self.uuid = uuid
            self.frame = frame
            self.visible = visible
        }
    }

    public static func displayLayout() -> [DisplayFrames] {
        var active = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &active, &count) == .success else { return [] }
        let screens = NSScreen.screens
        let primaryHeight = screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? screens.first?.frame.height
            ?? 0
        var visibleByID: [CGDirectDisplayID: Frame] = [:]
        for screen in screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }
            let vf = screen.visibleFrame
            guard vf.width > 100, vf.height > 100 else { continue }
            visibleByID[CGDirectDisplayID(number.uint32Value)] = Frame(
                x: vf.minX,
                y: primaryHeight - vf.maxY,
                width: vf.width,
                height: vf.height
            )
        }
        var out: [DisplayFrames] = []
        for i in 0..<Int(count) {
            let id = active[i]
            guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(id) else { continue }
            let uuid = unmanaged.takeRetainedValue()
            guard let str = CFUUIDCreateString(nil, uuid) as String? else { continue }
            let b = CGDisplayBounds(id)
            let full = Frame(x: b.minX, y: b.minY, width: b.width, height: b.height)
            out.append(DisplayFrames(uuid: str, frame: full, visible: visibleByID[id] ?? full))
        }
        // (x, then y): a stable arrangement order even when two displays
        // share an x, which vertically stacked monitors do.
        return out.sorted {
            $0.frame.x == $1.frame.x ? $0.frame.y < $1.frame.y : $0.frame.x < $1.frame.x
        }
    }

    /// UUID of the display holding the active menu bar — the display keyboard
    /// focus is on, and therefore the one whose current space every command
    /// means by "the current space".
    ///
    /// SLS answers "Main" instead of a UUID on some releases, and the string
    /// is unusable as a key then; both that case and an unknown UUID fall back
    /// to the main display, which is what a single-display machine wants
    /// anyway. `known` is the UUID set to validate against (pass the display
    /// layout's) — nil skips validation.
    public static func activeDisplayUUID(known: Set<String>? = nil) -> String? {
        let uuid = SLSCopyActiveMenuBarDisplayIdentifier(WorldReader.cid) as String?
        if let uuid, known.map({ $0.contains(uuid) }) ?? true { return uuid }
        return mainDisplayUUID()
    }

    /// UUID of CGMainDisplayID — the display with the menu bar at rest.
    public static func mainDisplayUUID() -> String? {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID()) else { return nil }
        return CFUUIDCreateString(nil, unmanaged.takeRetainedValue()) as String?
    }

    // MARK: - Space Focus (weft-sa, else weft's own Dock swipe, else ctrl+N)

    /// Switch to space `sid`, instantly wherever this Mac allows it.
    ///
    /// weft-sa first when it is loaded and its Dock hooks resolved; otherwise
    /// weft's own synthetic Dock swipe, which needs neither SIP off nor an
    /// addition. The ⌃N keystroke is the caller's last resort, not this one's.
    ///
    /// Returns true **only if the WindowServer actually reports `sid` as
    /// current afterwards**. An addition acknowledges a write whether or not
    /// it acted on it, and a swipe Dock refused looks exactly like one it
    /// took, so trusting either is how "alt-3 does nothing but weft thinks it
    /// switched" happened: the daemon retiled a space that was never brought
    /// to the front. Verify, then report.
    @discardableResult
    public static func focusSpace(_ sid: SpaceID) -> Bool {
        if ScriptingAddition.focusSpace(sid), waitForCurrentSpace(sid) { return true }
        return DockSwipe.focusSpace(sid)
    }

    /// True once any display reports `sid` as its current space. The Dock
    /// transition is fast but not synchronous with the socket reply, so poll
    /// briefly rather than sleeping a fixed amount: the common case returns on
    /// the first or second read (~2 ms), and a real failure costs 120 ms once
    /// before we fall back to the keystroke path.
    public static func waitForCurrentSpace(_ sid: SpaceID, timeout: TimeInterval = 0.12) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if WorldReader.currentSpaces().values.contains(sid) { return true }
            usleep(2_000)
        } while Date() < deadline
        return false
    }

    // MARK: - Mutations (verified by re-reading; false means nothing changed)

    /// Move a window to another space WITHOUT following it (S3 semantics).
    /// Verified by re-reading membership. False leaves nothing changed.
    /// - Parameter allowDrag: whether to fall back to the drag route, which
    ///   takes the screen over for a moment. True for anything the user just
    ///   asked for; false for anything weft decided on its own — a rule firing
    ///   because an app opened must not switch the desktop out from under
    ///   someone who is typing. See `[general] follow-space-rules`.
    @discardableResult
    public static func moveWindowToSpace(
        _ wid: WindowID, _ sid: SpaceID, allowDrag: Bool = true
    ) -> Bool {
        if ScriptingAddition.moveWindowToSpace(wid, sid) {
            usleep(60_000)
            if spacesForWindow(wid).contains(sid) {
                return true
            }
        }
        let arr = [NSNumber(value: wid)] as CFArray
        SLSMoveWindowsToManagedSpace(SLSMainConnectionID(), arr, sid)
        usleep(150_000)
        if spacesForWindow(wid).contains(sid) { return true }
        // Last, because it is the one that works and the one the user sees.
        //
        // Nothing above moves a window from an ordinary connection on macOS 27:
        // sixteen SkyLight routes were tried and refused, three of them by
        // returning kCGErrorSuccess and doing nothing (spikes/RESULTS.md §S8).
        // What remains is the gesture a person uses — hold the window, press
        // the bound "move a space" shortcut, let go — which costs two visible
        // desktop changes and needs no scripting addition and no SIP change.
        guard allowDrag else { return false }
        return DragMove.moveWindow(wid, to: sid)
    }

    /// Sticky bit (1 << 11): window appears on every space. Verified by
    /// membership count. False leaves nothing changed.
    @discardableResult
    public static func setSticky(_ wid: WindowID, _ on: Bool) -> Bool {
        if ScriptingAddition.setSticky(wid, on) {
            usleep(60_000)
            let count = spacesForWindow(wid).count
            if on ? count > 1 : count <= 1 {
                return true
            }
        }
        let cid = SLSMainConnectionID()
        var tags: UInt64 = 1 << 11
        if on {
            _ = SLSSetWindowTags(cid, wid, &tags, 64)
        } else {
            _ = SLSClearWindowTags(cid, wid, &tags, 64)
        }
        usleep(150_000)
        let count = spacesForWindow(wid).count
        return on ? count > 1 : count <= 1
    }

    /// Move a whole space to another display (yabai's `space --display`).
    ///
    /// Always false on macOS 26, and the reason is a missing symbol rather
    /// than a silent WindowServer no-op: the compat-id pair this needs lost
    /// `SLSSetDisplaySpaceCompatID` (see SkyLightShim.h). Kept as a real
    /// function so the verb has one honest answer and starts working the day
    /// a replacement is found, instead of pretending in the command layer.
    @discardableResult
    public static func moveSpaceToDisplay(_ sid: SpaceID, _ displayUUID: String) -> Bool {
        displayOfSpace(sid) == displayUUID
    }

    /// Display UUID owning `sid`, straight from the WindowServer.
    public static func displayOfSpace(_ sid: SpaceID) -> String? {
        SLSCopyManagedDisplayForSpace(WorldReader.cid, sid) as String?
    }

    // MARK: - Degraded space focus (unprivileged, always "works")

    /// Whether macOS will act on the ⌃N the keystroke fallback posts.
    ///
    /// "Switch to Desktop N" ships **off** on macOS, and without it — and
    /// without the scripting addition — `space focus` cannot move the user
    /// anywhere at all: the keystroke goes out and nothing receives it. That
    /// was worth knowing up front rather than one failed keybind at a time,
    /// because the failure is otherwise completely silent.
    ///
    /// Symbolic hot key ids 118…126 are Switch to Desktop 1…9. An id absent
    /// from the dictionary is one macOS has never been asked about, which
    /// means the shipped default: off.
    public static func missionControlSwitchShortcuts() -> Set<Int> {
        guard let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys")
        else { return [] }
        var on: Set<Int> = []
        for n in 118...126 {
            guard let entry = hotkeys["\(n)"] as? [String: Any],
                  let enabled = entry["enabled"] as? Bool, enabled
            else { continue }
            on.insert(n - 117)
        }
        return on
    }

    /// True when `space focus` has *some* way to switch desktops: weft-sa,
    /// weft's Dock swipe, or at least one Mission Control shortcut.
    public static func canFocusSpaces() -> Bool {
        ScriptingAddition.supportsSpaceFocus() || DockSwipe.isSupported
            || !missionControlSwitchShortcuts().isEmpty
    }

    /// Focus a space by its 1-based Mission Control number via ctrl+N.
    /// Costs the ~250ms system animation (the SA path makes it instant).
    /// Returns false for out-of-range numbers.
    ///
    /// Whether the keystroke reaches anything is a separate question, and one
    /// `missionControlSwitchShortcuts()` can now answer up front — posting a
    /// key nothing is bound to looks identical to success from here.
    @discardableResult
    public static func focusSpaceNumber(_ n: Int) -> Bool {
        // Hardware keycodes for 1..9 (ANSI positions, layout-independent).
        let keycodes: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        guard (1...9).contains(n) else { return false }
        // Posting keys without Accessibility is refused, and the refusal is a
        // system dialog. Nothing a keypress can do is worth one of those.
        guard AXIsProcessTrusted() else { return false }
        let keycode = CGKeyCode(keycodes[n - 1])
        let flags = CGEventFlags.maskControl
        // Tag both events with the "WEFT" marker the input tap checks for.
        // Without it our own synthetic ctrl+N re-enters our tap and, if the
        // user has bound anything on ctrl+digit, fires it recursively.
        let marker: Int64 = 0x57454654
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: true) {
            down.flags = flags
            down.setIntegerValueField(.eventSourceUserData, value: marker)
            down.post(tap: CGEventTapLocation.cgSessionEventTap)
        }
        usleep(20_000)
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: false) {
            up.flags = flags
            up.setIntegerValueField(.eventSourceUserData, value: marker)
            up.post(tap: CGEventTapLocation.cgSessionEventTap)
        }
        return true
    }
}

/// Capability record: what this connection can actually do, from probe
/// evidence — not from documentation. Served by `query capability` so the
/// M4-SA slice knows exactly what to unlock.
public struct PlatformCapability: Codable, Sendable {
    public var moveWindowToSpace: Bool
    public var moveWindowToSpaceNote: String
    public var sticky: Bool
    public var stickyNote: String
    public var orderWindow: Bool
    public var orderWindowNote: String
    public var focusSpaceKeystroke: Bool
    public var focusSpaceKeystrokeNote: String
    public var moveSpaceToDisplay: Bool
    public var moveSpaceToDisplayNote: String

    /// What the ⌃N fallback can actually reach right now. Reported rather
    /// than assumed: the shortcuts it needs are off on a stock macOS, and a
    /// note that says "needs them enabled" reads the same whether they are or
    /// not.
    static func keystrokeNote() -> String {
        let on = SpaceControl.missionControlSwitchShortcuts().sorted()
        guard !on.isEmpty else {
            return "unavailable: this macOS release does not take weft's Dock swipe (26.6 or later "
                + "does), weft-sa is not loaded, and System Settings → Keyboard → Shortcuts → "
                + "Mission Control → 'Switch to Desktop N' is off, so the ⌃N fallback reaches nothing."
        }
        let covered = on.map(String.init).joined(separator: ", ")
        return "degraded: ⌃N keystroke, ~250ms animation; desktops \(covered) only "
            + "(the rest need 'Switch to Desktop N' enabled)"
    }

    /// How `space focus` switches on this Mac, best first.
    static var focus: (available: Bool, note: String) {
        if ScriptingAddition.supportsSpaceFocus() {
            return (true, "instant, via weft-sa")
        }
        if DockSwipe.isSupported {
            return (true, "instant, via weft's Dock swipe (no scripting addition, SIP on)")
        }
        return (!SpaceControl.missionControlSwitchShortcuts().isEmpty, keystrokeNote())
    }

    /// Not an SA gap: the symbol the compat-id sequence needs is gone from
    /// SkyLight on macOS 26, so no connection of any privilege can do it.
    static let spaceToDisplayNote =
        "SkyLight no longer exports SLSSetDisplaySpaceCompatID (macOS 26.5.2, "
        + "dyld_info -exports) — the compat-id pair `space --display` needs is "
        + "half missing, and weft-sa would not change that. Move the windows instead."

    public static var current: PlatformCapability {
        let focus = Self.focus
        if ScriptingAddition.isAvailable() {
            return PlatformCapability(
                moveWindowToSpace: true,
                moveWindowToSpaceNote: "enabled via weft-sa (instant, non-activating)",
                sticky: true,
                stickyNote: "enabled via weft-sa",
                orderWindow: true,
                orderWindowNote: "enabled via weft-sa",
                focusSpaceKeystroke: focus.available,
                focusSpaceKeystrokeNote: focus.note,
                moveSpaceToDisplay: false,
                moveSpaceToDisplayNote: Self.spaceToDisplayNote
            )
        }
        // Read once: it parses a preferences dictionary, and it is asked about
        // twice below.
        let drag = DragMove.isSupported
        return PlatformCapability(
            moveWindowToSpace: drag,
            moveWindowToSpaceNote: drag
                ? "enabled with SIP on: weft holds the window and presses the bound 'move a space' "
                    + "shortcut, so the desktop visibly changes and changes back"
                : "SLSMoveWindowsToManagedSpace is silently ignored from an ordinary connection, and "
                    + "no 'Move left/right a space' shortcut is bound to carry a held window instead "
                    + "(System Settings → Keyboard → Keyboard Shortcuts → Mission Control)",
            sticky: false,
            stickyNote: "SLSSetWindowTags' sticky bit is accepted and dropped (rc=0, tag never set — "
                + "2026-09-15 probe). Dock's per-application 'All Desktops' is reachable through "
                + "Accessibility and is the likely route, but it is not verified, so weft does not "
                + "claim it",
            orderWindow: false,
            orderWindowNote: "SLSOrderWindow rc=1000 from regular connection (M3 probe)",
            focusSpaceKeystroke: focus.available,
            focusSpaceKeystrokeNote: focus.note,
            moveSpaceToDisplay: false,
            moveSpaceToDisplayNote: Self.spaceToDisplayNote
        )
    }
}

extension SpaceControl {
    /// How many ordinary desktops exist right now, across every display.
    ///
    /// Fullscreen and tiled spaces (type != 0) are not desktops: nothing can be
    /// labelled onto them and no rule can send a window there. Used by
    /// `weftctl migrate`, which has no daemon to ask, to avoid writing space
    /// labels for desktops the user does not have — a label with no desktop
    /// behind it resolves to nothing and every rule and keybind naming it fails
    /// silently, which is the worst way for a generated config to be wrong.
    public static func desktopCount() -> Int {
        let cid = SLSMainConnectionID()
        guard let raw = SLSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return 0 }
        var total = 0
        for displayDict in raw {
            for spaceDict in displayDict["Spaces"] as? [[String: Any]] ?? [] {
                let rawID: UInt64
                if let n = spaceDict["id64"] as? NSNumber {
                    rawID = n.uint64Value
                } else if let i = spaceDict["id"] as? NSNumber {
                    rawID = i.uint64Value
                } else {
                    continue
                }
                if SLSSpaceGetType(cid, rawID) == 0 { total += 1 }
            }
        }
        return total
    }
}

extension SpaceControl {
    /// Which space is showing on each display, right now, straight from the
    /// WindowServer. Keyed by the display UUID `SLSCopyManagedDisplaySpaces`
    /// uses, so it lines up with `SpaceState.currentByDisplay`.
    ///
    /// Deliberately the cheapest question that detects a space change: no
    /// window list, no AX, no layout. Measured at ~40 µs on a two-display
    /// setup, which is what makes it affordable to ask on a timer.
    public static func currentSpaceByDisplay() -> [String: SpaceID] {
        let cid = SLSMainConnectionID()
        guard let raw = SLSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [:] }
        var out: [String: SpaceID] = [:]
        for displayDict in raw {
            guard let uuid = displayDict["Display Identifier"] as? String else { continue }
            out[uuid] = SpaceID(SLSManagedDisplayGetCurrentSpace(cid, uuid as CFString))
        }
        return out
    }
}
