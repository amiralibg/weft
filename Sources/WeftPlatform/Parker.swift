// WeftPlatform/Parker.swift — hiding a window, and finding it again.
//
// A workspace is hidden by moving its windows off screen and shown by moving
// them back (WORKSPACES.md). Both directions are `SLSMoveWindow` and nothing
// else: 0.2 ms a window, no animation, and the application is never told, so
// there is nothing for it to clamp or refuse (S9).
//
// S4's nudge does not apply here. A window parked through SkyLight and
// unparked through Accessibility needs one, because the app still believes the
// position it had before the park and writing that same position back through
// AX is a no-op. Park and unpark that both go through SkyLight never touch the
// app's idea of its position at all, so it is consistent again the moment the
// window is back. `AXApplier.restore` keeps its nudge because it is the mixed
// case; this has none.
//
// Nothing calls `park` yet. Under the identity mapping every desktop holds one
// workspace and no workspace is ever hidden, so this is the primitive Phase 3
// turns on — and the ledger underneath it is live now rather than then,
// because a recovery path first exercised by the first crash is not a recovery
// path.

import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

public struct Parker: Sendable {
    public let ledger: ParkLedger

    public init(ledger: ParkLedger = ParkLedger()) {
        self.ledger = ledger
    }

    /// How close to its recorded corner a window has to be for weft to accept
    /// that it is the window it parked.
    private static let spotTolerance = 1.0

    // MARK: - Where a hidden window goes

    /// The bottom-right corner of a display, one point in.
    ///
    /// Not an aesthetic choice, and not interchangeable with parking to a
    /// large negative x, which is what an earlier design assumed:
    ///
    /// - Accessibility clamps off-screen placement, and it clamps
    ///   directionally. Parking to negative x is pulled back to keep 40px of
    ///   the window reachable; the bottom-right is not clamped the same way
    ///   (S4, then S9 measuring the other direction).
    /// - A window with a point of itself still on screen keeps reporting
    ///   `kCGWindowIsOnscreen` and stays in the on-screen window list. That is
    ///   what stops `evictOrderedOut` from treating a hidden workspace's
    ///   windows as closed and giving their slots away, and it is the
    ///   measurement the whole workspace design rests on (S9).
    ///
    /// Takes the display's **full** bounds rather than its usable rect: below
    /// the Dock is further out of the way, and the sliver wants to be as
    /// close to the screen edge as the WindowServer will still call on screen.
    public static func spot(in display: Frame) -> CGPoint {
        CGPoint(x: display.x + display.width - 1, y: display.y + display.height - 1)
    }

    // MARK: - Parking

    public enum ParkError: Error, CustomStringConvertible {
        /// The ledger exists and cannot be read, so weft cannot add to it
        /// without losing whatever it already held. Parking more windows on
        /// top of that would make the windows already hidden unrecoverable.
        case ledgerUnreadable(String)
        case ledgerUnwritable(ParkLedger.WriteError)
        /// This macOS no longer moves a window through the WindowServer the
        /// way weft relies on — the launch self-test moved one of weft's own
        /// windows and did not read it back where it was put. Hiding nothing
        /// is the safe answer: a workspace that stays visible is a nuisance, a
        /// window moved somewhere unverified can be a lost one.
        case unsupported(String)

        public var description: String {
            switch self {
            case .ledgerUnreadable(let why): return "park refused — \(why)"
            case .ledgerUnwritable(let e): return "park refused — \(e)"
            case .unsupported(let why):
                return "park refused — this macOS failed weft's window-move self-test (\(why))"
            }
        }
    }

    public struct ParkOutcome: Sendable, Equatable {
        /// Windows now sitting at the corner.
        public var parked: [WindowID]
        /// Windows that were already parked. Their ledger entry is left
        /// exactly as it was and they are not moved again — re-reading a
        /// parked window's bounds would record the corner as the place to
        /// restore it to.
        public var alreadyParked: [WindowID]
        /// Windows whose bounds could not be read. Nothing is moved that weft
        /// cannot write down first.
        public var unreadable: [WindowID]
        /// The WindowServer refused the move. The window is still on screen
        /// and its entry has been taken back out of the ledger.
        public var refused: [WindowID]
        /// Anything the caller should log. Set only when a window was refused
        /// AND its entry could not be taken back out.
        public var note: String?
    }

    /// Move these windows off screen, having first written down where they
    /// were.
    ///
    /// **The ledger write lands before anything moves, and a failure to write
    /// it moves nothing.** That ordering is the whole point of the file: a
    /// crash between the write and the moves leaves a ledger naming windows
    /// that are still where they were, which startup discards; a crash the
    /// other way round would leave windows at the corner with no record of
    /// them at all.
    ///
    /// One call per workspace, not one per window: the writing is what costs,
    /// and it costs once for the set.
    @discardableResult
    public func park(_ wids: [WindowID], on display: Frame) throws -> ParkOutcome {
        var held: [ParkedWindow]
        switch ledger.load() {
        case .nothingParked: held = []
        case .parked(let entries): held = entries
        case .unreadable(let why): throw ParkError.ledgerUnreadable(why)
        }

        let point = Self.spot(in: display)
        let already = Set(held.map { $0.wid })
        var outcome = ParkOutcome(
            parked: [], alreadyParked: [], unreadable: [], refused: [], note: nil
        )
        var fresh: [ParkedWindow] = []
        for wid in wids {
            if already.contains(wid) {
                outcome.alreadyParked.append(wid)
                continue
            }
            // The frame the window HAS, not the frame the layout computed for
            // it. An app that refused its tile is exactly the app whose
            // restore would otherwise put it somewhere it has never been, and
            // after a crash there is nothing else left to restore from.
            guard let frame = WorldReader.frame(of: wid) else {
                outcome.unreadable.append(wid)
                continue
            }
            fresh.append(
                ParkedWindow(
                    wid: wid,
                    frame: frame,
                    parkedAt: ParkedWindow.Spot(x: point.x, y: point.y)
                )
            )
        }
        guard !fresh.isEmpty else { return outcome }
        // Checked here rather than on entry: only a park that would move
        // something needs the answer, and asking is what runs the self-test.
        guard PrivateAPI.canMoveWindows else {
            let check = PrivateAPI.report.checks.first { $0.name == PrivateAPI.CheckName.windowMove.rawValue }
            throw ParkError.unsupported(check?.detail ?? "not run")
        }

        do {
            try ledger.save(held + fresh)
        } catch let e as ParkLedger.WriteError {
            throw ParkError.ledgerUnwritable(e)
        }

        // Only now.
        for entry in fresh {
            var p = point
            if SLSMoveWindow(WorldReader.cid, entry.wid, &p) == 0 {
                outcome.parked.append(entry.wid)
            } else {
                outcome.refused.append(entry.wid)
            }
        }

        // The one kind of stale entry that is not safe to leave. Everywhere
        // else the rule is a stale entry over a stranded window, and it holds
        // because a stale entry only ever claims a window is hidden when it is
        // home — which the corner check catches, and which costs nothing.
        // This one claims a window is hidden when it is on screen *and weft is
        // still running*, so the next park skips it as already done and it is
        // never hidden at all. Take it back out.
        if !outcome.refused.isEmpty {
            let stuck = Set(outcome.refused)
            do {
                try ledger.save((held + fresh).filter { !stuck.contains($0.wid) })
            } catch {
                // Not a stranded window — the refused ones never moved. The
                // next restart discards the entries anyway, because they are
                // not on the corner.
                outcome.note = "could not take \(outcome.refused) back out of the ledger: \(error)"
            }
        }
        return outcome
    }

    // MARK: - Unparking

    public struct UnparkOutcome: Sendable, Equatable {
        /// Windows put back where they were.
        public var restored: [WindowID]
        /// A ledger entry that does not name the window weft parked. Either
        /// the WindowServer handed the id to a new window after the old one
        /// died, or the application moved its own window while it was hidden.
        /// Either way the entry is dropped and nothing is moved: the check is
        /// what stops a recycled id being dragged to a dead window's frame.
        public var notOurs: [WindowID]
        /// The WindowServer refused the move. The entry is KEPT, so the next
        /// launch tries again rather than forgetting a window that is still
        /// off screen.
        public var refused: [WindowID]
        /// Anything the caller should put in the log. A ledger that cannot be
        /// read is the one failure that leaves windows stranded with nothing
        /// able to find them, so it is never silent.
        public var note: String?

        public var isEmpty: Bool {
            restored.isEmpty && notOurs.isEmpty && refused.isEmpty && note == nil
        }
    }

    /// Put every window the ledger holds back where it was. What the daemon
    /// runs at startup, before its first sweep.
    @discardableResult
    public func unparkAll() -> UnparkOutcome {
        switch ledger.load() {
        case .nothingParked:
            return UnparkOutcome(restored: [], notOurs: [], refused: [], note: nil)
        case .unreadable(let why):
            return UnparkOutcome(
                restored: [], notOurs: [], refused: [],
                note: "\(why) — any window weft had parked is still off screen"
            )
        case .parked(let entries):
            return unpark(entries, keeping: [])
        }
    }

    /// Put these windows back, leaving the rest of the ledger alone.
    @discardableResult
    public func unpark(_ wids: [WindowID]) -> UnparkOutcome {
        switch ledger.load() {
        case .nothingParked:
            return UnparkOutcome(restored: [], notOurs: [], refused: [], note: nil)
        case .unreadable(let why):
            return UnparkOutcome(
                restored: [], notOurs: [], refused: [],
                note: "\(why) — cannot say where \(wids.count) window(s) belong"
            )
        case .parked(let entries):
            let wanted = Set(wids)
            return unpark(
                entries.filter { wanted.contains($0.wid) },
                keeping: entries.filter { !wanted.contains($0.wid) }
            )
        }
    }

    /// Every window ID currently recorded as parked.
    public var parkedWIDs: Set<WindowID> {
        switch ledger.load() {
        case .parked(let entries): return Set(entries.map(\.wid))
        case .nothingParked, .unreadable: return []
        }
    }

    /// Whether a window is currently recorded as parked in the ledger.
    public func isParked(_ wid: WindowID) -> Bool {
        parkedWIDs.contains(wid)
    }

    /// Put back any window parked on a display that is no longer present.
    @discardableResult
    public func unparkOutside(displays: [Frame]) -> UnparkOutcome {
        switch ledger.load() {
        case .parked(let entries):
            let outside = entries.filter { entry in
                !displays.contains { $0.contains(x: entry.parkedAt.x, y: entry.parkedAt.y) }
            }
            guard !outside.isEmpty else {
                return UnparkOutcome(restored: [], notOurs: [], refused: [], note: nil)
            }
            return unpark(outside.map(\.wid))
        case .nothingParked, .unreadable:
            return UnparkOutcome(restored: [], notOurs: [], refused: [], note: nil)
        }
    }

    /// **The moves land before the ledger is rewritten**, which is the mirror
    /// of `park` and for the same reason. Dropping an entry and then failing
    /// to move the window is the one ordering that produces a window off
    /// screen with no record of it. A crash the other way round leaves an
    /// entry for a window that is already home, and the corner check throws it
    /// away the next time the ledger is read.
    private func unpark(_ entries: [ParkedWindow], keeping: [ParkedWindow]) -> UnparkOutcome {
        var outcome = UnparkOutcome(restored: [], notOurs: [], refused: [], note: nil)
        // Nothing asked for is in the ledger. Rewriting it with what it
        // already holds would be an fsync for a no-op.
        guard !entries.isEmpty else { return outcome }
        var stillParked = keeping
        for entry in entries {
            guard let live = WorldReader.frame(of: entry.wid),
                  abs(live.x - entry.parkedAt.x) <= Self.spotTolerance,
                  abs(live.y - entry.parkedAt.y) <= Self.spotTolerance
            else {
                outcome.notOurs.append(entry.wid)
                continue
            }
            var p = CGPoint(x: entry.frame.x, y: entry.frame.y)
            if SLSMoveWindow(WorldReader.cid, entry.wid, &p) == 0 {
                outcome.restored.append(entry.wid)
            } else {
                outcome.refused.append(entry.wid)
                stillParked.append(entry)
            }
        }
        if stillParked.isEmpty {
            if !ledger.clear() {
                outcome.note = "could not remove \(ledger.url.path)"
            }
        } else {
            do {
                try ledger.save(stillParked)
            } catch {
                // The windows are back on screen; this is bookkeeping that did
                // not land, not a window that cannot be reached. Say so and
                // carry on — the next park rewrites the file anyway.
                outcome.note = "could not rewrite \(ledger.url.path): \(error)"
            }
        }
        return outcome
    }
}
