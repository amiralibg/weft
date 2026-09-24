import CoreServices
import Foundation

// Everything a shortcut can do, in words.
//
// weft's commands are a small language (`space move-window 3 --no-follow`), and
// nobody setting up a shortcut should have to learn it. Each `ShortcutAction`
// here is one thing a person would say they want — "go to a workspace", "open
// an app" — with the blanks they fill in (which workspace, which app), how
// those turn into the command weft runs, and how to read an existing command
// back into the same blanks so a shortcut can be edited the way it was made.
//
// Anything the catalog does not recognise still round-trips: it becomes a
// "weft command" step that shows the text as written.

public enum ActionCategory: String, CaseIterable, Identifiable, Sendable {
    case windows = "Windows"
    case workspaces = "Workspaces"
    case layout = "Layout"
    case displays = "Displays"
    case stacks = "Stacks"
    case apps = "Apps & Web"
    case advanced = "Advanced"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .windows: return "macwindow"
        case .workspaces: return "square.grid.2x2"
        case .layout: return "rectangle.split.3x1"
        case .displays: return "display.2"
        case .stacks: return "square.stack"
        case .apps: return "app.badge"
        case .advanced: return "terminal"
        }
    }
}

/// One blank in an action.
public enum ActionParam: Equatable, Sendable {
    /// Toward another window: west, south, north, east.
    case direction
    /// The side a window grows on: left, right, up, down.
    case edge
    case workspace
    case display
    case app
    case amount
    case layout
    case splitAxis
    /// "follow" or "stay".
    case follow
    case mode
    case url
    case path
    case shell
    case raw

    public var initial: String {
        switch self {
        case .direction: return "west"
        case .edge: return "right"
        case .workspace: return "1"
        case .display: return "next"
        case .amount: return "40"
        case .layout: return "toggle"
        case .splitAxis: return "vertical"
        case .follow: return "follow"
        case .app, .mode, .url, .path, .shell, .raw: return ""
        }
    }

    /// The values a command may hold here, when there is a fixed set.
    public var choices: [String]? {
        switch self {
        case .direction: return ["west", "south", "north", "east"]
        case .edge: return ["left", "right", "up", "down"]
        case .layout: return ["bsp", "float", "toggle"]
        case .splitAxis: return ["vertical", "horizontal"]
        case .follow: return ["follow", "stay"]
        default: return nil
        }
    }

    public func accepts(_ value: String) -> Bool {
        if value.isEmpty { return false }
        if let choices { return choices.contains(value) }
        switch self {
        case .amount: return Double(value) != nil
        case .display: return ActionWords.displays.keys.contains(value) || Int(value).map { $0 >= 1 } == true
        case .workspace: return value != "recent" && !value.contains(" ")
        default: return true
        }
    }
}

public struct ShortcutAction: Identifiable, Sendable {
    public let id: String
    public let category: ActionCategory
    public let symbol: String
    /// What it does, as a person would ask for it: "Go to a workspace".
    public let title: String
    /// One line more, for the library.
    public let detail: String
    public let params: [ActionParam]
    /// The filled-in blanks → the command weft runs.
    public let command: @Sendable ([String]) -> String
    /// A command → its blanks, when the command is this action.
    public let read: @Sendable (String) -> [String]?
    /// The filled-in blanks → the action said in a sentence, lower case:
    /// "go to workspace 3".
    public let phrase: @Sendable ([String]) -> String
}

/// How weft's words are said to a person.
public enum ActionWords {
    public static let directions = ["west": "left", "east": "right", "north": "up", "south": "down"]
    public static let towards = ["west": "to the left", "east": "to the right", "north": "above", "south": "below"]
    public static let displays: [String: String] = [
        "west": "the display to the left", "east": "the display to the right",
        "north": "the display above", "south": "the display below",
        "next": "the next display", "prev": "the previous display",
        "cycle": "the next display, going round", "first": "the first display", "last": "the last display",
    ]

    public static func display(_ value: String) -> String {
        if let n = Int(value) { return "display \(n)" }
        return displays[value] ?? value
    }

    public static func workspace(_ value: String) -> String {
        if value == "recent" { return "the last workspace" }
        return Int(value) != nil ? "workspace \(value)" : "“\(value)”"
    }

    /// An app's name from its bundle id, as the Finder shows it.
    public static func appName(_ bundleID: String) -> String {
        if let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?
            .takeRetainedValue() as? [URL], let url = urls.first {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    /// A string as one shell word: `open 'My Folder'`.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Back from `shellQuote`, or the text as it was when it is not one word
    /// in single quotes.
    public static func shellUnquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.hasPrefix("'"), t.hasSuffix("'") else { return t }
        return String(t.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }

    /// A path as one shell word, leaving a leading `~/` outside the quotes so
    /// the shell still expands it: `~/'My Stuff'`.
    public static func shellPath(_ path: String) -> String {
        path.hasPrefix("~/") ? "~/" + shellQuote(String(path.dropFirst(2))) : shellQuote(path)
    }

    /// Back from `shellPath`.
    public static func shellUnpath(_ word: String) -> String {
        let t = word.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("~/") ? "~/" + shellUnquote(String(t.dropFirst(2))) : shellUnquote(t)
    }

    public static func looksLikeWebAddress(_ s: String) -> Bool {
        s.contains("://") || s.hasPrefix("www.")
    }
}

public enum ActionCatalog {
    /// A command with nothing to fill in.
    /// `also`: other spellings of the same command, read as this action and
    /// written back in the first spelling.
    private static func fixed(
        _ id: String, _ category: ActionCategory, _ symbol: String,
        _ title: String, _ detail: String, command: String, also: [String] = [], phrase: String
    ) -> ShortcutAction {
        ShortcutAction(
            id: id, category: category, symbol: symbol, title: title, detail: detail, params: [],
            command: { _ in command },
            read: { $0 == command || also.contains($0) ? [] : nil },
            phrase: { _ in phrase }
        )
    }

    /// `<prefix> <value>`, one blank.
    private static func one(
        _ id: String, _ category: ActionCategory, _ symbol: String,
        _ title: String, _ detail: String, prefix: String, _ param: ActionParam,
        phrase: @escaping @Sendable (String) -> String
    ) -> ShortcutAction {
        ShortcutAction(
            id: id, category: category, symbol: symbol, title: title, detail: detail, params: [param],
            command: { "\(prefix) \($0.first ?? "")" },
            read: { command in
                guard command.hasPrefix(prefix + " ") else { return nil }
                let value = String(command.dropFirst(prefix.count + 1))
                return param.accepts(value) ? [value] : nil
            },
            phrase: { phrase($0.first ?? "") }
        )
    }

    public static let all: [ShortcutAction] = [
        // Windows
        one("focus", .windows, "arrow.left.and.right.square", "Focus a window",
            "Move the keyboard to the window beside this one.", prefix: "focus", .direction) {
            "focus the window \(ActionWords.towards[$0] ?? $0)"
        },
        one("move", .windows, "arrow.up.and.down.and.arrow.left.and.right", "Move the window",
            "Move it one place over. It keeps its size.", prefix: "move", .direction) {
            "move the window \(ActionWords.directions[$0] ?? $0)"
        },
        one("swap", .windows, "arrow.left.arrow.right", "Swap with a window",
            "Trade places with the window beside it.", prefix: "swap", .direction) {
            "swap with the window \(ActionWords.towards[$0] ?? $0)"
        },
        ShortcutAction(
            id: "resize", category: .windows, symbol: "arrow.up.left.and.arrow.down.right",
            title: "Resize the window", detail: "Grow or shrink it on one side.",
            params: [.edge, .amount],
            command: { "resize \($0[0]) \($0[1])" },
            read: { command in
                let w = command.split(separator: " ").map(String.init)
                guard w.count == 3, w[0] == "resize", ActionParam.edge.accepts(w[1]), ActionParam.amount.accepts(w[2])
                else { return nil }
                return [w[1], w[2]]
            },
            phrase: { "resize the window \($0[1]) points \(["left": "to the left", "right": "to the right", "up": "upward", "down": "downward"][$0[0]] ?? $0[0])" }
        ),
        fixed("float", .windows, "macwindow.on.rectangle", "Float or tile the window",
              "Take it out of the tiling, or put it back.", command: "float toggle", also: ["float", "window toggle float"], phrase: "float or tile the window"),
        fixed("zoom", .windows, "arrow.up.left.and.arrow.down.right.square", "Fill the screen with the window",
              "Again to put it back.", command: "window toggle zoom-fullscreen", also: ["window toggle fullscreen", "fullscreen", "zoom-fullscreen"], phrase: "fill the screen with the window"),
        fixed("sticky", .windows, "pin", "Show the window on every workspace",
              "For a video or a chat you always want. Again to undo.", command: "sticky", also: ["sticky toggle"], phrase: "keep the window on every workspace"),

        // Workspaces
        one("space.focus", .workspaces, "square.grid.2x2", "Go to a workspace",
            "Show a workspace. It opens on its own display if it has one.", prefix: "space focus", .workspace) {
            "go to \(ActionWords.workspace($0))"
        },
        fixed("space.recent", .workspaces, "arrow.uturn.backward", "Go back to the last workspace",
              "Flip between two workspaces.", command: "space focus recent", phrase: "go back to the last workspace"),
        ShortcutAction(
            id: "space.move", category: .workspaces, symbol: "rectangle.portrait.and.arrow.right",
            title: "Send the window to a workspace", detail: "And go with it, or stay where you are.",
            params: [.workspace, .follow],
            command: { "space move-window \($0[0])" + ($0[1] == "stay" ? " --no-follow" : "") },
            read: { command in
                var w = command.split(separator: " ").map(String.init)
                guard w.count >= 3, w[0] == "space", w[1] == "move-window" else { return nil }
                let stay = w.contains("--no-follow") || w.contains("no-follow")
                w.removeAll { ["--no-follow", "no-follow", "--follow", "follow"].contains($0) }
                guard w.count == 3 else { return nil }
                return [w[2], stay ? "stay" : "follow"]
            },
            phrase: { "send the window to \(ActionWords.workspace($0[0]))" + ($0[1] == "stay" ? " and stay here" : " and go with it") }
        ),

        // Layout
        fixed("balance", .layout, "equal.square", "Even out the windows",
              "Make every split on this workspace equal.", command: "balance", phrase: "even out the windows"),
        fixed("flip", .layout, "rectangle.split.2x1", "Flip the split",
              "Side by side becomes one above the other.", command: "window toggle split", also: ["split toggle", "split flip"], phrase: "flip the split"),
        one("split", .layout, "rectangle.split.2x1.fill", "Choose how the next window splits",
            "Side by side, or one above the other.", prefix: "split", .splitAxis) {
            $0 == "horizontal" ? "open the next window below this one" : "open the next window beside this one"
        },
        one("layout", .layout, "rectangle.3.group", "Change the workspace's layout",
            "Tiled, floating, or switch between them.", prefix: "space layout", .layout) {
            switch $0 {
            case "bsp": return "tile this workspace"
            case "float": return "let this workspace's windows float"
            default: return "switch this workspace between tiled and floating"
            }
        },

        // Displays
        one("display.focus", .displays, "display", "Focus another display",
            "Move the keyboard to another screen.", prefix: "focus display", .display) {
            "focus \(ActionWords.display($0))"
        },
        ShortcutAction(
            id: "display.move", category: .displays, symbol: "rectangle.on.rectangle.angled",
            title: "Send the window to another display", detail: "And go with it, or stay where you are.",
            params: [.display, .follow],
            command: { "move display \($0[0])" + ($0[1] == "follow" ? " --follow" : "") },
            read: { command in
                var w = command.split(separator: " ").map(String.init)
                guard w.count >= 3, w[0] == "move", w[1] == "display" else { return nil }
                let follow = w.contains("--follow") || w.contains("follow")
                w.removeAll { $0 == "--follow" || $0 == "follow" }
                guard w.count == 3, ActionParam.display.accepts(w[2]) else { return nil }
                return [w[2], follow ? "follow" : "stay"]
            },
            phrase: { "send the window to \(ActionWords.display($0[0]))" + ($0[1] == "follow" ? " and go with it" : "") }
        ),
        one("display.space", .displays, "arrow.left.arrow.right.square", "Swap workspaces with a display",
            "This workspace goes there, and that one comes here.", prefix: "move space display", .display) {
            "swap this workspace with \(ActionWords.display($0))"
        },

        // Stacks
        fixed("stack.toggle", .stacks, "square.stack", "Stack the windows here",
              "Several windows in one place, one showing. Again to undo.", command: "stack toggle", also: ["stack wrap"],
              phrase: "stack the windows here"),
        fixed("stack.next", .stacks, "chevron.down.square", "Next window in the stack",
              "", command: "stack next", phrase: "show the next window in the stack"),
        fixed("stack.prev", .stacks, "chevron.up.square", "Previous window in the stack",
              "", command: "stack prev", phrase: "show the previous window in the stack"),
        fixed("stack.unstack", .stacks, "square.stack.3d.up.slash", "Take the window out of its stack",
              "", command: "stack unstack", phrase: "take the window out of its stack"),
        fixed("stack.all", .stacks, "square.stack.3d.up", "Stack every window on the workspace",
              "Again to undo.", command: "stack all", phrase: "stack every window on the workspace"),
        one("stack.move", .stacks, "square.stack.3d.forward.dottedline", "Put the window in a stack",
            "Join the stack beside it.", prefix: "stack move", .direction) {
            "put the window in the stack \(ActionWords.towards[$0] ?? $0)"
        },

        // Apps & Web
        one("app", .apps, "app.badge", "Open an app",
            "Opens it, goes to its window, or hides it when it's in front.", prefix: "app toggle", .app) {
            "open \(ActionWords.appName($0))"
        },
        ShortcutAction(
            id: "web", category: .apps, symbol: "safari", title: "Open a website",
            detail: "In your default browser.", params: [.url],
            command: { "exec open \(ActionWords.shellQuote($0[0]))" },
            read: { command in
                guard command.hasPrefix("exec open ") else { return nil }
                let target = ActionWords.shellUnquote(String(command.dropFirst("exec open ".count)))
                return ActionWords.looksLikeWebAddress(target) ? [target] : nil
            },
            phrase: { "open \($0[0].replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))" }
        ),
        ShortcutAction(
            id: "open", category: .apps, symbol: "folder", title: "Open a file or folder",
            detail: "In the app that opens it.", params: [.path],
            command: { "exec open \(ActionWords.shellPath($0[0]))" },
            read: { command in
                guard command.hasPrefix("exec open ") else { return nil }
                let rest = String(command.dropFirst("exec open ".count))
                // One path, not options or several words.
                guard !rest.hasPrefix("-") else { return nil }
                let target = ActionWords.shellUnpath(rest)
                let word = rest.hasPrefix("~/") ? String(rest.dropFirst(2)) : rest
                guard !ActionWords.looksLikeWebAddress(target),
                      word.hasPrefix("'") || !word.contains(" ")
                else { return nil }
                return [target]
            },
            phrase: { "open \(($0[0] as NSString).lastPathComponent)" }
        ),

        // Advanced
        one("shell", .advanced, "terminal", "Run a shell command",
            "Anything you'd type in Terminal.", prefix: "exec", .shell) {
            "run \($0)"
        },
        one("mode", .advanced, "keyboard", "Enter a mode",
            "A layer of keys that works until you leave it.", prefix: "mode", .mode) {
            "enter the “\($0)” mode"
        },
        fixed("mode.leave", .advanced, "escape", "Leave the mode",
              "Back to your normal shortcuts.", command: "mode default", phrase: "leave the mode"),
        ShortcutAction(
            id: "raw", category: .advanced, symbol: "chevron.left.forwardslash.chevron.right",
            title: "A weft command", detail: "Type any command from the README.", params: [.raw],
            command: { $0[0] }, read: { [$0] }, phrase: { "run the weft command “\($0[0])”" }
        ),
    ]

    public static func action(_ id: String) -> ShortcutAction? { all.first { $0.id == id } }

    /// The action a command is, with its blanks filled in. Falls through to a
    /// plain weft command, so nothing is ever lost by opening it here.
    public static func identify(_ command: String) -> (ShortcutAction, [String]) {
        // "mode default" is Leave, not Enter "default".
        let ordered = all.filter { $0.id == "mode.leave" } + all.filter { $0.id != "mode.leave" }
        for action in ordered where action.id != "raw" {
            if let values = action.read(command) { return (action, values) }
        }
        return (action("raw")!, [command])
    }

    /// A whole shortcut in one sentence, capitalised: "Go to workspace 3,
    /// then open Mail".
    public static func sentence(_ steps: [String]) -> String {
        let said = steps.map { command -> String in
            let (action, values) = identify(command)
            return action.phrase(values)
        }
        guard let first = said.first else { return "" }
        let text = ([first] + said.dropFirst()).joined(separator: ", then ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
