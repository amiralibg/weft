import AppKit
import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

/// Weft's own window borders.
///
/// Drawn from the frames weft is applying, so a border never trails its
/// window the way a separate process's does: that process learns a window
/// moved by being told afterwards and reading the geometry back. And weft
/// already knows which windows are windows — a border exists exactly when a
/// window is in a layout — so popovers, Spotlight and screenshot overlays
/// never get one.
///
/// Built to cost as little as possible, in this order:
/// - **Area.** Each border is a handful of windows covering only the ring
///   (`BorderGeometry`), never the window itself. The renderer removed in
///   0.7.4 put a full-window transparent overlay over every window and cost
///   16pp of GPU for it.
/// - **Blending.** Straight strips are a solid fill, and an opaque one when
///   the colour has no transparency, so the compositor copies instead of
///   blending. Only the four small corners are ever transparent.
/// - **Work per change.** A move is one WindowServer transaction for every
///   border at once, with no repaint. A resize reshapes the four strips and
///   moves the corners. A colour change repaints. Nothing runs when nothing
///   changed, and bursts of updates collapse into one pass.
/// - **Windows.** With inactive borders off, focus moving to another window
///   moves the one border there instead of tearing it down and building
///   another.
///
/// Everything here acts on windows this process creates, so it needs no
/// privilege weft does not already have and no scripting addition.
public final class BorderRenderer: @unchecked Sendable {
    public struct Style: Sendable, Equatable {
        /// Points, drawn outside the window.
        public var width: Double
        /// Fixed corner radius. Nil follows each window's own corners.
        public var radius: Double?
        public var square: Bool
        /// 0xAARRGGBB.
        public var activeColor: UInt32
        public var inactiveColor: UInt32
        public var showInactive: Bool

        public init(
            width: Double = 2, radius: Double? = nil, square: Bool = false,
            activeColor: UInt32 = 0xff7a_a2f7, inactiveColor: UInt32 = 0x4041_4868,
            showInactive: Bool = true
        ) {
            self.width = width
            self.radius = radius
            self.square = square
            self.activeColor = activeColor
            self.inactiveColor = inactiveColor
            self.showInactive = showInactive
        }

        /// Everything but the colours: a change here moves every piece.
        fileprivate func sameGeometry(as other: Style) -> Bool {
            width == other.width && radius == other.radius && square == other.square
        }
    }

    private struct Piece {
        var wid: SLWindowID
        var frame: Frame
        var isStrip: Bool
        var opaque: Bool
        var context: CGContext?
    }

    private struct Border {
        var target: Frame
        var color: UInt32
        var radius: Double
        var scale: Double
        var pieces: [Piece]
    }

    private let cid = SLSMainConnectionID()
    private let queue = DispatchQueue(label: "weft.borders", qos: .userInteractive)

    // Wanted state: written from any thread, under `lock`.
    private let lock = NSLock()
    private var wantedStyle: Style?
    private var wantedFrames: [WindowID: Frame] = [:]
    private var wantedFocus: WindowID?
    /// The frame weft last asked each window for.
    private var lastTargets: [WindowID: Frame] = [:]
    /// Where a window settled instead, and the target it settled against.
    private var observed: [WindowID: (actual: Frame, target: Frame)] = [:]
    private var scheduled = false
    private var screensStale = true

    // Drawn state: touched only on `queue`.
    private var borders: [WindowID: Border] = [:]
    private var drawnStyle: Style?
    private var raisedFocus: WindowID?
    private var screens: [(frame: Frame, scale: Double)] = []

    public init() {}

    // MARK: - Wanted state

    /// Nil turns borders off and releases every window.
    public func setStyle(_ style: Style?) {
        lock.withLock { wantedStyle = style }
        schedule()
    }

    /// The focused window's colour, which follows layout and mode.
    public func setActiveColor(_ argb: UInt32) {
        let changed: Bool = lock.withLock {
            guard wantedStyle != nil, wantedStyle?.activeColor != argb else { return false }
            wantedStyle?.activeColor = argb
            return true
        }
        if changed { schedule() }
    }

    /// Borders around exactly these windows — the visible layouts — and no
    /// others. `frames` are the ones weft is applying.
    public func update(frames: [WindowID: Frame], focused: WindowID?) {
        lock.withLock {
            var resolved = frames
            for (wid, target) in frames {
                if let o = observed[wid], Self.close(o.target, target) { resolved[wid] = o.actual }
            }
            observed = observed.filter { frames[$0.key] != nil }
            lastTargets = frames
            wantedFrames = resolved
            wantedFocus = focused
        }
        schedule()
    }

    /// New frames for windows already bordered, mid-gesture. Windows not in
    /// `moved` keep theirs.
    public func move(_ moved: [WindowID: Frame]) {
        lock.withLock {
            for (wid, frame) in moved where wantedFrames[wid] != nil {
                lastTargets[wid] = frame
                observed.removeValue(forKey: wid)
                wantedFrames[wid] = frame
            }
        }
        schedule()
    }

    /// Where the WindowServer says a bordered window actually is.
    ///
    /// An app can settle a few points off the frame weft asked for — a
    /// terminal rounding to whole character cells — and a border drawn around
    /// the target then stands off the window by that much. So the border
    /// follows the window, until weft asks that window for a different frame.
    public func observe(_ wid: WindowID, actual: Frame) {
        let changed: Bool = lock.withLock {
            guard let current = wantedFrames[wid], !Self.close(current, actual) else { return false }
            let target = lastTargets[wid] ?? current
            // Only a settle, never a frame from mid-flight.
            //
            // This accepted anything the WindowServer reported, and a resize
            // reports the window's *old* size until it finishes. So closing one
            // of two tiled windows recorded the survivor at its old half-width
            // against its new full-width target — and because the recorded
            // target is the current one, `close(o.target, target)` then matched
            // on every later pass and re-substituted the stale size forever.
            // The border stayed half the width of its window and never
            // recovered. The same read arriving early, before the layout
            // caught up, drew one ring across two windows.
            //
            // A character cell is a few points. Hundreds is not a rounding, it
            // is a window that has not finished moving, and the next layout
            // pass is a better answer than a guess.
            guard BorderGeometry.settles(actual, against: target) else { return false }
            observed[wid] = (actual, target)
            wantedFrames[wid] = actual
            return true
        }
        if changed { schedule() }
    }

    private static func close(_ a: Frame, _ b: Frame) -> Bool {
        abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    public func setFocus(_ wid: WindowID?) {
        let changed: Bool = lock.withLock {
            guard wantedFocus != wid else { return false }
            wantedFocus = wid
            return true
        }
        if changed { schedule() }
    }

    /// What was on screen is gone — a desktop switch, a display change. The
    /// borders are sticky so they show on every display, which is also why
    /// they have to go now rather than at the next layout pass.
    public func clear() {
        lock.withLock {
            wantedFrames = [:]
            lastTargets = [:]
            observed = [:]
        }
        schedule()
    }

    public func displaysChanged() {
        lock.withLock { screensStale = true }
        clear()
    }

    private func schedule() {
        let start: Bool = lock.withLock {
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    // MARK: - Drawing (on `queue`)

    private func drain() {
        let (style, frames, focus, refreshScreens) = lock.withLock {
            scheduled = false
            defer { screensStale = false }
            return (wantedStyle, wantedFrames, wantedFocus, screensStale)
        }
        if refreshScreens { screens = Self.readScreens() }
        guard let style, style.width > 0 else {
            for wid in Array(borders.keys) { destroy(wid) }
            drawnStyle = nil
            return
        }
        if let drawn = drawnStyle, !drawn.sameGeometry(as: style) {
            for wid in Array(borders.keys) { destroy(wid) }
        }
        drawnStyle = style

        var wanted = frames.filter { $0.value.width > 1 && $0.value.height > 1 }
        if !style.showInactive {
            wanted = wanted.filter { $0.key == focus }
            // Hand the one border to the newly focused window: moving windows
            // is cheaper than destroying some and creating others.
            if let (to, _) = wanted.first, borders[to] == nil,
               let from = borders.keys.first(where: { wanted[$0] == nil })
            {
                borders[to] = borders.removeValue(forKey: from)
                raisedFocus = nil
                matchLevel(of: to)
            }
        }
        for wid in Array(borders.keys) where wanted[wid] == nil { destroy(wid) }

        // What the borders actually cost, in the only unit that matters to the
        // compositor: how many windows exist, and how many were built this
        // pass. `clear()` on a desktop switch releases every piece, so rapid
        // space switching rebuilds all of them repeatedly — which is the first
        // thing to check when borders are blamed for GPU load.
        let existedBefore = borders.count
        defer {
            if Trace.logging {
                let pieces = borders.values.reduce(0) { $0 + $1.pieces.count }
                // Which window is painted which colour, and where its ring
                // actually is. "The yellow is round the wrong window" and "the
                // yellow is the wrong shape" look identical on a screenshot and
                // are different bugs; this separates them without anyone having
                // to interpret a picture.
                let drawn = borders.sorted { $0.key < $1.key }.map {
                    String(
                        format: "%u:%08x@%.0f,%.0f %.0fx%.0f", $0.key, $0.value.color,
                        $0.value.target.x, $0.value.target.y,
                        $0.value.target.width, $0.value.target.height)
                }
                fputs(
                    "weftd: borders \(borders.count) window(s), \(pieces) piece(s); "
                        + "\(borders.count - existedBefore) built this pass; "
                        + "drawn=[\(drawn.joined(separator: "  "))]\n",
                    stderr
                )
            }
        }

        // Made on the first move, if there is one: most passes move nothing.
        var transaction: CFTypeRef?
        for (wid, target) in wanted {
            let color = wid == focus ? style.activeColor : style.inactiveColor
            place(wid, target: target, color: color, style: style, transaction: &transaction)
        }
        if let transaction { SLSTransactionCommit(transaction, 0) }

        // Focus raises its window, which can put another window's edge over
        // this border where windows overlap. Tiles do not overlap; a float or
        // a stack does, and that is exactly where focus changes most.
        if let focus, focus != raisedFocus, let border = borders[focus] {
            for piece in border.pieces { order(piece.wid, above: focus) }
            raisedFocus = focus
        }
    }

    private func queueMove(_ piece: SLWindowID, to frame: Frame, in transaction: inout CFTypeRef?) {
        if transaction == nil { transaction = SLSTransactionCreate(cid) }
        SLSTransactionMoveWindowWithGroup(transaction, piece, CGPoint(x: frame.x, y: frame.y))
    }

    private func place(
        _ wid: WindowID, target: Frame, color: UInt32, style: Style, transaction: inout CFTypeRef?
    ) {
        let scale = scaleFactor(for: target)
        guard var border = borders[wid], abs(border.scale - scale) < 0.01 else {
            // New, or on a display of another resolution: its backing stores
            // are the wrong size, so it is built again rather than repainted.
            destroy(wid)
            create(wid, target: target, color: color, style: style, scale: scale)
            return
        }
        let sameSize = abs(border.target.width - target.width) < 0.5
            && abs(border.target.height - target.height) < 0.5
        let samePlace = abs(border.target.x - target.x) < 0.5 && abs(border.target.y - target.y) < 0.5
        if sameSize && samePlace && border.color == color { return }

        var repaint = Set<Int>()
        if !sameSize {
            let radius = resolveRadius(wid, style: style)
            let layout = BorderGeometry.pieces(around: target, width: style.width, radius: radius)
            guard layout.count == border.pieces.count else {
                destroy(wid)
                create(wid, target: target, color: color, style: style, scale: scale)
                return
            }
            for i in layout.indices {
                let next = layout[i].frame
                if abs(next.width - border.pieces[i].frame.width) < 0.5
                    && abs(next.height - border.pieces[i].frame.height) < 0.5
                {
                    // Same size — a corner, or a strip along an edge that did
                    // not grow. Moving it is all it needs.
                    queueMove(border.pieces[i].wid, to: next, in: &transaction)
                } else {
                    var rect = [CGRect(x: 0, y: 0, width: next.width, height: next.height)]
                    _ = weft_border_window_set_shape(cid, border.pieces[i].wid, CGPoint(x: next.x, y: next.y), &rect, 1)
                    // A new size is a new backing store: the old context draws
                    // into nothing.
                    border.pieces[i].context = nil
                    repaint.insert(i)
                }
                border.pieces[i].frame = next
            }
            if abs(radius - border.radius) > 0.01 { repaint.formUnion(border.pieces.indices) }
            border.radius = radius
        } else if !samePlace {
            let dx = target.x - border.target.x
            let dy = target.y - border.target.y
            for i in border.pieces.indices {
                border.pieces[i].frame.x += dx
                border.pieces[i].frame.y += dy
                queueMove(border.pieces[i].wid, to: border.pieces[i].frame, in: &transaction)
            }
        }
        if border.color != color { repaint.formUnion(border.pieces.indices) }
        border.target = target
        border.color = color
        for i in repaint { paint(&border.pieces[i], target: target, color: color, style: style, radius: border.radius) }
        borders[wid] = border
    }

    private func create(_ wid: WindowID, target: Frame, color: UInt32, style: Style, scale: Double) {
        let radius = resolveRadius(wid, style: style)
        var level: Int32 = 0
        _ = SLSGetWindowLevel(cid, SLWindowID(wid), &level)
        var pieces: [Piece] = []
        for layout in BorderGeometry.pieces(around: target, width: style.width, radius: radius) {
            let f = layout.frame
            var rect = [CGRect(x: 0, y: 0, width: f.width, height: f.height)]
            var pieceWID: SLWindowID = 0
            guard weft_border_window_create(cid, CGPoint(x: f.x, y: f.y), &rect, 1, &pieceWID) == 0,
                  pieceWID != 0
            else { continue }
            _ = SLSSetWindowResolution(cid, pieceWID, scale)
            // Bits 1 and 9 take the window out of hit testing: without them a
            // border eats every click along a window's edge, including the
            // border drags weft's own mouse handling depends on. Bit 11 is
            // sticky, so a border for a window on another display shows at
            // all; `clear` drops them on a desktop switch.
            var tags: UInt64 = (1 << 1) | (1 << 9) | (1 << 11)
            _ = SLSSetWindowTags(cid, pieceWID, &tags, 64)
            _ = SLSSetWindowLevel(cid, pieceWID, level)
            var piece = Piece(wid: pieceWID, frame: f, isStrip: layout.isStrip, opaque: false, context: nil)
            // Painted before it is ordered in: an unpainted window on screen
            // is a solid rectangle belonging to nothing.
            paint(&piece, target: target, color: color, style: style, radius: radius)
            pieces.append(piece)
        }
        for piece in pieces { order(piece.wid, above: wid) }
        borders[wid] = Border(target: target, color: color, radius: radius, scale: scale, pieces: pieces)
        if wid == raisedFocus { raisedFocus = nil }
    }

    private func destroy(_ wid: WindowID) {
        guard let border = borders.removeValue(forKey: wid) else { return }
        for piece in border.pieces {
            SLSOrderWindow(cid, piece.wid, 0, 0)
            SLSReleaseWindow(cid, piece.wid)
        }
        if raisedFocus == wid { raisedFocus = nil }
    }

    private func paint(_ piece: inout Piece, target: Frame, color: UInt32, style: Style, radius: Double) {
        // A strip is a straight run of one colour: opaque when the colour is,
        // so the compositor copies it instead of blending it.
        let opaque = piece.isStrip && (color >> 24) == 0xff
        if opaque != piece.opaque || piece.context == nil {
            _ = SLSSetWindowOpacity(cid, piece.wid, opaque)
            piece.opaque = opaque
        }
        if piece.context == nil {
            piece.context = SLWindowContextCreate(cid, piece.wid, nil)
        }
        guard let ctx = piece.context else { return }
        let size = CGSize(width: piece.frame.width, height: piece.frame.height)
        let bounds = CGRect(origin: .zero, size: size)
        let cg = Self.cgColor(color)
        if piece.isStrip {
            ctx.clear(bounds)
            ctx.setFillColor(cg)
            ctx.fill(bounds)
        } else {
            ctx.clear(bounds)
            ctx.saveGState()
            // The ring is stroked as a whole and each corner window shows its
            // part of it. Quartz is bottom-left, SLS is top-left.
            let outer = BorderGeometry.outer(of: target, width: style.width)
            ctx.translateBy(
                x: -(piece.frame.x - outer.x),
                y: -(outer.height - (piece.frame.y - outer.y) - piece.frame.height)
            )
            let inset = style.width / 2
            let rect = CGRect(x: 0, y: 0, width: outer.width, height: outer.height).insetBy(dx: inset, dy: inset)
            let r = radius > 0 ? radius + inset : 0
            ctx.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: min(r, rect.width / 2), cornerHeight: min(r, rect.height / 2),
                transform: nil
            ))
            ctx.setLineWidth(style.width)
            ctx.setStrokeColor(cg)
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.flush()
    }

    /// Directly above the window it belongs to, not simply at the front: in a
    /// stack, or with a float over a tile, the front is above the window
    /// covering this one.
    private func order(_ piece: SLWindowID, above wid: WindowID) {
        if SLSOrderWindow(cid, piece, 1, SLWindowID(wid)) != 0 {
            SLSOrderWindow(cid, piece, 1, 0)
        }
    }

    private func matchLevel(of wid: WindowID) {
        guard let border = borders[wid] else { return }
        var level: Int32 = 0
        _ = SLSGetWindowLevel(cid, SLWindowID(wid), &level)
        for piece in border.pieces { _ = SLSSetWindowLevel(cid, piece.wid, level) }
    }

    private func resolveRadius(_ wid: WindowID, style: Style) -> Double {
        if style.square { return 0 }
        if let radius = style.radius { return max(0, radius) }
        return WindowCorners.radius(of: wid) ?? 10
    }

    // MARK: - Displays

    private func scaleFactor(for target: Frame) -> Double {
        let cx = target.x + target.width / 2
        let cy = target.y + target.height / 2
        return screens.first { $0.frame.contains(x: cx, y: cy) }?.scale ?? screens.first?.scale ?? 2
    }

    /// Screen rects in the top-left space SLS uses, with their backing scale.
    /// Read once per display change, not once per border.
    private static func readScreens() -> [(frame: Frame, scale: Double)] {
        let screens = NSScreen.screens
        let primaryHeight = screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? screens.first?.frame.height ?? 0
        return screens.map { s in
            let f = s.frame
            return (
                Frame(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height),
                Double(s.backingScaleFactor)
            )
        }
    }

    // MARK: - Colours

    static func cgColor(_ argb: UInt32) -> CGColor {
        CGColor(
            red: CGFloat((argb >> 16) & 0xff) / 255,
            green: CGFloat((argb >> 8) & 0xff) / 255,
            blue: CGFloat(argb & 0xff) / 255,
            alpha: CGFloat((argb >> 24) & 0xff) / 255
        )
    }

    /// `0xAARRGGBB`, `#AARRGGBB` or `#RRGGBB`. Nil for anything else — a
    /// JankyBorders `gradient(...)` included.
    public static func parseColor(_ text: String) -> UInt32? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) } else if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt32(s, radix: 16) else { return nil }
        switch s.count {
        case 6: return 0xff00_0000 | value
        case 8: return value
        default: return nil
        }
    }
}
