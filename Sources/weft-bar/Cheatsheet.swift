import AppKit
import SwiftUI
import WeftBarConfig

// The keybinding cheatsheet (⌘K).
//
// Rewritten onto TomlDocument, which fixed the bug the old hand-rolled parser
// had: it scanned for `[keys]` and the literal string `[mode.resize]`, so a
// user who named their modal layer anything else — `[mode.window]`, say — had
// a cheatsheet that silently omitted every bind in it.

struct KeybindEntry: Identifiable {
    let id = UUID()
    let chord: String
    let command: String
    let mode: String
    let category: String
    let summary: String

    /// `alt-shift-h` → `⌥ ⇧ H`. Named keys keep their word (`TAB`, `ESCAPE`)
    /// because a glyph for them would be guessing at the user's keyboard.
    var caps: [String] {
        chord.split(separator: "-").map { token in
            switch token.lowercased() {
            case "alt", "opt": return "⌥"
            case "shift": return "⇧"
            case "cmd", "command": return "⌘"
            case "ctrl", "control": return "⌃"
            case "bracketleft": return "["
            case "bracketright": return "]"
            case "backslash": return "\\"
            case "grave": return "`"
            case "minus": return "−"
            case "equal": return "="
            case "comma": return ","
            case "period": return "."
            case "slash": return "/"
            case "semicolon": return ";"
            case "quote": return "'"
            case "space": return "␣"
            case "return": return "↩"
            case "tab": return "⇥"
            case "delete": return "⌫"
            case "escape": return "esc"
            case "left": return "←"
            case "right": return "→"
            case "up": return "↑"
            case "down": return "↓"
            default: return token.uppercased()
            }
        }
    }
}

@MainActor
final class CheatsheetModel: ObservableObject {
    @Published var entries: [KeybindEntry] = []
    @Published var query = ""

    var modes: [String] {
        var seen: [String] = []
        for e in entries where !seen.contains(e.mode) { seen.append(e.mode) }
        return seen
    }

    var filtered: [KeybindEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.chord.lowercased().contains(q)
                || $0.command.lowercased().contains(q)
                || $0.category.lowercased().contains(q)
                || $0.summary.lowercased().contains(q)
                || $0.caps.joined(separator: " ").lowercased().contains(q)
        }
    }

    func grouped(mode: String) -> [(category: String, entries: [KeybindEntry])] {
        let rows = filtered.filter { $0.mode == mode }
        var order: [String] = []
        var buckets: [String: [KeybindEntry]] = [:]
        for row in rows {
            if buckets[row.category] == nil { order.append(row.category) }
            buckets[row.category, default: []].append(row)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    func load() {
        guard let text = try? String(contentsOfFile: ConfigStore.configPath, encoding: .utf8) else {
            entries = []
            return
        }
        var out: [KeybindEntry] = []
        for section in TomlDocument(text).sections {
            guard let header = section.header else { continue }
            let mode: String
            if header == "[keys]" { mode = "Default" }
            else if header.hasPrefix("[mode.") { mode = String(header.dropFirst(6).dropLast()) }
            else { continue }

            for entry in section.entries {
                guard case .pair(let key, let value) = entry else { continue }
                let command = TomlValue.unquote(value)
                let (category, summary) = Self.describe(command)
                out.append(KeybindEntry(
                    chord: TomlValue.unquote(key),
                    command: command,
                    mode: mode,
                    category: category,
                    summary: summary
                ))
            }
        }
        entries = out
    }

    /// Plain English for a command, and the bucket it belongs in. Falls back to
    /// the command verbatim rather than inventing a description — a wrong
    /// summary is worse than none for a shortcut you are about to press.
    private static func describe(_ command: String) -> (String, String) {
        let words = command.split(separator: " ").map(String.init)
        func rest(_ n: Int) -> String { words.dropFirst(n).joined(separator: " ") }
        let direction: [String: String] = [
            "west": "left", "east": "right", "north": "up", "south": "down",
        ]

        switch words.first {
        case "focus" where words.count >= 3 && words[1] == "display":
            return ("Displays", "Focus the display \(direction[words[2]] ?? words[2])")
        case "focus" where words.count >= 2:
            return ("Focus", "Focus the window \(direction[words[1]] ?? words[1])")
        case "move" where words.count >= 3 && words[1] == "display":
            let follow = command.contains("--follow") ? ", and follow it" : ""
            return ("Displays", "Send the window to the display \(direction[words[2]] ?? words[2])\(follow)")
        case "move" where words.count >= 2:
            return ("Move", "Swap the window \(direction[words[1]] ?? words[1])")
        case "space" where words.count >= 2 && words[1] == "focus":
            return ("Spaces", rest(2) == "recent" ? "Back to the last space" : "Go to space “\(rest(2))”")
        case "space" where words.count >= 2 && words[1] == "move-window":
            return ("Spaces", "Send the window to space “\(rest(2))”")
        case "space" where words.count >= 2 && words[1] == "layout":
            return ("Layout", "Switch this space to the \(rest(2)) layout")
        case "window":
            if command.contains("zoom-fullscreen") { return ("Layout", "Zoom the window to fill the space") }
            if command.contains("split") { return ("Layout", "Flip the split under the window") }
            return ("Layout", command)
        case "float":
            return ("Layout", "Float the window, or put it back in the tiling")
        case "split":
            return ("Layout", "Next window opens \(words.count > 1 ? words[1] : "split")")
        case "balance":
            return ("Layout", "Even out every split on this space")
        case "stack":
            return ("Stacks", stackSummary(words))
        case "resize" where words.count >= 3:
            return ("Resize", "Grow or shrink \(direction[words[1]] ?? words[1]) by \(words[2])px")
        case "app" where words.count >= 3:
            // `com.mitchellh.ghostty` → `Ghostty`. The bundle id is right
            // there in the command column; repeating it in the summary just
            // pushed the readable half off the end of the row.
            let name = words[2].split(separator: ".").last.map(String.init) ?? words[2]
            return ("Apps", "Launch or focus \(name.prefix(1).uppercased() + name.dropFirst())")
        case "mode" where words.count >= 2:
            return ("Modes", words[1] == "default" ? "Leave the current mode" : "Enter “\(words[1])” mode")
        default:
            return ("Other", command)
        }
    }

    private static func stackSummary(_ words: [String]) -> String {
        switch words.dropFirst().first {
        case "wrap", "toggle": return "Stack the windows here into one slot, or back out"
        case "next": return "Next window in the stack"
        case "prev": return "Previous window in the stack"
        case "unstack": return "Pull the window out of its stack"
        case "all": return "Every window on this space in one stack, or back out"
        case "move" where words.count > 2: return "Put this window in the stack to the \(words[2])"
        case "split" where words.count > 2: return "Pull the window to the \(words[2]) into this stack"
        default: return words.joined(separator: " ")
        }
    }
}

// MARK: - View

struct CheatsheetView: View {
    @ObservedObject var model: CheatsheetModel

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.entries.isEmpty {
                empty(
                    "No keybindings in \(ConfigStore.configPath)",
                    "Add some under [keys] — or open Settings › Keybindings and record a chord."
                )
            } else if model.filtered.isEmpty {
                empty("Nothing matches “\(model.query)”", "Try a chord like ⌥H, or a word like “space”.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(model.modes, id: \.self) { mode in
                            let groups = model.grouped(mode: mode)
                            if !groups.isEmpty {
                                ModeSection(mode: mode, groups: groups)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .background(CheatsheetBackdrop())
        .tint(.weft)
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.weft)
                Text("Keybindings")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("\(model.entries.count) bound")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Filter — a chord, a command, or a space name", text: $model.query)
                    .textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "keyboard")
                .font(.system(size: 30))
                .foregroundStyle(.quaternary)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CheatsheetBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct ModeSection: View {
    let mode: String
    let groups: [(category: String, entries: [KeybindEntry])]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(mode == "Default" ? "Always live" : "Mode: \(mode)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(mode == "Default" ? Color.secondary : Color.weft)
                    .textCase(.uppercase)
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
            }

            ForEach(groups, id: \.category) { group in
                VStack(alignment: .leading, spacing: 5) {
                    Text(group.category)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                    VStack(spacing: 1) {
                        ForEach(group.entries) { entry in
                            EntryRow(entry: entry)
                        }
                    }
                }
            }
        }
    }
}

private struct EntryRow: View {
    let entry: KeybindEntry
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                ForEach(Array(entry.caps.enumerated()), id: \.offset) { _, cap in
                    KeyCap(text: cap)
                }
            }
            .frame(width: 168, alignment: .leading)

            Text(entry.summary)
                .font(.system(size: 12.5))
                .lineLimit(1)

            Spacer(minLength: 12)

            // The raw command, for the moment the summary is not enough — a
            // cheatsheet that hides what a bind actually runs sends people to
            // the config file to find out.
            Text(entry.command)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(hovering ? .secondary : .tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .onHover { hovering = $0 }
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: text.count > 1 ? .default : .monospaced))
            .frame(minWidth: 21, minHeight: 20)
            .padding(.horizontal, text.count > 1 ? 6 : 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10))
            )
    }
}

// MARK: - Window

@MainActor
final class CheatsheetWindowController: NSWindowController {
    static let shared = CheatsheetWindowController()

    private let model = CheatsheetModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Weft Keybindings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WeftCheatsheet")
        super.init(window: window)

        window.contentView = NSHostingView(rootView: CheatsheetView(model: model))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        model.load()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
