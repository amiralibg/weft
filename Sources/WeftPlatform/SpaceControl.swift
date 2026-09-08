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

    // MARK: - Space Focus (Instant via SA or degraded via ctrl+N)

    /// Instantly switch focus to space `sid` without animation (via SA).
    ///
    /// Returns true **only if the WindowServer actually reports `sid` as
    /// current afterwards**. The scripting addition acknowledges a write
    /// whether or not it acted on it — and an unrelated `yabai-sa` socket
    /// answers on the same path — so trusting the send is how "alt-3 does
    /// nothing but weft thinks it switched" happened: the daemon retiled a
    /// space that was never brought to the front. Verify, then report.
    @discardableResult
    public static func focusSpace(_ sid: SpaceID) -> Bool {
        guard ScriptingAddition.focusSpace(sid) else { return false }
        return waitForCurrentSpace(sid)
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

    // MARK: - Mutations (verified; false = needs weft-sa)

    /// Move a window to another space WITHOUT following it (S3 semantics).
    /// Verified by re-reading membership. False leaves nothing changed.
    @discardableResult
    public static func moveWindowToSpace(_ wid: WindowID, _ sid: SpaceID) -> Bool {
        if ScriptingAddition.moveWindowToSpace(wid, sid) {
            usleep(60_000)
            if spacesForWindow(wid).contains(sid) {
                return true
            }
        }
        let arr = [NSNumber(value: wid)] as CFArray
        SLSMoveWindowsToManagedSpace(SLSMainConnectionID(), arr, sid)
        usleep(150_000)
        return spacesForWindow(wid).contains(sid)
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

    /// Focus a space by its 1-based Mission Control number via ctrl+N.
    /// Costs the ~250ms system animation (the SA path in M4-SA makes it
    /// instant). Returns false for out-of-range numbers. NOTE: requires
    /// Settings → Keyboard → Shortcuts → Mission Control → "Switch to
    /// Desktop N" enabled — undetectable from here, so callers must say so
    /// when nothing happens.
    @discardableResult
    public static func focusSpaceNumber(_ n: Int) -> Bool {
        // Hardware keycodes for 1..9 (ANSI positions, layout-independent).
        let keycodes: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        guard (1...9).contains(n) else { return false }
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

    /// Not an SA gap: the symbol the compat-id sequence needs is gone from
    /// SkyLight on macOS 26, so no connection of any privilege can do it.
    static let spaceToDisplayNote =
        "SkyLight no longer exports SLSSetDisplaySpaceCompatID (macOS 26.5.2, "
        + "dyld_info -exports) — the compat-id pair `space --display` needs is "
        + "half missing, and weft-sa would not change that. Move the windows instead."

    public static var current: PlatformCapability {
        if ScriptingAddition.isAvailable() {
            return PlatformCapability(
                moveWindowToSpace: true,
                moveWindowToSpaceNote: "enabled via scripting addition (instant, non-activating)",
                sticky: true,
                stickyNote: "enabled via scripting addition",
                orderWindow: true,
                orderWindowNote: "enabled via scripting addition",
                focusSpaceKeystroke: true,
                focusSpaceKeystrokeNote: "instant space switching via scripting addition (animation bypassed)",
                moveSpaceToDisplay: false,
                moveSpaceToDisplayNote: Self.spaceToDisplayNote
            )
        }
        return PlatformCapability(
            moveWindowToSpace: false,
            moveWindowToSpaceNote: "SLSMoveWindowsToManagedSpace silently ignored (2026-09-04 probe) — needs weft-sa",
            sticky: false,
            stickyNote: "SLSSetWindowTags sticky bit silently ignored (2026-09-04 probe) — needs weft-sa",
            orderWindow: false,
            orderWindowNote: "SLSOrderWindow rc=1000 from regular connection (M3 probe) — needs weft-sa",
            focusSpaceKeystroke: true,
            focusSpaceKeystrokeNote: "degraded: ctrl+N keystroke, ~250ms animation; needs Mission Control shortcuts enabled",
            moveSpaceToDisplay: false,
            moveSpaceToDisplayNote: Self.spaceToDisplayNote
        )
    }
}
