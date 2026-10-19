import AppKit
import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

/// Placement animations: the glide every other window manager gets.
///
/// A placement change moves and resizes real windows in one WindowServer
/// transaction (AXApply's `commitPositions`), which is correct and instant —
/// instant in the way a teleport is instant. The REDESIGN roadmap put the
/// shape of the answer: capture each moved window's pixels, draw them into a
/// proxy of weft's own, move the real window underneath, glide the proxy from
/// the old frame to the new one, and fade it out once the window below has
/// arrived.
///
/// The seam is `AXApplier.apply`, and it is the only place both frames exist
/// at once — there is nothing between them to animate — so the animator draws
/// both ends at once. Each window gets one proxy: an SLS window of this
/// process's own, the size of the two frames' union, ordered just above the
/// real window at the real window's level. No SLS moves and no shape changes
/// happen during the glide — the proxy's bounds never change — and each step
/// is a clear-and-draw into the context at the interpolated rectangle: the
/// same offscreen repaint pattern the old border renderer ran per pass, now a
/// bounded few dozen over a bounded few hundred milliseconds, and then
/// nothing (S5: windows this process creates; no privilege, no polling,
/// nothing at rest).
///
/// The capture is `CGWindowListCreateImage`, which answers nothing when
/// Screen Recording is missing — the roadmap item is optional and behind that
/// permission, exactly as it says, and absence degrades to the instant move
/// this file exists to soften.
public final class PlacementAnimator: @unchecked Sendable {
    /// One animated window.
    private struct Item {
        var wid: WindowID          // the window followed; proxy order anchor
        var from: CGRect           // where the real window sat when captured
        var to: CGRect             // where the real window is now
        var union: CGRect          // proxy window bounds: from ∪ to
        var proxy: SLWindowID
        var context: CGContext?
        var image: CGImage
    }

    private var lock = NSLock()
    private let cid = SLSMainConnectionID()
    private var items: [Item] = []
    private var timer: DispatchSourceTimer?
    private var startedAt: UInt64 = 0

    /// Set from the daemon's config. Captures also need Screen Recording —
    /// `CGWindowListCreateImage` answers nil without it, so a config that
    /// asks for animation without the permission degrades to instant.
    public var enabled = false

    public init() {}

    // A glide quick enough to hide a move, slow enough that the steps read as
    // a movement instead of a shimmer. The fade overlaps nothing: the window
    // below has been at its destination since the first step.
    static let moveSeconds = 0.16
    static let fadeSeconds = 0.1
    static let tickInterval = DispatchTimeInterval.milliseconds(9)

    // MARK: The seam

    /// Capture and stage what can be captured; skip silently what cannot
    /// (Screen Recording absent, capture empty, context refused). A movement
    /// under two points of summed delta is not a movement. Runs before the
    /// WindowServer transaction that moves the reals, so the proxies are
    /// already sitting on the old frames when the reals teleport underneath.
    public func prepare(_ todos: [(wid: WindowID, to: Frame)]) {
        guard lock.withLock({ self.enabled }) else { return }
        var staged: [Item] = []
        for (wid, to) in todos {
            var from = CGRect.zero
            guard Self.readBounds(cid, wid, &from) == 0 else { continue }
            let delta = abs(from.minX - to.x) + abs(from.minY - to.y)
                + abs(from.width - to.width) + abs(from.height - to.height)
            guard delta >= 2 else { continue }
            guard Self.sameDisplay(from, Self.rect(to)) else { continue }
            guard let image = Self.snapshot(wid, at: from) else { continue }
            let target = Self.rect(to)
            let union = from.union(target)
            guard let (proxy, context) = makeProxy(cid, union: union, above: wid) else {
                continue
            }
            let item = Item(wid: wid, from: from, to: target, union: union, proxy: proxy, context: context, image: image)
            draw(item, image: image, at: from, alpha: 1.0)
            staged.append(item)
        }
        guard !staged.isEmpty else { return }
        lock.withLock {
            // A burst is replaced by the next one, not queued behind it: the
            // previous glide's proxies are torn down free — the reals are old
            // news anyway, a new burst is a newer answer for the same motion.
            if let t = timer { timer = nil; t.cancel() }
            for item in items {
                SLSOrderWindow(cid, item.proxy, 0, 0)
                SLSReleaseWindow(cid, item.proxy)
            }
            items = staged
        }
    }

    /// Steps the staged glides. Called right after the commit that moved the
    /// real windows; the proxies already show the old frame, so the first
    /// tick finds them in place over the motion they describe.
    public func run() {
        lock.withLock {
            guard !items.isEmpty, timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            t.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
            t.setEventHandler { [weak self] in self?.tick() }
            startedAt = DispatchTime.now().uptimeNanoseconds
            timer = t
            t.resume()
        }
    }

    // MARK: The loop

    private func tick() {
        let t = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
        let eased = 1 - pow(1 - Self.clamp01(t / Self.moveSeconds), 3)
        lock.withLock {
            if t < Self.moveSeconds + Self.fadeSeconds {
                for item in items {
                    let interp = Self.interpolated(item.from, to: item.to, by: eased)
                    let alpha: Double = t > Self.moveSeconds
                        ? max(0, 1 - (t - Self.moveSeconds) / Self.fadeSeconds)
                        : 1.0
                    draw(item, image: item.image, at: interp, alpha: alpha)
                }
            } else {
                releaseLocked()
            }
        }
    }

    // One step: free the previous content, place the image at `at` inside
    // the union's own backing store, in window-local Quartz coordinates
    // (bottom-left origin, the mapping the border renderer's strips used:
    // SLS's top-left frame space becomes Quartz's bottom-up drawing space
    // through the same translate). Stateful context, so every step brackets
    // its transform.
    private func draw(_ item: Item, image: CGImage, at: CGRect, alpha: Double) {
        guard let ctx = item.context else { return }
        if alpha != 1.0 {
            _ = SLSSetWindowAlpha(cid, item.proxy, Double(alpha))
        }
        let u = item.union
        ctx.saveGState()
        ctx.clear(CGRect(x: 0, y: 0, width: u.width, height: u.height))
        ctx.translateBy(
            x: at.minX - u.minX, y: u.height - (at.minY - u.minY) - at.height
        )
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: at.width, height: at.height))
        ctx.flush()
        ctx.restoreGState()
    }

    private func releaseLocked() {
        for item in items {
            SLSOrderWindow(cid, item.proxy, 0, 0)
            SLSReleaseWindow(cid, item.proxy)
        }
        items = []
        if let t = timer { timer = nil; t.cancel() }
    }

    // MARK: One-shot helpers

    /// The window's pixels, as WindowServer has them at this instant: content
    /// only, no shadow, at the frame's bounds. Nil without Screen Recording —
    /// the whole animation degrades to the instant move instead.
    static func snapshot(_ wid: WindowID, at frame: CGRect) -> CGImage? {
        weft_window_capture(
            frame, .optionIncludingWindow, CGWindowID(wid), .bestResolution
        )?.takeRetainedValue()
    }

    /// A non-interactive proxy at `union`, ordered just above `above`, at
    /// `above`'s level, unhittable like the old border renderer's pieces —
    /// bits 1 and 9 take the window out of hit testing. Prepared before the
    /// reals move: the proxy must already be covering whatever is underneath.
    private func makeProxy(_ cid: SLConnectionID, union: CGRect, above: WindowID)
        -> (SLWindowID, CGContext?)?
    {
        var level: Int32 = 0
        _ = SLSGetWindowLevel(cid, SLWindowID(above), &level)
        var proxy: SLWindowID = 0
        var one = [CGRect(x: 0, y: 0, width: union.width, height: union.height)]
        guard weft_region_window_create(
            cid, CGPoint(x: union.minX, y: union.minY), &one, 1, &proxy
        ) == 0, proxy != 0 else { return nil }
        var tags: UInt64 = (1 << 1) | (1 << 9)
        _ = SLSSetWindowTags(cid, proxy, &tags, 64)
        _ = SLSSetWindowLevel(cid, proxy, level)
        _ = SLSOrderWindow(cid, proxy, 1, SLWindowID(above))
        let context = unsafeBitCast(
            SLWindowContextCreate(cid, proxy, nil), to: CGContext?.self
        )
        return (proxy, context)
    }

    /// `SLSGetWindowBounds` with its error code standing duty as "this
    /// window is momentarily unreadable and gets no glide".
    static func readBounds(_ cid: SLConnectionID, _ wid: WindowID, _ out: inout CGRect) -> Int32 {
        SLSGetWindowBounds(cid, SLWindowID(wid), &out)
    }

    /// A move between displays has no glide worth drawing: its union spans
    /// both screens, the proxy would sweep a full-screen-wide sheet across
    /// the desktop between them, and a window headed for another display is
    /// usually one the user sent off this one on purpose — the from frame can
    /// also be a stale park position (a window the daemon could not place),
    /// which reads as a cross-display move without being one. Skip those.
    static func sameDisplay(_ a: CGRect, _ b: CGRect) -> Bool {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &displays, &count) == .success, count > 0 else {
            return true
        }
        func display(_ r: CGRect) -> CGDirectDisplayID? {
            displays.first { CGDisplayBounds($0).intersects(r) }
        }
        if let d = display(a) { return d == display(b) }
        return display(b) == nil
    }

    static func rect(_ f: Frame) -> CGRect {
        CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
    }

    static func clamp01(_ v: Double) -> Double {
        v < 0 ? 0 : (v > 1 ? 1 : v)
    }

    static func interpolated(_ c: CGRect, to toRect: CGRect, by t: Double) -> CGRect {
        let k = CGFloat(t)
        let nx = c.minX + (toRect.minX - c.minX) * k
        let ny = c.minY + (toRect.minY - c.minY) * k
        let nw = c.width + (toRect.width - c.width) * k
        let nh = c.height + (toRect.height - c.height) * k
        return CGRect(x: nx, y: ny, width: nw, height: nh)
    }
}
