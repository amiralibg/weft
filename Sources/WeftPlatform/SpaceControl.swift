import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

/// What the WindowServer says about displays and desktops. Reads only.
///
/// weft does not change desktops and does not move windows between them: the
/// WindowServer refuses every route from an ordinary connection (S8), and the
/// routes that remain — holding a title bar and pressing the user's space
/// shortcut, or a synthetic Dock gesture — were removed for breaking on macOS
/// updates (REDESIGN.md). Workspaces live on one managed desktop per display
/// instead, and everything that changes what is on screen is a park, an
/// unpark or a frame write.
public enum SpaceControl {

    public static func spacesForWindow(_ wid: WindowID) -> [SpaceID] {
        let cid = WorldReader.cid
        let arr = [NSNumber(value: wid)] as CFArray
        guard let result = SLSCopySpacesForWindows(cid, 0x7, arr) as? [NSNumber] else {
            guard PublicPaths.isMissing("SLSCopySpacesForWindows"),
                  let frame = WorldReader.frame(of: wid),
                  let display = PublicPaths.display(of: frame, among: displayLayout())
            else { return [] }
            return [PublicPaths.syntheticDesktop(for: display)]
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

    /// Each active display's uuid, its name as System Settings shows it, and
    /// whether it is the main one — west to east, the order `displayLayout`
    /// uses. What `[[space]] display = …` is matched against.
    public static func displayIdentities() -> [DisplayIdentity] {
        let main = mainDisplayUUID()
        var names: [String: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let unmanaged = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value)),
                  let uuid = CFUUIDCreateString(nil, unmanaged.takeRetainedValue()) as String?
            else { continue }
            names[uuid] = screen.localizedName
        }
        return displayLayout().map {
            DisplayIdentity(uuid: $0.uuid, name: names[$0.uuid] ?? "", isMain: $0.uuid == main)
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

    /// Display UUID owning `sid`, straight from the WindowServer.
    public static func displayOfSpace(_ sid: SpaceID) -> String? {
        SLSCopyManagedDisplayForSpace(WorldReader.cid, sid) as String?
    }

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
    /// setup.
    public static func currentSpaceByDisplay() -> [String: SpaceID] {
        let cid = SLSMainConnectionID()
        guard let raw = SLSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else {
            let (displays, _) = PublicPaths.isMissing("SLSCopyManagedDisplaySpaces")
                ? WorldReader.syntheticTopology() : ([], [])
            return Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, $0.currentSpace) })
        }
        var out: [String: SpaceID] = [:]
        for displayDict in raw {
            guard let uuid = displayDict["Display Identifier"] as? String else { continue }
            var current = SpaceID(SLSManagedDisplayGetCurrentSpace(cid, uuid as CFString))
            // No answer (the call is gone): the first desktop, as WorldReader
            // decides it. Zero would read as "paused" on every display.
            if current == 0 {
                let first = (displayDict["Spaces"] as? [[String: Any]])?.first
                current = (first?["id64"] as? NSNumber)?.uint64Value ?? 0
            }
            out[uuid] = current
        }
        return out
    }
}
