// WeftCore/Scroll.swift — niri-style scroll layout (M5), pure.
//
// An ordered horizontal strip of columns; each column holds a vertical stack
// of windows. The viewport (viewportX) pans so the focused column is visible;
// columns entirely outside viewport ± margin are PARKED (SLSMoveWindow to
// union.minX - 5000, S4) and cost nothing until re-entry. Unparking needs the
// nudge protocol (SLS back + AX different + AX target) — platform side.
//
// Visible columns move via AX only (S2 rejected SLSMoveWindow for visible
// windows: the app desyncs). Parking is SLS-only (AX clamps at -(width-40)).

public enum CenterMode: String, Codable, Sendable, Equatable {
    case always
    case never
    case onOverflow
}

public struct Column: Sendable, Equatable {
    public var windows: [WindowID]
    /// Fraction of usable width. Cycles the preset ring; resize adjusts.
    public var width: Double

    public init(windows: [WindowID], width: Double = ScrollState.defaultWidth) {
        self.windows = windows
        self.width = width
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
            Column(windows: col.windows.filter { $0 != id }, width: col.width)
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

    /// Move the focused window into the adjacent column (merge). Empty
    /// columns are dropped. Focus stays on the moved window.
    public func movingWindowToColumn(_ delta: Int) -> ScrollState {
        guard columns.indices.contains(focusCol),
              let wid = focusedWindow
        else { return self }
        let target = focusCol + delta
        guard columns.indices.contains(target) else { return self }
        var copy = self
        copy.columns[focusCol].windows.removeAll(where: { $0 == wid })
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
        copy.focusCol = t
        copy.focusRow = copy.columns[t].windows.count - 1
        return copy
    }

    /// Cycle the focused column through the preset ring.
    public func cyclingWidth() -> ScrollState {
        guard columns.indices.contains(focusCol) else { return self }
        var copy = self
        let cur = copy.columns[focusCol].width
        var best = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, p) in ScrollState.presets.enumerated() {
            let d = abs(p - cur)
            if d < bestDist { bestDist = d; best = i }
        }
        copy.columns[focusCol].width = ScrollState.presets[(best + 1) % ScrollState.presets.count]
        return copy
    }

    /// Nudge the focused column width (resize left/right). Clamped.
    public func adjustingWidth(_ delta: Double) -> ScrollState {
        guard columns.indices.contains(focusCol) else { return self }
        var copy = self
        copy.columns[focusCol].width = min(max(copy.columns[focusCol].width + delta, 0.15), 1.0)
        return copy
    }

    /// Swap two windows' positions (may span columns). Focus stays on `a`.
    public func swapping(_ a: WindowID, _ b: WindowID) -> ScrollState {
        guard a != b, windows.contains(a), windows.contains(b) else { return self }
        var copy = self
        copy.columns = copy.columns.map { col in
            Column(
                windows: col.windows.map { $0 == a ? b : ($0 == b ? a : $0) },
                width: col.width
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
        guard columns.indices.contains(col), usableW > 0, screen.width > 0 else { return }
        let outerLeft = config.outerGap.left
        let windowW = screen.width - outerLeft  // visible strip span below vx
        let (x0, x1) = columnRange(col, usableW: usableW)
        // 1. Minimum scroll to fit (left edge first, then right).
        var vx = viewportX
        if x0 < vx - outerLeft { vx = x0 + outerLeft }
        if x1 > vx + windowW { vx = x1 - windowW }
        // 2. Center modes, against the fresh window.
        let mid = (vx - outerLeft + vx + windowW) / 2
        switch centerMode {
        case .never:
            break
        case .always:
            vx += (x0 + x1) / 2 - mid
        case .onOverflow:
            // Only center what can't fit: it never sits fully in view.
            if x1 - x0 > screen.width { vx += (x0 + x1) / 2 - mid }
        }
        viewportX = max(vx, 0)
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
    }

    public var columns: [ColumnView]
    public var focusCol: Int
    public var focusRow: Int
    public var viewportX: Double
    public var centerMode: CenterMode

    public static func of(_ state: ScrollState) -> ScrollView {
        ScrollView(
            columns: state.columns.map { ColumnView(windows: $0.windows, width: $0.width) },
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
/// Parked = entirely outside [vx - margin, vx + w + margin], margin = w.
/// Returned frames are final (screen coords); parked windows get no frame —
/// the daemon SLS-parks them and persists the set.
public func scrollLayout(
    _ state: ScrollState,
    screen: Frame,
    config: TilingConfig
) -> (frames: [WindowID: Frame], parked: Set<WindowID>) {
    let gap = config.innerGap
    let (usableW, usableH, baseX, baseY) = scrollUsable(screen: screen, config: config)
    let vx = state.viewportX
    let margin = screen.width

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
        let x1 = x0 + col.width * usableW
        // Entirely outside the window (with margin) → parked, zero cost.
        if x1 < vx - margin || x0 > vx + screen.width + margin {
            parked.formUnion(col.windows)
            continue
        }
        let drawX = baseX + (x0 - vx) + gap / 2
        // Half-gap inset per side so columns don't touch (parking math stays
        // on raw strip widths — conservative, keeps marginal columns alive).
        let drawW = max(col.width * usableW - gap, 1)
        // Rows split the column height equally, inner gaps between.
        let n = max(col.windows.count, 1)
        let totalGap = gap * Double(max(n - 1, 0))
        let rowH = max((usableH - totalGap) / Double(n), 1)
        var y = baseY
        for (r, wid) in col.windows.enumerated() {
            let h = (r == n - 1) ? (baseY + usableH - y) : rowH
            frames[wid] = Frame(x: drawX, y: y, width: drawW, height: max(h, 1))
            y += h + gap
        }
    }
    if let fs = state.fullscreen, state.windows.contains(fs) {
        frames[fs] = screen
    }
    return (frames, parked)
}
