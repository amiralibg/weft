// WeftCore/Dividers.swift — the borders between tiled windows, as grabbable
// rectangles, and the exact resize that dragging one performs.
//
// Pure geometry over a computed layout: it takes `[WindowID: Frame]` and
// nothing else, because adjacency in a tiled layout is exactly "two frames
// separated by the inner gap, overlapping on the other axis".
//
// This is what makes a mouse resize possible without entering a resize mode:
// the daemon publishes these rects to the event tap, the tap swallows a click
// only when it lands on one, and every other click reaches the app untouched.

/// One border between two tiled windows.
public struct Divider: Sendable, Equatable {
    /// The window on the west (vertical divider) or north (horizontal) side.
    public var a: WindowID
    /// The window on the east / south side.
    public var b: WindowID
    /// Which way dragging it moves things. `.horizontal` is a *vertical* line
    /// you drag left and right — the axis names the motion, matching
    /// `ResizeDirection.axis` so the two can be compared directly.
    public var axis: ResizeAxis
    /// The grab zone, in screen coordinates. Always at least `grab` points
    /// thick, so a 0-gap layout is still draggable.
    public var rect: Frame

    public init(a: WindowID, b: WindowID, axis: ResizeAxis, rect: Frame) {
        self.a = a
        self.b = b
        self.axis = axis
        self.rect = rect
    }
}

/// Every border in a computed layout.
///
/// Two frames form a border when they are separated along one axis by no more
/// than the inner gap (plus a point of rounding slack), do not overlap, and
/// share at least `minOverlap` points on the other axis. Overlapping frames —
/// stack members sharing a slot, a fullscreen window over the rest — are
/// never adjacent to each other, which is exactly right: there is no divider
/// between two windows occupying the same space.
///
/// Deterministic order (by rect, then ids) so a republish with unchanged
/// geometry produces an unchanged list.
public func dividers(
    in frames: [WindowID: Frame],
    innerGap: Double,
    grab: Double = 12,
    minOverlap: Double = 24
) -> [Divider] {
    // The band a divider can live in: the gap itself, widened to `grab` when
    // the gap is smaller (and it usually is — 8pt is the default, and 0 is a
    // popular setting).
    let slack = innerGap + 1
    let half = max(grab, innerGap) / 2
    let ids = frames.keys.sorted()
    var out: [Divider] = []
    for (i, u) in ids.enumerated() {
        guard let f = frames[u] else { continue }
        for v in ids[(i + 1)...] {
            guard let g = frames[v] else { continue }
            // Vertical divider: one frame's right edge meets the other's left.
            let yOverlap = min(f.y + f.height, g.y + g.height) - max(f.y, g.y)
            if yOverlap >= minOverlap {
                let fThenG = g.x - (f.x + f.width)
                let gThenF = f.x - (g.x + g.width)
                if fThenG >= -1, fThenG <= slack {
                    out.append(vertical(a: u, b: v, at: f.x + f.width + fThenG / 2,
                                        from: max(f.y, g.y), overlap: yOverlap, half: half))
                } else if gThenF >= -1, gThenF <= slack {
                    out.append(vertical(a: v, b: u, at: g.x + g.width + gThenF / 2,
                                        from: max(f.y, g.y), overlap: yOverlap, half: half))
                }
            }
            // Horizontal divider: one frame's bottom edge meets the other's top.
            let xOverlap = min(f.x + f.width, g.x + g.width) - max(f.x, g.x)
            if xOverlap >= minOverlap {
                let fThenG = g.y - (f.y + f.height)
                let gThenF = f.y - (g.y + g.height)
                if fThenG >= -1, fThenG <= slack {
                    out.append(horizontal(a: u, b: v, at: f.y + f.height + fThenG / 2,
                                          from: max(f.x, g.x), overlap: xOverlap, half: half))
                } else if gThenF >= -1, gThenF <= slack {
                    out.append(horizontal(a: v, b: u, at: g.y + g.height + gThenF / 2,
                                          from: max(f.x, g.x), overlap: xOverlap, half: half))
                }
            }
        }
    }
    return out.sorted {
        ($0.rect.x, $0.rect.y, $0.a, $0.b) < ($1.rect.x, $1.rect.y, $1.a, $1.b)
    }
}

private func vertical(
    a: WindowID, b: WindowID, at centre: Double,
    from y: Double, overlap: Double, half: Double
) -> Divider {
    Divider(
        a: a, b: b, axis: .horizontal,
        rect: Frame(x: centre - half, y: y, width: half * 2, height: overlap)
    )
}

private func horizontal(
    a: WindowID, b: WindowID, at centre: Double,
    from x: Double, overlap: Double, half: Double
) -> Divider {
    Divider(
        a: a, b: b, axis: .vertical,
        rect: Frame(x: x, y: centre - half, width: overlap, height: half * 2)
    )
}

/// The divider under a point, innermost first.
///
/// Ties go to the smaller zone: where a horizontal and a vertical divider
/// cross, the corner belongs to whichever is more specific rather than to
/// whichever happened to sort first.
public func divider(at x: Double, y: Double, in list: [Divider]) -> Divider? {
    var best: Divider?
    var bestArea = Double.greatestFiniteMagnitude
    for d in list where d.rect.contains(x: x, y: y) {
        let area = d.rect.width * d.rect.height
        if area < bestArea {
            bestArea = area
            best = d
        }
    }
    return best
}

// MARK: - Exact divider resize

extension Tree {
    /// Move the divider between `a` and `b` by `deltaPoints`, positive
    /// toward `b` — the direction the mouse is going when a drag grows `a`.
    ///
    /// This is not `resizing(focused:axis:delta:totalSize:)` with the numbers
    /// rearranged. That one walks down from the root and adjusts the FIRST
    /// container whose orientation matches the axis, which is the right
    /// answer for a keybind (resize "my" window against its biggest
    /// neighbour) and the wrong one for a drag: in `splitV[splitV[A, B], C]`
    /// it would move the A|B grab onto the (AB)|C divider, and the border
    /// under the cursor would sit still while a different one moved.
    ///
    /// So: find the deepest container that separates `a` from `b` on this
    /// axis, and adjust exactly the two children that hold them. `frames`
    /// supplies the on-screen extent of those two children, so a drag of N
    /// points moves the border N points however deep in the tree it sits.
    public func resizing(
        divider a: WindowID,
        _ b: WindowID,
        axis: ResizeAxis,
        deltaPoints: Double,
        frames: [WindowID: Frame]
    ) -> Tree {
        guard let root, a != b else { return self }
        var copy = self
        guard let next = resizeDivider(
            root, a: a, b: b, axis: axis, deltaPoints: deltaPoints, frames: frames
        ) else { return self }
        copy.root = next
        return copy
    }
}

/// nil when this subtree does not separate the pair (so the caller can keep
/// looking); a rebuilt node when it does.
private func resizeDivider(
    _ node: Node,
    a: WindowID,
    b: WindowID,
    axis: ResizeAxis,
    deltaPoints: Double,
    frames: [WindowID: Frame]
) -> Node? {
    guard case .container(var c) = node else { return nil }
    // Deepest first: a nested container that separates the pair is a better
    // answer than this one.
    for (i, child) in c.children.enumerated() {
        if let rebuilt = resizeDivider(
            child, a: a, b: b, axis: axis, deltaPoints: deltaPoints, frames: frames
        ) {
            c.children[i] = rebuilt
            return .container(c)
        }
    }
    let matchesAxis = (axis == .horizontal && c.layout == .splitV)
        || (axis == .vertical && c.layout == .splitH)
    guard matchesAxis,
          let ia = c.children.firstIndex(where: { $0.windows.contains(a) }),
          let ib = c.children.firstIndex(where: { $0.windows.contains(b) }),
          ia != ib
    else { return nil }
    // On-screen extent of the two children, along the axis. A ratio point is
    // worth this many screen points, so this is what turns a pixel delta into
    // a ratio delta with no scaling error.
    let span = extent(of: c.children[ia], axis: axis, frames: frames)
        + extent(of: c.children[ib], axis: axis, frames: frames)
    guard span > 1 else { return nil }
    var ratios = c.ratios
    if ratios.count != c.children.count {
        ratios = Array(repeating: 1.0 / Double(c.children.count), count: c.children.count)
    }
    let sum = ratios.reduce(0, +)
    guard sum > 0 else { return nil }
    ratios = ratios.map { $0 / sum }
    let pairShare = ratios[ia] + ratios[ib]
    let dRatio = deltaPoints * pairShare / span
    // 5% of the container is the floor: small enough to shove a window right
    // out of the way, large enough that it can always be dragged back.
    let floorShare = 0.05 * pairShare
    let wanted = ratios[ia] + dRatio
    let clamped = min(max(wanted, floorShare), pairShare - floorShare)
    let applied = clamped - ratios[ia]
    guard abs(applied) > 1e-9 else { return nil }
    ratios[ia] = clamped
    ratios[ib] -= applied
    c.ratios = ratios
    return .container(c)
}

/// Union extent of every window under `node`, along `axis`.
private func extent(of node: Node, axis: ResizeAxis, frames: [WindowID: Frame]) -> Double {
    var lo = Double.greatestFiniteMagnitude
    var hi = -Double.greatestFiniteMagnitude
    for wid in node.windows {
        guard let f = frames[wid] else { continue }
        switch axis {
        case .horizontal:
            lo = min(lo, f.x)
            hi = max(hi, f.x + f.width)
        case .vertical:
            lo = min(lo, f.y)
            hi = max(hi, f.y + f.height)
        }
    }
    return hi > lo ? hi - lo : 0
}
