import AppKit
import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

/// Weft's own window borders.
///
/// The alternative is JankyBorders, and running it alongside weft has two
/// problems that are not JankyBorders' fault:
///
/// 1. **It has to guess.** It watches the WindowServer for anything that looks
///    like a window and draws a rectangle around it, so a menu-bar extra's
///    popover, a Spotlight panel and a screenshot overlay all get borders —
///    and there is nothing in the notification stream that distinguishes them
///    from a real window. Weft does not have to guess: a window has a border
///    exactly when it is in a layout, which is a fact weft already owns.
/// 2. **It is always a frame behind.** It learns that a window moved by being
///    told after the fact, then reads the geometry back and repaints. During a
///    drag, when weft is issuing the moves itself, that round trip is pure
///    latency: the border visibly trails the window. Drawing from the same
///    frames weft is about to apply removes the round trip entirely.
///
/// Plus a third that is: it is a second process, and telling it the active
/// colour changed means `fork` + `exec` of a CLI on every focus change.
///
/// Everything here acts on windows this process created, so it needs no
/// privilege weft does not already have and no scripting addition.
public final class BorderRenderer: @unchecked Sendable {
    public struct Style: Sendable, Equatable {
        /// Stroke width in points. The border is painted *outside* the
        /// window, so this never eats into the window's own area.
        public var width: Double
        /// Corner radius of the window itself, in points. macOS rounds a
        /// standard window's corners; a border drawn square around one leaves
        /// four little horns poking past the corner.
        public var radius: Double
        /// 0xAARRGGBB, the format JankyBorders' config uses, so a weft.toml
        /// carried over from it keeps working.
        public var activeColor: UInt32
        public var inactiveColor: UInt32
        /// Draw anything at all around unfocused windows.
        public var showInactive: Bool

        public init(
            width: Double = 4,
            radius: Double = 10,
            activeColor: UInt32 = 0xff7a_a2f7,
            inactiveColor: UInt32 = 0x4041_4868,
            showInactive: Bool = true
        ) {
            self.width = width
            self.radius = radius
            self.activeColor = activeColor
            self.inactiveColor = inactiveColor
            self.showInactive = showInactive
        }
    }

    /// One overlay window, and everything about it that decides whether it
    /// needs touching again.
    private struct Overlay {
        var wid: SLWindowID
        /// The *target* window's frame, not the overlay's.
        var target: Frame
        var color: UInt32
        var scale: Double
        var style: Style
        var context: CGContext?
    }

    private let cid: SLConnectionID
    private let lock = NSLock()
    private var overlays: [WindowID: Overlay] = [:]
    private var style = Style()
    private var enabled = false
    private var focused: WindowID?
    /// Every SLS call here has to happen in order and none of them may run on
    /// a caller's thread — a drag calls `update` from the mouse queue and an
    /// apply calls it from the apply queue.
    private let queue = DispatchQueue(label: "weft.borders", qos: .userInteractive)

    public init() {
        self.cid = SLSMainConnectionID()
    }

    /// Window ids weft must never treat as windows: our own overlays.
    ///
    /// They are layer-0, larger than 100×100 and owned by a process with no
    /// bundle, so every filter in `WorldReader` waves them through — weft
    /// would tile its own borders, each of which would then get a border.
    public func overlayWindowIDs() -> Set<WindowID> {
        lock.withLock { Set(overlays.values.map { WindowID($0.wid) }) }
    }

    // MARK: - Configuration

    public func setEnabled(_ on: Bool) {
        let changed: Bool = lock.withLock {
            guard enabled != on else { return false }
            enabled = on
            return true
        }
        guard changed else { return }
        if !on { clear() }
    }

    public func setStyle(_ next: Style) {
        let changed: Bool = lock.withLock {
            guard style != next else { return false }
            style = next
            return true
        }
        // Width changes the overlay's geometry, not just its paint, so the
        // cheapest correct answer is to rebuild on the next update.
        if changed { queue.async { self.repaintAll() } }
    }

    /// The colour the focused window's border is drawn in. Layout- and
    /// mode-dependent, so the daemon resolves it and hands the answer over.
    public func setActiveColor(_ color: UInt32) {
        let changed: Bool = lock.withLock {
            guard style.activeColor != color else { return false }
            style.activeColor = color
            return true
        }
        if changed { queue.async { self.repaintAll() } }
    }

    // MARK: - Updating

    /// Draw borders around exactly these windows, and nothing else.
    ///
    /// `frames` is the layout weft is applying, so the border is placed from
    /// the same numbers as the window — not read back from the WindowServer
    /// afterwards, which is what makes a border lag its window during a drag.
    /// `scope` is the set of windows this call speaks for. Nil means all of
    /// them — every overlay not in `frames` is torn down. A drag passes the
    /// windows it is moving, so it does not delete the borders on the other
    /// display along the way.
    public func update(frames: [WindowID: Frame], focused: WindowID?, scope: Set<WindowID>? = nil) {
        let on = lock.withLock {
            self.focused = focused
            return enabled
        }
        guard on else { return }
        queue.async { self.sync(frames: frames, focused: focused, scope: scope) }
    }

    /// Same, keeping whichever window is already the focused one. Used by the
    /// drag path, which changes geometry and nothing else.
    public func update(frames: [WindowID: Frame], scope: Set<WindowID>? = nil) {
        let (on, focus) = lock.withLock { (enabled, focused) }
        guard on else { return }
        let s = scope ?? Set(frames.keys)
        queue.async { self.sync(frames: frames, focused: focus, scope: s) }
    }

    /// Drop every overlay, because whatever they were describing is no longer
    /// on screen. The sweep that follows a space or display change rebuilds
    /// them from the new layout; without this the old space's borders hang
    /// over the new one until it does.
    public func clearOnSpaceChange() {
        guard lock.withLock({ enabled }) else { return }
        clear()
    }

    /// Focus moved but nothing else did: two repaints, not a whole resync.
    public func setFocus(_ wid: WindowID?) {
        let (on, previous) = lock.withLock {
            let old = focused
            focused = wid
            return (enabled, old)
        }
        guard on, previous != wid else { return }
        queue.async {
            for candidate in [previous, wid].compactMap({ $0 }) {
                self.repaint(candidate)
            }
        }
    }

    public func clear() {
        queue.async {
            let dead: [SLWindowID] = self.lock.withLock {
                let ids = self.overlays.values.map { $0.wid }
                self.overlays = [:]
                return ids
            }
            for wid in dead {
                SLSOrderWindow(self.cid, wid, 0, 0)
                SLSReleaseWindow(self.cid, wid)
            }
        }
    }

    // MARK: - The SLS side (always on `queue`)

    private func sync(frames: [WindowID: Frame], focused: WindowID?, scope: Set<WindowID>?) {
        let style = lock.withLock { self.style }
        var known = lock.withLock { Set(self.overlays.keys) }
        if let scope { known.formIntersection(scope) }
        // Windows that left the layout, and windows parked off-screen by the
        // scroll layout — a border sitting at x = −5000 is invisible but it
        // is still a window the compositor has to carry.
        let live = Set(frames.keys)
        for wid in known.subtracting(live) { destroy(wid) }
        for (wid, frame) in frames {
            guard frame.width > 1, frame.height > 1 else {
                destroy(wid)
                continue
            }
            let color = (wid == focused) ? style.activeColor : style.inactiveColor
            place(wid, target: frame, color: color, style: style)
        }
    }

    private func place(_ wid: WindowID, target: Frame, color: UInt32, style: Style) {
        let scale = Self.scaleFactor(for: target)
        let existing = lock.withLock { overlays[wid] }
        guard var overlay = existing else {
            create(wid, target: target, color: color, style: style, scale: scale)
            return
        }
        let sameSize = abs(overlay.target.width - target.width) < 0.5
            && abs(overlay.target.height - target.height) < 0.5
        let samePlace = abs(overlay.target.x - target.x) < 0.5
            && abs(overlay.target.y - target.y) < 0.5
        // A scale change means a different display: the backing store is the
        // wrong resolution and has to be rebuilt, not repainted.
        if abs(overlay.scale - scale) > 0.01 || overlay.style != style {
            destroy(wid)
            create(wid, target: target, color: color, style: style, scale: scale)
            return
        }
        if sameSize && samePlace && overlay.color == color { return }
        let frame = Self.overlayFrame(for: target, style: style)
        if !sameSize {
            // Shape carries the origin too, so this is one call, not a resize
            // followed by a move — and no frame in which the border sits in
            // the corner of the display on its way to the right place.
            weft_border_window_set_frame(cid, overlay.wid, frame)
            // A resized window gets a new backing store, so the old context
            // draws into nothing.
            overlay.context = nil
        } else if !samePlace {
            var origin = frame.origin
            SLSMoveWindow(cid, overlay.wid, &origin)
            if overlay.color == color {
                overlay.target = target
                lock.withLock { overlays[wid] = overlay }
                order(overlay.wid, above: wid)
                return
            }
        }
        overlay.target = target
        overlay.color = color
        lock.withLock { overlays[wid] = overlay }
        draw(wid)
        // Ordering is z-order, and z-order changes under us whenever the user
        // clicks anything. Re-asserting it on every move is one cheap
        // WindowServer call and it is the difference between a border and a
        // border that has slipped behind its own window.
        order(overlay.wid, above: wid)
    }

    private func create(_ wid: WindowID, target: Frame, color: UInt32, style: Style, scale: Double) {
        let frame = Self.overlayFrame(for: target, style: style)
        var overlayWID: SLWindowID = 0
        guard weft_border_window_create(cid, frame, &overlayWID) == 0, overlayWID != 0 else {
            return
        }
        SLSSetWindowResolution(cid, overlayWID, scale)
        // Sticky (bit 11). With two displays the "current" space at creation
        // time is the focused display's, so a border for a window on the
        // *other* monitor would otherwise be filed under a space nobody is
        // looking at and never appear. The bit is silently ignored for other
        // apps' windows without the scripting addition (§S3) — this is our
        // own window, and it costs one call to ask. Stale borders cannot
        // outlive a space switch either way: `clearOnSpaceChange` drops them
        // and the sweep that follows rebuilds them in the right place.
        var tags: UInt64 = 1 << 11
        SLSSetWindowTags(cid, overlayWID, &tags, 64)
        // Not opaque: everything outside the stroke has to stay see-through,
        // or the border is a filled rectangle covering the window.
        SLSSetWindowOpacity(cid, overlayWID, false)
        SLSSetWindowAlpha(cid, overlayWID, 1.0)
        // Click-through. Without it the WindowServer hit-tests the overlay
        // and hands the click to a connection that never reads one, so every
        // click within `width` points of a window edge is silently eaten —
        // including the border drags weft's own mouse handling depends on.
        SLSSetMouseEventEnableFlags(cid, overlayWID, false)
        var level: Int32 = 0
        if SLSGetWindowLevel(cid, SLWindowID(wid), &level) == 0 {
            SLSSetWindowLevel(cid, overlayWID, level)
        }
        lock.withLock {
            overlays[wid] = Overlay(
                wid: overlayWID, target: target, color: color,
                scale: scale, style: style, context: nil
            )
        }
        draw(wid)
        order(overlayWID, above: wid)
    }

    private func destroy(_ wid: WindowID) {
        let dead: SLWindowID? = lock.withLock {
            guard let overlay = overlays.removeValue(forKey: wid) else { return nil }
            return overlay.wid
        }
        if let dead {
            SLSOrderWindow(cid, dead, 0, 0)
            SLSReleaseWindow(cid, dead)
        }
    }

    /// Put the overlay directly above the window it belongs to.
    ///
    /// Not simply "at the front": in a stack, and with a float overlapping a
    /// tile, the front is the wrong place — the unfocused window underneath
    /// would have its border painted over the window on top of it.
    private func order(_ overlayWID: SLWindowID, above wid: WindowID) {
        if SLSOrderWindow(cid, overlayWID, 1, SLWindowID(wid)) != 0 {
            // Relative ordering can be refused (it is the same privileged
            // call that blocks reordering another app's windows). Ordering
            // ourselves in absolutely still beats not being visible.
            SLSOrderWindow(cid, overlayWID, 1, 0)
        }
    }

    private func repaint(_ wid: WindowID) {
        let (snapshot, style, focus) = lock.withLock {
            (overlays[wid], self.style, self.focused)
        }
        guard var overlay = snapshot else { return }
        let isFocused = (wid == focus)
        let color = isFocused ? style.activeColor : style.inactiveColor
        guard overlay.color != color || !style.showInactive else { return }
        overlay.color = color
        lock.withLock { overlays[wid] = overlay }
        draw(wid)
        // Focus raises the window, which puts it above its own border. This
        // is only visible where windows overlap — a float over a tile, a
        // stack — but that is exactly where focus changes most.
        if isFocused {
            order(overlay.wid, above: wid)
        }
    }

    private func repaintAll() {
        let (targets, style, focus) = lock.withLock {
            (overlays.mapValues { $0.target }, self.style, self.focused)
        }
        // Style changes move the geometry, so this is a full resync rather
        // than a repaint. It runs on a config reload, not on a drag.
        _ = style
        sync(frames: targets, focused: focus, scope: nil)
    }

    private func draw(_ wid: WindowID) {
        let (snapshot, currentFocus) = lock.withLock { (overlays[wid], self.focused) }
        guard var overlay = snapshot else { return }
        let context: CGContext
        if let cached = overlay.context {
            context = cached
        } else {
            guard let fresh = SLWindowContextCreate(cid, overlay.wid, nil) else { return }
            context = fresh
            overlay.context = fresh
            lock.withLock { overlays[wid] = overlay }
        }
        let style = overlay.style
        let frame = Self.overlayFrame(for: overlay.target, style: style)
        let bounds = CGRect(origin: .zero, size: frame.size)
        context.clear(bounds)
        let isFocused = (wid == currentFocus)
        if (!style.showInactive && !isFocused) || style.width <= 0 {
            context.flush()
            return
        }
        // Painted just outside the window: the stroke is centred on a rect
        // half a line width outside the window's own edge, so it runs from
        // the edge to `width` points beyond it and covers nothing.
        let inset = style.width / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = max(0, style.radius + inset)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: min(radius, rect.width / 2),
            cornerHeight: min(radius, rect.height / 2),
            transform: nil
        )
        context.setLineWidth(style.width)
        context.setStrokeColor(Self.cgColor(overlay.color))
        context.addPath(path)
        context.strokePath()
        context.flush()
    }

    // MARK: - Geometry

    /// The overlay covers the window plus `width` points on every side.
    static func overlayFrame(for target: Frame, style: Style) -> CGRect {
        CGRect(
            x: target.x - style.width,
            y: target.y - style.width,
            width: target.width + style.width * 2,
            height: target.height + style.width * 2
        )
    }

    /// Backing scale of the display the window is on. A border rendered at 1x
    /// on a retina display is the one thing about a border anyone notices.
    static func scaleFactor(for target: Frame) -> Double {
        let centre = CGPoint(x: target.x + target.width / 2, y: target.y + target.height / 2)
        let screens = NSScreen.screens
        let primaryHeight = screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? screens.first?.frame.height ?? 0
        for screen in screens {
            // NSScreen is bottom-left origin; SLS frames are top-left.
            let f = screen.frame
            let flipped = CGRect(
                x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height
            )
            if flipped.contains(centre) { return Double(screen.backingScaleFactor) }
        }
        return Double(screens.first?.backingScaleFactor ?? 2.0)
    }

    /// 0xAARRGGBB → CGColor, the format JankyBorders takes.
    static func cgColor(_ argb: UInt32) -> CGColor {
        CGColor(
            red: CGFloat((argb >> 16) & 0xff) / 255,
            green: CGFloat((argb >> 8) & 0xff) / 255,
            blue: CGFloat(argb & 0xff) / 255,
            alpha: CGFloat((argb >> 24) & 0xff) / 255
        )
    }

    /// Parse `0xaarrggbb` / `#aarrggbb` / `#rrggbb`. Nil when it is not one.
    public static func parseColor(_ text: String) -> UInt32? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) }
        else if s.hasPrefix("#") { s.removeFirst(1) }
        guard let value = UInt32(s, radix: 16) else { return nil }
        // #rrggbb without alpha → default to opaque (0xff...)
        if s.count == 6 { return 0xff00_0000 | value }
        if s.count == 8 { return value }
        return nil
    }
}
