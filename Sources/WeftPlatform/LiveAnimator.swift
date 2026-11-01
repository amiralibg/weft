import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

/// Placement animations on the real windows.
///
/// The animator that came before this one (a stage of captured copies gliding
/// over the desktop while the real windows moved behind it) never looked
/// smooth: every placement paid for a round of captures before anything
/// moved, the copies were stretched bitmaps of the old layout, and the stage
/// held still until the slowest app had landed, then cross-faded into
/// whatever the real windows looked like by then. Shuttle drives the windows
/// themselves and reads as one movement, so weft does the same now:
///
/// - one critically damped spring per moving window, stepped on the display's
///   refresh (`CVDisplayLink`), running only while something moves;
/// - each step hands the window's current frame to `post`, which keeps at most
///   one waiting frame per window and writes it on the app's own queue —
///   newest frame wins, so an app that answers slowly (a Chromium resize is
///   tens of milliseconds) gets fewer, newer frames and never holds up the
///   spring or any other app;
/// - when a window's spring settles, its `onSettle` callbacks run: the full
///   frame-set protocol (write, read back, correct) lands the exact target.
///
/// A placement while a window is still moving retargets its spring: position
/// and velocity carry over, so a key held down or pressed twice reads as one
/// continuous motion.
///
/// Needs no permission beyond Accessibility. Off under Reduce Motion (the
/// caller checks) and for moves between displays.
public final class LiveAnimator: @unchecked Sendable {
    /// Set by the owner: write `frame` to `wid` (owned by `pid`) soon, on that
    /// app's queue, replacing any frame still waiting for it.
    var post: ((WindowID, Int32, Frame) -> Void)?

    public var enabled: Bool {
        get { lock.withLock { _enabled } }
        set {
            let drop: Bool = lock.withLock {
                defer { _enabled = newValue }
                return _enabled && !newValue
            }
            if drop { finishAll() }
        }
    }

    public init() {}

    // MARK: Tuning

    /// Shuttle's spring: ω = 26 rad/s, about a quarter of a second to arrive.
    static let omega = 26.0
    /// Close enough to call it there: the remaining motion is under a point
    /// and slow. Without this the tail of the spring is a run of sub-point
    /// steps, and every one would be another relayout of the window.
    static let settleDistance = 1.0
    static let settleSpeed = 20.0
    /// A spring that somehow has not settled by now (a target that keeps
    /// moving away) is ended: the protocol write puts the window there.
    static let maxDuration = 0.8

    // MARK: State

    private let lock = NSLock()
    private var _enabled = false

    private struct Track {
        var pid: Int32
        var current: CGRect
        var target: CGRect
        var velocity = Velocity()
        var started: Double
        var settles: [() -> Void]
        /// The frame last handed to `post`, rounded, so a step that does not
        /// change the integral frame costs no write.
        var posted: Frame?
    }

    private var tracks: [WindowID: Track] = [:]
    private var link: OpaquePointer?
    private var lastTick = 0.0

    // MARK: The seam

    /// Whether `wid` is mid-glide.
    public func isAnimating(_ wid: WindowID) -> Bool {
        lock.withLock { tracks[wid] != nil }
    }

    /// Glide `wid` from `from` to `to`, then run `onSettle`. A window already
    /// moving is retargeted instead: `from` is ignored, the spring keeps its
    /// position and velocity, and `onSettle` joins the callbacks it already
    /// has. False (and `onSettle` is not kept) when animations are off or no
    /// display clock could be started; the caller writes the frame itself.
    @discardableResult
    public func animate(
        _ wid: WindowID, pid: Int32, from: CGRect, to: CGRect, onSettle: @escaping () -> Void
    ) -> Bool {
        let now = Self.now()
        return lock.withLock {
            guard _enabled else { return false }
            if var t = tracks[wid] {
                t.target = to
                t.pid = pid
                t.started = now
                t.settles.append(onSettle)
                tracks[wid] = t
                return true
            }
            if link == nil {
                lastTick = now
                let me = Unmanaged.passUnretained(self).toOpaque()
                link = weft_display_link_start(CGMainDisplayID(), { context, _ in
                    guard let context else { return }
                    Unmanaged<LiveAnimator>.fromOpaque(context).takeUnretainedValue().tick()
                }, me)
                guard link != nil else { return false }
            }
            tracks[wid] = Track(pid: pid, current: from, target: to, started: now, settles: [onSettle])
            return true
        }
    }

    /// Every glide ends now: no more frames, and every `onSettle` runs, so
    /// each window still gets its protocol write. A drag calls this before it
    /// starts moving windows under the cursor.
    public func finishAll() {
        let callbacks: [() -> Void] = lock.withLock {
            let all = tracks.values.flatMap(\.settles)
            tracks.removeAll()
            stopLinkLocked()
            return all
        }
        for c in callbacks { c() }
    }

    // MARK: Motion

    private func tick() {
        var posts: [(WindowID, Int32, Frame)] = []
        var callbacks: [() -> Void] = []
        lock.withLock {
            let now = Self.now()
            let dt = min(max(now - lastTick, 0), 1.0 / 30)
            lastTick = now
            for (wid, var t) in tracks {
                let done = Self.step(&t.current, toward: t.target, velocity: &t.velocity, dt: dt)
                    || now - t.started > Self.maxDuration
                if done {
                    callbacks += t.settles
                    tracks.removeValue(forKey: wid)
                    continue
                }
                let frame = Self.rounded(t.current)
                if frame != t.posted {
                    t.posted = frame
                    posts.append((wid, t.pid, frame))
                }
                tracks[wid] = t
            }
            if tracks.isEmpty { stopLinkLocked() }
        }
        if let post { for (wid, pid, frame) in posts { post(wid, pid, frame) } }
        for c in callbacks { c() }
    }

    private func stopLinkLocked() {
        guard let l = link else { return }
        link = nil
        nonisolated(unsafe) let stopping = l
        // Never from the link's own thread, which is where this usually runs:
        // stopping waits for the callback in progress.
        DispatchQueue.global(qos: .utility).async { weft_display_link_stop(stopping) }
    }

    struct Velocity: Equatable {
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        var magnitude: Double { abs(x) + abs(y) + abs(w) + abs(h) }
    }

    /// One step of a critically damped spring on each of the four channels.
    /// True once it is there, with `current` snapped to `target`.
    static func step(_ current: inout CGRect, toward target: CGRect, velocity v: inout Velocity, dt: Double) -> Bool {
        let w = omega
        let e = exp(-w * dt)
        func channel(_ cur: CGFloat, _ goal: CGFloat, _ vel: Double) -> (CGFloat, Double) {
            let x0 = Double(cur - goal)
            let c = vel + w * x0
            return (goal + CGFloat((x0 + c * dt) * e), (vel - w * c * dt) * e)
        }
        let (x, vx) = channel(current.minX, target.minX, v.x)
        let (y, vy) = channel(current.minY, target.minY, v.y)
        let (width, vw) = channel(current.width, target.width, v.w)
        let (height, vh) = channel(current.height, target.height, v.h)
        current = CGRect(x: x, y: y, width: max(1, width), height: max(1, height))
        v = Velocity(x: vx, y: vy, w: vw, h: vh)
        if distance(current, target) < settleDistance, v.magnitude < settleSpeed {
            current = target
            v = Velocity()
            return true
        }
        return false
    }

    static func distance(_ a: CGRect, _ b: CGRect) -> Double {
        let origin: CGFloat = abs(a.minX - b.minX) + abs(a.minY - b.minY)
        let size: CGFloat = abs(a.width - b.width) + abs(a.height - b.height)
        return Double(origin + size)
    }

    static func rounded(_ r: CGRect) -> Frame {
        Frame(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
    }

    static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
