import AppKit
import SwiftUI
import WeftBarConfig
import WeftConfig
import enum WeftCore.WeftVersion
import WeftIPC
import WeftPlatform

// The Settings window.
//
// Built to feel like a page of System Settings, not an editor for a file:
// native grouped forms, switches and sliders, plain words — and changes that
// apply as they are made, because weftd reloads the file within 100 ms and a
// Save button was one more thing to forget. The file stays the source of
// truth, and everything the form does not understand is carried through
// untouched (TomlDocument).
//
// On macOS 26 it is Liquid Glass: the sidebar and toolbar come from
// NavigationSplitView, and the desktop preview's windows are real glass over a
// wallpaper. On macOS 15 the same views fall back to materials.
//
// None of it costs anything while the window is closed. The whole view tree
// is torn down on close (ConfigEditorWindowController), so WeftBar — which is
// always running — does not carry a settings window around in memory, and
// nothing here animates unless a value is changing.

// MARK: - Sections

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, appearance, workspaces, shortcuts, apps, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .workspaces: return "Workspaces"
        case .shortcuts: return "Shortcuts"
        case .apps: return "Apps"
        case .advanced: return "Advanced"
        }
    }

    /// The tile behind the sidebar icon, as System Settings draws them.
    var tint: Color {
        switch self {
        case .general: return .gray
        case .appearance: return .pink
        case .workspaces: return .weft
        case .shortcuts: return .orange
        case .apps: return .green
        case .advanced: return .indigo
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .workspaces: return "rectangle.3.group"
        case .shortcuts: return "command"
        case .apps: return "square.on.square"
        case .advanced: return "slider.horizontal.3"
        }
    }

    /// `--tab <name>` on the command line. The old tab names keep working, so
    /// a support answer written last month still opens the right page.
    init?(launchName: String) {
        switch launchName {
        case "keys", "keybindings": self = .shortcuts
        case "rules": self = .apps
        case "spaces", "desktops": self = .workspaces
        case "integrations": self = .advanced
        case "workspace": self = .workspaces
        default:
            guard let section = SettingsSection(rawValue: launchName) else { return nil }
            self = section
        }
    }
}

// MARK: - Root

extension Notification.Name {
    /// Switch an open Settings window to a pane (`SettingsSection.rawValue`).
    static let weftShowSettingsSection = Notification.Name("weft.showSettingsSection")
}

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var health: EngineHealth
    @State private var section: SettingsSection?

    init(store: ConfigStore, health: EngineHealth, section: SettingsSection = .general) {
        self.store = store
        self.health = health
        _section = State(initialValue: section)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(SettingsSection.allCases) { item in
                    Label {
                        Text(item.title)
                    } icon: {
                        SidebarIcon(symbol: item.symbol, tint: item.tint)
                    }
                    .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
            .safeAreaInset(edge: .bottom) {
                EngineCard(health: health).padding(12)
            }
        } detail: {
            detail(section ?? .general)
                // A soft crossfade with a small rise between panes, rather than
                // a hard cut. Keyed by section, so nothing inside a pane
                // re-animates while you work in it.
                .id(section ?? .general)
                .transition(.opacity.combined(with: .offset(y: 8)))
                .animation(.easeOut(duration: 0.2), value: section)
                .navigationTitle((section ?? .general).title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { SaveStateBadge(store: store) }
                }
        }
        .frame(minWidth: 840, minHeight: 600)
        .onAppear { health.start() }
        .onDisappear { health.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .weftShowSettingsSection)) { note in
            if let raw = note.object as? String, let next = SettingsSection(rawValue: raw) { section = next }
        }
    }

    @ViewBuilder
    private func detail(_ section: SettingsSection) -> some View {
        switch section {
        case .general: GeneralPane(store: store, health: health)
        case .appearance: AppearancePane(store: store)
        case .workspaces: WorkspacesPane(store: store, health: health)
        case .shortcuts: ShortcutsPane(store: store)
        case .apps: AppsPane(store: store)
        case .advanced: AdvancedPane(store: store, health: health)
        }
    }
}

/// A sidebar icon on a coloured tile, the way System Settings draws its own.
private struct SidebarIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.gradient)
                    .shadow(color: tint.opacity(0.35), radius: 1.5, y: 0.5)
            )
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var health: EngineHealth

    var body: some View {
        Form {
            if health.needsRestart {
                Section { RestartNotice(health: health) }
            }
            if case .problem(let message) = store.status, store.validationError == nil {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                SliderRow(title: "Space between windows", value: store.bind(\.innerGap), range: 0...48)
                SliderRow(
                    title: "Space around the edges",
                    value: Binding(get: { store.outerTop }, set: { spreadOuter($0) }),
                    range: 0...64
                )
                Toggle("Set each edge separately", isOn: Binding(
                    get: { !store.linkOuterGaps },
                    set: { separate in
                        store.linkOuterGaps = !separate
                        if !separate { spreadOuter(store.outerTop) } else { store.markDirty() }
                    }
                ))
                if !store.linkOuterGaps {
                    LabeledContent("Each edge") {
                        EdgeCross(
                            top: $store.outerTop, bottom: $store.outerBottom,
                            left: $store.outerLeft, right: $store.outerRight,
                            onChange: store.markDirty
                        )
                    }
                }
            } header: {
                DesktopHero(store: store)
            }

            Section("Stacks") {
                SliderRow(
                    title: "Windows behind peek out by",
                    caption: "Shows there is more in a stack. 0 hides them completely.",
                    value: store.bind(\.stackOffset), range: 0...24
                )
            }

            Section("Mouse") {
                Toggle("Drag the line between two windows to resize them", isOn: store.bind(\.mouseBorderResize))
                Toggle("Focus follows the pointer", isOn: store.bind(\.focusFollowsMouse))
                Toggle("Move the pointer to the window you focus", isOn: store.bind(\.mouseFollowsFocus))
                Picker("Hold to move or resize a window", selection: store.bind(\.mouseModifier)) {
                    Text("Option ⌥").tag("alt")
                    Text("Command ⌘").tag("cmd")
                    Text("Control ⌃").tag("ctrl")
                    Text("Shift ⇧").tag("shift")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func spreadOuter(_ value: Int) {
        store.outerTop = value
        store.outerBottom = value
        store.outerLeft = value
        store.outerRight = value
        store.markDirty()
    }
}

/// The picture at the top of General: your desktop, in miniature, and the
/// layout that arranges it.
private struct DesktopHero: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        VStack(spacing: 18) {
            DesktopPreview(
                layout: store.defaultLayout,
                inner: store.innerGap,
                outer: store.outerTop,
                bordersOn: store.bordersEnabled,
                border: store.bordersWidth,
                corner: store.bordersStyle == "square" ? 0 : nil,
                accent: Color(hex: store.bordersActiveColor) ?? .weft,
                inactive: store.bordersShowInactive
                    ? (Color(hex: store.bordersInactiveColor) ?? Color.white.opacity(0.18)) : nil
            )
            .frame(height: 270)

            LayoutPicker(selection: store.bind(\.defaultLayout))
        }
        .padding(.top, 4)
        .padding(.bottom, 14)
        .textCase(nil)
        .foregroundStyle(.primary)
    }
}

/// Tiling or floating, as two glass capsules under the preview.
private struct LayoutPicker: View {
    @Binding var selection: String

    private struct Option: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let help: String
    }

    private let options = [
        Option(id: "bsp", title: "Tiling", symbol: "rectangle.split.2x2",
               help: "Every new window takes half of the one you are in."),
        Option(id: "float", title: "Floating", symbol: "macwindow.on.rectangle",
               help: "Windows stay wherever you put them."),
    ]

    var body: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(options) { option in
                    let on = selection == option.id
                    Button {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                            selection = option.id
                        }
                    } label: {
                        Label(option.title, systemImage: option.symbol)
                            .font(.system(size: 13, weight: on ? .semibold : .regular))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 9)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .weftGlass(Capsule(), tint: on ? Color.accentColor.opacity(0.75) : nil, interactive: true)
                    .help(option.help)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }
}

// MARK: - The desktop preview

/// A miniature of the desktop the settings produce: the wallpaper, the menu
/// bar, three windows laid out the way weft would lay them out, with the gaps,
/// the border and the corners they would really get.
///
/// Gaps are the one setting nobody can predict from a number, and a border
/// colour means nothing until it is around a window. The windows are Liquid
/// Glass on macOS 26, so the wallpaper shows through them the way a real
/// desktop does. It animates only when a value changes — a spring, then
/// nothing — so it costs no GPU sitting still.
struct DesktopPreview: View {
    let layout: String
    let inner: Int
    let outer: Int
    let bordersOn: Bool
    let border: Double
    /// Nil means "match the window", which on macOS 26 is about 16 points.
    let corner: Double?
    let accent: Color
    let inactive: Color?

    var body: some View {
        GeometryReader { geo in
            // Drawn against a nominal 480-point screen, so an 8-point gap is
            // visible at this size — the drawing answers "bigger or smaller
            // than I wanted", it is not a ruler.
            let scale = geo.size.width / 480
            let menuBar: CGFloat = 12
            let pad = CGFloat(outer) * scale
            let area = CGRect(
                x: pad, y: menuBar + pad,
                width: max(24, geo.size.width - pad * 2),
                height: max(24, geo.size.height - menuBar - pad * 2)
            )
            let rects = frames(in: area, gap: CGFloat(inner) * scale)
            let radius = CGFloat(corner ?? 16) * scale * 0.85
            let stroke = bordersOn ? max(1, CGFloat(border) * scale * 0.8) : 0

            ZStack(alignment: .topLeading) {
                Wallpaper()
                Rectangle()
                    .fill(Color.black.opacity(0.22))
                    .frame(height: menuBar)
                // Back to front, so the focused window — index 0 — is on top.
                ForEach(rects.indices.reversed(), id: \.self) { i in
                    MiniWindow(
                        focused: i == 0, radius: radius, border: stroke,
                        accent: accent, inactive: inactive
                    )
                    .frame(width: rects[i].width, height: rects[i].height)
                    .offset(x: rects[i].minX, y: rects[i].minY)
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.84), value: layout)
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: inner)
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: outer)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of your desktop with the current layout, spacing and borders")
    }

    /// Three windows: a main one and two beside it for tiling; a loose,
    /// overlapping cascade for floating. Three either way, so switching
    /// layouts moves each window to its new place rather than swapping sets.
    private func frames(in area: CGRect, gap: CGFloat) -> [CGRect] {
        if layout == "float" {
            return [
                CGRect(x: area.minX + area.width * 0.08, y: area.minY + area.height * 0.10,
                       width: area.width * 0.50, height: area.height * 0.62),
                CGRect(x: area.minX + area.width * 0.42, y: area.minY + area.height * 0.22,
                       width: area.width * 0.50, height: area.height * 0.58),
                CGRect(x: area.minX + area.width * 0.24, y: area.minY + area.height * 0.44,
                       width: area.width * 0.42, height: area.height * 0.50),
            ]
        }
        let half = (area.width - gap) / 2
        let halfHeight = (area.height - gap) / 2
        return [
            CGRect(x: area.minX, y: area.minY, width: half, height: area.height),
            CGRect(x: area.minX + half + gap, y: area.minY, width: half, height: halfHeight),
            CGRect(x: area.minX + half + gap, y: area.minY + halfHeight + gap,
                   width: half, height: halfHeight),
        ]
    }
}

/// Decorative colour only — the one place in the window with more than the
/// accent in it, and it never becomes a control.
struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.17, green: 0.21, blue: 0.43), Color(red: 0.05, green: 0.06, blue: 0.13)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.weft.opacity(0.75), .clear],
                center: UnitPoint(x: 0.18, y: 0.22), startRadius: 0, endRadius: 280
            )
            RadialGradient(
                colors: [Color(red: 0.64, green: 0.46, blue: 0.97).opacity(0.5), .clear],
                center: UnitPoint(x: 0.86, y: 0.88), startRadius: 0, endRadius: 250
            )
        }
    }
}

private struct MiniWindow: View {
    let focused: Bool
    let radius: CGFloat
    let border: CGFloat
    let accent: Color
    let inactive: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 6, height: 6)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 6, height: 6)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.26)).frame(width: 6, height: 6)
            }
            Capsule().fill(Color.white.opacity(0.24)).frame(maxWidth: 88).frame(height: 5)
            Capsule().fill(Color.white.opacity(0.14)).frame(maxWidth: 58).frame(height: 5)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .weftGlass(shape)
        .overlay {
            if border > 0, let color = focused ? accent : inactive {
                shape.inset(by: -border / 2).stroke(color, lineWidth: border)
            }
        }
    }
}

// MARK: - Workspaces

// MARK: - Appearance

private struct AppearancePane: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section {
                Toggle("Show a border around windows", isOn: store.bind(\.bordersEnabled))
                Group {
                    ColorPicker(
                        "Focused window",
                        selection: Binding(
                            get: { Color(hex: store.bordersActiveColor) ?? .weft },
                            set: { store.setActiveColor($0.argbHex) }
                        ),
                        supportsOpacity: false
                    )
                    DoubleSliderRow(title: "Thickness", value: store.bind(\.bordersWidth), range: 1...12)
                    Picker("Corners", selection: store.bind(\.bordersStyle)) {
                        Text("Match the window").tag("round")
                        Text("Square").tag("square")
                    }
                    .pickerStyle(.segmented)
                    Toggle("Outline the other windows too", isOn: store.bind(\.bordersShowInactive))
                    if store.bordersShowInactive {
                        ColorPicker(
                            "Other windows",
                            selection: Binding(
                                get: { Color(hex: store.bordersInactiveColor) ?? Color(argb: 0x4041_4868) },
                                set: { store.bordersInactiveColor = $0.argbHex; store.markDirty() }
                            ),
                            supportsOpacity: true
                        )
                    }
                }
                .disabled(!store.bordersEnabled)
            } header: {
                DesktopPreview(
                    layout: "bsp",
                    inner: store.innerGap,
                    outer: store.outerTop,
                    bordersOn: store.bordersEnabled,
                    border: store.bordersWidth,
                    corner: store.bordersStyle == "square" ? 0 : nil,
                    accent: Color(hex: store.bordersActiveColor) ?? .weft,
                    inactive: store.bordersShowInactive
                        ? (Color(hex: store.bordersInactiveColor) ?? Color.white.opacity(0.18)) : nil
                )
                .frame(height: 210)
                .padding(.top, 4)
                .padding(.bottom, 14)
                .textCase(nil)
            } footer: {
                if store.bordersEnabled && store.bordersBackend == "janky" {
                    Text("Borders are drawn by JankyBorders. These settings are passed to it.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @ObservedObject var store: ConfigStore
    @State private var query = ""
    @State private var editing: EditTarget?

    /// A shortcut open in the builder: a new one in `mode`, or `row`.
    private struct EditTarget: Identifiable {
        let id = UUID()
        let mode: KeyMode.ID
        let row: KeyRow.ID?
    }

    private struct Group: Identifiable {
        let name: String
        let rows: [KeyRow]
        var id: String { name }
    }

    var body: some View {
        Form {
            ForEach(store.modes) { mode in
                let duplicates = Self.duplicates(in: mode)
                if mode.isDefault {
                    Section {
                        ShortcutGuide()
                        Button {
                            editing = EditTarget(mode: mode.id, row: nil)
                        } label: {
                            Label("Add Shortcut…", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                    }
                    ForEach(groups(for: mode)) { group in
                        Section(group.name) {
                            ForEach(group.rows) { row in
                                shortcutRow(row, mode: mode, duplicate: duplicates.contains(row.chord.lowercased()))
                            }
                        }
                    }
                } else {
                    Section {
                        ForEach(mode.rows.filter(matches)) { row in
                            shortcutRow(row, mode: mode, duplicate: duplicates.contains(row.chord.lowercased()))
                        }
                        Button {
                            editing = EditTarget(mode: mode.id, row: nil)
                        } label: {
                            Label("Add Shortcut…", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                    } header: {
                        Text("In “\(mode.name)” mode")
                    } footer: {
                        Text("These only work after you enter the mode. Esc usually takes you back out.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .searchable(text: $query, placement: .toolbar, prompt: "Search shortcuts")
        .sheet(item: $editing) { target in editor(for: target) }
    }

    private var context: ShortcutContext {
        ShortcutContext(
            workspaces: store.spaces.map(\.label).filter { !$0.isEmpty },
            modes: store.modes.filter { !$0.isDefault }.map(\.name),
            displays: DisplayCatalog.current()
        )
    }

    @ViewBuilder
    private func editor(for target: EditTarget) -> some View {
        if let mode = store.modes.first(where: { $0.id == target.mode }) {
            let row = target.row.flatMap { id in mode.rows.first { $0.id == id } }
            ShortcutEditor(
                row: row,
                isModeLayer: !mode.isDefault,
                context: context,
                others: mode.rows.filter { $0.id != target.row && !$0.chord.isEmpty },
                onSave: { chord, steps in
                    save(chord: chord, steps: steps, into: target)
                    editing = nil
                },
                onDelete: row == nil ? nil : {
                    delete(target)
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
    }

    private func save(chord: String, steps: [String], into target: EditTarget) {
        guard let m = store.modes.firstIndex(where: { $0.id == target.mode }) else { return }
        // The keys belong to this shortcut now; the builder said so.
        store.modes[m].rows.removeAll { $0.id != target.row && $0.chord.lowercased() == chord.lowercased() }
        if let id = target.row, let r = store.modes[m].rows.firstIndex(where: { $0.id == id }) {
            store.modes[m].rows[r].chord = chord
            store.modes[m].rows[r].steps = steps
        } else {
            store.modes[m].rows.append(KeyRow(chord: chord, steps: steps))
        }
        store.markDirty()
    }

    private func delete(_ target: EditTarget) {
        guard let m = store.modes.firstIndex(where: { $0.id == target.mode }), let id = target.row else { return }
        store.modes[m].rows.removeAll { $0.id == id }
        store.markDirty()
    }

    private func shortcutRow(_ row: KeyRow, mode: KeyMode, duplicate: Bool) -> some View {
        ShortcutRowView(
            row: binding(mode: mode.id, row: row.id),
            duplicate: duplicate,
            onEdit: { editing = EditTarget(mode: mode.id, row: row.id) },
            onDelete: {
                guard let m = store.modes.firstIndex(where: { $0.id == mode.id }) else { return }
                store.modes[m].rows.removeAll { $0.id == row.id }
                store.markDirty()
            }
        )
    }

    /// Grouped the way the builder's library is, so a shortcut is found
    /// under the same heading it was picked from.
    private func groups(for mode: KeyMode) -> [Group] {
        var buckets: [String: [KeyRow]] = [:]
        for row in mode.rows where matches(row) {
            let name = row.steps.isEmpty ? "New" : ActionCatalog.identify(row.steps[0]).0.category.rawValue
            buckets[name, default: []].append(row)
        }
        return (["New"] + ActionCategory.allCases.map(\.rawValue)).compactMap { name in
            buckets[name].map { Group(name: name, rows: $0) }
        }
    }

    private func matches(_ row: KeyRow) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return ActionCatalog.sentence(row.steps).lowercased().contains(needle)
            || row.steps.joined(separator: " ").lowercased().contains(needle)
            || row.chord.lowercased().contains(needle)
            || ChordNaming.caps(for: row.chord).joined().lowercased().contains(needle)
    }

    private static func duplicates(in mode: KeyMode) -> Set<String> {
        var seen = Set<String>()
        var twice = Set<String>()
        for row in mode.rows where !row.chord.isEmpty {
            let key = row.chord.lowercased()
            if !seen.insert(key).inserted { twice.insert(key) }
        }
        return twice
    }

    /// A row, found by id on every read and write. An index captured when the
    /// view was built goes stale — or out of range — the moment a row above
    /// it is deleted.
    private func binding(mode: KeyMode.ID, row: KeyRow.ID) -> Binding<KeyRow> {
        Binding(
            get: {
                store.modes.first { $0.id == mode }?.rows.first { $0.id == row } ?? KeyRow()
            },
            set: { value in
                guard let m = store.modes.firstIndex(where: { $0.id == mode }),
                      let r = store.modes[m].rows.firstIndex(where: { $0.id == row })
                else { return }
                store.modes[m].rows[r] = value
                store.markDirty()
            }
        )
    }
}

/// How to make a shortcut, said once at the top of the pane.
private struct ShortcutGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Make a shortcut").font(.headline)
            step(1, "Click **Add Shortcut…**")
            step(2, "Press the keys you want to use.")
            step(3, "Choose what they do from the list of everything weft can do. "
                + "Add more steps and one shortcut does several things in a row: "
                + "go to a workspace, then open an app.")
            Text("Click any shortcut below to change it. ⌥ combinations are the safest: "
                + "most apps leave them free, and weft never lets an app see a key it uses.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    /// `text` is Markdown, for the bold control names.
    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.weft.opacity(0.18)))
            Text(LocalizedStringKey(text)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ShortcutRowView: View {
    @Binding var row: KeyRow
    let duplicate: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            if let first = row.steps.first {
                ActionIcon(action: ActionCatalog.identify(first).0, size: 24)
            }
            Button(action: onEdit) {
                HStack(spacing: 6) {
                    if row.steps.isEmpty {
                        Text("Choose what this does…").foregroundStyle(.secondary)
                    } else {
                        Text(ActionCatalog.sentence(row.steps)).lineLimit(2)
                    }
                    if row.steps.count > 1 {
                        Text("\(row.steps.count) steps")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.weft.opacity(0.15)))
                            .foregroundStyle(Color.weft)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(row.readOnly)
            .help(row.readOnly
                ? "Written over several lines in weft.toml — change it there"
                : "Change this shortcut")

            if row.readOnly {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            }
            if duplicate {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Another shortcut here uses the same keys — only one of them works.")
            }

            ChordField(chord: $row.chord)
                .disabled(row.readOnly)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(hovering ? Color.red : Color.secondary)
            .opacity(hovering ? 1 : 0.3)
            .help("Remove this shortcut")
        }
        .onHover { hovering = $0 }
    }
}

/// The keys, drawn as keys. Click to record a new combination: weft's names
/// for keys (`alt-bracketleft`) are hardware positions nobody guesses right,
/// so pressing the chord is the only sane way to enter one.
private struct ChordField: View {
    @Binding var chord: String
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Group {
                if recording {
                    Text("Press keys…")
                        .font(.callout)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                } else {
                    KeyCaps(chord: chord)
                }
            }
            .frame(minWidth: 96, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(recording ? "Press the new combination, or click to cancel" : "Click, then press a new combination")
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        // A local monitor, not a tap: this only has to see keys while the
        // window is key, and a tap needs the very permission someone may be
        // here to sort out.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop()  // a bare Esc cancels
                return nil
            }
            guard let name = ChordNaming.name(forKeyCode: Int(event.keyCode)) else { return nil }
            chord = ChordNaming.modifierPrefix(event.modifierFlags) + name
            stop()
            return nil  // swallowed, so recording ⌘W does not close the window
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// `alt-shift-bracketright` drawn as ⌥ ⇧ ].
struct KeyCaps: View {
    let chord: String

    var body: some View {
        HStack(spacing: 4) {
            if chord.isEmpty {
                Text("Record keys")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(ChordNaming.caps(for: chord).enumerated()), id: \.offset) { _, cap in
                    Text(cap)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .frame(minWidth: 20)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                }
            }
        }
    }
}

// MARK: - Apps

private struct AppsPane: View {
    @ObservedObject var store: ConfigStore
    @State private var running: [RunningApp] = []

    var body: some View {
        Form {
            Section {
                if store.rules.isEmpty {
                    EmptyState(
                        symbol: "square.on.square",
                        title: "Every app is tiled",
                        text: "Add an app to keep it floating, or to open it on the same desktop every time."
                    )
                }
                ForEach($store.rules) { $rule in
                    AppRuleRow(
                        rule: store.dirty($rule),
                        labels: store.spaceLabels,
                        onDelete: {
                            store.rules.removeAll { $0.id == rule.id }
                            store.markDirty()
                        }
                    )
                }
            } footer: {
                if store.rules.count > 1 {
                    Text("When an app matches more than one rule, the first one wins.")
                }
            }

            Section {
                Menu {
                    ForEach(running) { app in
                        Button {
                            add(app)
                        } label: {
                            Label {
                                Text(app.name)
                            } icon: {
                                Image(nsImage: AppIcons.icon(bundleID: app.id, size: 16))
                            }
                        }
                    }
                    if !running.isEmpty { Divider() }
                    Button("Match by name or window title…") {
                        store.addRule()
                    }
                } label: {
                    Label("Add App", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .formStyle(.grouped)
        .onAppear { running = RunningApp.current() }
    }

    private func add(_ app: RunningApp) {
        store.rules.append(RuleRow(
            app: "^" + NSRegularExpression.escapedPattern(for: app.name) + "$",
            bundleID: app.id,
            manage: false
        ))
        store.markDirty()
    }
}

private struct AppRuleRow: View {
    @Binding var rule: RuleRow
    let labels: [String]
    let onDelete: () -> Void
    @State private var expanded = false

    private var managed: Bool { rule.manage ?? true }

    private var name: String {
        if let named = AppIcons.name(bundleID: rule.bundleID) { return named }
        let plain = rule.app
            .replacingOccurrences(of: "^", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "\\", with: "")
        if !plain.isEmpty { return plain }
        return rule.title.isEmpty ? "New rule" : "Windows titled “\(rule.title)”"
    }

    private var summary: String {
        switch (managed, rule.space.isEmpty) {
        case (true, true): return "Tiled like any other app"
        case (true, false): return "Tiled, on “\(rule.space)”"
        case (false, true): return "Floats wherever you put it"
        case (false, false): return "Floats, on “\(rule.space)”"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: AppIcons.icon(bundleID: rule.bundleID, size: 32))
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).fontWeight(.medium)
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { managed },
                    set: { rule.manage = $0 ? nil : false }
                )) {
                    Text("Tile").tag(true)
                    Text("Float").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("", selection: $rule.space) {
                    Text("Any \(WorkspaceVocabulary.noun)").tag("")
                    ForEach(labels, id: \.self) { Text($0).tag($0) }
                    if !rule.space.isEmpty, !labels.contains(rule.space) {
                        Text(rule.space).tag(rule.space)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .buttonStyle(.borderless)
                .help("Match by window title or bundle ID")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove")
            }
            if expanded {
                LabeledContent("App name matches") {
                    TextField("Ghostty|kitty", text: $rule.app)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Window title matches") {
                    TextField("any title", text: $rule.title)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Bundle ID") {
                    TextField("com.example.app", text: $rule.bundleID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                Text("Names and titles are regular expressions: “Brave|Zen” matches either.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !rule.isValid {
                Label("Choose an app, or give this rule a name or title to match.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RunningApp: Identifiable, Hashable {
    let id: String
    let name: String

    @MainActor
    static func current() -> [RunningApp] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let id = app.bundleIdentifier, let name = app.localizedName,
                      id != Bundle.main.bundleIdentifier, seen.insert(id).inserted
                else { return nil }
                return RunningApp(id: id, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// App icons and names by bundle id, looked up once each. Only the Apps page
/// asks, and only while it is open.
@MainActor
private enum AppIcons {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]

    static func icon(bundleID: String, size: CGFloat) -> NSImage {
        let key = "\(bundleID)@\(Int(size))"
        if let hit = icons[key] { return hit }
        let base: NSImage
        if !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            base = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            base = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        let image = (base.copy() as? NSImage) ?? base
        image.size = NSSize(width: size, height: size)
        icons[key] = image
        return image
    }

    static func name(bundleID: String) -> String? {
        guard !bundleID.isEmpty else { return nil }
        if let hit = names[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        names[bundleID] = name
        return name
    }
}

/// The bar under the update's current stage.
///
/// Determinate while the download reports a percentage, indeterminate for the
/// stages that cannot — and the elapsed clock runs either way. That clock is
/// the part that matters: a determinate bar creeping and a stalled one look
/// identical over four seconds, and the complaint this answers was about
/// minutes. A number that is visibly counting says "slow", where a still
/// sentence says "broken".
private struct UpdateProgressRow: View {
    let fraction: Double?
    let elapsed: TimeInterval

    var body: some View {
        HStack(spacing: 8) {
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 160)
                Text("\(Int((fraction * 100).rounded()))%")
                    .monospacedDigit()
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 160)
            }
            Text(Self.clock(elapsed))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

// MARK: - Advanced

private struct AdvancedPane: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var health: EngineHealth
    @ObservedObject private var updater = Updater.shared
    @State private var newMode = ""
    @State private var preview = ""
    @State private var showsFile = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    EdgeCross(
                        top: $store.reserveTop, bottom: $store.reserveBottom,
                        left: $store.reserveLeft, right: $store.reserveRight,
                        onChange: store.markDirty
                    )
                } label: {
                    Text("Keep free")
                    Text("Space weft never tiles into — for a bar or a Dock that is always showing.")
                }
            } header: {
                Text("Screen")
            }

            Section("Behavior") {
                Toggle(isOn: store.bind(\.manageMenubarApps)) {
                    Text("Tile windows of menu-bar apps")
                    Text("Usually their dropdown panels, which should not take a slot.")
                }
            }

            // Updating used to live here as a lone toggle, with the version
            // nowhere and no way to act on an update from this window. The
            // menu bar carried the only notice, and only while it was open.
            Section {
                LabeledContent("Version") {
                    HStack(spacing: 8) {
                        Text(WeftVersion.current)
                            .monospacedDigit()
                        if health.updateAvailable, let update = health.update {
                            Text("\(update.latest) available")
                                .foregroundStyle(.orange)
                        } else if health.update != nil {
                            Text("up to date")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if health.updateAvailable, let update = health.update {
                    LabeledContent {
                        Button(updater.isRunning
                            ? "Updating…" : "Update to \(update.latest)…")
                        {
                            updater.promptAndInstall(update)
                        }
                        .weftProminentButton()
                        .controlSize(.small)
                        .disabled(updater.isRunning)
                    } label: {
                        Text("A newer weft is out")
                        // What the installer is doing, while it is doing it —
                        // with the download's own percentage, which is nearly
                        // all of the wall clock. A single unchanging sentence
                        // is what "it showed no progress" was: on a slow link
                        // to GitHub's CDN the download alone runs for minutes,
                        // measured at 45% after two and a half.
                        if let step = updater.step {
                            Text(step)
                            UpdateProgressRow(
                                fraction: updater.fraction, elapsed: updater.elapsed)
                            Text("weft quits and reopens on its own when this finishes.")
                        } else {
                            Text("Downloads the release, checks it, and restarts. "
                                + "Your settings and permissions are kept.")
                        }
                    }
                }
                if let failure = updater.failure {
                    LabeledContent {
                        Button("Release Page…") {
                            if let u = URL(string: health.update?.url
                                ?? "https://github.com/amiralibg/weft/releases/latest")
                            {
                                NSWorkspace.shared.open(u)
                            }
                        }
                        .weftGlassButton()
                        .controlSize(.small)
                    } label: {
                        Text("The update did not run")
                            .foregroundStyle(.orange)
                        Text(failure)
                    }
                }
                Toggle(isOn: store.bind(\.checkForUpdates)) {
                    Text("Check for new versions of weft")
                    Text("Asks GitHub once a day. Nothing is downloaded until you say so.")
                }
                LabeledContent {
                    Button(health.checkingForUpdate ? "Checking…" : "Check Now") {
                        health.checkForUpdatesNow()
                    }
                    .weftGlassButton()
                    .controlSize(.small)
                    .disabled(health.checkingForUpdate)
                } label: {
                    Text("Check now")
                    if let checked = health.update?.checkedAt {
                        Text("Last checked \(checked.formatted(.relative(presentation: .named))).")
                    } else {
                        Text("Not checked yet.")
                    }
                }
            } header: {
                Text("Updates")
            }

            // Setup is reachable from here whether or not anything is wrong.
            // The menu bar only carries it while a permission is missing, and
            // "everything is granted" is not a reason to make the window that
            // explains the permissions unreachable.
            Section {
                LabeledContent {
                    Button("Open Setup…") { OnboardingWindowController.shared.show() }
                        .weftGlassButton()
                        .controlSize(.small)
                } label: {
                    Text("Permissions")
                    Text(health.needsPermissions
                        ? "Something weft needs is still switched off."
                        : "Accessibility, Input Monitoring and Screen Recording are in place.")
                }
            } header: {
                Text("Permissions")
            }

            Section {
                let modes = store.modes.filter { !$0.isDefault }
                ForEach(modes) { mode in
                    HStack {
                        Text(mode.name)
                        Text("\(mode.rows.count) shortcut\(mode.rows.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            store.removeMode(mode.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this mode and its shortcuts")
                    }
                }
                HStack {
                    TextField("New mode name", text: $newMode)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addMode)
                    Button("Add", action: addMode)
                        .disabled(newMode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Shortcut modes")
            } footer: {
                Text("A mode is a second layer of shortcuts — like resize mode — that only works after you enter it. Give a shortcut “Enter mode” in Shortcuts to reach it.")
            }

            Section {
                Toggle("Switch to a workspace when a rule sends a new window there", isOn: Binding(
                    get: { store.followSpaceRules },
                    set: { store.setFollowSpaceRules($0) }
                ))
            } header: {
                Text("Rules")
            } footer: {
                Text("A rule with a workspace always places the window there — it is instant and "
                    + "invisible. This only decides whether the screen follows it. Off by default: "
                    + "a rule fires when an app opens, which may be while you are typing somewhere else.")
            }

            Section("Border drawing") {
                Picker("Drawn by", selection: store.bind(\.bordersBackend)) {
                    Text("Weft").tag("native")
                    Text("JankyBorders").tag("janky")
                }
                if store.bordersBackend == "janky" {
                    LabeledContent("JankyBorders") { InstallState(path: health.bordersPath) }
                    Toggle("Keep JankyBorders running", isOn: store.bind(\.bordersSupervise))
                    LabeledContent("Arguments") {
                        TextField("width=2.0 style=round", text: store.bind(\.bordersArgs))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .disabled(store.bordersArgsLocked)
                    }
                }
            }

            Section("Sketchybar") {
                Toggle("Send layout and focus events to Sketchybar", isOn: store.bind(\.sketchybarEnabled))
                if store.sketchybarEnabled {
                    LabeledContent("Sketchybar") { InstallState(path: health.sketchybarPath) }
                    LabeledContent("Bar program") {
                        TextField("sketchybar", text: store.bind(\.sketchybarBarName))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                    }
                    SliderRow(title: "Group events closer than", value: store.bind(\.sketchybarCoalesceMs),
                              range: 0...100, unit: "ms")
                }
            }

            Section {
                HStack {
                    Button("Open in Editor") { store.openExternally() }
                    Button("Show in Finder") { store.revealInFinder() }
                    Button("Reload") { store.load() }
                }
                DisclosureGroup("The file, as weft will read it", isExpanded: $showsFile) {
                    ScrollView([.vertical, .horizontal]) {
                        Text(preview.isEmpty ? "—" : preview)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 260)
                }
            } header: {
                Text("Configuration file")
            } footer: {
                Text(ConfigStore.configPath)
            }

            Section {
                LabeledContent("weftctl") {
                    Text(Self.cliInstalled ? "~/.local/bin/weftctl" : "Not installed")
                        .foregroundStyle(.secondary)
                }
                if Self.cliInstalled {
                    LabeledContent("Add to your shell") {
                        HStack {
                            Text(Self.pathLine)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(Self.pathLine, forType: .string)
                            }
                        }
                    }
                }
            } header: {
                Text("Command line")
            } footer: {
                Text("Optional. Everything the command line can do has a place in this window.")
            }

            Section("Engine") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(health.tint).frame(width: 8, height: 8)
                        Text(health.headline)
                    }
                }
                Button(health.isRestarting ? "Restarting…" : "Restart Engine") { health.restart() }
                    .disabled(health.isRestarting)
                // The one place to remove weft — Settings, not the menu bar,
                // where a destructive item sits one slip away from Quit.
                Button("Uninstall Weft…", role: .destructive) { Uninstaller.confirmAndRun() }
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .onAppear { preview = store.previewText() }
        .onChange(of: showsFile) { _, open in if open { preview = store.previewText() } }
        .onChange(of: store.lastSavedAt) { _, _ in if showsFile { preview = store.previewText() } }
    }

    private static let pathLine = #"export PATH="$HOME/.local/bin:$PATH""#

    private static var cliInstalled: Bool {
        FileManager.default.isExecutableFile(
            atPath: ("~/.local/bin/weftctl" as NSString).expandingTildeInPath
        )
    }

    private func addMode() {
        store.addMode(named: newMode)
        newMode = ""
    }
}

private struct InstallState: View {
    let path: String?

    var body: some View {
        Label(path == nil ? "Not installed" : "Installed", systemImage: path == nil ? "xmark.circle" : "checkmark.circle.fill")
            .foregroundStyle(path == nil ? Color.orange : Color.green)
            .help(path ?? "Searched the usual install locations and your PATH.")
    }
}

// MARK: - Shared pieces

private struct SliderRow: View {
    let title: String
    var caption: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var unit = "pt"

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(
                    value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                    in: Double(range.lowerBound)...Double(range.upperBound)
                )
                .frame(minWidth: 160, maxWidth: 260)
                Text("\(value) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        } label: {
            Text(title)
            if let caption { Text(caption) }
        }
    }
}

private struct DoubleSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.5
    var unit = "pt"

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                // Rounded here rather than with `step:`, which on macOS draws a
                // tick for every step — twenty-two of them for a thickness.
                Slider(
                    value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }),
                    in: range
                )
                .frame(minWidth: 160, maxWidth: 260)
                Text(value.formatted(.number.precision(.fractionLength(0...1))) + " " + unit)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

/// The one thing that needs doing after a late permission grant, said once.
private struct RestartNotice: View {
    @ObservedObject var health: EngineHealth

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Weft needs to restart once").fontWeight(.semibold)
                Text("A permission arrived after it started, and macOS only hands it over at launch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(health.isRestarting ? "Restarting…" : "Restart") { health.restart() }
                .weftProminentButton()
                .disabled(health.isRestarting)
        }
    }
}

/// The engine's state, at the foot of the sidebar — and the one button that
/// fixes it, never a command to go and type.
private struct EngineCard: View {
    @ObservedObject var health: EngineHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(health.tint).frame(width: 8, height: 8)
                Text(health.headline).font(.callout.weight(.medium))
                Spacer(minLength: 0)
            }
            Text(health.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !health.running {
                Button(health.isRestarting ? "Starting…" : "Start Weft") { health.startEngine() }
                    .weftProminentButton()
                    .controlSize(.small)
                    .disabled(health.isRestarting)
            } else if health.needsRestart {
                Button(health.isRestarting ? "Restarting…" : "Restart") { health.restart() }
                    .weftProminentButton()
                    .controlSize(.small)
                    .disabled(health.isRestarting)
            } else if health.needsPermissions {
                Button("Open Setup…") { OnboardingWindowController.shared.show() }
                    .weftGlassButton()
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .weftGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// "Saved", briefly, after each change lands — or why it could not be.
private struct SaveStateBadge: View {
    @ObservedObject var store: ConfigStore
    @State private var showsSaved = false
    @State private var showsError = false

    var body: some View {
        Group {
            if let error = store.validationError {
                Button {
                    showsError = true
                } label: {
                    Label("Not saved", systemImage: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
                .popover(isPresented: $showsError) {
                    Text(error)
                        .padding(14)
                        .frame(width: 300, alignment: .leading)
                }
                .help("A change cannot be saved yet — click for why")
            } else if showsSaved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .task(id: store.lastSavedAt) {
            guard store.lastSavedAt != nil else { return }
            withAnimation(.easeOut(duration: 0.15)) { showsSaved = true }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeOut(duration: 0.3)) { showsSaved = false }
        }
    }
}

/// Four edge values laid out as a cross — top above, left and right either
/// side, bottom below — so where a field sits says which edge it is.
private struct EdgeCross: View {
    @Binding var top: Int
    @Binding var bottom: Int
    @Binding var left: Int
    @Binding var right: Int
    var range: ClosedRange<Int> = 0...400
    let onChange: () -> Void

    private static let cell: CGFloat = 58
    private static let spacing: CGFloat = 8

    var body: some View {
        VStack(spacing: Self.spacing) {
            field($top, "Top")
            HStack(spacing: Self.spacing) {
                field($left, "Left")
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: Self.cell, height: 32)
                field($right, "Right")
            }
            field($bottom, "Bottom")
        }
        .frame(width: Self.cell * 3 + Self.spacing * 2)
    }

    private func field(_ binding: Binding<Int>, _ name: String) -> some View {
        TextField("", value: binding, format: .number)
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .frame(width: Self.cell)
            .onChange(of: binding.wrappedValue) { _, value in
                let clamped = min(max(value, range.lowerBound), range.upperBound)
                if clamped != value { binding.wrappedValue = clamped }
                onChange()
            }
            .help("\(name), in points")
            .accessibilityLabel(name)
    }
}

// MARK: - Liquid Glass, with a fallback

/// Liquid Glass where the system has it (macOS 26), a material where it does
/// not. Glass is drawn by the WindowServer's compositor and costs nothing
/// while nothing moves; it is only ever on screen while this window is.
extension View {
    @ViewBuilder
    func weftGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self
                .background(shape.fill(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.regularMaterial)))
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }

    @ViewBuilder
    func weftProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func weftGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// Glass shapes that sit close together blend as one on macOS 26; a plain
/// group elsewhere.
private struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Colour

extension Color {
    /// From 0xAARRGGBB — the notation weft.toml and JankyBorders use.
    init(argb: UInt32) {
        self.init(
            .sRGB,
            red: Double((argb >> 16) & 0xff) / 255,
            green: Double((argb >> 8) & 0xff) / 255,
            blue: Double(argb & 0xff) / 255,
            opacity: Double((argb >> 24) & 0xff) / 255
        )
    }

    init?(hex: String) {
        guard !hex.isEmpty, let value = parseBorderColor(hex) else { return nil }
        self.init(argb: value)
    }

    /// Back to 0xAARRGGBB for the file.
    var argbHex: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "0xff7aa2f7" }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(
            format: "0x%02x%02x%02x%02x",
            byte(c.alphaComponent), byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent)
        )
    }
}

// MARK: - Bindings that save

extension ConfigStore {
    /// A binding to one of the store's settings that marks it changed —
    /// which, since changes apply as they are made, schedules the save.
    func bind<Value>(_ keyPath: ReferenceWritableKeyPath<ConfigStore, Value>) -> Binding<Value> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { self[keyPath: keyPath] = $0; self.markDirty() }
        )
    }

    /// The same, for a binding a view already has: a row in a list.
    func dirty<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = $0; self.markDirty() }
        )
    }
}

// MARK: - Key names

/// Keycode → the token `parseChord` expects. Deliberately the inverse of
/// WeftInput's table rather than a character lookup: the config is
/// layout-independent, so a Colemak user recording the key labelled "N" must
/// get the ANSI position's name, not the glyph on the cap.
enum ChordNaming {
    private static let letters: [Int: String] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h",
        34: "i", 38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p",
        12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x",
        16: "y", 6: "z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9",
        27: "minus", 24: "equal", 33: "bracketleft", 30: "bracketright",
        41: "semicolon", 39: "quote", 43: "comma", 47: "period", 44: "slash",
        42: "backslash", 50: "grave", 49: "space", 48: "tab", 36: "return",
        51: "delete", 53: "escape", 123: "left", 124: "right", 125: "down", 126: "up",
    ]

    static func name(forKeyCode code: Int) -> String? { letters[code] }

    private static let glyphs: [String: String] = [
        "ctrl": "⌃", "alt": "⌥", "shift": "⇧", "cmd": "⌘",
        "space": "␣", "tab": "⇥", "return": "↩", "delete": "⌫", "escape": "⎋",
        "left": "←", "right": "→", "up": "↑", "down": "↓",
        "bracketleft": "[", "bracketright": "]", "backslash": "\\",
        "grave": "`", "minus": "−", "equal": "=", "comma": ",", "period": ".",
        "slash": "/", "semicolon": ";", "quote": "'",
    ]

    /// `alt-shift-bracketright` → ["⌥", "⇧", "]"].
    static func caps(for chord: String) -> [String] {
        chord.split(separator: "-").map { token in
            let key = token.lowercased()
            return glyphs[key] ?? (key.count == 1 ? key.uppercased() : key)
        }
    }

    static func modifierPrefix(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        return parts.isEmpty ? "" : parts.joined(separator: "-") + "-"
    }
}

// MARK: - Engine health

/// The daemon's state, for the sidebar card. Polled slowly — every five
/// seconds, only while the window is open.
@MainActor
final class EngineHealth: ObservableObject {
    @Published var running = false
    @Published var accessibility = false
    /// The event tap, not the Input Monitoring switch: Accessibility alone is
    /// enough for macOS to let weftd open it.
    @Published var keybindsLive = false
    @Published var isRestarting = false
    /// Running with grants it cannot use, because they came after it started.
    @Published var needsRestart = false
    /// Labels of the workspaces that exist right now, in `space focus N`
    /// order.
    @Published var liveSpaces: [String] = []
    /// The same, with what the canvas draws: layout, windows, and whether each
    /// is showing right now.
    @Published var liveWorkspaces: [SpaceStatus] = []
    /// How the workspaces sit on the displays, from `query workspaces`. Nil
    /// until the daemon has answered once.
    @Published var workspaces: WorkspacesStatus?
    /// The newest release weft knows about, newer than this one or not.
    /// Nil means nobody has asked yet, or asking failed.
    @Published var update: UpdateCheck.Result?
    /// A check the user asked for, in flight. Only ever set by the button —
    /// the background read is silent.
    @Published var checkingForUpdate = false

    let bordersPath = ExternalBinary.find("borders")
    let sketchybarPath = ExternalBinary.find("sketchybar")

    private var timer: Timer?

    var needsPermissions: Bool { running && !(accessibility && keybindsLive) }

    /// There is a newer weft than the one running.
    var updateAvailable: Bool { update?.isNewerThanRunning ?? false }

    var tint: Color {
        if !running { return .orange }
        if needsRestart { return .accentColor }
        return needsPermissions ? .yellow : .green
    }

    var headline: String {
        if !running { return "Weft isn't running" }
        if needsRestart { return "Restart needed" }
        return needsPermissions ? "Needs permission" : "Weft is running"
    }

    var detail: String {
        if !running { return "Windows aren't being tiled." }
        if needsRestart { return "A permission arrived after it started." }
        if needsPermissions {
            var missing: [String] = []
            if !accessibility { missing.append("Accessibility") }
            if !keybindsLive { missing.append("Input Monitoring") }
            return missing.joined(separator: " and ") + " is off."
        }
        return "Changes apply as you make them."
    }

    func start() {
        refresh()
        // Ask GitHub if nobody has this launch, or if the cached answer has
        // aged out.
        //
        // Everything here used to read the cache and only the cache, so a
        // Settings window opened before the background check had landed — or on
        // a machine where it had never run — showed the running version with
        // nothing beside it and no Update button, which is indistinguishable
        // from "you are up to date". Opening the one window that displays
        // update state is as clear a signal that someone wants the answer as
        // pressing Check Now, and `refreshIfNeeded` still honours the daily
        // throttle and the config switch, so this is at most one request per
        // day and none at all when updates are turned off.
        if UpdateCheck.isStale(UpdateCheck.cached()) {
            let enabled = ConfigStore.readCheckForUpdates()
            UpdateCheck.refreshIfNeeded(enabled: enabled) { [weak self] result in
                guard let result else { return }
                Task { @MainActor in
                    guard let self, !self.checkingForUpdate else { return }
                    self.update = result
                }
            }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// How the daemon can change desktops, in the terms the Settings window
    /// needs: works or does not, and one line saying why.
    func refresh() {
        Task.detached(priority: .utility) {
            let perms: DaemonPermissions? = {
                guard let json = BarIPC.send("query permissions"),
                      let data = json.data(using: .utf8)
                else { return nil }
                return try? JSONDecoder().decode(DaemonPermissions.self, from: data)
            }()
            let statuses: [SpaceStatus] = {
                guard let json = BarIPC.send("query spaces"),
                      let data = json.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode([SpaceStatus].self, from: data)
                else { return [] }
                return decoded
            }()
            let spaces = statuses.map(\.label)
            let workspaces: WorkspacesStatus? = {
                guard let json = BarIPC.send("query workspaces"),
                      let data = json.data(using: .utf8)
                else { return nil }
                return try? JSONDecoder().decode(WorkspacesStatus.self, from: data)
            }()
            // The cached answer only — a file read, no network. The window
            // polls every five seconds and must not turn that into traffic.
            let cachedUpdate = UpdateCheck.cached()
            await MainActor.run {
                self.running = perms != nil
                self.accessibility = perms?.accessibility ?? false
                self.keybindsLive = perms?.tapLive ?? false
                self.needsRestart = perms?.mustRestart ?? false
                self.liveSpaces = spaces
                if self.liveWorkspaces != statuses { self.liveWorkspaces = statuses }
                self.workspaces = workspaces
                if !self.checkingForUpdate { self.update = cachedUpdate }
            }
        }
    }

    /// Ask GitHub now, because the user pressed the button.
    ///
    /// The background path is throttled to a day, which is right for something
    /// nobody asked for and wrong for something somebody did: "Check Now" that
    /// returns a day-old answer is a button that does nothing.
    func checkForUpdatesNow() {
        guard !checkingForUpdate else { return }
        checkingForUpdate = true
        Task.detached(priority: .userInitiated) {
            let result = await UpdateCheck.fetchNow()
            await MainActor.run {
                if let result { self.update = result }
                self.checkingForUpdate = false
            }
        }
    }

    func restart() {
        isRestarting = true
        Task.detached(priority: .userInitiated) {
            ConfigEditorWindowController.restartWeftCtl()
            _ = await OnboardingWindowController.awaitDaemon()
            await MainActor.run {
                self.isRestarting = false
                self.refresh()
            }
        }
    }

    /// Not running: install it if this app carries an engine that is not in
    /// place yet, otherwise register and start the service.
    func startEngine() {
        let installed = FileManager.default.isExecutableFile(
            atPath: EngineInstaller.binDir.appendingPathComponent("weftctl").path
        )
        if !installed, EngineInstaller.bundledWeftctl != nil {
            OnboardingWindowController.shared.showInstall()
            return
        }
        isRestarting = true
        Task.detached(priority: .userInitiated) {
            ConfigEditorWindowController.runWeftctl(["service", "install"])
            _ = await OnboardingWindowController.awaitDaemon()
            await MainActor.run {
                self.isRestarting = false
                self.refresh()
            }
        }
    }
}

// MARK: - Window

@MainActor
final class ConfigEditorWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ConfigEditorWindowController()

    /// Built when the window opens and released when it closes: WeftBar runs
    /// all day, and a settings window it is not showing should cost nothing.
    private var store: ConfigStore?
    private var health: EngineHealth?
    private var lastFrame: NSRect?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Weft Settings"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        // A window AppKit keeps alive between showings stays filed under the
        // space it was first ordered into, so reopening it from another space
        // either yanks the user back to the old one or shows nothing at all.
        // `moveToActiveSpace` brings it to whichever space is in front now.
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        window.setFrameAutosaveName("WeftSettings")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    static func configPath() -> String { ConfigStore.configPath }

    /// `--tab shortcuts` on the command line, for `open -a WeftBar --args
    /// --settings --tab shortcuts`.
    private static var launchSection: SettingsSection {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--tab"), i + 1 < args.count else { return .general }
        return SettingsSection(launchName: args[i + 1]) ?? .general
    }

    /// Open on `section`, or switch an open window to it.
    func show(section: SettingsSection) {
        let fresh = window?.contentViewController == nil
        show(initial: section)
        if !fresh {
            NotificationCenter.default.post(name: .weftShowSettingsSection, object: section.rawValue)
        }
    }

    func show() { show(initial: nil) }

    private func show(initial: SettingsSection?) {
        guard let window else { return }
        if window.contentViewController == nil {
            // Load before the views exist. Loading into views already on
            // screen changes values under controls that react to changes —
            // the edge fields do — which marked the file changed and saved it
            // just because Settings was opened.
            let store = ConfigStore()
            store.load()
            let health = EngineHealth()
            self.store = store
            self.health = health
            let host = NSHostingController(
                rootView: SettingsView(store: store, health: health, section: initial ?? Self.launchSection)
            )
            host.sceneBridgingOptions = [.toolbars, .title]
            let frame = lastFrame ?? window.frame
            window.contentViewController = host
            window.setFrame(frame, display: false)
        }
        health?.refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak window] in window?.makeFirstResponder(nil) }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { teardown() }
    }

    private func teardown() {
        store?.flush()
        health?.stop()
        lastFrame = window?.frame
        window?.contentViewController = nil
        store = nil
        health = nil
    }

    /// Resolve weftctl without a hardcoded home directory.
    nonisolated static func weftctlURL() -> URL? {
        let candidates = [
            "~/.local/bin/weftctl",
            "/opt/homebrew/bin/weftctl",
            "/usr/local/bin/weftctl",
        ].map { ($0 as NSString).expandingTildeInPath }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["weftctl"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        let found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return found.isEmpty ? nil : URL(fileURLWithPath: found)
    }

    nonisolated static func runWeftctl(_ arguments: [String]) {
        guard let url = weftctlURL() else { return }
        let proc = Process()
        proc.executableURL = url
        proc.arguments = arguments
        try? proc.run()
        proc.waitUntilExit()
    }

    nonisolated static func restartWeftCtl() {
        runWeftctl(["service", "restart"])
    }
}
