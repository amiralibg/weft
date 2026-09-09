import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

/// M1: read-only snapshot of the WindowServer world. Mutates nothing.
///
/// Discovery is WindowServer-first (S0): `CGWindowListCopyWindowInfo` sees
/// every space, AX only tells us whether a window is currently *bound*
/// (reachable). Frames come from `SLSGetWindowBounds`, never AX (§5.1).
///
/// **Nothing here may perform AX IPC on a hot path.** `snapshot()` runs on the
/// core queue via observer events; an AX round-trip per app (0.15 s timeout
/// each) stalled every keybind behind it. `bound` is therefore opt-in
/// (`snapshot(includeAXBinding: true)`, used only by `weftctl query windows`)
/// and defaults to `false`, which no layout decision reads.
public enum WorldReader {
    /// The main connection id never changes for the life of the process, and
    /// `SLSMainConnectionID()` was previously called once per window frame read.
    static let cid: SLConnectionID = SLSMainConnectionID()

    public static func snapshot(includeAXBinding: Bool = false) -> World {
        let (displays, baseSpaces) = readDisplaysAndSpaces(cid: cid)
        // Fullscreen / system spaces are skipped entirely (§11 risk 6). Leaving
        // them in shifted every ordinal, so `space focus 6` landed on the wrong
        // desktop as soon as anything was full-screened.
        let usableSpaces = baseSpaces.filter { !$0.isFullscreen }
        let usableSids = Set(usableSpaces.map { $0.id })
        let windows = readWindows(cid: cid, includeAXBinding: includeAXBinding)
            .map { w -> WindowInfo in
                var copy = w
                copy.spaces = w.spaces.filter { usableSids.contains($0) }
                return copy
            }
            .filter { !$0.spaces.isEmpty }
        // SLSCopyManagedDisplaySpaces space dicts carry no window list
        // (keys are ManagedSpaceID/id64/type/uuid). Invert window→spaces.
        var bySpace: [SpaceID: [WindowID]] = [:]
        for w in windows {
            for sid in w.spaces { bySpace[sid, default: []].append(w.id) }
        }
        let spaces = usableSpaces.map { s in
            var copy = s
            copy.windows = (bySpace[s.id] ?? []).sorted()
            return copy
        }
        let usableDisplays = displays.map { d -> Display in
            var copy = d
            copy.spaces = d.spaces.filter { usableSids.contains($0) }
            return copy
        }
        return World(displays: usableDisplays, spaces: spaces, windows: windows)
    }

    // MARK: - Displays + spaces

    static func readDisplaysAndSpaces(cid: SLConnectionID) -> ([Display], [Space]) {
        guard let raw = SLSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else {
            return ([], [])
        }
        var displays: [Display] = []
        var spaces: [Space] = []

        for displayDict in raw {
            guard let uuid = displayDict["Display Identifier"] as? String else { continue }
            let current = SLSpaceID(SLSManagedDisplayGetCurrentSpace(cid, uuid as CFString))
            var spaceIDs: [SpaceID] = []

            let spaceDicts = displayDict["Spaces"] as? [[String: Any]] ?? []
            for spaceDict in spaceDicts {
                let rawID: UInt64
                if let n = spaceDict["id64"] as? NSNumber {
                    rawID = n.uint64Value
                } else if let i = spaceDict["id"] as? NSNumber {
                    rawID = i.uint64Value
                } else {
                    continue
                }
                spaceIDs.append(rawID)
                let type = SLSSpaceGetType(cid, rawID)
                // No per-space window list in this dict (verified on 26.5.2);
                // filled by inversion in snapshot(). Keep empty here.
                let windowIDs: [WindowID] = []
                spaces.append(Space(
                    id: rawID,
                    type: type,
                    displayUUID: uuid,
                    isCurrent: rawID == current,
                    windows: windowIDs
                ))
            }

            displays.append(Display(uuid: uuid, spaces: spaceIDs, currentSpace: current))
        }
        return (displays, spaces)
    }

    /// Displays + their spaces without enumerating a single window. The space
    /// verbs only need topology, and paying for a full window sweep on the
    /// `space focus` critical path is latency for nothing.
    public static func displaysOnly() -> [Display] {
        let (displays, spaces) = readDisplaysAndSpaces(cid: cid)
        let usable = Set(spaces.filter { !$0.isFullscreen }.map { $0.id })
        return displays.map { d in
            var copy = d
            copy.spaces = d.spaces.filter(usable.contains)
            return copy
        }
    }

    /// Current space per display, without building a whole world. Used by the
    /// space-focus verification loop, which must not pay for a window sweep.
    public static func currentSpaces() -> [String: SpaceID] {
        guard let raw = SLSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [:] }
        var out: [String: SpaceID] = [:]
        for displayDict in raw {
            guard let uuid = displayDict["Display Identifier"] as? String else { continue }
            out[uuid] = SLSpaceID(SLSManagedDisplayGetCurrentSpace(cid, uuid as CFString))
        }
        return out
    }

    // MARK: - Windows

    struct Candidate {
        let wid: WindowID
        let app: String
        let title: String
        let pid: Int32
    }

    static func readWindows(cid: SLConnectionID, includeAXBinding: Bool = false) -> [WindowInfo] {
        guard let info = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        // Same filter that reduced 55 raw entries to 8 real windows (S0):
        // layer == 0, both dims > 100, skip borders overlays.
        var candidates: [Candidate] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
            let boundsDict = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            guard (boundsDict["Width"] as? Double ?? 0) > 100,
                  (boundsDict["Height"] as? Double ?? 0) > 100
            else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
            guard owner != "borders" && owner != "WeftBar" && owner != "weft-bar" else { continue }
            let wid = WindowID(w[kCGWindowNumber as String] as? Int ?? 0)
            guard wid != 0 else { continue }
            let pid = Int32(w[kCGWindowOwnerPID as String] as? Int ?? 0)
            // Menu-bar extras. A Stats or Ice panel is layer 0 and larger than
            // 100×100, so the geometry filter waves it straight through and
            // weft tiles it: it takes a slot in the layout, and because weft
            // then focuses and raises it, the click-outside that would
            // normally dismiss it never reaches it — the panel can only be
            // closed by clicking its menu bar icon again.
            //
            // Every one of these belongs to an agent app: LSUIElement, no Dock
            // icon, `.accessory` activation policy. That is the whole test,
            // and it costs a cached lookup rather than the AX subrole round
            // trip this path is not allowed to make.
            guard manageMenubarApps || isManageableOwner(pid: pid) else { continue }
            candidates.append(Candidate(
                wid: wid,
                app: owner,
                title: w[kCGWindowName as String] as? String ?? "",
                pid: pid
            ))
        }

        // AX reachability is diagnostic only and costs one cross-process round
        // trip per app, so it is computed solely for `query windows`.
        let boundWids: Set<WindowID> = includeAXBinding
            ? axBoundWindowIDs(pids: Set(candidates.map { $0.pid }))
            : []

        var out: [WindowInfo] = []
        for c in candidates {
            let spaceIDs = spacesForWindow(cid: cid, wid: c.wid)
            guard !spaceIDs.isEmpty else { continue }
            guard let frame = windowBounds(cid: cid, wid: c.wid) else { continue }
            out.append(WindowInfo(
                id: c.wid,
                app: c.app,
                title: c.title,
                pid: c.pid,
                spaces: spaceIDs,
                frame: Frame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
                bound: boundWids.contains(c.wid)
            ))
        }
        return out.sorted { $0.id < $1.id }
    }

    /// Owners whose windows weft manages: apps with a Dock icon.
    ///
    /// Cached per pid because this runs for every window on every snapshot and
    /// an app's activation policy does not change under us; the cache is
    /// bounded by dropping pids that are no longer running.
    private static let ownerPolicyLock = NSLock()
    private nonisolated(unsafe) static var ownerIsRegular: [Int32: Bool] = [:]

    /// Set from config. Opt-in, for the rare agent app with a real window.
    private nonisolated(unsafe) static var _manageMenubarApps = false
    public static var manageMenubarApps: Bool {
        get { ownerPolicyLock.withLock { _manageMenubarApps } }
        set { ownerPolicyLock.withLock { _manageMenubarApps = newValue } }
    }

    static func isManageableOwner(pid: Int32) -> Bool {
        if let known = ownerPolicyLock.withLock({ ownerIsRegular[pid] }) { return known }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        let regular = app.activationPolicy == .regular
        ownerPolicyLock.withLock {
            if ownerIsRegular.count > 512 { ownerIsRegular.removeAll() }
            ownerIsRegular[pid] = regular
        }
        return regular
    }

    /// Drop a terminated app's cached verdict, so a pid reused by a different
    /// app is classified afresh.
    public static func forgetOwner(pid: Int32) {
        ownerPolicyLock.withLock { _ = ownerIsRegular.removeValue(forKey: pid) }
    }

    static func spacesForWindow(cid: SLConnectionID, wid: WindowID) -> [SpaceID] {
        let arr = [NSNumber(value: wid)] as CFArray
        guard let result = SLSCopySpacesForWindows(cid, 0x7, arr) as? [NSNumber] else {
            return []
        }
        return result.map { $0.uint64Value }
    }

    static func windowBounds(cid: SLConnectionID, wid: WindowID) -> CGRect? {
        var rect = CGRect.zero
        return SLSGetWindowBounds(cid, wid, &rect) == 0 ? rect : nil
    }

    /// Single-window SLS frame read for echo-suppression checks (µs, no app IPC).
    public static func frame(of wid: WindowID) -> Frame? {
        guard let r = windowBounds(cid: cid, wid: wid) else { return nil }
        return Frame(x: r.minX, y: r.minY, width: r.width, height: r.height)
    }

    /// Per-pid AX enumeration. Read-only: never sets anything, 0.15s timeout
    /// per app so a wedged app can't stall the snapshot (§5.2).
    ///
    /// Diagnostic path only — see the type comment. Do not call from the core
    /// queue or from any code an observer event can reach.
    static func axBoundWindowIDs(pids: Set<Int32>) -> Set<WindowID> {
        var out = Set<WindowID>()
        for pid in pids {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 0.15)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                appEl, kAXWindowsAttribute as CFString, &value
            ) == .success, let elements = value as? [AXUIElement] {
                for el in elements {
                    var wid: UInt32 = 0
                    if _AXUIElementGetWindow(el, &wid) == .success, wid != 0 {
                        out.insert(wid)
                    }
                }
            }
            for attr in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
                var singleVal: CFTypeRef?
                if AXUIElementCopyAttributeValue(appEl, attr as CFString, &singleVal) == .success,
                   let el = singleVal as! AXUIElement? {
                    var wid: UInt32 = 0
                    if _AXUIElementGetWindow(el, &wid) == .success, wid != 0 {
                        out.insert(wid)
                    }
                }
            }
        }
        return out
    }
}
