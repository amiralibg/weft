// WeftCore/Command.swift — one grammar for keybinds AND weftctl (§7).
//
// Anything bindable is scriptable: config values and CLI args parse through
// `Command.parse`. M2 covers tiling on one display; spaces/displays/scroll/
// stack arrive in M3–M5 and extend this enum (never a second grammar).

public enum Direction: String, Sendable, Equatable {
    case west, east, north, south
}

public enum ResizeDirection: String, Sendable, Equatable {
    case left, right, up, down
}

public enum Command: Sendable, Equatable {
    // Focus / warp (swap with neighbour)
    case focus(Direction)
    case move(Direction)
    // Resize focused window; delta in points along the direction.
    case resize(ResizeDirection, Double)
    // Orientation for the next bsp insertion.
    case split(ContainerLayout)
    case insertion(Tree.InsertionMode)
    case balance
    // Stack containers (M3).
    case stack(StackCommand)
    // Scroll strip (M5).
    case scroll(ScrollCommand)
    // Native spaces (M4).
    case space(SpaceCommand)
    case sticky(WindowID?, StickyMode)
    case focusDisplay(DisplayTarget)
    /// Send the focused window to another display's current space.
    /// `follow` makes focus go with it — yabai needs two chained commands
    /// (`window --display east && display --focus east`) for that, and a
    /// weft keybind is a single command.
    case moveWindowToDisplay(DisplayTarget, follow: Bool)
    /// Send the whole current space to another display.
    case moveSpaceToDisplay(DisplayTarget)
    // App launcher/focus/hide (M6): not running → open; running, not
    // frontmost → focus it (space switch + raise); frontmost → hide.
    case appToggle(String)
    // Window toggles
    case toggleFullscreen
    case toggleSplit
    case toggleFloat
    // Tree membership (also produced by window-created/destroyed events).
    case insert(WindowID)
    case remove(WindowID)
    case setFocus(WindowID)
    // Read-only (M1 query path, kept in the grammar so keybinds can use it).
    case query(QueryKind)
}

public enum StackCommand: Sendable, Equatable {
    /// i3-style: convert the parent container into a stack.
    case wrap
    /// Pull the neighbour in `dir` into a stack with the focused window.
    case split(Direction)
    /// Cycle the active member of the focused stack.
    case next
    case prev
    /// Convert the focused stack back to a vertical split.
    case unstack
}

public enum ScrollCommand: Sendable, Equatable {
    /// Focus the adjacent column by strip index (reaches parked columns;
    /// the viewport follows on apply).
    case focusColumn(Int)
    /// Move the focused window into the adjacent column (merge).
    case moveColumn(Int)
    /// Cycle the focused column through the width preset ring.
    case widthCycle
}

public enum QueryKind: String, Sendable, Equatable {
    case displays, spaces, windows, world, capability
}

public enum SpaceCommand: Sendable, Equatable {
    /// Focus a space by label, sid, or 1-based ordinal.
    case focus(String)
    /// Move a window (default: focused) to a space without following it.
    /// Verified; reports needs-weft-sa when the SLS call is ignored.
    case moveWindow(String, WindowID?)
    /// Rename the current space (persists by ordinal).
    case label(String)
    /// Switch the current space's layout, preserving membership.
    case layout(String)
}

public enum StickyMode: String, Sendable, Equatable {
    case on, off, toggle
}

public enum DisplayTarget: Sendable, Equatable {
    /// `next`/`prev` deliberately do NOT wrap: yabai fails at the last
    /// display, which is what makes `{ … next … } || { … first … }` in a
    /// keybind land on the first display instead of silently doing nothing.
    /// `cycle` is that whole chain in one word — next, wrapping to first.
    case next, prev, west, east, north, south, first, last, cycle
    case index(Int)  // 1-based, west→east
}

extension DisplayTarget {
    /// Shared by `focus display …`, `move display …` and `move space display …`.
    public static func parse(_ word: String) -> DisplayTarget? {
        switch word {
        case "next": return .next
        case "prev": return .prev
        case "west": return .west
        case "east": return .east
        case "north", "up": return .north
        case "south", "down": return .south
        case "first": return .first
        case "last": return .last
        case "cycle": return .cycle
        default:
            guard let n = Int(word), n >= 1 else { return nil }
            return .index(n)
        }
    }
}

public enum CommandParseError: Error, Sendable, Equatable {
    case empty
    case unknown(String)
    case badArgs(String)
}

extension Command {
    /// Parse `"focus west"`, `"move east"`, `"resize right 60"`,
    /// `"split vertical"`, `"balance"`, `"insert 139"`, `"query windows"`.
    public static func parse(_ input: String) throws -> Command {
        let parts = input.split(separator: " ").map(String.init)
        guard let head = parts.first else { throw CommandParseError.empty }
        switch head {
        case "fullscreen", "zoom-fullscreen":
            return .toggleFullscreen
        case "toggle":
            guard parts.count >= 2 else { throw CommandParseError.badArgs(input) }
            switch parts[1] {
            case "fullscreen", "zoom-fullscreen": return .toggleFullscreen
            case "split": return .toggleSplit
            case "float": return .toggleFloat
            default: throw CommandParseError.badArgs(input)
            }
        case "window":
            guard parts.count >= 3, parts[1] == "toggle" else { throw CommandParseError.badArgs(input) }
            switch parts[2] {
            case "fullscreen", "zoom-fullscreen": return .toggleFullscreen
            case "split": return .toggleSplit
            case "float": return .toggleFloat
            default: throw CommandParseError.badArgs(input)
            }
        case "float":
            if parts.count == 2 && parts[1] == "toggle" { return .toggleFloat }
            throw CommandParseError.badArgs(input)
        case "focus":
            // `focus display <…>` switches display; plain `focus <dir>` moves
            // within the space — the display keyword disambiguates.
            if parts.count == 3, parts[1] == "display" {
                guard let target = DisplayTarget.parse(parts[2]) else {
                    throw CommandParseError.badArgs(input)
                }
                return .focusDisplay(target)
            }
            guard parts.count == 2, let dir = Direction(rawValue: parts[1]) else {
                throw CommandParseError.badArgs(input)
            }
            return .focus(dir)
        case "move":
            // `move display <…>` sends the window to another display and
            // `move space display <…>` sends the whole desktop; plain
            // `move <dir>` still moves within the space.
            if parts.count >= 3, parts[1] == "display" {
                guard let target = DisplayTarget.parse(parts[2]) else {
                    throw CommandParseError.badArgs(input)
                }
                switch parts.count {
                case 3: return .moveWindowToDisplay(target, follow: false)
                case 4 where parts[3] == "--follow" || parts[3] == "follow":
                    return .moveWindowToDisplay(target, follow: true)
                default: throw CommandParseError.badArgs(input)
                }
            }
            if parts.count == 4, parts[1] == "space", parts[2] == "display" {
                guard let target = DisplayTarget.parse(parts[3]) else {
                    throw CommandParseError.badArgs(input)
                }
                return .moveSpaceToDisplay(target)
            }
            guard parts.count == 2, let dir = Direction(rawValue: parts[1]) else {
                throw CommandParseError.badArgs(input)
            }
            return .move(dir)
        case "resize":
            guard parts.count == 3,
                  let dir = ResizeDirection(rawValue: parts[1]),
                  let delta = Double(parts[2])
            else { throw CommandParseError.badArgs(input) }
            return .resize(dir, delta)
        case "split":
            guard parts.count >= 2 else { throw CommandParseError.badArgs(input) }
            switch parts[1] {
            case "vertical", "v", "east", "west": return .split(.splitV)
            case "horizontal", "h", "north", "south": return .split(.splitH)
            case "toggle", "flip": return .toggleSplit
            default: throw CommandParseError.badArgs(input)
            }
        case "insertion":
            guard parts.count == 2 else { throw CommandParseError.badArgs(input) }
            switch parts[1] {
            case "bsp": return .insertion(.bsp)
            case "manual": return .insertion(.manual)
            default: throw CommandParseError.badArgs(input)
            }
        case "balance":
            return .balance
        case "scroll":
            // scroll focus prev-column|next-column
            // scroll move-window prev-column|next-column
            // scroll width cycle
            guard parts.count >= 2 else { throw CommandParseError.badArgs(input) }
            switch parts[1] {
            case "focus":
                guard parts.count == 3 else { throw CommandParseError.badArgs(input) }
                switch parts[2] {
                case "prev-column": return .scroll(.focusColumn(-1))
                case "next-column": return .scroll(.focusColumn(1))
                default: throw CommandParseError.badArgs(input)
                }
            case "move-window":
                guard parts.count == 3 else { throw CommandParseError.badArgs(input) }
                switch parts[2] {
                case "prev-column": return .scroll(.moveColumn(-1))
                case "next-column": return .scroll(.moveColumn(1))
                default: throw CommandParseError.badArgs(input)
                }
            case "width":
                guard parts == ["scroll", "width", "cycle"] else {
                    throw CommandParseError.badArgs(input)
                }
                return .scroll(.widthCycle)
            default: throw CommandParseError.badArgs(input)
            }
        case "space":
            guard parts.count >= 3 else { throw CommandParseError.badArgs(input) }
            switch parts[1] {
            case "focus":
                return .space(.focus(parts[2...].joined(separator: " ")))
            case "move-window":
                let wid: WindowID? = parts.count > 3 ? UInt32(parts[3]) : nil
                if parts.count > 3, wid == nil { throw CommandParseError.badArgs(input) }
                return .space(.moveWindow(parts[2], wid))
            case "label":
                return .space(.label(parts[2...].joined(separator: " ")))
            case "layout":
                guard parts.count == 3,
                      ["bsp", "scroll", "float", "toggle"].contains(parts[2])
                else { throw CommandParseError.badArgs(input) }
                return .space(.layout(parts[2]))
            default: throw CommandParseError.badArgs(input)
            }
        case "sticky":
            // sticky | sticky <wid> | sticky <wid> <on|off|toggle> | sticky <on|off|toggle>
            var wid: WindowID?
            var mode = StickyMode.toggle
            for token in parts.dropFirst() {
                if let id = UInt32(token) { wid = id }
                else if let m = StickyMode(rawValue: token) { mode = m }
                else { throw CommandParseError.badArgs(input) }
            }
            return .sticky(wid, mode)
        case "app":
            guard parts.count >= 3, parts[1] == "toggle" else {
                throw CommandParseError.badArgs(input)
            }
            return .appToggle(parts[2...].joined(separator: " "))
        case "stack":
            guard parts.count >= 2 else { throw CommandParseError.badArgs(input) }
            switch parts[1] {
            case "wrap": return .stack(.wrap)
            case "next": return .stack(.next)
            case "prev": return .stack(.prev)
            case "unstack": return .stack(.unstack)
            case "split":
                guard parts.count == 3 else { throw CommandParseError.badArgs(input) }
                switch parts[2] {
                case "west": return .stack(.split(.west))
                case "east": return .stack(.split(.east))
                case "north": return .stack(.split(.north))
                case "south": return .stack(.split(.south))
                case "left": return .stack(.split(.west))
                case "right": return .stack(.split(.east))
                case "up": return .stack(.split(.north))
                case "down": return .stack(.split(.south))
                default: throw CommandParseError.badArgs(input)
                }
            default: throw CommandParseError.badArgs(input)
            }
        case "insert":
            guard parts.count == 2, let id = UInt32(parts[1]) else {
                throw CommandParseError.badArgs(input)
            }
            return .insert(id)
        case "remove":
            guard parts.count == 2, let id = UInt32(parts[1]) else {
                throw CommandParseError.badArgs(input)
            }
            return .remove(id)
        case "set-focus":
            guard parts.count == 2, let id = UInt32(parts[1]) else {
                throw CommandParseError.badArgs(input)
            }
            return .setFocus(id)
        case "query":
            guard parts.count == 2, let kind = QueryKind(rawValue: parts[1]) else {
                throw CommandParseError.badArgs(input)
            }
            return .query(kind)
        default:
            throw CommandParseError.unknown(head)
        }
    }
}

extension ResizeDirection {
    public var axis: ResizeAxis {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }

    /// Signed delta along the axis: right/down grow, left/up shrink.
    public func signed(_ magnitude: Double) -> Double {
        switch self {
        case .right, .down: return magnitude
        case .left, .up: return -magnitude
        }
    }
}
