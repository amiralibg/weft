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
    case general, appearance, workspaces, shortcuts, apps, desktops, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .workspaces: return "Workspaces"
        case .shortcuts: return "Shortcuts"
        case .apps: return "Apps"
        case .desktops: return "Desktops"
        case .advanced: return "Advanced"
        }
    }

    /// The Desktops pane lists whatever the workspaces mode makes: named
    /// desktops under `native`, named workspaces under `virtual`. One pane
    /// either way — it is the same `[[space]]` list — but calling it
    /// "Desktops" under virtual names the wrong thing, and the wrong noun in
    /// the sidebar is what sends someone to Mission Control to fix a setting
    /// that lives in this window.
    func title(virtual: Bool) -> String {
        guard virtual, self == .desktops else { return title }
        return "Workspace List"
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .workspaces: return "rectangle.3.group"
        case .shortcuts: return "command"
        case .apps: return "square.on.square"
        case .desktops: return "menubar.dock.rectangle"
        case .advanced: return "slider.horizontal.3"
        }
    }

    /// `--tab <name>` on the command line. The old tab names keep working, so
    /// a support answer written last month still opens the right page.
    init?(launchName: String) {
        switch launchName {
        case "keys", "keybindings": self = .shortcuts
        case "rules": self = .apps
        case "spaces": self = .desktops
        case "integrations": self = .advanced
        case "workspace": self = .workspaces
        default:
            guard let section = SettingsSection(rawValue: launchName) else { return nil }
            self = section
        }
    }
}

// MARK: - Root

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
                    Label(item.title(virtual: store.workspacesMode == "virtual"),
                          systemImage: item.symbol)
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
                .navigationTitle(
                    (section ?? .general).title(virtual: store.workspacesMode == "virtual")
                )
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { SaveStateBadge(store: store) }
                }
        }
        .frame(minWidth: 840, minHeight: 600)
        .onAppear { health.start() }
        .onDisappear { health.stop() }
    }

    @ViewBuilder
    private func detail(_ section: SettingsSection) -> some View {
        switch section {
        case .general: GeneralPane(store: store, health: health)
        case .appearance: AppearancePane(store: store)
        case .workspaces: WorkspacesPane(store: store, health: health)
        case .shortcuts: ShortcutsPane(store: store)
        case .apps: AppsPane(store: store)
        case .desktops: DesktopsPane(store: store, health: health)
        case .advanced: AdvancedPane(store: store, health: health)
        }
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
private struct DesktopPreview: View {
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
private struct Wallpaper: View {
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

/// Where workspaces live: inside one macOS desktop, or one per desktop.
///
/// This is the pane that decides what "space" means everywhere else in weft,
/// so it leads with a picture rather than a switch. The two models are hard to
/// tell apart from prose — both give you named groups of windows you switch
/// between with alt-N — and the difference that matters is entirely mechanical:
/// one changes desktop and one does not.
private struct WorkspacesPane: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var health: EngineHealth

    private var virtual: Bool { store.workspacesMode == "virtual" }

    /// The file and the running daemon can disagree: a reload is in flight, or
    /// the engine has not been restarted. weftd rebuilds its workspace set
    /// when the mode changes, so this usually clears itself within a second —
    /// but while it is true, everything else in this window describes a model
    /// the user is not looking at.
    private var pending: Bool {
        guard health.running, let live = health.workspacesMode else { return false }
        return live != store.workspacesMode
            || (virtual && health.anchorDesktop != store.workspaceAnchor)
    }

    var body: some View {
        Form {
            if pending {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                        Text("Weft is still running in **\(health.workspacesMode ?? "?")** mode. "
                            + "It picks the change up on its own; restart the engine if it does not.")
                            .font(.callout)
                        Spacer()
                        Button("Restart") { health.restart() }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Section {
                WorkspacesHero(virtual: virtual, anchor: store.workspaceAnchor,
                               desktops: max(1, health.desktopCount))
                    .frame(height: 210)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                Picker("", selection: Binding(
                    get: { store.workspacesMode },
                    set: { store.setWorkspacesMode($0) }
                )) {
                    Text("All on one desktop").tag("virtual")
                    Text("One per macOS desktop").tag("native")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if virtual {
                    // Only desktops that exist are offered, which is the UI
                    // half of "an anchor naming no desktop is silently
                    // clamped": this window cannot produce that value at all.
                    Picker("Host desktop", selection: Binding(
                        get: { min(store.workspaceAnchor, max(1, health.desktopCount)) },
                        set: { store.workspaceAnchor = $0; store.markDirty() }
                    )) {
                        ForEach(1...max(1, health.desktopCount), id: \.self) { n in
                            Text("Desktop \(n)").tag(n)
                        }
                    }
                    .disabled(health.desktopCount <= 1)
                }
            } header: {
                Text("Where your workspaces live")
            } footer: {
                Text(virtual ? Self.virtualFooter : Self.nativeFooter)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            Section {
                ComparisonRow(
                    symbol: "bolt.fill",
                    title: "Switching",
                    virtual: "Instant. Nothing animates.",
                    native: "About half a second of desktop animation.",
                    showingVirtual: virtual
                )
                ComparisonRow(
                    symbol: "arrow.left.arrow.right",
                    title: "Moving a window",
                    virtual: "Works for every window, including one with no title bar.",
                    native: "Weft holds the title bar, so a window without one cannot move.",
                    showingVirtual: virtual
                )
                ComparisonRow(
                    symbol: "square.grid.3x3",
                    title: "Mission Control",
                    virtual: "Hidden windows show as a sliver on the host desktop.",
                    native: "Unchanged — every desktop looks the way macOS made it.",
                    showingVirtual: virtual
                )
            } header: {
                Text("What changes")
            } footer: {
                Text("Your other macOS desktops keep working either way: full-screen apps "
                    + "make their own, swipes and Mission Control still switch them, and weft "
                    + "tiles whatever is on them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
    }

    private static let virtualFooter =
        "Your workspaces all sit on one macOS desktop. Switching between them hides the "
        + "windows you are not using just off the edge of the screen and puts the others back "
        + "— no desktop change, nothing to animate, and it works on any window. "
        + "Add and name them in the Workspace List."

    private static let nativeFooter =
        "Each workspace is one of macOS's own desktops, the way weft worked before 0.9.12. "
        + "Switching is a real desktop change, so it animates, and moving a window to another "
        + "one means weft holds it by the title bar and presses your \"move a space\" shortcut "
        + "— which a window with no title bar does not have."
}

/// One row of the virtual/native comparison. Both answers are written down;
/// only the live one is emphasised, so the pane reads as a comparison rather
/// than as a list of whichever facts happen to apply right now.
private struct ComparisonRow: View {
    let symbol: String
    let title: String
    let virtual: String
    let native: String
    let showingVirtual: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(showingVirtual ? virtual : native)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// The two models, drawn.
///
/// `DesktopPreview` next door draws one screen and the windows inside it;
/// this draws the screens themselves and where workspaces sit relative to
/// them, which is the only thing the two modes actually disagree about. It
/// springs between the two arrangements so switching the picker shows the
/// change rather than replacing one static picture with another.
private struct WorkspacesHero: View {
    let virtual: Bool
    let anchor: Int
    let desktops: Int

    var body: some View {
        GeometryReader { geo in
            let count = max(1, min(desktops, 3))
            let gap: CGFloat = 14
            let w = (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let h = min(geo.size.height, w * 0.62)
            HStack(spacing: gap) {
                ForEach(1...count, id: \.self) { n in
                    MiniScreen(
                        number: n,
                        // Under native every desktop carries exactly one
                        // workspace; under virtual the host carries the stack
                        // and the rest carry one each, which is the whole
                        // shape of the model in one number.
                        chips: virtual ? (n == min(anchor, count) ? 4 : 1) : 1,
                        highlighted: virtual && n == min(anchor, count)
                    )
                    .frame(width: w, height: h)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .animation(.spring(response: 0.42, dampingFraction: 0.84), value: virtual)
            .animation(.spring(response: 0.42, dampingFraction: 0.84), value: anchor)
        }
        .padding(.vertical, 10)
    }
}

/// One screen: wallpaper, menu bar, and a chip per workspace it holds. The
/// front chip is the one showing; the ones behind it are parked.
private struct MiniScreen: View {
    let number: Int
    let chips: Int
    let highlighted: Bool

    var body: some View {
        GeometryReader { geo in
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            ZStack(alignment: .topLeading) {
                Wallpaper().clipShape(shape)
                Rectangle()
                    .fill(Color.black.opacity(0.28))
                    .frame(height: 8)
                VStack {
                    Spacer()
                    ZStack {
                        // Drawn back to front, so the stack reads as depth.
                        ForEach((0..<chips).reversed(), id: \.self) { i in
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(i == 0 ? 0.30 : 0.12))
                                .frame(
                                    width: geo.size.width * (0.62 - CGFloat(i) * 0.06),
                                    height: geo.size.height * 0.42
                                )
                                .offset(x: CGFloat(i) * 7, y: CGFloat(i) * -5)
                                .overlay {
                                    if i == 0 {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .stroke(Color.white.opacity(0.45), lineWidth: 1)
                                            .frame(
                                                width: geo.size.width * 0.62,
                                                height: geo.size.height * 0.42
                                            )
                                    }
                                }
                        }
                    }
                    Spacer()
                    Text("Desktop \(number)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.bottom, 6)
                }
                .frame(maxWidth: .infinity)
            }
            .clipShape(shape)
            .overlay {
                shape.stroke(
                    highlighted ? Color.accentColor : Color.white.opacity(0.18),
                    lineWidth: highlighted ? 2 : 1
                )
            }
        }
    }
}

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

    private struct Group: Identifiable {
        let name: String
        let rows: [KeyRow]
        var id: String { name }
    }

    /// The order a person thinks about these in, not the order the file has.
    private static let order = [
        "New", "Focus", "Move", "Spaces", "Layout", "Stacks", "Resize", "Displays", "Apps", "Modes", "Other",
    ]

    var body: some View {
        Form {
            ForEach(store.modes) { mode in
                let duplicates = Self.duplicates(in: mode)
                if mode.isDefault {
                    Section {
                        Button {
                            store.addKey(to: mode.id)
                        } label: {
                            Label("Add Shortcut", systemImage: "plus")
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
                            store.addKey(to: mode.id)
                        } label: {
                            Label("Add Shortcut", systemImage: "plus")
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
    }

    private func shortcutRow(_ row: KeyRow, mode: KeyMode, duplicate: Bool) -> some View {
        ShortcutRowView(
            row: binding(mode: mode.id, row: row.id),
            duplicate: duplicate,
            onDelete: {
                guard let m = store.modes.firstIndex(where: { $0.id == mode.id }) else { return }
                store.modes[m].rows.removeAll { $0.id == row.id }
                store.markDirty()
            }
        )
    }

    private func groups(for mode: KeyMode) -> [Group] {
        var buckets: [String: [KeyRow]] = [:]
        for row in mode.rows where matches(row) {
            buckets[Self.category(of: row), default: []].append(row)
        }
        let known = Self.order.compactMap { name in
            buckets[name].map {
                Group(name: name == "Spaces" ? WorkspaceVocabulary.plural : name, rows: $0)
            }
        }
        let rest = buckets.keys.filter { !Self.order.contains($0) }.sorted().compactMap { name in
            buckets[name].map { Group(name: name, rows: $0) }
        }
        return known + rest
    }

    private static func category(of row: KeyRow) -> String {
        row.command.isEmpty ? "New" : CheatsheetModel.describe(row.command).0
    }

    private func matches(_ row: KeyRow) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return ShortcutRowView.summary(for: row.command).lowercased().contains(needle)
            || row.command.lowercased().contains(needle)
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

private struct ShortcutRowView: View {
    @Binding var row: KeyRow
    let duplicate: Bool
    let onDelete: () -> Void
    @State private var picking = false
    @State private var hovering = false

    /// What the shortcut does, in words — "space" said the way the rest of
    /// this window says it, which depends on the workspaces mode.
    static func summary(for command: String) -> String {
        guard !command.isEmpty else { return "" }
        return WorkspaceVocabulary.rephrase(CheatsheetModel.describe(command).1)
    }

    var body: some View {
        let summary = Self.summary(for: row.command)
        let isCustom = !row.command.isEmpty && CheatsheetModel.describe(row.command).1 == row.command
        HStack(spacing: 12) {
            Button {
                picking = true
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if row.command.isEmpty {
                        Text("Choose what this does…").foregroundStyle(.secondary)
                    } else if isCustom {
                        Text(row.command).font(.system(.body, design: .monospaced))
                    } else {
                        Text(summary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change what this shortcut does")
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                ActionPicker(current: row.command) { command in
                    row.command = command
                    picking = false
                }
            }

            if duplicate {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Another shortcut here uses the same keys — only one of them works.")
            }

            ChordField(chord: $row.chord)

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

/// Every action weft knows, in words, searchable — plus a way out for a
/// command the list does not have. A popover, so it is built when it opens
/// and costs nothing sitting in sixty rows.
private struct ActionPicker: View {
    let current: String
    let onPick: (String) -> Void
    @State private var query = ""
    @State private var custom = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search actions", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(CommandCatalog.groups, id: \.name) { group in
                        let hits = group.commands.filter(matches)
                        if !hits.isEmpty {
                            Text(group.name == "Spaces" ? WorkspaceVocabulary.plural : group.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(hits, id: \.self) { command in
                                ActionRow(command: command, selected: command == current) { onPick(command) }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Custom command", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(useCustom)
                Button("Use", action: useCustom)
                    .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 360, height: 440)
        .onAppear {
            if !current.isEmpty, !CommandCatalog.contains(current) { custom = current }
        }
    }

    private func useCustom() {
        let command = custom.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }
        onPick(command)
    }

    private func matches(_ command: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty
            || command.lowercased().contains(needle)
            || ShortcutRowView.summary(for: command).lowercased().contains(needle)
    }
}

private struct ActionRow: View {
    let command: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(ShortcutRowView.summary(for: command))
                    Text(command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(hovering ? 0.16 : 0))
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
private struct KeyCaps: View {
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

// MARK: - Desktops

private struct DesktopsPane: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var health: EngineHealth

    private var virtual: Bool { store.workspacesMode == "virtual" }

    /// Rows past this have no desktop to land on: names go out in Mission
    /// Control order, so it is purely a count.
    ///
    /// Under `virtual` every row lands — the host desktop takes as many
    /// workspaces as are named, and that is the entire point of the mode — so
    /// the question does not arise and every row is marked live.
    private var landing: Int {
        if virtual { return store.spaces.count }
        return health.running ? health.desktopCount : store.spaces.count
    }

    var body: some View {
        Form {
            // Native only. Under `virtual` more names than desktops is the
            // configuration working, not a mistake — and the count it used to
            // compare against was `liveSpaces.count`, which in that mode is
            // the workspace count, so the test compared a number with itself.
            if !virtual, health.running, store.spaces.count > health.desktopCount {
                Section {
                    Label(
                        "You have \(health.desktopCount) desktop(s), but \(store.spaces.count) names. Add desktops in Mission Control, remove the extra names, or switch to virtual workspaces under Workspaces.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }

            if virtual, health.running {
                Section {
                    let others = max(0, health.desktopCount - 1)
                    Label(
                        others == 0
                            ? "\(store.spaces.count) workspace(s), all on desktop \(health.anchorDesktop)."
                            : "\(store.spaces.count) workspace(s) on desktop \(health.anchorDesktop), plus one on each of your other \(others) desktop(s).",
                        systemImage: "rectangle.3.group"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                if store.spaces.isEmpty {
                    EmptyState(
                        symbol: virtual ? "rectangle.3.group" : "menubar.dock.rectangle",
                        title: virtual ? "No workspaces yet" : "No named desktops",
                        text: virtual
                            ? "Add a few and give them names. Each one is a separate set of windows you switch between instantly, all on the same macOS desktop."
                            : "Every desktop uses the default layout. Name one to give it a layout of its own, or to send apps to it."
                    )
                }
                ForEach(Array(store.spaces.enumerated()), id: \.element.id) { index, space in
                    DesktopRow(
                        number: index + 1,
                        space: binding(space.id),
                        hasDesktop: index < landing,
                        virtual: virtual,
                        canMoveUp: index > 0,
                        canMoveDown: index < store.spaces.count - 1,
                        onMove: { move(space.id, by: $0) },
                        onDelete: {
                            store.spaces.removeAll { $0.id == space.id }
                            store.markDirty()
                        }
                    )
                }
                Button {
                    store.addSpace()
                } label: {
                    Label(virtual ? "Add Workspace" : "Add Desktop", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            } footer: {
                Text(
                    virtual
                        ? "The order here is the order alt-1, alt-2 and so on count in. Shortcuts and apps can refer to a workspace by its name. Adding one costs nothing — there is no macOS desktop to create."
                        : "Names follow Mission Control order — the first name is your first desktop. Shortcuts and apps can refer to a desktop by its name."
                )
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ id: SpaceRow.ID) -> Binding<SpaceRow> {
        Binding(
            get: { store.spaces.first { $0.id == id } ?? SpaceRow() },
            set: { value in
                guard let i = store.spaces.firstIndex(where: { $0.id == id }) else { return }
                store.spaces[i] = value
                store.markDirty()
            }
        )
    }

    private func move(_ id: SpaceRow.ID, by delta: Int) {
        guard let from = store.spaces.firstIndex(where: { $0.id == id }),
              store.spaces.indices.contains(from + delta)
        else { return }
        store.spaces.swapAt(from, from + delta)
        store.markDirty()
    }
}

private struct DesktopRow: View {
    let number: Int
    @Binding var space: SpaceRow
    let hasDesktop: Bool
    let virtual: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMove: (Int) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 28, height: 28)
                .foregroundStyle(hasDesktop ? Color.white : Color.secondary)
                .weftGlass(Circle(), tint: hasDesktop ? Color.accentColor.opacity(0.8) : nil)
            TextField("Name", text: $space.label)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            if !hasDesktop, !virtual {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("There is no desktop for this name yet.")
            }
            Spacer(minLength: 8)
            Picker("", selection: $space.layout) {
                Text("Tiling").tag("bsp")
                Text("Floating").tag("float")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            HStack(spacing: 2) {
                Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(!canMoveUp)
                Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(!canMoveDown)
            }
            .buttonStyle(.borderless)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove")
        }
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
                if let s = health.spaceSwitching {
                    LabeledContent("Switching desktops") {
                        Label(
                            s.instant ? "Instant" : (s.works ? "Keystroke" : "Not available"),
                            systemImage: s.works
                                ? (s.instant ? "checkmark.circle.fill" : "checkmark.circle")
                                : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(s.works ? (s.instant ? Color.green : .secondary) : Color.orange)
                    }
                    Text(s.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if store.workspacesMode == "virtual" {
                        // The capability above is about macOS desktops, and
                        // under virtual most switching never touches one. Left
                        // alone it read as a verdict on alt-1..9, which it is
                        // not, and a red "Not available" next to shortcuts
                        // that work perfectly is the worst kind of wrong.
                        Text("This is about moving between macOS desktops. Switching between "
                            + "your workspaces does not use it — that is instant and needs nothing.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if !s.works {
                        Button("Open Keyboard Shortcuts") {
                            if let url = URL(string:
                                "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")
                            {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                } else {
                    LabeledContent("Switching desktops") {
                        Text(health.running ? "Checking…" : "Weft isn't running")
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(
                    store.workspacesMode == "virtual"
                        ? "Let a rule send a window to its workspace when it opens"
                        : "Let a rule send a window to its desktop when it opens",
                    isOn: Binding(
                        get: { store.followSpaceRules },
                        set: { store.setFollowSpaceRules($0) }
                    )
                )
            } header: {
                Text(store.workspacesMode == "virtual" ? "Desktops & rules" : "Desktops")
            } footer: {
                Text(
                    store.workspacesMode == "virtual"
                        ? "Weft never asks you to change System Integrity Protection.\n\nWith workspaces on one desktop, a rule placing a window is instant and invisible, so this is on by default — there is nothing to interrupt. It only takes the screen over for a rule naming a workspace on a *different* macOS desktop, which weft still has to switch to the old way.\n\nKeeping a window on every desktop is macOS’s own setting rather than weft’s: right-click the app in the Dock → Options → All Desktops."
                        : "Weft never asks you to change System Integrity Protection. Switching desktops is instant. Sending a window to another desktop works by holding the window and pressing your “move a space” shortcut, so the screen changes desktop and changes back — bind that shortcut under Mission Control above.\n\nThat visible movement is why the rule setting is off by default: you asked for it when you press a shortcut, but a rule fires whenever a matching app opens, which may be while you are typing somewhere else.\n\nKeeping a window on every desktop is macOS’s own setting rather than weft’s: right-click the app in the Dock → Options → All Desktops."
                )
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

private struct EmptyState: View {
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

enum CommandCatalog {
    struct Group {
        let name: String
        let commands: [String]
    }

    static let groups: [Group] = [
        Group(name: "Focus", commands: [
            "focus west", "focus east", "focus north", "focus south",
            "focus display west", "focus display east",
            "focus display next", "focus display cycle",
        ]),
        Group(name: "Move", commands: [
            "move west", "move east", "move north", "move south",
            // The literal exchange. `move` restructures and keeps the window's
            // size; `swap` trades slots, so the window takes the size of the
            // one it traded with.
            "swap west", "swap east", "swap north", "swap south",
            "move display west --follow", "move display east --follow",
            "move display next --follow", "move display cycle --follow",
        ]),
        Group(name: "Window", commands: [
            "window toggle zoom-fullscreen", "window toggle split",
            "float toggle", "balance",
            "split vertical", "split horizontal",
        ]),
        Group(name: "Stacks", commands: [
            "stack toggle", "stack next", "stack prev", "stack unstack", "stack all",
            "stack split west", "stack split east",
            "stack move west", "stack move east",
        ]),
        Group(name: "Spaces", commands: [
            "space focus 1", "space focus 2", "space focus 3", "space focus 4", "space focus 5",
            "space focus recent",
            "space move-window 1", "space move-window 2", "space move-window 3",
            // The screen changes desktop either way, so the plain form follows
            // the window; this is for a bind that means to stay put.
            "space move-window 1 --no-follow", "space move-window 2 --no-follow",
            "space layout bsp", "space layout float", "space layout toggle",
        ]),
        Group(name: "Resize", commands: [
            "resize left 40", "resize right 40", "resize up 40", "resize down 40",
            "resize left 120", "resize right 120", "resize up 120", "resize down 120",
        ]),
        Group(name: "Modes", commands: ["mode default", "mode resize"]),
        // Starting points, not a menu: the argument is a shell command, so
        // these are meant to be picked and then edited.
        Group(name: "Run a command", commands: [
            "exec open -a Terminal",
            "exec open ~/Downloads",
            "exec pmset displaysleepnow",
            "exec screencapture -i -c",
        ]),
    ]

    static func contains(_ command: String) -> Bool {
        groups.contains { $0.commands.contains(command) }
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
    /// Labels of the desktops that exist right now.
    ///
    /// Under `workspaces = "virtual"` this is one entry per *workspace*, not
    /// per desktop — `query spaces` reports the model weft runs, not macOS's.
    /// Anything that needs the desktop count wants `desktopCount`.
    @Published var liveSpaces: [String] = []
    /// The mode the daemon is actually running, which is not always what the
    /// file says: a mode change is applied by a reload that may not have
    /// landed. Nil until the daemon has answered once, or when it is too old
    /// to know the question.
    @Published var workspacesMode: String?
    /// The desktop actually hosting virtual workspaces — already clamped, so
    /// it always names a desktop that exists.
    @Published var anchorDesktop = 1
    /// Live native desktops, i.e. what Mission Control shows. Equal to
    /// `liveSpaces.count` under `native` and smaller under `virtual`.
    @Published var desktopCount = 1
    /// Whether `space focus` has any way at all to change desktop, and what
    /// it would use. Nil until the daemon has answered once.
    @Published var spaceSwitching: SpaceSwitching?
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
    struct SpaceSwitching: Equatable {
        var works: Bool
        var instant: Bool
        var detail: String
    }

    func refresh() {
        Task.detached(priority: .utility) {
            struct Capability: Decodable {
                var focusSpaceKeystroke: Bool
                var focusSpaceKeystrokeNote: String
                var moveWindowToSpace: Bool
            }
            let switching: SpaceSwitching? = {
                guard let json = BarIPC.send("query capability"),
                      let data = json.data(using: .utf8),
                      let cap = try? JSONDecoder().decode(Capability.self, from: data)
                else { return nil }
                // Instant no longer means weft-sa: the Dock swipe is instant
                // too, and needs nothing installed. The daemon's note leads
                // with "instant" for either; `moveWindowToSpace` says which.
                let instant = cap.focusSpaceKeystroke
                    && cap.focusSpaceKeystrokeNote.hasPrefix("instant")
                return SpaceSwitching(
                    works: cap.focusSpaceKeystroke,
                    instant: instant,
                    detail: !instant
                        ? cap.focusSpaceKeystrokeNote
                        : cap.moveWindowToSpace
                            ? "Instant, through weft-sa."
                            : "Instant, through weft's Dock swipe. Nothing to install."
                )
            }()
            let perms: DaemonPermissions? = {
                guard let json = BarIPC.send("query permissions"),
                      let data = json.data(using: .utf8)
                else { return nil }
                return try? JSONDecoder().decode(DaemonPermissions.self, from: data)
            }()
            let spaces: [String] = {
                guard let json = BarIPC.send("query spaces"),
                      let data = json.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode([SpaceStatus].self, from: data)
                else { return [] }
                return decoded.map(\.label)
            }()
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
                self.workspacesMode = workspaces?.mode
                self.anchorDesktop = workspaces?.anchor ?? 1
                // Falling back to the space count keeps every "how many
                // desktops" reader right against a daemon too old to answer —
                // which is exactly the daemon that is also always in native
                // mode, where the two numbers are the same.
                self.desktopCount = workspaces?.desktops ?? spaces.count
                self.spaceSwitching = switching
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

    func show() {
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
                rootView: SettingsView(store: store, health: health, section: Self.launchSection)
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
