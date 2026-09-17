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

    /// Whether a window has arrived at the frame it was asked for.
    ///
    /// An app can land a few points off what weft asked for and be finished —
    /// a terminal rounds to whole character cells — so "arrived" cannot mean
    /// "equal". Hundreds of points is not a rounding: it is a window that has
    /// not finished moving, because a resize reports the old size until it
    /// completes.
    ///
    /// The border renderer uses this to decide when to **stop looking**. It
    /// draws every border where the WindowServer says the window is, and after
    /// each pass it asks whether anything is still in flight; while something
    /// is, it re-reads on a short decaying ladder, and when nothing is, it
    /// stops and no timer runs.
    ///
    /// It used to be asked a different question — *may the border follow this
    /// frame* — because the border was drawn around the frame weft had asked
    /// for and this decided whether to substitute the observed one. Getting
    /// that judgement wrong was unrecoverable in both directions: a survivor
    /// of a closed split latched at its old half width around a full-width
    /// window, permanently; the same read arriving early drew one ring across
    /// two windows. Nothing substitutes anything now, so a wrong answer here
    /// costs at most a few extra reads or a slightly early stop.
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
