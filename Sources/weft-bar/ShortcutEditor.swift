import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WeftBarConfig

// The shortcut builder: press the keys, pick what they do, add more steps if
// one key should do several things. Every choice is a control — a direction
// is arrows, a workspace is a menu of your workspaces, an app is a menu of
// apps with their icons — so nothing has to be typed unless the user wants a
// shell command. The sentence at the bottom says what the shortcut will do in
// plain words, which is the check that it does what they meant.

extension ActionCategory {
    var tint: Color {
        switch self {
        case .windows: return .blue
        case .workspaces: return .indigo
        case .layout: return .teal
        case .displays: return .purple
        case .stacks: return .orange
        case .apps: return .pink
        case .advanced: return .gray
        }
    }
}

/// What the blanks can be filled with on this Mac.
struct ShortcutContext {
    /// Declared workspace labels, in order.
    var workspaces: [String]
    /// Modes other than the default layer.
    var modes: [String]
    var displays: [CanvasDisplay]
}

/// One step while it is being edited.
struct DraftStep: Identifiable, Equatable {
    let id = UUID()
    var actionID: String
    var values: [String]

    var action: ShortcutAction { ActionCatalog.action(actionID) ?? ActionCatalog.action("raw")! }
    var command: String { action.command(values) }
    var isComplete: Bool {
        values.count == action.params.count
            && zip(action.params, values).allSatisfy { $0.accepts($1.trimmingCharacters(in: .whitespaces)) }
    }

    init(command: String) {
        let (action, values) = ActionCatalog.identify(command)
        actionID = action.id
        self.values = values
    }

    init(action: ShortcutAction, context: ShortcutContext) {
        actionID = action.id
        values = action.params.map { param in
            switch param {
            case .mode: return context.modes.first ?? ""
            case .workspace: return context.workspaces.first ?? param.initial
            default: return param.initial
            }
        }
    }

    static func == (a: DraftStep, b: DraftStep) -> Bool {
        a.id == b.id && a.actionID == b.actionID && a.values == b.values
    }
}

// MARK: - The sheet

struct ShortcutEditor: View {
    let isNew: Bool
    /// A layer entered with `mode …`, where a bare key is normal.
    let isModeLayer: Bool
    let context: ShortcutContext
    /// The other shortcuts in the same layer, for clashes.
    let others: [KeyRow]
    let onSave: (_ chord: String, _ steps: [String]) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @SwiftUI.State private var chord: String
    @SwiftUI.State private var steps: [DraftStep]
    @SwiftUI.State private var addingStep = false
    /// The step whose action is being changed, when the library is open for it.
    @SwiftUI.State private var replacing: DraftStep.ID?

    init(
        row: KeyRow?, isModeLayer: Bool, context: ShortcutContext, others: [KeyRow],
        onSave: @escaping (String, [String]) -> Void, onDelete: (() -> Void)?, onCancel: @escaping () -> Void
    ) {
        isNew = row == nil
        self.isModeLayer = isModeLayer
        self.context = context
        self.others = others
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _chord = SwiftUI.State(initialValue: row?.chord ?? "")
        _steps = SwiftUI.State(initialValue: (row?.steps ?? []).map(DraftStep.init(command:)))
    }

    private var clash: KeyRow? {
        guard !chord.isEmpty else { return nil }
        return others.first { $0.chord.lowercased() == chord.lowercased() }
    }

    private var modifiers: Set<String> {
        Set(chord.lowercased().split(separator: "-").dropLast().map(String.init))
    }

    /// No modifier at all, in the everyday layer: that letter would stop
    /// typing in every app.
    private var bareKey: Bool { !chord.isEmpty && modifiers.isEmpty && !isModeLayer }

    private var canSave: Bool {
        !chord.isEmpty && !bareKey && !steps.isEmpty && steps.allSatisfy(\.isComplete)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isNew ? "New Shortcut" : "Edit Shortcut")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("Press the keys, then choose what they do. One shortcut can do several things in a row.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("Keys")
                        KeyRecorder(chord: $chord, startRecording: isNew)
                        notices
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(steps.count > 1 ? "Does, in this order" : "Does")
                        if steps.isEmpty {
                            ActionLibrary { action in
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    steps.append(DraftStep(action: action, context: context))
                                }
                            }
                            .frame(height: 330)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.primary.opacity(0.035))
                            )
                        } else {
                            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                                StepCard(
                                    step: binding(for: step.id),
                                    number: index + 1,
                                    count: steps.count,
                                    context: context,
                                    onMove: { move(step.id, by: $0) },
                                    onRemove: { remove(step.id) },
                                    onChangeAction: { replacing = step.id }
                                )
                                .popover(isPresented: Binding(
                                    get: { replacing == step.id },
                                    set: { if !$0 { replacing = nil } }
                                ), arrowEdge: .trailing) {
                                    ActionLibrary { action in
                                        replace(step.id, with: action)
                                        replacing = nil
                                    }
                                    .frame(width: 400, height: 460)
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            Button {
                                addingStep = true
                            } label: {
                                Label("Add Another Step", systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .popover(isPresented: $addingStep, arrowEdge: .bottom) {
                                ActionLibrary { action in
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        steps.append(DraftStep(action: action, context: context))
                                    }
                                    addingStep = false
                                }
                                .frame(width: 400, height: 460)
                            }
                        }
                    }

                    if !steps.isEmpty { summary }
                }
                .padding(24)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: steps)
            }

            Divider()
            HStack {
                if let onDelete {
                    Button("Delete Shortcut", role: .destructive, action: onDelete)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Shortcut" : "Save") {
                    onSave(chord, steps.map { $0.command.trimmingCharacters(in: .whitespaces) })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 620, height: 660)
    }

    @ViewBuilder
    private var notices: some View {
        if bareKey {
            Notice(
                symbol: "xmark.octagon.fill", tint: .red,
                text: "Add ⌥, ⌃ or ⌘. With no modifier, this key would stop typing in every app."
            )
        } else if let clash {
            Notice(
                symbol: "exclamationmark.triangle.fill", tint: .orange,
                text: "These keys already \(ActionCatalog.sentence(clash.steps).lowercasedFirst). "
                    + "Saving gives them to this shortcut instead."
            )
        } else if modifiers.contains("cmd"), !modifiers.contains("alt"), !modifiers.contains("ctrl") {
            Notice(
                symbol: "info.circle.fill", tint: .blue,
                text: "Apps use ⌘ shortcuts. weft takes this one from every app. ⌥ is usually free."
            )
        }
    }

    private var summary: some View {
        let keys = chord.isEmpty ? "the keys" : ChordNaming.caps(for: chord).joined()
        let what = steps.allSatisfy(\.isComplete)
            ? ActionCatalog.sentence(steps.map(\.command)).lowercasedFirst
            : "…fill in the steps above"
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "text.bubble")
                .foregroundStyle(Color.weft)
            Text("Press **\(keys)** to \(what).")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.weft.opacity(0.08))
        )
    }

    private func binding(for id: DraftStep.ID) -> Binding<DraftStep> {
        Binding(
            get: { steps.first { $0.id == id } ?? DraftStep(command: "") },
            set: { value in
                if let i = steps.firstIndex(where: { $0.id == id }) { steps[i] = value }
            }
        )
    }

    private func move(_ id: DraftStep.ID, by offset: Int) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard steps.indices.contains(j) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { steps.swapAt(i, j) }
    }

    private func remove(_ id: DraftStep.ID) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { steps.removeAll { $0.id == id } }
    }

    private func replace(_ id: DraftStep.ID, with action: ShortcutAction) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i] = DraftStep(action: action, context: context)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

private struct Notice: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .transition(.opacity)
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Recording keys

/// A big target that records the next key combination pressed. Shows the
/// modifiers as they are held, so the user can see it is listening.
struct KeyRecorder: View {
    @Binding var chord: String
    var startRecording = false
    @SwiftUI.State private var recording = false
    @SwiftUI.State private var held = ""
    @SwiftUI.State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            HStack(spacing: 14) {
                if recording {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                    Text(held.isEmpty ? "Press the keys you want…" : held + "…")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                    Spacer()
                    Text("Esc to cancel").font(.caption).foregroundStyle(.secondary)
                } else if chord.isEmpty {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.secondary)
                    Text("Click to record keys")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    HStack(spacing: 6) {
                        ForEach(Array(ChordNaming.caps(for: chord).enumerated()), id: \.offset) { _, cap in
                            Text(cap)
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .frame(minWidth: 34, minHeight: 34)
                                .padding(.horizontal, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.primary.opacity(0.07))
                                        .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
                                )
                        }
                    }
                    Spacer()
                    Text("Click to change").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 64)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(recording ? 0.06 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        recording ? Color.weft : Color.primary.opacity(0.1),
                        style: StrokeStyle(lineWidth: recording ? 2 : 1, dash: recording ? [5, 4] : [])
                    )
            )
        }
        .buttonStyle(.plain)
        .onAppear { if startRecording, chord.isEmpty { start() } }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        held = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                held = ChordNaming.caps(for: ChordNaming.modifierPrefix(event.modifierFlags) + "x").dropLast().joined()
                return event
            }
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop()
                return nil
            }
            guard let name = ChordNaming.name(forKeyCode: Int(event.keyCode)) else { return nil }
            chord = ChordNaming.modifierPrefix(event.modifierFlags) + name
            stop()
            // Swallowed, so recording ⌘W does not close the window.
            return nil
        }
    }

    private func stop() {
        recording = false
        held = ""
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - A step

private struct StepCard: View {
    @Binding var step: DraftStep
    let number: Int
    let count: Int
    let context: ShortcutContext
    let onMove: (Int) -> Void
    let onRemove: () -> Void
    let onChangeAction: () -> Void

    var body: some View {
        let action = step.action
        HStack(alignment: .top, spacing: 12) {
            ActionIcon(action: action, size: 34)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if count > 1 {
                        Text("\(number)")
                            .font(.caption2.weight(.bold))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.primary.opacity(0.1)))
                    }
                    Text(action.title).font(.system(size: 14, weight: .semibold))
                    Button("Change", action: onChangeAction)
                        .buttonStyle(.link)
                        .font(.caption)
                }
                ForEach(Array(action.params.enumerated()), id: \.offset) { i, param in
                    ParamControl(param: param, value: value(i), context: context)
                }
            }
            Spacer(minLength: 0)
            if count > 1 {
                VStack(spacing: 2) {
                    Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                        .disabled(number == 1)
                        .help("Do this earlier")
                    Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                        .disabled(number == count)
                        .help("Do this later")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove this step")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(step.isComplete ? Color.clear : Color.orange.opacity(0.5), lineWidth: 1)
        )
    }

    private func value(_ i: Int) -> Binding<String> {
        Binding(
            get: { i < step.values.count ? step.values[i] : "" },
            set: { v in
                while step.values.count <= i { step.values.append("") }
                step.values[i] = v
            }
        )
    }
}

struct ActionIcon: View {
    let action: ShortcutAction
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: action.symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(action.category.tint.gradient)
            )
    }
}

/// The control for one blank.
private struct ParamControl: View {
    let param: ActionParam
    @Binding var value: String
    let context: ShortcutContext

    var body: some View {
        switch param {
        case .direction:
            segmented([("west", "Left", "arrow.left"), ("south", "Down", "arrow.down"),
                       ("north", "Up", "arrow.up"), ("east", "Right", "arrow.right")])
        case .edge:
            segmented([("left", "Left", "arrow.left"), ("down", "Down", "arrow.down"),
                       ("up", "Up", "arrow.up"), ("right", "Right", "arrow.right")])
        case .layout:
            segmented([("bsp", "Tiled", "rectangle.split.2x1"), ("float", "Floating", "macwindow.on.rectangle"),
                       ("toggle", "Switch", "arrow.triangle.2.circlepath")])
        case .splitAxis:
            segmented([("vertical", "Side by side", "rectangle.split.2x1"),
                       ("horizontal", "Above and below", "rectangle.split.1x2")])
        case .follow:
            Toggle("Go with it", isOn: Binding(get: { value != "stay" }, set: { value = $0 ? "follow" : "stay" }))
                .toggleStyle(.switch)
                .controlSize(.small)
        case .workspace:
            menu(workspaceOptions, label: { ActionWords.workspace($0).capitalizedFirst })
        case .display:
            menu(displayOptions, label: displayLabel)
        case .amount:
            menu(amountOptions, label: { "\($0) points" })
        case .mode:
            if context.modes.isEmpty {
                Text("No modes yet. Add a [mode.name] section to weft.toml first.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                menu(context.modes + (context.modes.contains(value) || value.isEmpty ? [] : [value]),
                     label: { "“\($0)”" })
            }
        case .app:
            AppPicker(bundleID: $value)
        case .url:
            TextField("https://…", text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 340)
        case .path:
            HStack {
                TextField("~/Documents", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = true
                    panel.prompt = "Choose"
                    if panel.runModal() == .OK, let url = panel.url {
                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                        value = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
                    }
                }
            }
        case .shell:
            TextField("say hello", text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: 400)
        case .raw:
            TextField("a weft command", text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: 400)
        }
    }

    private func segmented(_ options: [(String, String, String)]) -> some View {
        Picker("", selection: $value) {
            ForEach(options, id: \.0) { option in
                Label(option.1, systemImage: option.2).tag(option.0)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func menu(_ options: [String], label: @escaping (String) -> String) -> some View {
        Picker("", selection: $value) {
            ForEach(options, id: \.self) { Text(label($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var workspaceOptions: [String] {
        var out = context.workspaces
        for n in 1...9 where !out.contains("\(n)") { out.append("\(n)") }
        if !value.isEmpty, !out.contains(value) { out.append(value) }
        return out
    }

    private var displayOptions: [String] {
        var out = ["next", "prev", "cycle", "west", "east", "north", "south"]
        out += context.displays.map { "\($0.index)" }
        if !value.isEmpty, !out.contains(value) { out.append(value) }
        return out
    }

    private func displayLabel(_ value: String) -> String {
        if let n = Int(value) {
            let name = context.displays.first { $0.index == n }?.name
            return name.map { "Display \(n) — \($0)" } ?? "Display \(n)"
        }
        let said = ActionWords.display(value)
        return said.prefix(1).uppercased() + said.dropFirst()
    }

    private var amountOptions: [String] {
        var out = ["20", "40", "80", "120", "200"]
        if !value.isEmpty, !out.contains(value) { out.append(value) }
        return out
    }
}

// MARK: - Apps

/// A menu of apps with their icons: what is open now, what every Mac has, and
/// any other app from the Applications folder.
struct AppPicker: View {
    @Binding var bundleID: String

    private static let everyMac = [
        "com.apple.Safari", "com.apple.finder", "com.apple.Terminal", "com.apple.mail",
        "com.apple.Notes", "com.apple.iCal", "com.apple.MobileSMS", "com.apple.Music",
        "com.apple.reminders", "com.apple.Photos", "com.apple.systempreferences", "com.apple.ActivityMonitor",
    ]

    var body: some View {
        Menu {
            let running = Self.runningApps()
            if !running.isEmpty {
                Section("Open now") {
                    ForEach(running, id: \.self) { item($0) }
                }
            }
            Section("On every Mac") {
                ForEach(Self.everyMac.filter { !running.contains($0) }, id: \.self) { item($0) }
            }
            Divider()
            Button("Choose Another App…") {
                if let id = Self.chooseApp() { bundleID = id }
            }
        } label: {
            HStack(spacing: 6) {
                if bundleID.isEmpty {
                    Text("Choose an app")
                } else {
                    Image(nsImage: Self.icon(bundleID))
                    Text(ActionWords.appName(bundleID))
                }
            }
        }
        .fixedSize()
    }

    private func item(_ id: String) -> some View {
        Button {
            bundleID = id
        } label: {
            Label {
                Text(ActionWords.appName(id))
            } icon: {
                Image(nsImage: Self.icon(id))
            }
        }
    }

    static func runningApps() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { $0 != Bundle.main.bundleIdentifier }
            .sorted { ActionWords.appName($0).localizedCaseInsensitiveCompare(ActionWords.appName($1)) == .orderedAscending }
    }

    static func icon(_ bundleID: String) -> NSImage {
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    static func chooseApp() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.message = "Choose the app this shortcut opens"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}

// MARK: - Everything a shortcut can do

/// Every action, searchable, grouped by what it acts on.
struct ActionLibrary: View {
    let onPick: (ShortcutAction) -> Void
    @SwiftUI.State private var query = ""
    @SwiftUI.State private var category: ActionCategory?

    private var shown: [ShortcutAction] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return ActionCatalog.all.filter { action in
            (category == nil || action.category == category)
                && (needle.isEmpty || action.title.lowercased().contains(needle)
                    || action.detail.lowercased().contains(needle)
                    || action.category.rawValue.lowercased().contains(needle))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search everything a shortcut can do", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            .padding([.horizontal, .top], 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(nil, "All", "square.grid.3x3")
                    ForEach(ActionCategory.allCases) { chip($0, $0.rawValue, $0.symbol) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(ActionCategory.allCases) { group in
                        let rows = shown.filter { $0.category == group }
                        if !rows.isEmpty {
                            Text(group.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                            ForEach(rows) { action in
                                LibraryRow(action: action) { onPick(action) }
                            }
                        }
                    }
                    if shown.isEmpty {
                        Text("Nothing matches “\(query)”. Try Advanced › A weft command.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(16)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func chip(_ value: ActionCategory?, _ title: String, _ symbol: String) -> some View {
        let on = category == value
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { category = value }
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(on ? (value?.tint ?? Color.weft).opacity(0.2) : Color.primary.opacity(0.06)))
                .foregroundStyle(on ? (value?.tint ?? Color.weft) : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

private struct LibraryRow: View {
    let action: ShortcutAction
    let pick: () -> Void
    @SwiftUI.State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                ActionIcon(action: action, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title).font(.system(size: 13, weight: .medium))
                    if !action.detail.isEmpty {
                        Text(action.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle")
                    .foregroundStyle(hovering ? Color.weft : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.weft.opacity(hovering ? 0.1 : 0))
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
