// WeftCore/Displays.swift — which display a name means, and where 0.9.21
// parked windows. Pure geometry and matching; no AppKit.

/// A corner of a display, where 0.9.21 parked a hidden workspace's windows.
/// Read back from its ledger at startup; nothing parks any more.
public enum Corner: String, Sendable, Equatable, CaseIterable {
    case bottomRight, bottomLeft, topRight, topLeft
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
    /// The Mac's own screen. Asked of the display itself, so it holds
    /// whichever display has the menu bar.
    case builtIn
    /// The first display that is not the Mac's own screen, west to east. On
    /// a Mac with no screen of its own, the first that is not the main one.
    case external
    /// 1-based, west to east — what `focus display N` counts.
    case index(Int)
    /// A display whose name contains this, ignoring case ("Studio", "LG").
    case named(String)

    public init(_ text: String) {
        switch text.lowercased() {
        case "main", "primary": self = .main
        case "secondary": self = .secondary
        case "built-in", "builtin", "internal", "laptop": self = .builtIn
        case "external": self = .external
        default:
            if let n = Int(text), n >= 1 { self = .index(n) } else { self = .named(text) }
        }
    }
}

/// `visible` with a menu bar at the top of `display` taken off it. A bar
/// counts when it starts at the display's top edge and lies within its width;
/// one already outside `visible` (the main display's, which `visibleFrame`
/// removes itself) changes nothing.
public func belowMenuBars(_ visible: Frame, display: Frame, menuBars: [Frame]) -> Frame {
    var out = visible
    for bar in menuBars
    where abs(bar.y - display.y) < 1 && bar.x >= display.x - 1 && bar.x + bar.width <= display.x + display.width + 1 {
        let top = bar.y + bar.height
        if out.y < top {
            out.height -= top - out.y
            out.y = top
        }
    }
    return out
}

/// A connected display, as pin resolution needs it.
public struct DisplayIdentity: Sendable, Equatable {
    public var uuid: String
    public var name: String
    public var isMain: Bool
    /// The Mac's own screen (`CGDisplayIsBuiltin`).
    public var isBuiltIn: Bool

    public init(uuid: String, name: String, isMain: Bool, isBuiltIn: Bool = false) {
        self.uuid = uuid
        self.name = name
        self.isMain = isMain
        self.isBuiltIn = isBuiltIn
    }

    /// Built in by the display's own answer, or failing that by the name
    /// macOS gives the Mac's screen.
    var looksBuiltIn: Bool { isBuiltIn || name.lowercased().contains("built-in") }

    /// What to call each of `uuids` in a list of displays: the name System
    /// Settings shows, numbered when two displays share it (two of the same
    /// monitor), and "Display N" — its place in the list — when it has none
    /// or is not connected.
    public static func titles(for uuids: [String], among displays: [DisplayIdentity]) -> [String] {
        let names = uuids.map { uuid in displays.first { $0.uuid == uuid }?.name ?? "" }
        return names.enumerated().map { i, name in
            guard !name.isEmpty else { return "Display \(i + 1)" }
            let same = names.enumerated().filter { $0.element == name }.map(\.offset)
            guard same.count > 1, let n = same.firstIndex(of: i) else { return name }
            return "\(name) \(n + 1)"
        }
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
    case .builtIn:
        return displays.first(where: \.looksBuiltIn)?.uuid
    case .external:
        return displays.contains(where: \.looksBuiltIn)
            ? displays.first { !$0.looksBuiltIn }?.uuid
            : displays.first { !$0.isMain }?.uuid
    case .index(let n):
        return displays.indices.contains(n - 1) ? displays[n - 1].uuid : nil
    case .named(let text):
        return displays.first { $0.name.lowercased().contains(text.lowercased()) }?.uuid
    }
}
