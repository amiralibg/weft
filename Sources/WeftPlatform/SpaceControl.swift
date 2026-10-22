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
    /// the UUIDs SLS reports, because it is the only fiddly part: every
    /// position comes from CoreGraphics, which is live, and AppKit gives only
    /// the Dock and menu bar insets (`usableArea`). Origins read from
    /// `NSScreen` went stale in weftd when a display was plugged or unplugged,
    /// and only a restart fixed them.
    /// `visibleFrame` takes the menu bar off the main display only, in a
    /// process without an `NSApplication` — which weftd is. `tilingAreas`
    /// takes every other display's off too.
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
        // AppKit's frames, kept in its own bottom-left space: `usableArea`
        // takes only the insets from them, and places them on CG's bounds.
        var appKitByID: [CGDirectDisplayID: (frame: Frame, visible: Frame)] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }
            let f = screen.frame, vf = screen.visibleFrame
            appKitByID[CGDirectDisplayID(number.uint32Value)] = (
                Frame(x: f.minX, y: f.minY, width: f.width, height: f.height),
                Frame(x: vf.minX, y: vf.minY, width: vf.width, height: vf.height)
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
            let appKit = appKitByID[id]
            out.append(DisplayFrames(
                uuid: str, frame: full,
                visible: usableArea(bounds: full, screenFrame: appKit?.frame, screenVisible: appKit?.visible)
            ))
        }
        // (x, then y): a stable arrangement order even when two displays
        // share an x, which vertically stacked monitors do.
        return out.sorted {
            $0.frame.x == $1.frame.x ? $0.frame.y < $1.frame.y : $0.frame.x < $1.frame.x
        }
    }

    /// What layouts tile into on each display, by uuid: `visible`, less any
    /// menu bar at the top of that display.
    ///
    /// With "Displays have separate Spaces" on, every display has a menu bar,
    /// but `visibleFrame` in a process with no `NSApplication` leaves the
    /// strip in on all but the main one. Tiles at the top of a second display
    /// were aimed under its menu bar, macOS moved them back down, and weft
    /// floated them as windows that refuse to be placed. Creating an
    /// `NSApplication` fixed the frame and made every WindowServer call weftd
    /// made take up to half a second: an app whose events are never read is
    /// one the WindowServer waits on. The menu bars are read from the window
    /// list instead, which is where they are.
    public static func tilingAreas(_ layout: [DisplayFrames]) -> [(String, Frame)] {
        let bars = menuBarFrames()
        return layout.map { ($0.uuid, belowMenuBars($0.visible, display: $0.frame, menuBars: bars)) }
    }

    /// The WindowServer's menu bar windows on screen, top-left origin. One
    /// per display with separate Spaces on; none while the menu bar hides
    /// itself, which is the right answer then too.
    static func menuBarFrames() -> [Frame] {
        let level = Int(CGWindowLevelForKey(.mainMenuWindow))
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return info.compactMap { w -> Frame? in
            guard (w[kCGWindowLayer as String] as? Int) == level,
                  let b = w[kCGWindowBounds as String] as? [String: Double],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  height > 0, height < 100
            else { return nil }
            return Frame(x: x, y: y, width: width, height: height)
        }
    }

    /// Each active display's uuid, its name as System Settings shows it, and
    /// whether it is the main one — west to east, the order `displayLayout`
    /// uses. What `[[space]] display = …` is matched against.
    public static func displayIdentities() -> [DisplayIdentity] {
        let main = mainDisplayUUID()
        var builtIn: Set<String> = []
        var active = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetActiveDisplayList(16, &active, &count) == .success {
            for id in active.prefix(Int(count)) where CGDisplayIsBuiltin(id) != 0 {
                if let u = CGDisplayCreateUUIDFromDisplayID(id),
                   let s = CFUUIDCreateString(nil, u.takeRetainedValue()) as String? { builtIn.insert(s) }
            }
        }
        var names: [String: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let unmanaged = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value)),
                  let uuid = CFUUIDCreateString(nil, unmanaged.takeRetainedValue()) as String?
            else { continue }
            names[uuid] = screen.localizedName
        }
        return displayLayout().map {
            DisplayIdentity(
                uuid: $0.uuid, name: names[$0.uuid] ?? "", isMain: $0.uuid == main, isBuiltIn: builtIn.contains($0.uuid)
            )
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
    /// How many ordinary desktops each display has, by the display uuid
    /// `SLSCopyManagedDisplaySpaces` reports, in its order. Fullscreen apps are
    /// not counted: they come and go with the app and are not the user's to
    /// remove. With "Displays have separate Spaces" off there is one entry,
    /// "Main", for all of them. Empty when the call is unavailable.
    public static func desktopsByDisplay() -> [(uuid: String, count: Int)] {
        let cid = SLSMainConnectionID()
        guard let raw = SLSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }
        return raw.compactMap { displayDict in
            guard let uuid = displayDict["Display Identifier"] as? String else { return nil }
            let count = (displayDict["Spaces"] as? [[String: Any]] ?? []).filter { spaceDict in
                let id = (spaceDict["id64"] as? NSNumber) ?? (spaceDict["id"] as? NSNumber)
                return id.map { SLSSpaceGetType(cid, $0.uint64Value) == 0 } ?? false
            }.count
            return (uuid, count)
        }
    }

    /// One display's spaces as Mission Control draws them: in order, each a
    /// desktop or a fullscreen / Split View space, and the one showing.
    public struct DisplaySpaces: Sendable, Equatable {
        public struct Entry: Sendable, Equatable {
            public var id: SpaceID
            public var fullscreen: Bool
        }
        public var uuid: String
        public var spaces: [Entry]
        public var current: SpaceID
    }

    /// Every display's spaces, in SkyLight's display order. For Settings and
    /// Setup, which draw the desktops whether or not weftd is running. Empty
    /// when the call is unavailable.
    public static func topology() -> [DisplaySpaces] {
        let cid = SLSMainConnectionID()
        guard let raw = SLSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }
        return raw.compactMap { d in
            guard let uuid = d["Display Identifier"] as? String else { return nil }
            let entries = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { space -> DisplaySpaces.Entry? in
                guard let id = ((space["id64"] as? NSNumber) ?? (space["id"] as? NSNumber))?.uint64Value else { return nil }
                return .init(id: id, fullscreen: SLSSpaceGetType(cid, id) != 0)
            }
            return DisplaySpaces(uuid: uuid, spaces: entries, current: SLSManagedDisplayGetCurrentSpace(cid, uuid as CFString))
        }
    }

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
