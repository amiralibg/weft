// WeftCore/Command.swift — one grammar for keybinds AND weftctl (§7).
//
// Anything bindable is scriptable: config values and CLI args parse through
// `Command.parse`. M2 covers tiling on one display; spaces/displays/
// stack arrive in M3–M5 and extend this enum (never a second grammar).

public enum Direction: String, Sendable, Equatable {
    case west, east, north, south
}

public enum ResizeDirection: String, Sendable, Equatable {
    case left, right, up, down
}

public enum Command: Sendable, Equatable {
    case focus(Direction)
    /// Move the focused window one step, restructuring the tree — i3's `move`,
    /// yabai's `window --warp`. See `Tree.moving(_:towards:)`.
    case move(Direction)
    /// Trade places with the window in that direction, leaving the tree's
    /// shape alone — yabai's `window --swap`. The two windows take each
    /// other's slots, so a window swapped into a smaller slot gets smaller.
    /// `move` is what a keybind usually wants; this is the literal version.
    case swap(Direction)
    // Resize focused window; delta in points along the direction.
    case resize(ResizeDirection, Double)
    // Orientation for the next bsp insertion.
    case split(ContainerLayout)
    case insertion(Tree.InsertionMode)
    case balance
    // Stack containers (M3).
    case stack(StackCommand)
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
    /// Run a shell command. The payload is the rest of the line, verbatim —
    /// weft does not tokenise it, because `/bin/sh -c` is the point: a config
    /// migrated from skhd is full of lines that are not window-manager verbs.
    case exec(String)
    // Window toggles
    case toggleFullscreen
    case toggleSplit
    /// Take one window out of the layout (or put it back). `on`/`off` are the
    /// scriptable halves; `toggle` is what a keybind wants.
    case float(StickyMode)
    // Tree membership (also produced by window-created/destroyed events).
    case insert(WindowID)
    case remove(WindowID)
    case setFocus(WindowID)
    // Read-only (M1 query path, kept in the grammar so keybinds can use it).
    case query(QueryKind)
}

public enum StackCommand: Sendable, Equatable {
    /// i3-style: convert the parent container into a stack, and take the
    /// focused window back out of one it is already in. `wrap` parses to this
    /// too — it named the half of the behaviour that existed at the time, and
    /// every config in the wild spells it that way.
    case toggle
    /// Pull the neighbour in `dir` into a stack with the focused window.
    case split(Direction)
    /// Cycle the active member of the focused stack.
    case next
    case prev
    /// Convert the focused stack back to a vertical split.
    case unstack
    /// Every window on the space in one stack; again to undo.
    case all
    /// Put the focused window into the neighbour's stack in `dir`.
    case move(Direction)
}

public enum QueryKind: String, Sendable, Equatable {
    case displays, spaces, windows, world, capability
}

public enum SpaceCommand: Sendable, Equatable {
    /// Focus a space by label, sid, or 1-based ordinal.
    case focus(String)
    /// Move a window (default: focused) to a space, and by default go with it.
    ///
    /// Verified by re-reading membership. The move works by holding the window
    /// and pressing the bound "move a space" shortcut — the only route macOS 27
    /// leaves open from an ordinary process (spikes/RESULTS.md §S8) — so the
    /// screen visibly changes desktop on the way. **That is why following is
    /// the default.** Not following means changing desktop and changing back,
    /// which costs an extra switch to end up where a user who just sent a
    /// window somewhere usually did not want to be, and reads as a bug rather
    /// than as the deliberate "do not follow" it is. `--no-follow` is still
    /// there for scripts and for anyone who means it.
    case moveWindow(String, WindowID?, follow: Bool)
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
        // Before the split-on-spaces grammar below, and from the raw string:
        // everything else here is a fixed set of words, and this is the one
        // verb whose argument is arbitrary text. Rejoining `parts` would
        // collapse runs of spaces and silently rewrite `sed 's/a  b/c/'`.
        if head == "exec" {
            let body = input.drop(while: { $0 == " " }).dropFirst("exec".count)
            let command = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { throw CommandParseError.badArgs(input) }
            return .exec(command)
        }
        switch head {
        case "fullscreen", "zoom-fullscreen":
            return .toggleFullscreen
        case "toggle":
            guard parts.count >= 2 else { throw CommandParseError.badArgs(input) }
            switch parts[1] {
            case "fullscreen", "zoom-fullscreen": return .toggleFullscreen
            case "split": return .toggleSplit
            case "float": return .float(.toggle)
            default: throw CommandParseError.badArgs(input)
            }
        case "window":
            guard parts.count >= 3, parts[1] == "toggle" else { throw CommandParseError.badArgs(input) }
            switch parts[2] {
            case "fullscreen", "zoom-fullscreen": return .toggleFullscreen
            case "split": return .toggleSplit
            case "float": return .float(.toggle)
            default: throw CommandParseError.badArgs(input)
            }
        case "float":
            // Bare `float` is the toggle: the keybind spelling people reach
            // for first, and there is nothing else it could mean.
            guard parts.count <= 2 else { throw CommandParseError.badArgs(input) }
            guard parts.count == 2 else { return .float(.toggle) }
            guard let mode = StickyMode(rawValue: parts[1]) else {
                throw CommandParseError.badArgs(input)
            }
            return .float(mode)
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
        case "swap":
            guard parts.count == 2, let dir = Direction(rawValue: parts[1]) else {
                throw CommandParseError.badArgs(input)
            }
            return .swap(dir)
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
        case "space":
            guard parts.count >= 3 else { throw CommandParseError.badArgs(input) }
            switch parts[1] {
            case "focus":
                return .space(.focus(parts[2...].joined(separator: " ")))
            case "move-window":
                // `space move-window <target> [wid] [--follow|--no-follow]`,
                // flags in any trailing position so neither ordering surprises
                // anyone.
                var wid: WindowID?
                var follow = true
                for token in parts.dropFirst(3) {
                    switch token {
                    case "--follow", "follow": follow = true
                    case "--no-follow", "no-follow": follow = false
                    default:
                        guard wid == nil, let id = UInt32(token) else {
                            throw CommandParseError.badArgs(input)
                        }
                        wid = id
                    }
                }
                return .space(.moveWindow(parts[2], wid, follow: follow))
            case "label":
                return .space(.label(parts[2...].joined(separator: " ")))
            case "layout":
                // "scroll" still parses. The layout is gone, but someone
                // whose keybind or muscle memory still says it deserves an
                // answer that explains that, not a syntax error — the daemon
                // maps it to bsp and says so.
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
            case "toggle", "wrap": return .stack(.toggle)
            case "next": return .stack(.next)
            case "prev": return .stack(.prev)
            case "unstack": return .stack(.unstack)
            case "all":
                guard parts.count == 2 else { throw CommandParseError.badArgs(input) }
                return .stack(.all)
            case "split", "move":
                guard parts.count == 3 else { throw CommandParseError.badArgs(input) }
                let dir: Direction
                switch parts[2] {
                case "west", "left": dir = .west
                case "east", "right": dir = .east
                case "north", "up": dir = .north
                case "south", "down": dir = .south
                default: throw CommandParseError.badArgs(input)
                }
                return parts[1] == "split" ? .stack(.split(dir)) : .stack(.move(dir))
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
