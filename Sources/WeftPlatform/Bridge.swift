// WeftPlatform/Bridge.swift — moving windows between macOS desktops and
// switching a display's desktop, through SkyLight's bridged operations
// (BridgeShim.h), each call verified by reading the result back.
//
// docs/NATIVE.md, "Moving windows", "Switching" and "Self-tests and
// degradation". The rule this file keeps: no bridged write runs unless its
// self-test passed on this macOS build, and no call is believed until the
// WindowServer reads back what was asked for. Return codes from this family
// have lied every time they were checked (S8, S10, S11).

import ApplicationServices
import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

public enum NativeBridge {
    /// nil when this macOS has every piece the bridge uses; otherwise the
    /// first one missing (or turned off by `WEFT_PUBLIC_ONLY`).
    public static var missingPiece: String? {
        weft_bridge_missing().map { String(cString: $0) }
    }

    /// Each window's desktops, read from the WindowServer. A window that
    /// reads back nothing is absent from the result.
    public static func readSpaces(_ windows: [WindowID]) -> [WindowID: [SpaceID]] {
        let cid = WorldReader.cid
        var out: [WindowID: [SpaceID]] = [:]
        for w in windows {
            guard let r = SLSCopySpacesForWindows(cid, 0x7, [NSNumber(value: w)] as CFArray) as? [NSNumber],
                  !r.isEmpty
            else { continue }
            out[w] = r.map(\.uint64Value).sorted()
        }
        return out
    }

    public struct Moved: Sendable {
        public var verdict: MoveVerdict
        public var milliseconds: Double
    }

    /// One bridged operation carrying every window in `windows` to `target`,
    /// then a read-back until each one reports exactly `target` or the
    /// deadline passes. A window that did not arrive is reported, never
    /// assumed (S12: ~4 ms plus 0.65 ms a window).
    public static func move(_ windows: [WindowID], to target: SpaceID) -> Moved {
        let start = Date()
        guard !windows.isEmpty else {
            return Moved(verdict: MoveVerdict(arrived: [], missing: []), milliseconds: 0)
        }
        let submitted = windows.withUnsafeBufferPointer {
            weft_bridge_move_windows($0.baseAddress, Int32($0.count), target)
        }
        var verdict = MoveVerdict.judge(windows, target: target, readBack: [:])
        if submitted {
            let deadline = start.addingTimeInterval(0.25 + 0.002 * Double(windows.count))
            repeat {
                verdict = MoveVerdict.judge(windows, target: target, readBack: readSpaces(windows))
                if verdict.complete { break }
                usleep(500)
            } while Date() < deadline
        }
        return Moved(verdict: verdict, milliseconds: Date().timeIntervalSince(start) * 1000)
    }

    public struct Switched: Sendable {
        public var verdict: SwitchVerdict
        public var milliseconds: Double
    }

    /// Switch `display` from `from` to `to` with Show + Hide + SetCurrent, then
    /// judge it by the display's current desktop and the on-screen window list
    /// (`SwitchVerdict`). `expectShown` / `expectHidden` are the managed
    /// windows on the target alone and on the old desktop alone.
    public static func switchDisplay(
        _ display: String, from: SpaceID, to: SpaceID,
        expectShown: [WindowID] = [], expectHidden: [WindowID] = []
    ) -> Switched {
        let start = Date()
        guard weft_bridge_switch(display as CFString, from, to) else {
            let showing = SLSManagedDisplayGetCurrentSpace(WorldReader.cid, display as CFString)
            return Switched(verdict: .notCurrent(showing: showing), milliseconds: 0)
        }
        return awaitSwitch(display, to: to, expectShown: expectShown, expectHidden: expectHidden, since: start)
    }

    /// The fallback: Dock swipes, one desktop per step, each step read back
    /// (`DockSwipe`), then judged like the bridged switch.
    public static func dockSwitch(
        _ display: String, to: SpaceID, expectShown: [WindowID] = [], expectHidden: [WindowID] = []
    ) -> Switched {
        let start = Date()
        guard DockSwipe.focusSpace(to) else {
            let showing = SLSManagedDisplayGetCurrentSpace(WorldReader.cid, display as CFString)
            return Switched(verdict: .notCurrent(showing: showing), milliseconds: Date().timeIntervalSince(start) * 1000)
        }
        return awaitSwitch(display, to: to, expectShown: expectShown, expectHidden: expectHidden, since: start)
    }

    /// The read-back moves first; windows paint just after it. A good switch
    /// passes on an early pass, so only a failing one waits out the deadline.
    static func awaitSwitch(
        _ display: String, to: SpaceID, expectShown: [WindowID], expectHidden: [WindowID], since start: Date
    ) -> Switched {
        let cid = WorldReader.cid
        let deadline = Date().addingTimeInterval(0.3)
        var verdict: SwitchVerdict
        repeat {
            verdict = SwitchVerdict.judge(
                target: to, currentAfter: SLSManagedDisplayGetCurrentSpace(cid, display as CFString),
                expectShown: expectShown, expectHidden: expectHidden,
                onScreen: WorldReader.onScreenWindowIDs()
            )
            if verdict.landed { break }
            usleep(1_000)
        } while Date() < deadline
        return Switched(verdict: verdict, milliseconds: Date().timeIntervalSince(start) * 1000)
    }
}

// MARK: - Self-tests

public enum NativeSelfTest {
    /// `kern.osversion`, e.g. "26A434". A switch result holds for one build.
    public static var macOSBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }

    /// Both perform functions and every operation class resolve.
    public static func symbols() -> RouteStatus {
        if PublicPaths.publicOnlyRequested { return RouteStatus(.off, "WEFT_PUBLIC_ONLY") }
        if let missing = NativeBridge.missingPiece { return RouteStatus(.failed, "\(missing) not found") }
        return RouteStatus(.passed, "both perform functions and every operation class found")
    }

    /// Move a 1×1 window of weft's own, never ordered in, to a desktop and on
    /// to a second one, judged by read-back. Invisible: the window is never
    /// shown and sits far off every display. A new window is on no desktop,
    /// so even one desktop is enough to prove a move happens.
    public static func move() -> RouteStatus {
        guard symbols().usable else { return RouteStatus(.off, "symbol walk did not pass") }
        let cid = WorldReader.cid
        let desktops = WorldReader.readDisplaysAndSpaces(cid: cid).1.filter { $0.type == 0 }.map(\.id)
        guard let first = desktops.first else { return RouteStatus(.untested, "no desktop reported") }
        var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        var wid: SLWindowID = 0
        guard weft_region_window_create(cid, CGPoint(x: -16000, y: -16000), &rect, 1, &wid) == 0, wid != 0 else {
            return RouteStatus(.untested, "could not create the probe window")
        }
        defer { _ = SLSReleaseWindow(cid, wid) }
        var times: [String] = []
        for target in [first] + desktops.dropFirst().prefix(1) {
            let r = NativeBridge.move([wid], to: target)
            guard r.verdict.complete else {
                let now = NativeBridge.readSpaces([wid])[wid] ?? []
                return RouteStatus(.failed, "moved to desktop \(target), reads back \(now)")
            }
            times.append(String(format: "%.1f ms", r.milliseconds))
        }
        return RouteStatus(.passed, "probe window moved and read back (\(times.joined(separator: ", ")))")
    }

    /// The visible test: switch a display to a neighbouring desktop and back,
    /// each step judged by read-back and the on-screen list. One brief
    /// flicker. Needs a display with two ordinary desktops showing one of
    /// them; otherwise there is nothing to switch and the answer is untested.
    public static func switchDesktop() -> RouteStatus {
        guard symbols().usable else { return RouteStatus(.off, "symbol walk did not pass") }
        return roundTrip { display, from, to, shown, hidden in
            NativeBridge.switchDisplay(display, from: from, to: to, expectShown: shown, expectHidden: hidden)
        }
    }

    /// The same round trip by Dock swipe. Needs Accessibility (posting events)
    /// and macOS 26.6 or later; puts the pointer back, since a swipe goes to
    /// the display under it.
    public static func dockSwipe() -> RouteStatus {
        if PublicPaths.publicOnlyRequested { return RouteStatus(.off, "WEFT_PUBLIC_ONLY") }
        guard DockSwipe.isSupported else {
            return RouteStatus(.off, "lands on a blank desktop before macOS 26.6")
        }
        guard AXIsProcessTrusted() else {
            return RouteStatus(.untested, "this process has no Accessibility permission")
        }
        let pointer = CGEvent(source: nil)?.location
        defer { if let pointer { CGWarpMouseCursorPosition(pointer) } }
        return roundTrip { display, _, to, shown, hidden in
            NativeBridge.dockSwitch(display, to: to, expectShown: shown, expectHidden: hidden)
        }
    }

    /// One display's showing desktop to its neighbour and back with `step`,
    /// judged by windows that were on screen, so ordered-out ones (S12) never
    /// count: they were not showing to begin with.
    private static func roundTrip(
        _ step: (_ display: String, _ from: SpaceID, _ to: SpaceID, _ shown: [WindowID], _ hidden: [WindowID])
            -> NativeBridge.Switched
    ) -> RouteStatus {
        let (displays, spaces) = WorldReader.readDisplaysAndSpaces(cid: WorldReader.cid)
        let ordinary = Set(spaces.filter { $0.type == 0 }.map(\.id))
        guard let (display, from, to) = displays.lazy.compactMap({ d -> (String, SpaceID, SpaceID)? in
            let mine = d.spaces.filter { ordinary.contains($0) }
            guard ordinary.contains(d.currentSpace), let i = mine.firstIndex(of: d.currentSpace), mine.count > 1
            else { return nil }
            return (d.uuid, d.currentSpace, mine[i + 1 < mine.count ? i + 1 : i - 1])
        }).first else {
            return RouteStatus(.untested, "no display shows one of two or more desktops")
        }
        let shownHere = exclusiveOnScreen(on: from)
        let out = step(display, from, to, [], shownHere)
        let shownThere = out.verdict.landed ? exclusiveOnScreen(on: to) : []
        let back = step(display, to, from, shownHere, shownThere)
        let fmt = { (ms: Double) in String(format: "%.1f ms", ms) }
        if !out.verdict.landed {
            return RouteStatus(.failed, "to desktop \(to): \(out.verdict.detail)"
                + (back.verdict.landed ? "" : "; switching back: \(back.verdict.detail)"))
        }
        if !back.verdict.landed {
            return RouteStatus(.failed, "back to desktop \(from): \(back.verdict.detail)")
        }
        return RouteStatus(.passed, "desktop \(from) → \(to) → \(from): \(fmt(out.milliseconds)), \(fmt(back.milliseconds))")
    }

    /// Ordinary windows on screen now that are on `space` and no other.
    static func exclusiveOnScreen(on space: SpaceID) -> [WindowID] {
        let candidates = WorldReader.onScreenWindowIDs().filter { wid in
            guard let info = PublicPaths.info(of: wid) else { return false }
            return (info[kCGWindowLayer as String] as? Int) == 0
        }
        let spaces = NativeBridge.readSpaces(Array(candidates))
        return candidates.filter { spaces[$0] == [space] }.sorted()
    }
}

// MARK: - Per-build results

/// `~/.config/weft/native-routes.json`: the self-test results for one macOS
/// build. The visible switch test runs once per build and is read from here
/// after; the invisible tests run every launch and are written back with it.
public struct NativeRoutesCache: Sendable {
    public let url: URL

    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/weft/native-routes.json")) {
        self.url = url
    }

    /// The stored results, if they were made on `build`.
    public func load(build: String) -> NativeRoutes? {
        guard let data = try? Data(contentsOf: url),
              let routes = try? JSONDecoder().decode(NativeRoutes.self, from: data),
              routes.macOSBuild == build
        else { return nil }
        return routes
    }

    public func save(_ routes: NativeRoutes) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(routes) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

extension NativeSelfTest {
    /// Every route for this launch. The symbol walk and the move test run now;
    /// the switch result comes from the cache for this build, and the visible
    /// test runs only when there is none and `allowVisible` (or `force`, for
    /// `doctor --selftest`). Never written under `WEFT_PUBLIC_ONLY`: a run
    /// with every route turned off on purpose says nothing about the build.
    public static func routes(
        cache: NativeRoutesCache = NativeRoutesCache(), allowVisible: Bool, force: Bool = false
    ) -> NativeRoutes {
        let build = macOSBuild
        let cached = force ? nil : cache.load(build: build)
        var routes = NativeRoutes(macOSBuild: build)
        routes[.symbols] = symbols()
        routes[.move] = move()
        if !routes[.symbols].usable {
            routes[.switchDesktop] = RouteStatus(.off, "symbol walk did not pass")
        } else if let cached, [.passed, .failed].contains(cached[.switchDesktop].state) {
            routes[.switchDesktop] = cached[.switchDesktop]
        } else if allowVisible || force {
            routes[.switchDesktop] = switchDesktop()
        } else {
            routes[.switchDesktop] = RouteStatus(.untested, "not run on this macOS build yet")
        }
        // The fallback is tested when it is needed — the instant switch
        // failed on this build — and on demand.
        let cachedSwipe = cached.map { $0[.dockSwipe] }.flatMap { [.passed, .failed].contains($0.state) ? $0 : nil }
        if force || (allowVisible && routes[.switchDesktop].state == .failed && cachedSwipe == nil) {
            routes[.dockSwipe] = dockSwipe()
        } else if let cachedSwipe {
            routes[.dockSwipe] = cachedSwipe
        } else if routes[.switchDesktop].usable {
            routes[.dockSwipe] = RouteStatus(.untested, "not needed: the instant switch passed")
        } else {
            routes[.dockSwipe] = RouteStatus(.untested, "not run on this macOS build yet")
        }
        if !PublicPaths.publicOnlyRequested { cache.save(routes) }
        return routes
    }
}
