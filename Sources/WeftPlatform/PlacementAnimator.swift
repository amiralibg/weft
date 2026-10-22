import AppKit
import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

/// Placement animations: a rearrangement reads as one movement.
///
/// The real windows cannot be animated. Their frames go through each app's
/// Accessibility queue (on macOS 27 the WindowServer accepts a move of another
/// app's window and does not perform it — PrivateAPI), so they arrive one app
/// at a time, at whatever moment each app answers, and a browser lands its
/// position and its size as two separate steps. Gliding copies of the windows
/// over that, as the first version of this file did, showed both: the copies
/// moving, and the real windows jumping about beside and under them.
///
/// So the animator puts up a *stage* on each display where windows move, and
/// the real rearrangement happens behind it:
///
/// - a backdrop — the desktop itself (wallpaper and icons, captured once per
///   display and kept), shaped to just the places the moving windows pass
///   through, with holes for every other window, which stays real;
/// - one proxy per moving window — its pixels and its own shadow, drawn once
///   and moved and scaled by the compositor (a window transform per refresh,
///   nothing redrawn), on a critically damped spring;
///
/// The stage sits one level above ordinary windows, so a raise or a focus
/// change behind it cannot poke a real window through. It stays up until the
/// glide has settled *and* every real window has reported landing on the
/// frame its proxy shows (`markLanded`), then fades out over them as one
/// crossfade. An app that never answers holds it for at most `holdLimit`.
///
/// A new placement while a stage is up retargets it: the proxies keep their
/// position and velocity and swing to the new frames, so a key held down or
/// pressed twice reads as one continuous motion rather than a restart.
///
/// Needs Screen Recording for the captures; without it, with Reduce Motion
/// on, or with `enabled` off, placements are instant.
public final class PlacementAnimator: @unchecked Sendable {
    /// Set from the daemon's config.
    public var enabled = false {
        didSet { if enabled && !oldValue { prewarm() } }
    }

    public init() {}

    // MARK: Tuning

    /// Spring response: the period of the undamped oscillation. Critically
    /// damped, so it never overshoots; at 0.2 s a move is visually done in
    /// about 0.2 s and the tail is under a point by 0.3 s.
    static let response = 0.2
    static var omega: Double { 2 * Double.pi / response }
    /// How long the stage fades once the reals are in place. Short, and front
    /// loaded (`fadeAlpha`): the proxy is a snapshot, and a window that drew
    /// something new or reflowed to its new size meanwhile shows through it
    /// doubled for as long as both are visible.
    static let fadeSeconds = 0.09
    /// The real windows' grace after the last one reported landing: the app
    /// has accepted the frame but may not have painted its relayout yet.
    static let landedGrace = 0.035
    /// The longest a stage waits for a real window that never reports.
    static let holdLimit = 0.7
    /// Room around a window's frame for its shadow in the capture.
    static let shadowPad: CGFloat = 40

    // MARK: State

    private let lock = NSLock()
    private let cid = SLSMainConnectionID()
    private var stages: [CGDirectDisplayID: Stage] = [:]

    private struct Piece {
        var wid: SLWindowID
        var context: CGContext?
    }

    private struct Proxy {
        var piece: Piece
        /// The frame the image was captured at (no shadow room).
        var captured: CGRect
        /// Where the proxy shows the window now, and where it is headed.
        var current: CGRect
        var target: CGRect
        var velocity: (x: Double, y: Double, w: Double, h: Double) = (0, 0, 0, 0)
        /// The real window has reported landing on `target`.
        var landed = false
        var settled = false
    }

    private final class Stage {
        let display: CGDirectDisplayID
        let bounds: CGRect
        let scale: Double
        var backdrop: Piece
        /// What the backdrop covers, in global space.
        var shape: [CGRect] = []
        var proxies: [WindowID: Proxy] = [:]
        /// Back to front.
        var order: [WindowID] = []
        var link: OpaquePointer?
        var lastTick: Double
        var heldSince: Double
        var landedAt: Double?
        var fadeStart: Double?

        init(display: CGDirectDisplayID, bounds: CGRect, scale: Double, backdrop: Piece, now: Double) {
            self.display = display
            self.bounds = bounds
            self.scale = scale
            self.backdrop = backdrop
            self.lastTick = now
            self.heldSince = now
        }

        var pieces: [SLWindowID] {
            [backdrop.wid] + order.compactMap { proxies[$0]?.piece.wid }
        }
    }

    // MARK: The seam

    /// Put up (or retarget) the stage for a placement, before any real window
    /// is written. `todos` are the windows about to be written; `settled` are
    /// windows the placement leaves where they already are — a proxy showing
    /// one of those swings back to it and needs no landing report.
    public func prepare(_ todos: [(wid: WindowID, to: Frame)], settled: [WindowID: Frame] = [:]) {
        guard enabled, !todos.isEmpty || !settled.isEmpty else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return }
        let t0 = Self.now()
        let screen = OnScreen.read()
        let displays = Self.activeDisplays()
        let writing = Set(todos.map(\.wid))

        // Movers by display: on screen at an ordinary level, really moving,
        // and staying on the display they are on.
        var movers: [CGDirectDisplayID: [(wid: WindowID, from: CGRect, to: CGRect)]] = [:]
        for (wid, to) in todos {
            guard let w = screen.windows[wid], w.layer == 0 else { continue }
            let target = Self.rect(to)
            guard let d = Self.display(of: w.bounds, in: displays),
                  Self.display(of: target, in: displays) == d
            else { continue }
            movers[d, default: []].append((wid, w.bounds, target))
        }

        // Retargets first: a live stage holding some of these windows.
        var fresh: [CGDirectDisplayID: [(wid: WindowID, from: CGRect, to: CGRect)]] = [:]
        lock.withLock {
            for (wid, frame) in settled {
                for stage in stages.values where stage.fadeStart == nil && stage.proxies[wid] != nil {
                    retargetLocked(stage, wid, to: Self.rect(frame), landed: true, now: t0)
                }
            }
            for (d, list) in movers {
                if let stage = stages[d], stage.fadeStart != nil { releaseLocked(stage) }
                if let stage = stages[d] {
                    var rest: [(wid: WindowID, from: CGRect, to: CGRect)] = []
                    for m in list {
                        if stage.proxies[m.wid] != nil {
                            retargetLocked(stage, m.wid, to: m.to, landed: false, now: t0)
                        } else {
                            rest.append(m)
                        }
                    }
                    if !rest.isEmpty { fresh[d] = rest }
                } else if list.contains(where: { Self.delta($0.from, $0.to) >= 2 }) {
                    // Every window written here gets a proxy, the ones that
                    // barely move too: the backdrop leaves them all out.
                    fresh[d] = list
                }
            }
        }

        // New proxies and their backdrop, captured off the lock.
        for (d, list) in fresh {
            let existing: Set<WindowID> = lock.withLock { stages[d].map { Set($0.proxies.keys) } ?? [] }
            let staged = existing.union(list.map(\.wid)).union(writing)
            let tc = Self.now()
            guard let built = capture(display: d, displays: displays, screen: screen, movers: list,
                                      staged: staged)
            else { continue }
            Trace.record("anim.capture", ms: (Self.now() - tc) * 1000, detail: "\(list.count) window(s)")
            lock.withLock { install(built, display: d, now: t0) }
        }
        let n = fresh.values.reduce(0) { $0 + $1.count }
        if n > 0 { Trace.record("anim.stage", ms: (Self.now() - t0) * 1000, detail: "\(n) window(s)") }
    }

    /// A real window's write for `frame` has finished — landed or refused;
    /// either way there is nothing more to wait for.
    public func markLanded(_ wid: WindowID, frame: Frame) {
        let f = Self.rect(frame)
        lock.withLock {
            for stage in stages.values {
                guard var p = stage.proxies[wid], Self.delta(p.target, f) < 2 else { continue }
                p.landed = true
                stage.proxies[wid] = p
            }
        }
    }

    /// Drop every stage now: an interactive drag moves the reals itself.
    public func cancelAll() {
        lock.withLock { for stage in stages.values { releaseLocked(stage) } }
    }

    // MARK: Building a stage

    private struct Captured {
        var bounds: CGRect
        var scale: Double
        var backdrop: Piece
        var shape: [CGRect]
        var proxies: [(wid: WindowID, from: CGRect, to: CGRect, piece: Piece)]
    }

    /// The desktop of each display — wallpaper and icons, no windows — kept
    /// decoded. It is the backdrop of every stage there, and it is the one
    /// capture big enough to cost: a whole Retina display taken and decoded is
    /// some 40 ms, against about one to draw it once it is in memory.
    private struct Desktop {
        var ids: [WindowID]
        var image: CGImage
        var at: Double
    }
    private var desktops: [CGDirectDisplayID: Desktop] = [:]
    private let desktopLock = NSLock()
    /// A cached desktop older than this is refreshed after the stage that
    /// used it: dynamic wallpapers drift, and icons come and go.
    static let desktopMaxAge = 30.0

    /// Capture and decode every display's desktop now, off the caller's
    /// thread: on a display change, on a desktop switch, and when animation
    /// is turned on, so the first stage after them does not pay for it.
    public func prewarm() {
        guard enabled else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            let screen = OnScreen.read()
            for d in Self.activeDisplays() { _ = desktop(of: d.id, bounds: d.bounds, screen: screen, fresh: true) }
        }
    }

    private func desktop(of display: CGDirectDisplayID, bounds: CGRect, screen: OnScreen, fresh: Bool = false) -> CGImage? {
        let ids = screen.ordered.filter { $0.layer < 0 && $0.bounds.intersects(bounds) }.map(\.wid)
        if !fresh, let cached = desktopLock.withLock({ desktops[display] }), cached.ids == ids {
            if Self.now() - cached.at > Self.desktopMaxAge { prewarm() }
            return cached.image
        }
        let raw = ids.map { CGWindowID($0) }.withUnsafeBufferPointer {
            weft_windows_composite(bounds, $0.baseAddress, Int32($0.count))?.takeRetainedValue()
        }
        guard let raw, let image = Self.decoded(raw) else { return nil }
        desktopLock.withLock { desktops[display] = Desktop(ids: ids, image: image, at: Self.now()) }
        return image
    }

    /// Everything a stage needs on `display`, or nil when any of it cannot be
    /// captured — a stage missing a window would show a hole where it was.
    private func capture(
        display: CGDirectDisplayID,
        displays: [(id: CGDirectDisplayID, bounds: CGRect)],
        screen: OnScreen,
        movers: [(wid: WindowID, from: CGRect, to: CGRect)],
        staged: Set<WindowID>
    ) -> Captured? {
        guard let bounds = displays.first(where: { $0.id == display })?.bounds else { return nil }
        let scale = Self.scale(of: display)

        // The backdrop covers only where a moving window's real self can be
        // seen on its way: where it was, where it goes, and the two frames in
        // between that an Accessibility write passes through (new origin at
        // the old size, or old origin at the new size). Every other window
        // keeps showing, real, through the holes left for it.
        var cover: [CGRect] = []
        for m in movers {
            for r in [m.from, m.to,
                      CGRect(origin: m.to.origin, size: m.from.size),
                      CGRect(origin: m.from.origin, size: m.to.size)] {
                let padded = r.insetBy(dx: -Self.shadowPad, dy: -Self.shadowPad).intersection(bounds)
                if !padded.isEmpty { cover.append(padded) }
            }
        }
        let others = screen.ordered.filter {
            $0.layer == 0 && !staged.contains($0.wid) && $0.bounds.intersects(bounds)
        }
        for w in others { cover = cover.flatMap { Self.subtract(w.bounds, from: $0) } }
        // A stage that grows gets a new backdrop shaped to everything it now
        // covers.
        let shape = lock.withLock { stages[display].map(\.shape) ?? [] } + cover

        // Every piece is captured, created and drawn on its own thread, all at
        // once. The first draw into a new window costs about as much as the
        // capture (the compositor's backing store is touched for the first
        // time), and a burst of four windows done one after another was the
        // better part of a tenth of a second before anything moved.
        let pieces = Pieces(count: movers.count + 1)
        func build(_ i: Int) {
            let t = Self.now()
            if i == movers.count {
                guard let desktop = desktop(of: display, bounds: bounds, screen: screen) else { return }
                let td = Self.now()
                Trace.record("anim.desktop", ms: (td - t) * 1000)
                pieces[i] = makeBackdrop(shape: shape, bounds: bounds, scale: scale, desktop: desktop)
                Trace.record("anim.backdrop", ms: (Self.now() - td) * 1000)
                return
            }
            let m = movers[i]
            let padded = m.from.insetBy(dx: -Self.shadowPad, dy: -Self.shadowPad)
            guard let image = weft_window_capture(
                padded, .optionIncludingWindow, CGWindowID(m.wid), .bestResolution
            )?.takeRetainedValue() else { return }
            let tw = Self.now()
            Trace.record("anim.grab", ms: (tw - t) * 1000, detail: "\(m.wid)")
            pieces[i] = makePiece(at: padded, scale: scale, image: image)
            Trace.record("anim.copy", ms: (Self.now() - tw) * 1000, detail: "\(m.wid)")
        }
        DispatchQueue.concurrentPerform(iterations: movers.count + 1) { build($0) }
        let made = (0...movers.count).map { pieces[$0] }
        guard let backdrop = made[movers.count], made.dropLast().allSatisfy({ $0 != nil }) else {
            for piece in made.compactMap({ $0 }) { SLSReleaseWindow(cid, piece.wid) }
            return nil
        }
        var proxies: [(wid: WindowID, from: CGRect, to: CGRect, piece: Piece)] = []
        for (i, m) in movers.enumerated() { proxies.append((m.wid, m.from, m.to, made[i]!)) }
        // Back to front, the order they will be stacked in.
        proxies.sort { (screen.windows[$0.wid]?.index ?? 0) > (screen.windows[$1.wid]?.index ?? 0) }
        return Captured(bounds: bounds, scale: scale, backdrop: backdrop, shape: shape, proxies: proxies)
    }

    /// Create the windows for `c` (or add them to the live stage), draw every
    /// one *before* it is ordered in — a window ordered in empty shows white
    /// for as long as its first draw takes — and order the lot in one
    /// synchronous transaction, so the stage is on the glass before any real
    /// window is written.
    private func install(_ c: Captured, display: CGDirectDisplayID, now: Double) {
        let live = stages[display].flatMap { $0.fadeStart == nil ? $0 : nil }
        if live == nil, let old = stages[display] { releaseLocked(old) }
        let stage: Stage
        var retired: Piece?
        if let live {
            stage = live
            // The old backdrop goes once the new one is ordered in over it.
            retired = live.backdrop
            stage.backdrop = c.backdrop
        } else {
            stage = Stage(display: display, bounds: c.bounds, scale: c.scale, backdrop: c.backdrop, now: now)
            stages[display] = stage
        }
        stage.shape = c.shape
        for p in c.proxies {
            stage.proxies[p.wid] = Proxy(piece: p.piece, captured: p.from, current: p.from, target: p.to)
            stage.order.append(p.wid)
        }
        stage.heldSince = now
        stage.landedAt = nil
        guard let tx = SLSTransactionCreate(cid) else { releaseLocked(stage); return }
        var below: SLWindowID = 0
        for wid in stage.pieces {
            SLSTransactionOrderWindow(tx, wid, 1, below)
            below = wid
        }
        for wid in stage.order { if let p = stage.proxies[wid] { setTransform(tx, p) } }
        SLSTransactionCommit(tx, 1)
        if let retired {
            SLSOrderWindow(cid, retired.wid, 0, 0)
            SLSReleaseWindow(cid, retired.wid)
        }
        if stage.link == nil {
            let me = Unmanaged.passUnretained(self).toOpaque()
            stage.link = weft_display_link_start(display, { context, display in
                guard let context else { return }
                Unmanaged<PlacementAnimator>.fromOpaque(context).takeUnretainedValue().tick(display)
            }, me)
            // No clock for this display: no glide either.
            if stage.link == nil { releaseLocked(stage) }
        }
    }

    /// The backdrop: one window over the bounding box of `shape`, shaped to
    /// it, showing the display's desktop in place.
    private func makeBackdrop(shape: [CGRect], bounds: CGRect, scale: Double, desktop: CGImage) -> Piece? {
        guard let box = shape.reduce(nil as CGRect?, { $0?.union($1) ?? $1 }), !box.isEmpty else { return nil }
        var local = shape.map { $0.offsetBy(dx: -box.minX, dy: -box.minY) }
        var wid: SLWindowID = 0
        guard weft_region_window_create(cid, box.origin, &local, Int32(local.count), &wid) == 0, wid != 0
        else { return nil }
        configure(wid, scale: scale, space: desktop.colorSpace)
        let context = unsafeBitCast(SLWindowContextCreate(cid, wid, nil), to: CGContext?.self)
        if let ctx = context {
            // Global top-left space to this window's bottom-left drawing space.
            ctx.setBlendMode(.copy)
            ctx.draw(desktop, in: CGRect(
                x: bounds.minX - box.minX, y: box.maxY - bounds.maxY,
                width: bounds.width, height: bounds.height
            ))
            ctx.flush()
        }
        return Piece(wid: wid, context: context)
    }

    /// `r` less `hole`, as up to four rectangles.
    static func subtract(_ hole: CGRect, from r: CGRect) -> [CGRect] {
        let h = hole.intersection(r)
        guard !h.isEmpty else { return [r] }
        var out: [CGRect] = []
        if h.minY > r.minY { out.append(CGRect(x: r.minX, y: r.minY, width: r.width, height: h.minY - r.minY)) }
        if h.maxY < r.maxY { out.append(CGRect(x: r.minX, y: h.maxY, width: r.width, height: r.maxY - h.maxY)) }
        if h.minX > r.minX { out.append(CGRect(x: r.minX, y: h.minY, width: h.minX - r.minX, height: h.height)) }
        if h.maxX < r.maxX { out.append(CGRect(x: h.maxX, y: h.minY, width: r.maxX - h.maxX, height: h.height)) }
        return out
    }

    /// An image held in memory in the compositor's own pixel layout, so
    /// drawing it is a copy rather than a readback and a conversion.
    static func decoded(_ image: CGImage) -> CGImage? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// One of weft's own windows at `rect`, one level above ordinary windows,
    /// out of hit testing, not opaque, at the display's backing scale, with
    /// `image` drawn into it. Not yet ordered in.
    private func makePiece(at rect: CGRect, scale: Double, image: CGImage) -> Piece? {
        var wid: SLWindowID = 0
        var shape = [CGRect(x: 0, y: 0, width: rect.width, height: rect.height)]
        guard weft_region_window_create(cid, rect.origin, &shape, 1, &wid) == 0, wid != 0 else { return nil }
        configure(wid, scale: scale, space: image.colorSpace)
        let context = unsafeBitCast(SLWindowContextCreate(cid, wid, nil), to: CGContext?.self)
        let piece = Piece(wid: wid, context: context)
        draw(piece, image, size: rect.size)
        return piece
    }

    private func configure(_ wid: SLWindowID, scale: Double, space: CGColorSpace?) {
        if let space { _ = SLSSetWindowColorSpace(cid, wid, space) }
        var tags: UInt64 = (1 << 1) | (1 << 9)
        _ = SLSSetWindowTags(cid, wid, &tags, 64)
        _ = SLSSetWindowOpacity(cid, wid, false)
        _ = SLSSetWindowResolution(cid, wid, scale)
        _ = SLSSetWindowLevel(cid, wid, Int32(CGWindowLevelForKey(.normalWindow)) + 1)
    }

    private func draw(_ piece: Piece, _ image: CGImage, size: CGSize) {
        guard let ctx = piece.context else { return }
        // A new window: nothing to clear, and nothing to blend with — a
        // straight copy is the cheapest draw there is.
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.flush()
    }

    // MARK: Motion

    private func retargetLocked(_ stage: Stage, _ wid: WindowID, to: CGRect, landed: Bool, now: Double) {
        guard var p = stage.proxies[wid] else { return }
        if Self.delta(p.target, to) >= 1 { p.settled = false }
        p.target = to
        p.landed = landed
        stage.proxies[wid] = p
        stage.heldSince = now
        stage.landedAt = nil
    }

    private func tick(_ display: UInt32) {
        lock.withLock {
            guard let stage = stages[display] else { return }
            let now = Self.now()
            let dt = min(max(now - stage.lastTick, 0), 1.0 / 30)
            stage.lastTick = now

            if let fadeStart = stage.fadeStart {
                let k = min(1, (now - fadeStart) / Self.fadeSeconds)
                guard k < 1, let tx = SLSTransactionCreate(cid) else { releaseLocked(stage); return }
                let alpha = Float((1 - k) * (1 - k))
                for wid in stage.pieces { SLSTransactionSetWindowAlpha(tx, wid, alpha) }
                SLSTransactionCommit(tx, 0)
                return
            }

            var moving = false
            let tx = SLSTransactionCreate(cid)
            for wid in stage.order {
                guard var p = stage.proxies[wid], !p.settled else { continue }
                Self.step(&p, dt: dt)
                stage.proxies[wid] = p
                if let tx { setTransform(tx, p) }
                if !p.settled { moving = true }
            }
            if let tx { SLSTransactionCommit(tx, 0) }

            let allLanded = stage.proxies.values.allSatisfy(\.landed)
            if allLanded, stage.landedAt == nil { stage.landedAt = now }
            guard !moving else { return }
            let ready = allLanded && now - (stage.landedAt ?? now) >= Self.landedGrace
            guard ready || now - stage.heldSince > Self.holdLimit else { return }
            stage.fadeStart = now
            // The backdrop goes at once, not with the fade. Every real window
            // is in place now, so outside the proxies it shows what the
            // screen shows anyway; fading it would bleed the old desktop
            // through the proxies as they turn translucent.
            SLSOrderWindow(cid, stage.backdrop.wid, 0, 0)
        }
    }

    /// Advance one proxy's spring by `dt`: each of x, y, width and height is
    /// a critically damped spring towards the target, solved exactly over the
    /// step, so an uneven step costs no accuracy and no stability.
    private static func step(_ p: inout Proxy, dt: Double) {
        let w = omega
        let e = exp(-w * dt)
        func channel(_ cur: CGFloat, _ target: CGFloat, _ v: Double) -> (CGFloat, Double) {
            let x0 = Double(cur - target)
            let c = v + w * x0
            return (target + CGFloat((x0 + c * dt) * e), (v - w * c * dt) * e)
        }
        let (x, vx) = channel(p.current.minX, p.target.minX, p.velocity.x)
        let (y, vy) = channel(p.current.minY, p.target.minY, p.velocity.y)
        let (width, vw) = channel(p.current.width, p.target.width, p.velocity.w)
        let (height, vh) = channel(p.current.height, p.target.height, p.velocity.h)
        p.current = CGRect(x: x, y: y, width: max(1, width), height: max(1, height))
        p.velocity = (vx, vy, vw, vh)
        if delta(p.current, p.target) < 0.5, abs(vx) + abs(vy) + abs(vw) + abs(vh) < 4 {
            p.current = p.target
            p.velocity = (0, 0, 0, 0)
            p.settled = true
        }
    }

    /// The compositor transform that shows a proxy's capture at `current`:
    /// global space to window space, the shadow room scaled with the window.
    private func setTransform(_ tx: CFTypeRef, _ p: Proxy) {
        let sx = p.current.width / p.captured.width
        let sy = p.current.height / p.captured.height
        let t = CGAffineTransform(translationX: -p.current.minX, y: -p.current.minY)
            .concatenating(CGAffineTransform(scaleX: 1 / sx, y: 1 / sy))
            .concatenating(CGAffineTransform(translationX: Self.shadowPad, y: Self.shadowPad))
        SLSTransactionSetWindowTransform(tx, p.piece.wid, 0, 0, t)
    }

    private func releaseLocked(_ stage: Stage) {
        for wid in stage.pieces {
            SLSOrderWindow(cid, wid, 0, 0)
            SLSReleaseWindow(cid, wid)
        }
        if stages[stage.display] === stage { stages.removeValue(forKey: stage.display) }
        if let link = stage.link {
            stage.link = nil
            nonisolated(unsafe) let link = link
            // Never from the link's own thread, which is where this usually
            // runs: stopping waits for the callback in progress.
            DispatchQueue.global(qos: .utility).async { weft_display_link_stop(link) }
        }
    }

    // MARK: Helpers

    /// The pieces of one stage, made on several threads at once.
    private final class Pieces: @unchecked Sendable {
        private let lock = NSLock()
        private var pieces: [Piece?]
        init(count: Int) { pieces = Array(repeating: nil, count: count) }
        subscript(i: Int) -> Piece? {
            get { lock.withLock { pieces[i] } }
            set { lock.withLock { pieces[i] = newValue } }
        }
    }

    /// The on-screen windows, front to back, as the public list has them.
    private struct OnScreen {
        struct Window {
            var wid: WindowID
            var index: Int
            var layer: Int
            var bounds: CGRect
        }
        var ordered: [Window] = []
        var windows: [WindowID: Window] = [:]

        static func read() -> OnScreen {
            var out = OnScreen()
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            for (i, info) in list.enumerated() {
                guard let n = info[kCGWindowNumber as String] as? NSNumber,
                      let layer = info[kCGWindowLayer as String] as? Int,
                      let dict = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: dict)
                else { continue }
                let w = Window(wid: WindowID(n.uint32Value), index: i, layer: layer, bounds: bounds)
                out.ordered.append(w)
                out.windows[w.wid] = w
            }
            return out
        }
    }

    static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    static func activeDisplays() -> [(id: CGDirectDisplayID, bounds: CGRect)] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) }
    }

    /// The display holding most of `r`: its centre, or failing that any overlap.
    static func display(of r: CGRect, in displays: [(id: CGDirectDisplayID, bounds: CGRect)]) -> CGDirectDisplayID? {
        let centre = CGPoint(x: r.midX, y: r.midY)
        return displays.first { $0.bounds.contains(centre) }?.id
            ?? displays.first { $0.bounds.intersects(r) }?.id
    }

    static func scale(of display: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return 1 }
        return max(1, Double(mode.pixelWidth) / Double(mode.width))
    }

    static func rect(_ f: Frame) -> CGRect {
        CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
    }

    /// Summed edge distance between two frames.
    static func delta(_ a: CGRect, _ b: CGRect) -> Double {
        // Summed term by term: as one expression, CI's compiler gave up
        // type-checking it.
        let origin: CGFloat = abs(a.minX - b.minX) + abs(a.minY - b.minY)
        let size: CGFloat = abs(a.width - b.width) + abs(a.height - b.height)
        return Double(origin + size)
    }
}
