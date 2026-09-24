// WeftPlatform/PrivateAPI.swift — which private macOS calls this Mac still
// has, and whether the ones that matter still do what weft relies on.
//
// Every private symbol is resolved by name at load (SkyLightShim.c), so a
// missing one no longer stops a process launching; it makes its call fail.
// That is only half of surviving a macOS update. The other half is that a
// symbol can still be exported and have stopped working — S6 and S8 both
// found calls returning success and doing nothing — so presence is reported
// and behaviour is tested, separately.
//
// The behaviour tests act only on a window this process creates and never
// shows. No user window is touched, nothing appears on screen, and the whole
// run is a few milliseconds.

import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

public struct PrivateAPIReport: Codable, Sendable, Equatable {
    public struct Symbol: Codable, Sendable, Equatable {
        public var name: String
        public var present: Bool
    }

    public struct Check: Codable, Sendable, Equatable {
        public var name: String
        public var passed: Bool
        public var detail: String
    }

    /// `ProcessInfo.operatingSystemVersionString`, so a report pasted into a
    /// bug names the build it came from.
    public var macOS: String
    public var symbols: [Symbol]
    public var checks: [Check]

    public var missing: [String] { symbols.filter { !$0.present }.map { $0.name } }
    public var failed: [Check] { checks.filter { !$0.passed } }

    public func passed(_ check: PrivateAPI.CheckName) -> Bool {
        checks.first { $0.name == check.rawValue }?.passed ?? false
    }

    /// One line for a log.
    public var summary: String {
        let found = symbols.count - missing.count
        var out = "\(found)/\(symbols.count) private symbols"
        if failed.isEmpty {
            out += ", self-test passed"
        } else {
            out += ", self-test FAILED: " + failed.map { "\($0.name) (\($0.detail))" }.joined(separator: "; ")
        }
        if !missing.isEmpty { out += "; missing: " + missing.joined(separator: ", ") }
        return out
    }
}

public enum PrivateAPI {
    public enum CheckName: String, CaseIterable, Sendable {
        /// A WindowServer connection. Nothing else works without it.
        case connection
        /// Displays, their desktops, and which one is showing.
        case topology
        /// Reading a window's frame from the WindowServer.
        case windowBounds = "window-bounds"
        /// Moving a window through the WindowServer: hiding a workspace.
        case windowMove = "window-move"
        /// Several moves landing on one frame: tiling without tearing.
        case transaction
    }

    /// What a missing symbol costs, for `weftctl doctor`. Every one has a
    /// public path now (`PublicPaths`), so these read as slower or less,
    /// never as broken. A symbol not listed costs something its name says.
    public static let impact: [String: String] = [
        "SLSMainConnectionID": "every WindowServer speed-up; weft runs on public paths alone",
        "SLSCopyManagedDisplaySpaces": "knowing about other macOS desktops — weft manages one desktop per display and cannot pause",
        "SLSManagedDisplayGetCurrentSpace": "knowing which desktop is showing — weft cannot pause on another one",
        "SLSCopySpacesForWindows": "knowing a window's desktop exactly — weft goes by which display it is on",
        "SLSGetWindowBounds": "fast window frames — read from the public window list instead",
        "SLSMoveWindow": "instant hiding — workspaces switch through Accessibility, about 30 ms a window",
        "SLSTransactionCreate": "moving several windows on one frame (drags may tear)",
        "SLSNewWindow": "weft's own borders",
        "SLWindowContextCreate": "weft's own borders",
        "CGSNewRegionWithRectList": "weft's own borders",
        "_AXUIElementGetWindow": "fast window matching — matched by position and size instead",
        "SLSSpaceGetType": "skipping native fullscreen desktops",
        "SLSCopyActiveMenuBarDisplayIdentifier": "knowing which display has focus — the main display is assumed",
    ]

    /// Symbols weft cannot work without. None, since every one has a public
    /// path; kept so doctor can tell "slower" from "broken" if that changes.
    public static let essential: Set<String> = []

    public static var symbols: [PrivateAPIReport.Symbol] {
        (0..<weft_private_symbol_count()).compactMap { i in
            guard let name = weft_private_symbol_name(i) else { return nil }
            return .init(name: String(cString: name), present: weft_private_symbol_present(i))
        }
    }

    /// This process's answer, computed once. Every caller in a process gets
    /// the same one, so a feature cannot be on for one path and off for
    /// another within a launch.
    public static let report: PrivateAPIReport = selfTest()

    /// Whether hiding a workspace can be trusted: a window moved through the
    /// WindowServer is read back where it was put.
    public static var canMoveWindows: Bool { report.passed(.windowMove) }

    /// Run every check now. `report` is the cached one; this is for callers
    /// that want a fresh answer, such as `weftctl doctor`.
    public static func selfTest() -> PrivateAPIReport {
        var checks: [PrivateAPIReport.Check] = []
        func record(_ name: CheckName, _ passed: Bool, _ detail: String) {
            checks.append(.init(name: name.rawValue, passed: passed, detail: detail))
        }

        let cid = SLSMainConnectionID()
        record(.connection, cid != 0, cid != 0 ? "cid \(cid)" : "no connection")
        guard cid != 0 else {
            for name in CheckName.allCases where name != .connection {
                record(name, false, "no connection")
            }
            return PrivateAPIReport(
                macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                symbols: symbols, checks: checks
            )
        }

        let (topologyOK, topologyDetail) = checkTopology(cid)
        record(.topology, topologyOK, topologyDetail)

        let probe = ProbeWindow(cid: cid)
        defer { probe?.release() }
        if let probe {
            let (boundsOK, boundsDetail) = probe.checkBounds()
            record(.windowBounds, boundsOK, boundsDetail)
            let (moveOK, moveDetail) = probe.checkMove()
            record(.windowMove, moveOK, moveDetail)
            let (txOK, txDetail) = probe.checkTransaction()
            record(.transaction, txOK, txDetail)
        } else {
            let why = "could not create a probe window"
            record(.windowBounds, false, why)
            record(.windowMove, false, why)
            record(.transaction, false, why)
        }

        return PrivateAPIReport(
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            symbols: symbols, checks: checks
        )
    }

    /// At least one display with at least one desktop, and the desktop the
    /// WindowServer says is showing is one of that display's.
    private static func checkTopology(_ cid: SLConnectionID) -> (Bool, String) {
        guard let raw = SLSCopyManagedDisplaySpaces(cid) as? [[String: Any]], !raw.isEmpty else {
            return (false, "no displays reported")
        }
        for display in raw {
            guard let uuid = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]], !spaces.isEmpty
            else { continue }
            let ids = Set(spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value })
            let current = SLSManagedDisplayGetCurrentSpace(cid, uuid as CFString)
            guard ids.contains(current) else {
                return (false, "current desktop \(current) is not among \(ids.sorted())")
            }
            return (true, "\(raw.count) display(s), current desktop \(current)")
        }
        return (false, "no display lists a desktop")
    }
}

/// A 1×1 window of this process's own, far off every display and never
/// ordered in, so it is never seen.
private struct ProbeWindow {
    let cid: SLConnectionID
    let wid: SLWindowID
    static let origin = CGPoint(x: -16000, y: -16000)

    init?(cid: SLConnectionID) {
        var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        var wid: SLWindowID = 0
        guard weft_border_window_create(cid, Self.origin, &rect, 1, &wid) == 0, wid != 0 else {
            return nil
        }
        self.cid = cid
        self.wid = wid
    }

    func release() { _ = SLSReleaseWindow(cid, wid) }

    private func bounds() -> CGRect? {
        var r = CGRect.zero
        return SLSGetWindowBounds(cid, wid, &r) == 0 ? r : nil
    }

    private func isAt(_ p: CGPoint) -> Bool {
        guard let r = bounds() else { return false }
        return abs(r.minX - p.x) < 0.5 && abs(r.minY - p.y) < 0.5
    }

    func checkBounds() -> (Bool, String) {
        guard let r = bounds() else { return (false, "bounds unreadable") }
        return isAt(Self.origin)
            ? (true, "read back at creation point")
            : (false, "created at \(Self.origin), read back \(r.origin)")
    }

    /// Verified by reading back, never by the return code (S6, S8).
    func checkMove() -> (Bool, String) {
        var target = CGPoint(x: Self.origin.x + 7, y: Self.origin.y + 5)
        let rc = SLSMoveWindow(cid, wid, &target)
        if isAt(target) { return (true, "moved and read back") }
        return (false, "rc \(rc), window did not arrive")
    }

    /// Commits are asynchronous, so the read-back waits for the move to land
    /// — up to 100 ms, which only a failing check ever spends.
    func checkTransaction() -> (Bool, String) {
        guard let t = SLSTransactionCreate(cid) else { return (false, "no transaction") }
        let target = CGPoint(x: Self.origin.x + 13, y: Self.origin.y + 11)
        _ = SLSTransactionMoveWindowWithGroup(t, wid, target)
        _ = SLSTransactionCommit(t, 0)
        let deadline = Date().addingTimeInterval(0.1)
        repeat {
            if isAt(target) { return (true, "committed and read back") }
            usleep(2_000)
        } while Date() < deadline
        return (false, "committed, window did not arrive")
    }
}
