// WeftPlatform/PublicPaths.swift — what weft does when a private call is gone.
//
// Every private SkyLight call weft makes has a public way to get the same
// answer, or a close enough one, and this is where they live (REDESIGN.md,
// "Platform budget"). The private call stays first because it is faster or
// more exact; the public one is what a macOS update cannot take away.
//
// `WEFT_PUBLIC_ONLY=1` in weftd's environment turns every private symbol off
// at launch, so all of this can be run on purpose rather than discovered by
// the update that breaks something.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

public enum PublicPaths {
    /// Take every private symbol away, for `WEFT_PUBLIC_ONLY=1`. Returns how
    /// many were turned off.
    @discardableResult
    public static func disablePrivateSymbols() -> Int {
        var n = 0
        for i in 0..<weft_private_symbol_count() {
            if let name = weft_private_symbol_name(i), weft_private_symbol_simulate_missing(name, true) { n += 1 }
        }
        return n
    }

    /// Whether this process has lost a private symbol — gone from this macOS,
    /// or turned off by `WEFT_PUBLIC_ONLY`. What every fallback checks, so a
    /// private call that merely failed is never answered by a public guess.
    public static func isMissing(_ name: String) -> Bool {
        for i in 0..<weft_private_symbol_count() {
            if let n = weft_private_symbol_name(i), String(cString: n) == name {
                return !weft_private_symbol_present(i)
            }
        }
        return false
    }

    public static var publicOnlyRequested: Bool {
        ProcessInfo.processInfo.environment["WEFT_PUBLIC_ONLY"] == "1"
    }

    // MARK: - One window, from the public window list

    /// The window list's entry for one window: its bounds, owner and whether
    /// it is on screen. Public, and it names every window on every desktop.
    static func info(of wid: WindowID) -> [String: Any]? {
        (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(wid)) as? [[String: Any]])?.first
    }

    static func bounds(_ entry: [String: Any]) -> Frame? {
        guard let b = entry[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? Double, let y = b["Y"] as? Double,
              let w = b["Width"] as? Double, let h = b["Height"] as? Double
        else { return nil }
        return Frame(x: x, y: y, width: w, height: h)
    }

    public static func frame(of wid: WindowID) -> Frame? {
        info(of: wid).flatMap(bounds)
    }

    public static func ownerPID(of wid: WindowID) -> Int32? {
        (info(of: wid)?[kCGWindowOwnerPID as String] as? Int).map(Int32.init)
    }

    // MARK: - Which window an AX element is

    /// The WindowServer id of an AX window element.
    ///
    /// `_AXUIElementGetWindow` answers directly and every Mac window manager
    /// relies on it. Without it, the element's position and size are matched
    /// against the app's own windows in the public window list — exact for
    /// every window that is not stacked precisely on top of a sibling of the
    /// same size, and then the title breaks the tie.
    public static func windowID(of element: AXUIElement, pid: Int32? = nil) -> WindowID? {
        var wid: UInt32 = 0
        let rc = _AXUIElementGetWindow(element, &wid)
        if rc == .success, wid != 0 { return wid }
        // Only when the call is gone. It also fails for ordinary reasons — a
        // window still being assembled, an element that is not a window — and
        // answering those with a scan of every window on the machine would
        // cost the normal path what only the degraded one should pay.
        guard rc == .notImplemented else { return nil }

        var owner: pid_t = pid ?? 0
        if owner == 0, AXUIElementGetPid(element, &owner) != .success { return nil }
        guard let frame = axFrame(element) else { return nil }
        let all = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        let matches = all.filter { entry in
            (entry[kCGWindowOwnerPID as String] as? Int) == Int(owner)
                && (entry[kCGWindowLayer as String] as? Int) == 0
                && bounds(entry).map { close($0, frame) } == true
        }
        if matches.count > 1, let title = axString(element, kAXTitleAttribute) {
            if let named = matches.first(where: { ($0[kCGWindowName as String] as? String) == title }) {
                return (named[kCGWindowNumber as String] as? Int).map(WindowID.init)
            }
        }
        return (matches.first?[kCGWindowNumber as String] as? Int).map(WindowID.init)
    }

    private static func close(_ a: Frame, _ b: Frame) -> Bool {
        abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    static func axFrame(_ el: AXUIElement) -> Frame? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef
        else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        // Both are AXValue by contract; the casts cannot fail for a success.
        AXValueGetValue(posValue as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &s)
        return Frame(x: p.x, y: p.y, width: s.width, height: s.height)
    }

    private static func axString(_ el: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    // MARK: - Displays and desktops, without SkyLight

    /// A stand-in desktop id for a display when SkyLight cannot say which
    /// desktops it has: one per display, derived from its uuid so it is the
    /// same on every launch. weft then manages one desktop per display, which
    /// is what it does anyway — it only loses the ability to tell another
    /// macOS desktop is showing, and so to pause.
    public static func syntheticDesktop(for uuid: String) -> SpaceID {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in uuid.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        // Clear of every real space id, which are small.
        return hash | (1 << 62)
    }

    /// The display a window is on: the one holding most of it, or — for a
    /// parked window with one point on screen — the one it touches.
    public static func display(of frame: Frame, among displays: [SpaceControl.DisplayFrames]) -> String? {
        func area(_ d: Frame) -> Double {
            let w = min(frame.x + frame.width, d.x + d.width) - max(frame.x, d.x)
            let h = min(frame.y + frame.height, d.y + d.height) - max(frame.y, d.y)
            return w > 0 && h > 0 ? w * h : 0
        }
        return displays.max { area($0.frame) < area($1.frame) }.flatMap { area($0.frame) > 0 ? $0.uuid : nil }
    }
}

/// Hiding a window through Accessibility, for when the WindowServer move is
/// gone or failed its self-test.
///
/// Slower (a round trip to the app, ~30 ms a window in S9) and clamped: macOS
/// keeps 40 points of a window reachable when it is moved toward negative x,
/// so a left-corner park leaves more showing. `Parker` records where each
/// window actually landed, so finding it again does not depend on the clamp.
public final class AXParkMover: @unchecked Sendable {
    private let applier: AXApplier

    public init(applier: AXApplier) {
        self.applier = applier
    }

    /// How far from the asked-for spot a window may land and still count as
    /// moved: macOS keeps up to ~50 points of a window reachable (S4, S9).
    static let clampAllowance = 100.0

    public func move(_ wid: WindowID, to point: CGPoint) -> Bool {
        guard let pid = PublicPaths.ownerPID(of: wid),
              let current = WorldReader.frame(of: wid)
        else { return false }

        if applier.placeSynchronously(
            wid, pid: pid,
            at: Frame(x: point.x, y: point.y, width: current.width, height: current.height)
        ) { return true }
        // Clamped is still moved: parking asks for a spot macOS will not quite
        // allow, and the parker records where the window really went. The
        // public window list catches up with an Accessibility move a moment
        // late, so the landing is waited for — briefly, and only here.
        let deadline = Date().addingTimeInterval(0.4)
        repeat {
            if let landed = WorldReader.frame(of: wid),
               abs(landed.x - point.x) <= Self.clampAllowance,
               abs(landed.y - point.y) <= Self.clampAllowance {
                return true
            }
            usleep(20_000)
        } while Date() < deadline
        return false
    }
}
