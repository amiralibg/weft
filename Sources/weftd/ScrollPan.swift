// weftd/ScrollPan.swift — interpolated viewport motion for scroll spaces.
//
// `docs/DESIGN.md` §1 forbids animation, for a reason that still holds
// everywhere else: an interpolated retile means N AX writes per window per
// frame, each one a cross-process round trip an app can be slow at, and the
// layout falls behind the machine that is driving it.
//
// A scroll pan is the one motion that costs none of that. Every window keeps
// its size and its Y and moves the same distance along X, so a frame of the
// animation is a single `SLSTransaction` of positions — WindowServer-local,
// no app IPC, atomic, and the same mechanism a border drag already uses at
// mouse rate. The AX write that keeps each app's own idea of where it is
// honest (S2) happens once, when the pan lands.
//
// So the constraint is kept where it is load-bearing and relaxed where it is
// free, which is why this is `scroll-animation-ms` and not `animations = true`.

import Dispatch
import Foundation
import WeftCore

/// How a pan stopped, which decides who owes the windows a settled layout.
enum PanEnd {
    /// Reached its target. The frames it was animating towards go out now,
    /// through AX, which is what tells each app where it ended up.
    case landed
    /// Another pan took the animator. If it is the same strip, that pan now
    /// owns these windows and will settle them; if it is a different one,
    /// these windows are frozen part-way and need settling immediately.
    case superseded(by: SpaceID)
    /// The daemon stopped it in order to draw the strip itself, and is
    /// writing the settled frames on the caller's thread.
    case cancelled
}

/// A viewport pan in flight, and the clock driving it.
///
/// One at a time, globally: a pan is a response to a keypress, and a second
/// keypress means the user has changed their mind about where they are going
/// rather than asked for two journeys. `retarget` therefore continues from
/// wherever the current pan has reached instead of queueing behind it, which
/// is what makes holding down a column-focus key read as one continuous
/// scroll rather than a series of lurches.
final class PanAnimator: @unchecked Sendable {
    /// 8 ms: one frame at 120 Hz, and two at 60. Ticks are one WindowServer
    /// transaction each, so the cost of over-sampling a 60 Hz display is a
    /// few microseconds and the benefit on a ProMotion one is the whole point.
    private static let tick: TimeInterval = 1.0 / 120.0

    private let queue = DispatchQueue(label: "weft.scroll-pan", qos: .userInteractive)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// Which space the running pan belongs to. A pan for a different space
    /// replaces it outright — two strips cannot both be under the cursor.
    private var sid: SpaceID?
    private var fromVX: Double = 0
    private var toVX: Double = 0
    private var startedAt: Date = .distantPast
    private var duration: TimeInterval = 0
    private var onFrame: ((Double) -> Void)?
    private var onEnd: ((PanEnd) -> Void)?

    /// Where the pan for `sid` has got to and where it is going, or nil if
    /// none is running for it.
    ///
    /// `current` is the start of a retarget. `target` answers the other
    /// question a caller has: a pan already heading exactly where this change
    /// wants to go must be left alone, not cancelled and restarted from where
    /// it happens to have reached — restarting a pan every time an event
    /// re-derives the same layout is how motion turns into a crawl.
    func state(of sid: SpaceID) -> (current: Double, target: Double)? {
        lock.withLock {
            guard self.sid == sid, timer != nil else { return nil }
            return (interpolatedLocked(), toVX)
        }
    }

    /// Start (or retarget) a pan. `onFrame` runs on the animator's queue for
    /// every intermediate viewport; `onEnd` runs exactly once, saying how the
    /// pan stopped and therefore who owes the windows a settled layout.
    func run(
        sid: SpaceID,
        from: Double,
        to: Double,
        duration: TimeInterval,
        onFrame: @escaping (Double) -> Void,
        onEnd: @escaping (PanEnd) -> Void
    ) {
        let previous: ((PanEnd) -> Void)? = lock.withLock {
            let previous = self.onEnd
            timer?.cancel()
            timer = nil
            self.sid = sid
            self.fromVX = from
            self.toVX = to
            self.startedAt = Date()
            self.duration = max(duration, Self.tick)
            self.onFrame = onFrame
            self.onEnd = onEnd
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + Self.tick, repeating: Self.tick, leeway: .nanoseconds(0))
            t.setEventHandler { [weak self] in self?.step() }
            self.timer = t
            t.resume()
            return previous
        }
        previous?(.superseded(by: sid))
    }

    /// Stop without landing, and report whether there was anything to stop.
    ///
    /// The pending `onLanded` is told it was superseded, so the frames it
    /// would have written are left to the caller that cancelled — which is
    /// why the answer matters: a cancelled pan leaves every window at an
    /// interpolated position its app has not been told about, so the caller
    /// owes it a forced AX write rather than a diffed one.
    ///
    /// `sid` cancels only a pan belonging to that space; pass nil for any.
    @discardableResult
    func cancel(sid: SpaceID? = nil) -> Bool {
        let stopped: (yes: Bool, end: ((PanEnd) -> Void)?) = lock.withLock {
            guard timer != nil, sid == nil || sid == self.sid else { return (false, nil) }
            let previous = onEnd
            timer?.cancel()
            timer = nil
            self.sid = nil
            onFrame = nil
            onEnd = nil
            return (true, previous)
        }
        stopped.end?(.cancelled)
        return stopped.yes
    }

    /// End a pan by arriving: snap to the target and let the landing settle
    /// it. For the moments the user stops watching — a space switch, a display
    /// change — where cancelling would leave windows frozen part-way across
    /// the screen with nobody left to finish them.
    func finish(sid: SpaceID? = nil) {
        let ended: (frame: ((Double) -> Void)?, end: ((PanEnd) -> Void)?, to: Double) =
            lock.withLock {
                guard timer != nil, sid == nil || sid == self.sid else { return (nil, nil, 0) }
                let f = onFrame
                let e = onEnd
                timer?.cancel()
                timer = nil
                self.sid = nil
                onFrame = nil
                onEnd = nil
                return (f, e, toVX)
            }
        ended.frame?(ended.to)
        ended.end?(.landed)
    }

    private func step() {
        enum Next {
            case frame(Double, (Double) -> Void)
            case land(Double, (Double) -> Void, ((PanEnd) -> Void)?)
            case nothing
        }
        let next: Next = lock.withLock {
            guard timer != nil, let onFrame else { return .nothing }
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed >= duration {
                let end = onEnd
                timer?.cancel()
                timer = nil
                sid = nil
                self.onFrame = nil
                self.onEnd = nil
                return .land(toVX, onFrame, end)
            }
            return .frame(interpolatedLocked(), onFrame)
        }
        switch next {
        case .nothing:
            break
        case .frame(let vx, let f):
            f(vx)
        case .land(let vx, let f, let done):
            f(vx)
            done?(.landed)
        }
    }

    private func interpolatedLocked() -> Double {
        let elapsed = Date().timeIntervalSince(startedAt)
        let t = min(max(elapsed / duration, 0), 1)
        return fromVX + (toVX - fromVX) * PanAnimator.ease(t)
    }

    /// Cubic ease-out.
    ///
    /// The pan is the answer to a key that has already been pressed, so the
    /// motion has to leave immediately and settle gently — the opposite shape
    /// from a gesture the hand is still driving. Symmetric easing on a 140 ms
    /// move reads as lag at the start, which is the one thing an input
    /// response cannot afford.
    static func ease(_ t: Double) -> Double {
        let u = 1 - t
        return 1 - u * u * u
    }
}
