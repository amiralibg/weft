/// Where a border's windows go.
///
/// The compositor pays for a window by its *area*, and it pays on every frame
/// the window underneath draws. The renderer removed in 0.7.4 covered each
/// window with a transparent overlay the full size of that window, and that
/// alone cost 16pp of GPU. A border is a ring a couple of points wide, so the
/// windows drawing it cover only the ring: four straight strips, which are a
/// solid fill and can be opaque (nothing to blend), and four small corner
/// squares that carry the rounding. A 1000×800 window with a 2pt border and
/// 12pt corners puts about 1% of its area under weft's windows.
///
/// Pure, so the pieces are tested here: that they cover the ring, that they
/// never reach into the window, and that they never overlap each other.
public enum BorderGeometry {
    public struct Piece: Equatable, Sendable {
        /// Global, top-left origin — the space `SLSGetWindowBounds` uses.
        public var frame: Frame
        /// A straight run: drawn as a plain fill. Corners are stroked.
        public var isStrip: Bool

        public init(frame: Frame, isStrip: Bool) {
            self.frame = frame
            self.isStrip = isStrip
        }
    }

    /// How far a window may settle from the frame it was asked for and still
    /// count as having honoured it. Two character cells of a large font.
    public static let settleTolerance: Double = 40

    /// Whether `actual` is `target` with a settle, or a different frame.
    ///
    /// An app can land a few points off what weft asked for — a terminal rounds
    /// to whole character cells — and a border drawn around the request then
    /// stands off the window by that much, so the renderer follows the window.
    /// It must not follow a frame from *mid-flight*: a resize reports the old
    /// size until it finishes, and accepting that recorded the survivor of a
    /// closed split at its old half width against its new full-width target.
    /// Because the recorded target is the current one, the substitution then
    /// matched on every later pass and the border stayed half the width of its
    /// window forever; arriving early instead, it drew one ring across two
    /// windows. Both were the same bug, and both were reported as "the border
    /// is around the wrong thing".
    ///
    /// Hundreds of points is not a rounding. It is a window that has not
    /// finished moving, and the next layout pass is a better answer than a
    /// guess at where it went.
    public static func settles(_ actual: Frame, against target: Frame) -> Bool {
        abs(actual.x - target.x) <= settleTolerance
            && abs(actual.y - target.y) <= settleTolerance
            && abs(actual.width - target.width) <= settleTolerance
            && abs(actual.height - target.height) <= settleTolerance
    }

    /// The rectangle the ring's outer edge follows: `width` points outside
    /// the window on every side, so the border never covers the window.
    public static func outer(of target: Frame, width: Double) -> Frame {
        Frame(
            x: target.x - width, y: target.y - width,
            width: target.width + width * 2, height: target.height + width * 2
        )
    }

    /// The pieces of a border `width` points wide around `target`, whose
    /// corners are rounded to `radius` (0 for square).
    ///
    /// Order is fixed — top, bottom, left, right, then the four corners —
    /// so a resize can match each piece to the window already drawing it and
    /// only reshape what changed size. The corners never do.
    public static func pieces(around target: Frame, width: Double, radius: Double) -> [Piece] {
        guard width > 0 else { return [] }
        let o = outer(of: target, width: width)
        // Corner square side: the arc spans radius + width from the outer edge.
        let c = radius > 0 ? radius + width : width
        guard o.width > c * 2, o.height > c * 2 else {
            // Too small to split (never a tiled window): one piece, stroked.
            return [Piece(frame: o, isStrip: false)]
        }
        if radius <= 0 {
            // Square: the strips meet at the corners, nothing to round.
            return [
                Piece(frame: Frame(x: o.x, y: o.y, width: o.width, height: width), isStrip: true),
                Piece(frame: Frame(x: o.x, y: o.maxY - width, width: o.width, height: width), isStrip: true),
                Piece(frame: Frame(x: o.x, y: o.y + width, width: width, height: o.height - width * 2), isStrip: true),
                Piece(frame: Frame(x: o.maxX - width, y: o.y + width, width: width, height: o.height - width * 2), isStrip: true),
            ]
        }
        return [
            Piece(frame: Frame(x: o.x + c, y: o.y, width: o.width - c * 2, height: width), isStrip: true),
            Piece(frame: Frame(x: o.x + c, y: o.maxY - width, width: o.width - c * 2, height: width), isStrip: true),
            Piece(frame: Frame(x: o.x, y: o.y + c, width: width, height: o.height - c * 2), isStrip: true),
            Piece(frame: Frame(x: o.maxX - width, y: o.y + c, width: width, height: o.height - c * 2), isStrip: true),
            Piece(frame: Frame(x: o.x, y: o.y, width: c, height: c), isStrip: false),
            Piece(frame: Frame(x: o.maxX - c, y: o.y, width: c, height: c), isStrip: false),
            Piece(frame: Frame(x: o.x, y: o.maxY - c, width: c, height: c), isStrip: false),
            Piece(frame: Frame(x: o.maxX - c, y: o.maxY - c, width: c, height: c), isStrip: false),
        ]
    }
}

private extension Frame {
    var maxX: Double { x + width }
    var maxY: Double { y + height }
}
