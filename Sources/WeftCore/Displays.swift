// WeftCore/Displays.swift — where hidden windows go, and which display a
// workspace is pinned to. Pure geometry and matching; no AppKit.

/// A corner of a display, where a hidden workspace's windows are parked.
public enum Corner: String, Sendable, Equatable, CaseIterable {
    case bottomRight, bottomLeft, topRight, topLeft
}

/// The overlap, in points², of two frames. Zero when they only touch.
private func overlap(_ a: Frame, _ b: Frame) -> Double {
    let w = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
    let h = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
    return w > 0 && h > 0 ? w * h : 0
}

/// The area a window parked at `corner` of `display` can cover: from the
/// one point left on screen, outward by the display's own size — no window
/// weft lays out is bigger than its display.
func parkZone(_ corner: Corner, of display: Frame) -> Frame {
    let right = display.x + display.width - 1
    let bottom = display.y + display.height - 1
    switch corner {
    case .bottomRight:
        return Frame(x: right, y: bottom, width: display.width, height: display.height)
    case .bottomLeft:
        return Frame(x: display.x - display.width + 1, y: bottom, width: display.width, height: display.height)
    case .topRight:
        return Frame(x: right, y: display.y - display.height + 1, width: display.width, height: display.height)
    case .topLeft:
        return Frame(
            x: display.x - display.width + 1, y: display.y - display.height + 1,
            width: display.width, height: display.height
        )
    }
}

/// The first corner of `display` a parked window can use without landing on
/// another display, in the order bottom-right, bottom-left, top-right,
/// top-left. Nil when every corner has a neighbour — a middle monitor with
/// displays on both sides and above.
///
/// A window parked into a neighbour does not stay hidden: it shows up on the
/// other monitor, and macOS may move it to that display's desktop.
/// Bottom-right comes first because it is the corner S9 measured, and because
/// Accessibility clamps parking toward negative x (S4).
public func freeCorner(of display: Frame, among others: [Frame]) -> Corner? {
    let neighbours = others.filter { $0 != display }
    return Corner.allCases.first { corner in
        let zone = parkZone(corner, of: display)
        return !neighbours.contains { overlap(zone, $0) > 0 }
    }
}

/// Where a window of `size` goes to be parked at `corner`: the window sits
/// outside the display with one point of it still on screen, which is what
/// keeps it in the on-screen window list (S9).
public func parkOrigin(width: Double, height: Double, corner: Corner, in display: Frame) -> (x: Double, y: Double) {
    let right = display.x + display.width - 1
    let bottom = display.y + display.height - 1
    switch corner {
    case .bottomRight: return (right, bottom)
    case .bottomLeft: return (display.x - width + 1, bottom)
    case .topRight: return (right, display.y - height + 1)
    case .topLeft: return (display.x - width + 1, display.y - height + 1)
    }
}

// MARK: - Pinning a workspace to a display

/// `[[space]] display = …`: which display a workspace shows on.
public enum DisplayPin: Sendable, Equatable {
    /// The display with the menu bar at rest (CGMainDisplayID).
    case main
    /// The first display that is not the main one, west to east.
    case secondary
    /// 1-based, west to east — what `focus display N` counts.
    case index(Int)
    /// A display whose name contains this, ignoring case ("Studio", "LG").
    case named(String)

    public init(_ text: String) {
        switch text.lowercased() {
        case "main", "primary": self = .main
        case "secondary", "external": self = .secondary
        default:
            if let n = Int(text), n >= 1 { self = .index(n) } else { self = .named(text) }
        }
    }
}

/// A connected display, as pin resolution needs it.
public struct DisplayIdentity: Sendable, Equatable {
    public var uuid: String
    public var name: String
    public var isMain: Bool

    public init(uuid: String, name: String, isMain: Bool) {
        self.uuid = uuid
        self.name = name
        self.isMain = isMain
    }
}

/// The display a pin names, among `displays` given west to east. Nil when it
/// names nothing connected — the workspace then behaves as unpinned until
/// that display comes back.
public func resolvePin(_ pin: DisplayPin, among displays: [DisplayIdentity]) -> String? {
    switch pin {
    case .main:
        return displays.first(where: \.isMain)?.uuid ?? displays.first?.uuid
    case .secondary:
        return displays.first { !$0.isMain }?.uuid
    case .index(let n):
        return displays.indices.contains(n - 1) ? displays[n - 1].uuid : nil
    case .named(let text):
        return displays.first { $0.name.lowercased().contains(text.lowercased()) }?.uuid
    }
}
