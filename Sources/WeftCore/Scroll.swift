// WeftCore/Scroll.swift — niri-style scroll layout (M5), pure.
//
// An ordered horizontal strip of columns; each column holds a vertical stack
// of windows. The viewport (viewportX) pans so the focused column is visible;
// columns with too little of themselves on screen for AX to place honestly are
// PARKED (SLSMoveWindow to union.minX - 5000, S4) and cost nothing until
// re-entry. Unparking needs the nudge protocol (SLS back + AX different + AX
// target) — platform side.
//
// Visible columns move via AX only (S2 rejected SLSMoveWindow for visible
// windows: the app desyncs). Parking is SLS-only (AX clamps at -(width-40)).

public enum CenterMode: String, Codable, Sendable, Equatable {
    case always
    case never
    case onOverflow

    /// From the spelling `weft.toml` uses. The config writes kebab-case
    /// (`on-overflow`) and the enum is camel-cased, so a plain `init(rawValue:)`
    /// would silently reject the only spelling the config parser accepts.
    public init?(configValue: String) {
        switch configValue {
        case "always": self = .always
        case "never": self = .never
        case "on-overflow", "onOverflow": self = .onOverflow
        default: return nil
        }
    }
}

public struct Column: Sendable, Equatable {
    public var windows: [WindowID]
    /// Fraction of usable width. Cycles the preset ring; resize adjusts.
    public var width: Double
    /// Fraction of the column height per row, summing to 1.
    ///
    /// Rows used to divide the column equally with no way to change it, so
    /// `resize up`/`resize down` — and dragging a horizontal border with the
    /// mouse — did nothing at all on a scroll space. Kept count-matched with
    /// `windows` by `normalized()`; a column that has never been resized
    /// holds equal shares and lays out exactly as before.
    public var heights: [Double]

    public init(
        windows: [WindowID],
        width: Double = ScrollState.defaultWidth,
        heights: [Double] = []
    ) {
        self.windows = windows
        self.width = width
        self.heights = heights
        normalize()
    }

    /// Equal shares when the count is wrong or the stored shares are junk;
    /// otherwise the stored shares scaled to sum to 1. New rows enter at an
    /// equal share and the existing rows give up that space proportionally,
    /// which is what makes adding a window to a resized column not throw the
    /// resize away.
    mutating func normalize() {
        let n = windows.count
        guard n > 0 else { heights = []; return }
        if heights.count != n || heights.contains(where: { !($0 > 0) }) {
            var next = heights.filter { $0 > 0 }
            if next.count > n { next = Array(next.prefix(n)) }
            let share = next.isEmpty ? 1.0 / Double(n) : next.reduce(0, +) / Double(next.count)
            while next.count < n { next.append(share) }
            heights = next
        }
        let total = heights.reduce(0, +)
        guard total > 0 else {
            heights = Array(repeating: 1.0 / Double(n), count: n)
            return
        }
        heights = heights.map { $0 / total }
    }
}

public struct ScrollState: Sendable, Equatable {
    public static let presets: [Double] = [0.333, 0.5, 0.667, 1.0]
    public static let defaultWidth: Double = 0.5

    public var columns: [Column]
    /// Scroll offset in strip coordinates (points).
    public var viewportX: Double
    public var focusCol: Int
    public var focusRow: Int
    public var centerMode: CenterMode
    /// Fullscreen (zoomed) window.
    public var fullscreen: WindowID?

    public init(
        columns: [Column] = [],
        viewportX: Double = 0,
        focusCol: Int = 0,
        focusRow: Int = 0,
        centerMode: CenterMode = .onOverflow,
        fullscreen: WindowID? = nil
    ) {
        self.columns = columns
        self.viewportX = viewportX
        self.focusCol = focusCol
        self.focusRow = focusRow
        self.centerMode = centerMode
        self.fullscreen = fullscreen
    }

    public var windows: [WindowID] { columns.flatMap { $0.windows } }

    public var focusedWindow: WindowID? {
        guard columns.indices.contains(focusCol),
              columns[focusCol].windows.indices.contains(focusRow)
        else { return nil }
        return columns[focusCol].windows[focusRow]
    }

    // MARK: - Membership

    /// niri policy: new window opens as a column right of the focused one.
    public func inserting(_ id: WindowID) -> ScrollState {
        if windows.contains(id) { return focusing(id) }
        var copy = self
        let col = Column(windows: [id])
        if copy.columns.isEmpty {
            copy.columns = [col]
            copy.focusCol = 0
        } else {
            let at = min(copy.focusCol + 1, copy.columns.count)
            copy.columns.insert(col, at: at)
            copy.focusCol = at
        }
        copy.focusRow = 0
        return copy
    }

    public func removing(_ id: WindowID) -> ScrollState {
        var copy = self
        let wasFocused = copy.focusedWindow == id
        copy.columns = copy.columns.map { col in
            // Keep the surviving rows' shares; `normalize` rescales them back
            // to 1 so the removed row's height is redistributed in proportion.
            let keep = col.windows.enumerated().filter { $0.element != id }
            return Column(
                windows: keep.map(\.element),
                width: col.width,
                heights: keep.map { col.heights[safe: $0.offset] ?? 0 }
            )
        }.filter { !$0.windows.isEmpty }
        copy.focusCol = min(copy.focusCol, max(copy.columns.count - 1, 0))
        if let col = copy.columns[safe: copy.focusCol] {
            copy.focusRow = min(copy.focusRow, max(col.windows.count - 1, 0))
        } else {
            copy.focusRow = 0
        }
        if copy.fullscreen == id {
            copy.fullscreen = nil
        }
        _ = wasFocused
        return copy
    }

    /// Toggle zoom-fullscreen on the focused window.
    public func togglingFullscreen() -> ScrollState {
        guard let focused = focusedWindow else { return self }
        var copy = self
        if copy.fullscreen == focused {
            copy.fullscreen = nil
        } else {
            copy.fullscreen = focused
        }
        return copy
    }

    /// Focus a window, syncing (col, row) to it.
    public func focusing(_ id: WindowID) -> ScrollState {
        var copy = self
        for (c, col) in copy.columns.enumerated() {
            if let r = col.windows.firstIndex(of: id) {
                copy.focusCol = c
                copy.focusRow = r
                return copy
            }
        }
        return self
    }

    // MARK: - Column ops

    /// Move focus by columns, clamping the row into the new column.
    public func movingFocusByColumn(_ delta: Int) -> ScrollState {
        guard !columns.isEmpty else { return self }
        var copy = self
        copy.focusCol = min(max(copy.focusCol + delta, 0), copy.columns.count - 1)
        copy.focusRow = min(copy.focusRow, max(copy.columns[copy.focusCol].windows.count - 1, 0))
        return copy
    }

    /// Move focus by rows within the current column.
    public func movingFocusByRow(_ delta: Int) -> ScrollState {
        guard columns.indices.contains(focusCol) else { return self }
        let rowCount = columns[focusCol].windows.count
        guard rowCount > 0 else { return self }
        var copy = self
        copy.focusRow = min(max(copy.focusRow + delta, 0), rowCount - 1)
        return copy
    }

    /// Swap the focused column with an adjacent column in the strip (delta = ±1).
    public func swappingColumns(_ delta: Int) -> ScrollState {
        guard columns.indices.contains(focusCol) else { return self }
        let targetCol = focusCol + delta
        guard columns.indices.contains(targetCol), targetCol != focusCol else { return self }
        var copy = self
        copy.columns.swapAt(focusCol, targetCol)
        copy.focusCol = targetCol
        return copy
    }

    /// Swap the focused row with an adjacent row in the current column (delta = ±1).
    public func swappingRowsInFocusedColumn(_ delta: Int) -> ScrollState {
        guard columns.indices.contains(focusCol) else { return self }
        let targetRow = focusRow + delta
        guard columns[focusCol].windows.indices.contains(targetRow), targetRow != focusRow else {
            return self
        }
        var copy = self
        copy.columns[focusCol].windows.swapAt(focusRow, targetRow)
        if copy.columns[focusCol].heights.indices.contains(focusRow) &&
           copy.columns[focusCol].heights.indices.contains(targetRow) {
            copy.columns[focusCol].heights.swapAt(focusRow, targetRow)
        }
        copy.focusRow = targetRow
        return copy
    }

    /// Move the focused window into the adjacent column (merge). Empty
    /// columns are dropped. Focus stays on the moved window.
    public func movingWindowToColumn(_ delta: Int) -> ScrollState {
        guard columns.indices.contains(focusCol),
              let wid = focusedWindow
        else { return self }
        let target = focusCol + delta
        // Moving a window into the column it is already in is not a move; it
        // used to take the window out and put it back at the bottom, which
        // reordered the column and threw away its row heights.
        guard delta != 0, columns.indices.contains(target) else { return self }
        var copy = self
        copy.columns[focusCol].windows.removeAll(where: { $0 == wid })
        copy.columns[focusCol].normalize()
        var t = target
        // Drop the emptied column first so indices stay honest.
        copy.columns = copy.columns.enumerated().compactMap { (i, col) in
            if i == focusCol, col.windows.isEmpty { return nil as Column? }
            return col
        }
        // Removal shifted columns left of the old target.
        if focusCol < target { t -= 1 }
        guard copy.columns.indices.contains(t) else { return self }
        copy.columns[t].windows.append(wid)
        copy.columns[t].normalize()
        copy.focusCol = t
        copy.focusRow = copy.columns[t].windows.count - 1
        return copy
    }

    /// Where a window sits in the strip, or nil if it is not in it.
    ///
    /// A mouse drag names the two windows either side of the border it
    /// grabbed, so the resize has to be aimed at *that* column — not at
    /// whatever happens to be focused.
    public func position(of id: WindowID) -> (col: Int, row: Int)? {
        for (c, col) in columns.enumerated() {
            if let r = col.windows.firstIndex(of: id) { return (c, r) }
        }
        return nil
    }

    /// Cycle the focused column through the preset ring.
    ///
    /// `presets` is the space's own ring — `[[space]] scroll.preset-column-widths`
    /// — falling back to the default one. It was a hard-coded static, so the
    /// config key was parsed, validated, reported in errors, and then ignored.
    public func cyclingWidth(presets: [Double] = ScrollState.presets) -> ScrollState {
        guard columns.indices.contains(focusCol) else { return self }
        let ring = presets.filter { $0 > 0 }.isEmpty ? ScrollState.presets : presets.filter { $0 > 0 }
        var copy = self
        let cur = copy.columns[focusCol].width
        var best = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, p) in ring.enumerated() {
            let d = abs(p - cur)
            if d < bestDist { bestDist = d; best = i }
        }
        copy.columns[focusCol].width = ring[(best + 1) % ring.count]
        return copy
    }

    /// Nudge the focused column width (resize left/right). Clamped.
    public func adjustingWidth(_ delta: Double) -> ScrollState {
        adjustingWidth(delta, column: focusCol)
    }

    /// Nudge a named column's width. Clamped. Every column right of it moves
    /// by the same amount, because a column's strip position is the sum of
    /// the widths before it — which is what makes the rest of the strip
    /// follow a resize instead of overlapping it.
    public func adjustingWidth(_ delta: Double, column: Int) -> ScrollState {
        guard columns.indices.contains(column) else { return self }
        var copy = self
        copy.columns[column].width = min(max(copy.columns[column].width + delta, 0.15), 1.0)
        return copy
    }

    /// Nudge the boundary below the focused row, as a fraction of the column
    /// height. The row below gives up exactly what the focused one gains, so
    /// the column still fills its height. The last row in a column pushes the
    /// boundary *above* it instead — otherwise the bottom window was the one
    /// window in the strip that could not be resized.
    public func adjustingHeight(_ delta: Double) -> ScrollState {
        adjustingHeight(delta, column: focusCol, row: focusRow)
    }

    /// The same edit, aimed at a named row of a named column, for a mouse
    /// drag on a horizontal border.
    public func adjustingHeight(_ delta: Double, column: Int, row rawRow: Int) -> ScrollState {
        guard columns.indices.contains(column) else { return self }
        var col = columns[column]
        let n = col.windows.count
        guard n > 1, col.heights.count == n else { return self }
        let row = min(max(rawRow, 0), n - 1)
        // Which pair of adjacent rows the boundary sits between, and which of
        // the two grows for a positive delta.
        let (grow, shrink) = row < n - 1 ? (row, row + 1) : (row, row - 1)
        let minShare = 0.08
        let d = min(max(delta, minShare - col.heights[grow]), col.heights[shrink] - minShare)
        guard abs(d) > 1e-9 else { return self }
        col.heights[grow] += d
        col.heights[shrink] -= d
        var copy = self
        copy.columns[column] = col
        return copy
    }

    /// Swap two windows' positions (may span columns). Focus stays on `a`.
    public func swapping(_ a: WindowID, _ b: WindowID) -> ScrollState {
        guard a != b, windows.contains(a), windows.contains(b) else { return self }
        var copy = self
        copy.columns = copy.columns.map { col in
            Column(
                windows: col.windows.map { $0 == a ? b : ($0 == b ? a : $0) },
                width: col.width,
                heights: col.heights
            )
        }
        return copy.focusing(a)
    }

    // MARK: - Viewport

    /// Pan the minimum distance to bring column `col` fully into view, then
    /// apply the center mode. Strip positions live in usable-width units
    /// (screen minus outer gaps) starting at 0; the visible strip window is
    /// [vx - outerLeft, vx + screenW - outerLeft] (the 8pt offset is where
    /// the outer inset lands in screen coords).
    public mutating func ensureVisible(_ col: Int, screen: Frame, config: TilingConfig) {
        let (usableW, _, _, _) = scrollUsable(screen: screen, config: config)
        guard usableW > 0, screen.width > 0 else { return }
        guard !columns.isEmpty else { viewportX = 0; return }
        let stripW = totalWidth(usableW: usableW)
        // The strip is shorter than the screen: there is nothing to scroll,
        // and the only question is where the group sits.
        //
        // It used to sit at strip 0 whatever the viewport said, which is how
        // closing the right-hand column left a hole: `viewportX` was still
        // parked at the old strip end, so the survivor was drawn a screen
        // width to the left of the screen — far enough to be parked outright.
        // Centring the whole group is the honest answer to "one window is
        // open": it lands in the middle, and each column added after it
        // pushes the group left rather than the first one staying pinned to
        // the edge. `.never` means the user asked for edge-aligned, so it is.
        if stripW <= usableW {
            viewportX = centerMode == .never ? 0 : (stripW - usableW) / 2
            return
        }
        guard columns.indices.contains(col) else {
            viewportX = min(max(viewportX, 0), stripW - usableW)
            return
        }
        let (x0, x1) = columnRange(col, usableW: usableW)
        // 1. Minimum scroll to fit (left edge first, then right).
        //
        // The visible strip window is [vx, vx + usableW], not [vx - outerLeft,
        // vx + screen.width - outerLeft]. Strip coordinates already run inside
        // the outer gaps — `scrollLayout` draws strip position `vx` at
        // `screen.x + outerGap.left` — so measuring the window in *screen*
        // width let a scrolled-to column sit flush against the screen edge
        // with its outer gap eaten, and did it only after a scroll.
        var vx = viewportX
        if x0 < vx { vx = x0 }
        if x1 > vx + usableW { vx = x1 - usableW }
        // 2. Center modes, against the fresh window.
        let mid = vx + usableW / 2
        switch centerMode {
        case .never:
            break
        case .always:
            vx += (x0 + x1) / 2 - mid
        case .onOverflow:
            // Only center what can't fit: it never sits fully in view.
            if x1 - x0 > usableW { vx += (x0 + x1) / 2 - mid }
        }
        viewportX = clampViewport(vx, usableW: usableW, stripW: stripW)
    }

    /// The viewport the layout actually draws with — the stored `viewportX`
    /// put back inside the range the current strip allows.
    ///
    /// `viewportX` is *intent*: the last place a focus change panned to. The
    /// strip underneath it changes without the intent changing at all — a
    /// column closes, a resize shortens the strip, a space is re-laid out on
    /// a narrower display — and the stored value is then a scroll position
    /// that no longer exists. Deriving the drawn viewport instead of trusting
    /// the stored one is what stops those leaving a hole on one side, and it
    /// means every reader of the layout (the drag path, `query tree`, the
    /// divider zones, the borders) agrees without anyone writing state back.
    public func effectiveViewportX(usableW: Double) -> Double {
        guard usableW > 0, !columns.isEmpty else { return 0 }
        let stripW = totalWidth(usableW: usableW)
        if stripW <= usableW {
            return centerMode == .never ? 0 : (stripW - usableW) / 2
        }
        return clampViewport(viewportX, usableW: usableW, stripW: stripW)
    }

    /// The scrollable range of `viewportX`, for a strip that overflows.
    ///
    /// `.never` and `.onOverflow` stop at the two ends of the strip, so the
    /// last column cannot be scrolled past into empty space. `.always` keeps
    /// the focused column centred *including* at the ends — that is what the
    /// mode means — so its range runs from the first column centred to the
    /// last one centred, which is deliberately wider.
    private func clampViewport(_ vx: Double, usableW: Double, stripW: Double) -> Double {
        let lo: Double
        let hi: Double
        switch centerMode {
        case .always:
            let (f0, f1) = columnRange(0, usableW: usableW)
            let (l0, l1) = columnRange(columns.count - 1, usableW: usableW)
            lo = (f0 + f1) / 2 - usableW / 2
            hi = (l0 + l1) / 2 - usableW / 2
        case .never, .onOverflow:
            lo = 0
            hi = stripW - usableW
        }
        return min(max(vx, lo), max(lo, hi))
    }

    /// Total strip width in points, in the same units as `columnRange`.
    public func totalWidth(usableW w: Double) -> Double {
        columns.reduce(0) { $0 + $1.width * w }
    }

    /// Strip-coordinate range of a column in usable-width units (matches the
    /// layout builder exactly — same widths, no gaps).
    func columnRange(_ col: Int, usableW w: Double) -> (Double, Double) {
        var x = 0.0
        for (i, c) in columns.enumerated() {
            let cw = c.width * w
            if i == col { return (x, x + cw) }
            x += cw
        }
        return (x, x)
    }
}

extension Array {
    fileprivate subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}

// MARK: - Layout

/// Codable snapshot of the strip for `query tree` on scroll spaces.
public struct ScrollView: Codable, Sendable, Equatable {
    public struct ColumnView: Codable, Sendable, Equatable {
        public var windows: [WindowID]
        public var width: Double
        public var heights: [Double]
    }

    public var columns: [ColumnView]
    public var focusCol: Int
    public var focusRow: Int
    public var viewportX: Double
    public var centerMode: CenterMode

    public static func of(_ state: ScrollState) -> ScrollView {
        ScrollView(
            columns: state.columns.map {
                ColumnView(windows: $0.windows, width: $0.width, heights: $0.heights)
            },
            focusCol: state.focusCol,
            focusRow: state.focusRow,
            viewportX: state.viewportX,
            centerMode: state.centerMode
        )
    }
}

/// Usable rect (outer gaps removed) shared by the strip builder, the
/// viewport math, and the daemon's ensureVisible calls.
public func scrollUsable(screen: Frame, config: TilingConfig) -> (
    w: Double, h: Double, baseX: Double, baseY: Double
) {
    let w = max(screen.width - config.outerGap.left - config.outerGap.right, 1)
    let h = max(screen.height - config.outerGap.top - config.outerGap.bottom, 1)
    return (w, h, screen.x + config.outerGap.left, screen.y + config.outerGap.top)
}

/// Screen-coordinate frames for VISIBLE columns + the parked set.
///
/// Parked = not enough of the column lands on screen to be worth placing.
/// Returned frames are final (screen coords); parked windows get no frame —
/// the daemon SLS-parks them and persists the set.
///
/// The threshold is not a taste call. AX refuses to put a window where only a
/// sliver of it would be visible — it clamps at roughly `-(width - 40)` — and
/// it clamps *silently*, so a column scrolled off the left edge was written to
/// its true off-screen position, snapped back by the WindowServer, and left
/// sitting under the leftmost visible column. Four windows into a scroll space
/// that reads as a pile of windows stacked in the corner, which is exactly
/// what it is. Anything AX would clamp gets SLS-parked instead, which has no
/// such limit.
/// `viewportX` overrides the state's own viewport, for the one caller that
/// has a better one: the pan animator, which draws intermediate positions
/// between two settled viewports and must not have them re-derived under it.
public func scrollLayout(
    _ state: ScrollState,
    screen: Frame,
    config: TilingConfig,
    viewportX: Double? = nil
) -> (frames: [WindowID: Frame], parked: Set<WindowID>) {
    stripFrames(state, screen: screen, config: config, viewportX: viewportX, cull: true)
}

/// Every window's frame at a given viewport, with the parking rule switched
/// off — columns that are off screen get honest off-screen frames instead of
/// being dropped.
///
/// For the pan animator, which moves windows with `SLSMoveWindow`. That has
/// no clamp (S4), so a column can be *drawn* arriving from beyond the display
/// edge rather than appearing the instant it becomes legal for AX to place —
/// which is the difference between a strip that scrolls and a strip that
/// cuts. Nothing here may be handed to AX; the settle pass at the end of the
/// pan uses `scrollLayout` for that.
public func scrollStripFrames(
    _ state: ScrollState,
    screen: Frame,
    config: TilingConfig,
    viewportX: Double? = nil
) -> [WindowID: Frame] {
    stripFrames(state, screen: screen, config: config, viewportX: viewportX, cull: false).frames
}

/// The windows a pan between two viewports actually drags across `screen`.
///
/// Everything else stays where it is — parked beyond the display union — for
/// the length of the pan. Their true strip positions are hundreds or thousands
/// of points past the edge, and on a multi-display desktop "past the edge" is
/// the next monitor, which is the whole reason parking targets
/// `union.minX - 5000` rather than `-width`.
///
/// A pan moves every window monotonically, so the exact question is whether
/// the interval a window sweeps overlaps the screen at any point — not
/// whether it is visible at either end. A column can cross the whole screen
/// during a long jump and be off both edges when the pan starts and stops.
public func scrollPanParticipants(
    _ state: ScrollState,
    screen: Frame,
    config: TilingConfig,
    from fromVX: Double,
    to toVX: Double
) -> Set<WindowID> {
    let begin = scrollStripFrames(state, screen: screen, config: config, viewportX: fromVX)
    let end = scrollStripFrames(state, screen: screen, config: config, viewportX: toVX)
    var out = Set<WindowID>()
    for (wid, b) in begin {
        guard let e = end[wid] else { continue }
        let lo = min(b.x, e.x)
        let hi = max(b.x, e.x)
        if hi + e.width > screen.x, lo < screen.x + screen.width { out.insert(wid) }
    }
    return out
}

private func stripFrames(
    _ state: ScrollState,
    screen: Frame,
    config: TilingConfig,
    viewportX: Double?,
    cull: Bool
) -> (frames: [WindowID: Frame], parked: Set<WindowID>) {
    let gap = config.innerGap
    let (usableW, usableH, baseX, baseY) = scrollUsable(screen: screen, config: config)
    let vx = viewportX ?? state.effectiveViewportX(usableW: usableW)
    /// How much of a column has to be on screen for AX to place it honestly.
    /// The clamp leaves 40pt; 48 keeps a margin over it, and a column narrower
    /// than that is measured against its own width instead so a deliberately
    /// tiny column is never unreachable.
    let minVisible = 48.0

    // Strip positions (raw widths, matching columnRange).
    var stripX: [Double] = []
    var cursor = 0.0
    for col in state.columns {
        stripX.append(cursor)
        cursor += col.width * usableW
    }

    var frames: [WindowID: Frame] = [:]
    var parked = Set<WindowID>()
    for (i, col) in state.columns.enumerated() {
        let x0 = stripX[i]
        let drawX = baseX + (x0 - vx) + gap / 2
        // Half-gap inset per side so columns don't touch.
        let drawW = max(col.width * usableW - gap, 1)
        let onScreen = min(drawX + drawW, screen.x + screen.width) - max(drawX, screen.x)
        if onScreen < min(minVisible, drawW) {
            parked.formUnion(col.windows)
            if cull { continue }
        }
        // Rows divide the column height by their stored shares (equal until
        // something resizes them), inner gaps between.
        let n = max(col.windows.count, 1)
        let totalGap = gap * Double(max(n - 1, 0))
        let avail = max(usableH - totalGap, 1)
        var y = baseY
        for (r, wid) in col.windows.enumerated() {
            let share = col.heights[safe: r] ?? 1.0 / Double(n)
            // Last row takes the remainder so rounding never leaks a pixel.
            let h = (r == n - 1) ? (baseY + usableH - y) : avail * share
            frames[wid] = Frame(x: drawX, y: y, width: drawW, height: max(h, 1))
            y += h + gap
        }
    }
    // Same as the bsp path: zoom fills the tiling area, gaps and reserve
    // included, rather than the whole display.
    if let fs = state.fullscreen, state.windows.contains(fs) {
        frames[fs] = Frame(x: baseX, y: baseY, width: usableW, height: usableH)
        // A zoomed window covers the screen, so it is visible by definition
        // even when its own column has scrolled out of the strip. Without
        // this it was handed a frame and parked in the same pass.
        parked.remove(fs)
    }
    return (frames, parked)
}
