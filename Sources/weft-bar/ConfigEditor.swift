import AppKit
import Foundation
import WeftPlatform
import WeftBarConfig
import SwiftUI
import WeftConfig

// Settings: a full weft.toml editor that never requires hand-editing TOML.
//
// The previous version was hand-laid-out AppKit — absolute frames, a segmented
// control, and four raw text areas. It worked, and it looked like a debug
// panel: nothing lined up under resize, gaps were four unlabelled number
// fields with no idea what they did to the screen, and "Window Rules" was a
// blob of TOML you had to already understand to change.
//
// This is the same job in SwiftUI: a sidebar, grouped forms, real controls per
// concept, a live picture of what the gap numbers do, and a keybinding table
// that records a chord instead of asking you to spell one. The raw text is
// still one click away in Advanced, because the file is the source of truth
// and hiding it would be a lie.

// MARK: - Sections

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, spaces, rules, keys, integrations, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .spaces: return "Spaces"
        case .rules: return "Window Rules"
        case .keys: return "Keybindings"
        case .integrations: return "Integrations"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .spaces: return "square.grid.2x2"
        case .rules: return "line.3.horizontal.decrease.circle"
        case .keys: return "keyboard"
        case .integrations: return "puzzlepiece.extension"
        case .advanced: return "curlybraces"
        }
    }

    var blurb: String {
        switch self {
        case .general: return "Gaps, default layout and how the mouse behaves."
        case .spaces: return "Name your spaces and pick a layout for each."
        case .rules: return "Send apps to a space, or leave them alone entirely."
        case .keys: return "Every chord weft listens for, and what it runs."
        case .integrations: return "JankyBorders and Sketchybar."
        case .advanced: return "The file itself, exactly as it will be written."
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var health: EngineHealth
    @State private var tab: SettingsTab

    init(store: ConfigStore, health: EngineHealth, tab: SettingsTab = .general) {
        self.store = store
        self.health = health
        _tab = State(initialValue: tab)
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(tab: $tab, health: health)
                .frame(width: 218)

            Divider()

            VStack(spacing: 0) {
                DetailHeader(tab: tab)
                Divider().opacity(0.6)

                ScrollView {
                    Group {
                        switch tab {
                        case .general: GeneralTab(store: store)
                        case .spaces: SpacesTab(store: store, health: health)
                        case .rules: RulesTab(store: store, health: health)
                        case .keys: KeysTab(store: store)
                        case .integrations: IntegrationsTab(store: store, health: health)
                        case .advanced: AdvancedTab(store: store)
                        }
                    }
                    .frame(maxWidth: 780, alignment: .leading)
                    .padding(.leading, 26)
                    .padding(.trailing, 32)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.35))

                Divider().opacity(0.6)
                ActionBar(store: store, health: health)
            }
        }
        .frame(minWidth: 880, minHeight: 620)
        .tint(.weft)
        .onAppear { health.start() }
        .onDisappear { health.stop() }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Binding var tab: SettingsTab
    @ObservedObject var health: EngineHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(colors: [.weft, .weftDeep],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 26, height: 26)
                    .overlay(
                        Image(systemName: "square.split.bottomrightquarter")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 0) {
                    Text("Weft").font(.system(size: 14, weight: .semibold))
                    Text("Settings").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 26)
            .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { item in
                    SidebarRow(item: item, selected: tab == item) { tab = item }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            EngineCard(health: health)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SidebarMaterial())
    }
}

private struct SidebarRow: View {
    let item: SettingsTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12.5))
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        selected
                            ? AnyShapeStyle(LinearGradient(
                                colors: [.weft, .weftDeep],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            : AnyShapeStyle(Color.primary.opacity(hovering ? 0.07 : 0))
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The real sidebar vibrancy. SwiftUI's `.ultraThinMaterial` sits on top of the
/// window background rather than behind it, so a settings sidebar built with it
/// reads grey next to every other macOS sidebar on screen.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct EngineCard: View {
    @ObservedObject var health: EngineHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(health.tint)
                    .frame(width: 7, height: 7)
                Text(health.headline)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer(minLength: 0)
            }
            Text(health.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if health.needsPermissions {
                Button("Open Setup…") {
                    OnboardingWindowController.shared.show()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

private struct DetailHeader: View {
    let tab: SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tab.title).font(.system(size: 17, weight: .semibold))
            Text(tab.blurb).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }
}

// MARK: - Action bar

private struct ActionBar: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var health: EngineHealth

    var body: some View {
        HStack(spacing: 12) {
            StatusPill(status: store.status, dirty: store.isDirty)
            Spacer(minLength: 12)

            Button("Revert") { store.load() }
                .disabled(!store.isDirty)

            Button {
                health.restart()
            } label: {
                HStack(spacing: 6) {
                    if health.isRestarting { ProgressView().controlSize(.small) }
                    Text("Restart engine")
                }
            }
            .disabled(health.isRestarting)
            .help("Config reloads on its own — this is only for a wedged daemon")

            Button("Save") { store.save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!store.isDirty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct StatusPill: View {
    let status: ConfigStore.Status
    let dirty: Bool

    private var symbol: String {
        if dirty { return "pencil.circle.fill" }
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .problem: return "exclamationmark.triangle.fill"
        case .idle: return "info.circle"
        }
    }

    private var tint: Color {
        if dirty { return .weft }
        switch status {
        case .ok: return .green
        case .problem: return .orange
        case .idle: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(dirty ? "Unsaved changes" : status.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(tint)
    }
}

// MARK: - Shared building blocks

private struct Card<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 11)

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

/// Label on the left at a fixed width, control on the right — the one thing the
/// old absolute-frame layout got right, kept.
private struct Row<Content: View>: View {
    let label: String
    var help: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(label).font(.system(size: 12))
            }
            .frame(width: 150, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                content
                if let help {
                    Text(help).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PixelField: View {
    let label: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...400
    let onChange: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                TextField("", value: $value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $value, in: range)
                    .labelsHidden()
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .onChange(of: value) { _, _ in onChange() }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        VStack(spacing: 16) {
            Card(title: "Gaps", subtitle: "Space between tiled windows, and around the edge of the screen.") {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        Row(label: "Inner gap", help: "Between neighbouring windows.") {
                            HStack(spacing: 0) {
                                TextField("", value: $store.innerGap, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 58)
                                    .multilineTextAlignment(.trailing)
                                Stepper("", value: $store.innerGap, in: 0...200).labelsHidden()
                            }
                            .onChange(of: store.innerGap) { _, _ in store.markDirty() }
                        }

                        Row(label: "Outer gap") {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Same on all sides", isOn: $store.linkOuterGaps)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 11.5))
                                    .onChange(of: store.linkOuterGaps) { _, linked in
                                        if linked { spreadOuter(store.outerTop) }
                                        store.markDirty()
                                    }

                                if store.linkOuterGaps {
                                    HStack(spacing: 0) {
                                        TextField("", value: Binding(
                                            get: { store.outerTop },
                                            set: { spreadOuter($0); store.markDirty() }
                                        ), format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 58)
                                        .multilineTextAlignment(.trailing)
                                        Stepper("", value: Binding(
                                            get: { store.outerTop },
                                            set: { spreadOuter($0); store.markDirty() }
                                        ), in: 0...400).labelsHidden()
                                    }
                                } else {
                                    HStack(spacing: 12) {
                                        PixelField(label: "Top", value: $store.outerTop) { store.markDirty() }
                                        PixelField(label: "Bottom", value: $store.outerBottom) { store.markDirty() }
                                        PixelField(label: "Left", value: $store.outerLeft) { store.markDirty() }
                                        PixelField(label: "Right", value: $store.outerRight) { store.markDirty() }
                                    }
                                }
                            }
                        }
                    }

                    VStack(spacing: 6) {
                        LayoutPreview(
                            inner: store.innerGap,
                            outer: (store.outerTop, store.outerBottom, store.outerLeft, store.outerRight),
                            reserve: (store.reserveTop, store.reserveBottom, store.reserveLeft, store.reserveRight),
                            layout: store.defaultLayout
                        )
                        .frame(width: 236, height: 150)
                        Text(store.reserveTop > 0
                             ? "Preview · orange band is the reserved strip"
                             : "Preview · not to scale")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Card(title: "Screen reserve", subtitle: "Room kept clear for a bar or dock that is always on screen.") {
                HStack(spacing: 12) {
                    PixelField(label: "Top", value: $store.reserveTop) { store.markDirty() }
                    PixelField(label: "Bottom", value: $store.reserveBottom) { store.markDirty() }
                    PixelField(label: "Left", value: $store.reserveLeft) { store.markDirty() }
                    PixelField(label: "Right", value: $store.reserveRight) { store.markDirty() }
                    Spacer()
                }
            }

            Card(title: "Layout") {
                Row(label: "Default layout", help: "Used by any space that does not name one of its own.") {
                    Picker("", selection: $store.defaultLayout) {
                        Text("BSP — binary split").tag("bsp")
                        Text("Scroll — columns").tag("scroll")
                        Text("Float — untiled").tag("float")
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .onChange(of: store.defaultLayout) { _, _ in store.markDirty() }
                }
            }

            Card(title: "Mouse") {
                Row(label: "Modifier", help: "Held down to drag a window, or to resize from its edge.") {
                    Picker("", selection: $store.mouseModifier) {
                        Text("⌥ Option").tag("alt")
                        Text("⌘ Command").tag("cmd")
                        Text("⌃ Control").tag("ctrl")
                        Text("⇧ Shift").tag("shift")
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .onChange(of: store.mouseModifier) { _, _ in store.markDirty() }
                }

                Row(label: "Cursor") {
                    VStack(alignment: .leading, spacing: 7) {
                        Toggle("Warp the cursor to a window when it takes focus", isOn: $store.mouseFollowsFocus)
                            .onChange(of: store.mouseFollowsFocus) { _, _ in store.markDirty() }
                        Toggle("Focus whatever window the cursor is over", isOn: $store.focusFollowsMouse)
                            .onChange(of: store.focusFollowsMouse) { _, _ in store.markDirty() }
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                }
            }
        }
    }

    private func spreadOuter(_ value: Int) {
        store.outerTop = value
        store.outerBottom = value
        store.outerLeft = value
        store.outerRight = value
    }
}

/// What the four gap numbers actually do, at a glance.
///
/// Gaps are the one setting nobody can predict from a number: "outer-gap 8,
/// reserve top 32" is two abstractions away from the thing it changes. Drawing
/// it costs a hundred lines and removes an entire save-look-adjust loop.
private struct LayoutPreview: View {
    let inner: Int
    let outer: (top: Int, bottom: Int, left: Int, right: Int)
    let reserve: (top: Int, bottom: Int, left: Int, right: Int)
    let layout: String

    var body: some View {
        GeometryReader { geo in
            // Scaled against a nominal 820-point-wide screen. A real 1440-wide
            // display would put an 8px gap at barely one point here, which is
            // honest and completely unreadable — the drawing exists to answer
            // "is that bigger or smaller than I wanted", so it is drawn at
            // roughly half a screen's width and gaps read at a glance.
            let scale = geo.size.width / 820
            let top = CGFloat(outer.top + reserve.top) * scale
            let bottom = CGFloat(outer.bottom + reserve.bottom) * scale
            let left = CGFloat(outer.left + reserve.left) * scale
            let right = CGFloat(outer.right + reserve.right) * scale
            let gap = max(0.5, CGFloat(inner) * scale)
            let usable = CGRect(
                x: left, y: top,
                width: max(6, geo.size.width - left - right),
                height: max(6, geo.size.height - top - bottom)
            )

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))

                if CGFloat(reserve.top) * scale > 0.5 {
                    Rectangle()
                        .fill(Color.orange.opacity(0.22))
                        .frame(width: geo.size.width, height: CGFloat(reserve.top) * scale)
                }

                ForEach(Array(tiles(in: usable, gap: gap).enumerated()), id: \.offset) { i, rect in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(i == 0 ? Color.weft.opacity(0.75) : Color.weft.opacity(0.32))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
    }

    /// Three windows, arranged the way the chosen layout would arrange them.
    private func tiles(in area: CGRect, gap: CGFloat) -> [CGRect] {
        switch layout {
        case "float":
            return [
                CGRect(x: area.minX + area.width * 0.06, y: area.minY + area.height * 0.10,
                       width: area.width * 0.54, height: area.height * 0.60),
                CGRect(x: area.minX + area.width * 0.34, y: area.minY + area.height * 0.34,
                       width: area.width * 0.56, height: area.height * 0.56),
            ]
        case "scroll":
            let columns = 3
            let w = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            return (0..<columns).map { i in
                CGRect(x: area.minX + (w + gap) * CGFloat(i), y: area.minY,
                       width: w, height: area.height)
            }
        default:
            let halfW = (area.width - gap) / 2
            let halfH = (area.height - gap) / 2
            return [
                CGRect(x: area.minX, y: area.minY, width: halfW, height: area.height),
                CGRect(x: area.minX + halfW + gap, y: area.minY, width: halfW, height: halfH),
                CGRect(x: area.minX + halfW + gap, y: area.minY + halfH + gap,
                       width: halfW, height: halfH),
            ]
        }
    }
}

// MARK: - Spaces

private struct SpacesTab: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var health: EngineHealth

    /// Rows past this index have no desktop to be assigned to. Labels go out
    /// in Mission Control order, so it is purely a count question.
    private var landing: Int { health.running ? health.liveSpaces.count : store.spaces.count }

    var body: some View {
        VStack(spacing: 16) {
            if health.running && store.spaces.count > health.liveSpaces.count {
                Notice(
                    tone: .warning,
                    title: "\(store.spaces.count) spaces declared, \(health.liveSpaces.count) desktop(s) on this Mac",
                    detail: "Labels are handed out in Mission Control order, so the greyed rows below have nowhere to land. Keybinds and rules naming them do nothing at all — silently. Add desktops in Mission Control, or remove the extra rows."
                )
            }

            Card(
                title: "Spaces",
                subtitle: "Listed in order. Keybinds refer to a space by its label, so renaming one means renaming it in Keybindings too."
            ) {
                if store.spaces.isEmpty {
                    EmptyHint(
                        symbol: "square.grid.2x2",
                        text: "No spaces configured. Weft tiles every desktop with the default layout until you add some."
                    )
                } else {
                    VStack(spacing: 7) {
                        ForEach(Array($store.spaces.enumerated()), id: \.element.id) { index, $space in
                            SpaceEditorRow(space: $space, store: store, hasDesktop: index < landing)
                        }
                    }
                }

                Button {
                    store.addSpace()
                } label: {
                    Label("Add space", systemImage: "plus")
                }
                .controlSize(.small)
            }
        }
    }
}

private struct SpaceEditorRow: View {
    @Binding var space: SpaceRow
    @ObservedObject var store: ConfigStore
    var hasDesktop = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: LayoutGlyph.symbol(space.layout))
                .font(.system(size: 12))
                .foregroundStyle(hasDesktop ? Color.weft : Color.secondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hasDesktop ? Color.weft.opacity(0.13) : Color.primary.opacity(0.06)))

            TextField("label", text: $space.label)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .onChange(of: space.label) { _, _ in store.markDirty() }

            Picker("", selection: $space.layout) {
                Text("BSP").tag("bsp")
                Text("Scroll").tag("scroll")
                Text("Float").tag("float")
            }
            .labelsHidden()
            .frame(width: 110)
            .onChange(of: space.layout) { _, _ in store.markDirty() }

            if !hasDesktop {
                Label("no desktop", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .help("No desktop for this row. Add one in Mission Control, or remove the row.")
            }

            Spacer(minLength: 0)

            OrderButtons(
                onUp: { move(-1) }, onDown: { move(1) },
                canUp: index > 0, canDown: index < store.spaces.count - 1
            )

            DeleteButton { 
                store.spaces.removeAll { $0.id == space.id }
                store.markDirty()
            }
        }
    }

    private var index: Int { store.spaces.firstIndex { $0.id == space.id } ?? 0 }

    private func move(_ delta: Int) {
        let from = index
        let to = from + delta
        guard store.spaces.indices.contains(to) else { return }
        store.spaces.swapAt(from, to)
        store.markDirty()
    }
}

enum LayoutGlyph {
    static func symbol(_ layout: String) -> String {
        switch layout {
        case "scroll": return "rectangle.split.3x1"
        case "float": return "macwindow.on.rectangle"
        default: return "rectangle.split.2x2"
        }
    }
}

private struct OrderButtons: View {
    let onUp: () -> Void
    let onDown: () -> Void
    let canUp: Bool
    let canDown: Bool

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onUp) { Image(systemName: "chevron.up") }
                .disabled(!canUp)
            Button(action: onDown) { Image(systemName: "chevron.down") }
                .disabled(!canDown)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
    }
}

private struct DeleteButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Remove")
    }
}

/// A banner for the case where the config is valid TOML and still will not do
/// what it says. Those are the ones worth a whole box.
private struct Notice: View {
    enum Tone { case warning, info }

    let tone: Tone
    let title: String
    let detail: String

    private var color: Color { tone == .warning ? .orange : .weft }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(color.opacity(0.28))
        )
    }
}

private struct EmptyHint: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }
}

// MARK: - Rules

private struct RulesTab: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var health: EngineHealth

    var body: some View {
        VStack(spacing: 16) {
            Card(
                title: "Window rules",
                subtitle: "Checked top to bottom; the first rule that matches wins. App and Title are regular expressions — “Brave|Zen” matches either."
            ) {
                if store.rules.isEmpty {
                    EmptyHint(symbol: "line.3.horizontal.decrease.circle",
                              text: "No rules. Every window is tiled on whatever space it opens on.")
                } else {
                    // One header, not a caption above all four fields of all
                    // twenty rows: the labels repeated per row turned a table
                    // into a wall.
                    HStack(spacing: 8) {
                        ColumnLabel("App", width: 168)
                        ColumnLabel("Title", width: 130)
                        ColumnLabel("Send to space", width: 132)
                        ColumnLabel("Tiling", width: 116)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 10)

                    VStack(spacing: 5) {
                        ForEach($store.rules) { $rule in
                            RuleRowView(rule: $rule, store: store, live: liveLabels)
                        }
                    }
                }

                Button { store.addRule() } label: { Label("Add rule", systemImage: "plus") }
                    .controlSize(.small)
            }
        }
    }

    /// Nil when the daemon is not up: with nothing to check against, marking
    /// every target "missing" would be a lie, not a warning.
    private var liveLabels: Set<String>? {
        health.running ? Set(health.liveSpaces) : nil
    }
}

private struct RuleRowView: View {
    @Binding var rule: RuleRow
    @ObservedObject var store: ConfigStore
    /// Labels that exist on this machine right now, or nil if unknown.
    var live: Set<String>?

    /// A target that is spelled correctly, declared in the config, and still
    /// has no desktop behind it. weftd logs one line and moves the window
    /// nowhere, which is the hardest kind of "broken" to notice.
    private var targetIsUnreachable: Bool {
        guard !rule.space.isEmpty, let live else { return false }
        return !live.contains(rule.space)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField("Ghostty|kitty", text: $rule.app)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 168)
                    .onChange(of: rule.app) { _, _ in store.markDirty() }

                TextField("any", text: $rule.title)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .onChange(of: rule.title) { _, _ in store.markDirty() }

                Picker("", selection: Binding(
                    get: { rule.space },
                    set: { rule.space = $0; store.markDirty() }
                )) {
                    Text("— stay put —").tag("")
                    ForEach(store.spaceLabels, id: \.self) { Text($0).tag($0) }
                    if !rule.space.isEmpty && !store.spaceLabels.contains(rule.space) {
                        Text("\(rule.space) — not in Spaces").tag(rule.space)
                    }
                }
                .labelsHidden()
                .frame(width: 132)

                if targetIsUnreachable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help("No desktop is labelled “\(rule.space)”, so this rule moves nothing.")
                }

                Picker("", selection: Binding(
                    get: { rule.manage ?? true },
                    set: { rule.manage = $0 ? nil : false; store.markDirty() }
                )) {
                    Text("Manage").tag(true)
                    Text("Leave alone").tag(false)
                }
                .labelsHidden()
                .frame(width: 116)

                Spacer(minLength: 0)

                DeleteButton {
                    store.rules.removeAll { $0.id == rule.id }
                    store.markDirty()
                }
            }

            if !rule.isValid {
                Label("Give this rule an app or a title to match — weftd rejects a rule that matches nothing.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rule.isValid && !targetIsUnreachable ? Color.clear : Color.orange.opacity(0.07))
        )
    }
}

private struct ColumnLabel: View {
    let text: String
    let width: CGFloat

    init(_ text: String, width: CGFloat) {
        self.text = text
        self.width = width
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }
}

private struct LabeledField: View {
    let label: String
    @Binding var text: String
    var width: CGFloat = 140
    var placeholder: String = ""
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .onChange(of: text) { _, _ in onChange() }
        }
    }
}

// MARK: - Keybindings

private struct KeysTab: View {
    @ObservedObject var store: ConfigStore
    @State private var newMode = ""
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 16) {
            // Sixty binds is a normal weft.toml, and finding the one you meant
            // to change by scrolling is the reason people give up and open the
            // file instead.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Filter by chord or command", text: $filter)
                    .textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            ForEach($store.modes) { $mode in
                let shown = matches(mode)
                if !shown.isEmpty || filter.isEmpty {
                Card(
                    title: mode.isDefault ? "Default bindings" : "Mode: \(mode.name)",
                    subtitle: mode.isDefault
                        ? "Always live. Bind “mode <name>” to enter one of the layers below."
                        : "Only live after entering this mode. Bind “mode default” to get back out."
                ) {
                    if mode.rows.isEmpty {
                        EmptyHint(symbol: "keyboard", text: "No bindings in this mode yet.")
                    } else if shown.isEmpty {
                        EmptyHint(symbol: "magnifyingglass", text: "Nothing in this mode matches “\(filter)”.")
                    }
                    VStack(spacing: 6) {
                        ForEach($mode.rows) { $row in
                            if shown.contains(row.id) {
                                KeyRowView(
                                    row: $row, store: store, mode: $mode,
                                    duplicate: duplicates(mode).contains(row.chord.lowercased())
                                )
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Button { store.addKey(to: mode.id) } label: {
                            Label("Add binding", systemImage: "plus")
                        }
                        if !mode.isDefault {
                            Button(role: .destructive) { store.removeMode(mode.id) } label: {
                                Label("Delete mode", systemImage: "trash")
                            }
                        }
                        Spacer()
                        Text("\(mode.rows.count) binding\(mode.rows.count == 1 ? "" : "s")")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    .controlSize(.small)
                }
                }
            }

            Card(title: "New mode", subtitle: "A modal layer — like vim's, but for window management.") {
                HStack(spacing: 10) {
                    TextField("resize", text: $newMode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Button("Add mode") {
                        store.addMode(named: newMode)
                        newMode = ""
                    }
                    .disabled(newMode.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                }
                .controlSize(.small)
            }
        }
    }

    private func matches(_ mode: KeyMode) -> Set<KeyRow.ID> {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return Set(mode.rows.map(\.id)) }
        return Set(mode.rows.filter {
            $0.chord.lowercased().contains(needle) || $0.command.lowercased().contains(needle)
        }.map(\.id))
    }

    /// Two rows on the same chord is a silent bug: the file is a TOML table,
    /// so the second one wins and the first simply never fires.
    private func duplicates(_ mode: KeyMode) -> Set<String> {
        var seen: Set<String> = []
        var dupes: Set<String> = []
        for row in mode.rows where !row.chord.isEmpty {
            let key = row.chord.lowercased()
            if !seen.insert(key).inserted { dupes.insert(key) }
        }
        return dupes
    }
}

private struct KeyRowView: View {
    @Binding var row: KeyRow
    @ObservedObject var store: ConfigStore
    @Binding var mode: KeyMode
    var duplicate = false

    var body: some View {
        HStack(spacing: 8) {
            ChordField(chord: $row.chord) { store.markDirty() }

            if duplicate {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Another binding in this mode uses the same chord — only the last one fires.")
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)

            TextField("focus west", text: $row.command)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
                .onChange(of: row.command) { _, _ in store.markDirty() }

            Menu {
                ForEach(CommandCatalog.groups, id: \.name) { group in
                    Menu(group.name) {
                        ForEach(group.commands, id: \.self) { command in
                            Button(command) {
                                row.command = command
                                store.markDirty()
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("Pick from the commands weftd understands")

            DeleteButton {
                mode.rows.removeAll { $0.id == row.id }
                store.markDirty()
            }
        }
    }
}

/// Type a chord, or press one. The recorder is the point: weft's chord syntax
/// is hardware keycodes spelled out in words (`alt-bracketleft`), which nobody
/// guesses correctly for a bracket, a backslash or an arrow key.
private struct ChordField: View {
    @Binding var chord: String
    let onChange: () -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            TextField("alt-h", text: $chord)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(width: 150)
                .onChange(of: chord) { _, _ in onChange() }

            Button {
                recording ? stop() : start()
            } label: {
                Image(systemName: recording ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(recording ? Color.red : Color.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.leading, 4)
            .help(recording ? "Press a chord, or click again to cancel" : "Record a chord")
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        // A local monitor, not a tap: this only has to see keys while the
        // Settings window is key, and a tap would need the very permission the
        // user may be here to work around.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let name = ChordNaming.name(forKeyCode: Int(event.keyCode)) else { return nil }
            chord = ChordNaming.modifierPrefix(event.modifierFlags) + name
            onChange()
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
            "focus display west", "focus display east", "focus display next",
        ]),
        Group(name: "Move", commands: [
            "move west", "move east", "move north", "move south",
            "move display west --follow", "move display east --follow",
            "move display next --follow",
        ]),
        Group(name: "Window", commands: [
            "window toggle zoom-fullscreen", "window toggle split",
            "float toggle", "balance",
            "split vertical", "split horizontal",
        ]),
        Group(name: "Stack", commands: [
            "stack wrap", "stack next", "stack prev", "stack unstack",
        ]),
        Group(name: "Scroll layout", commands: [
            "scroll focus next-column", "scroll focus prev-column", "scroll width cycle",
        ]),
        Group(name: "Spaces", commands: [
            "space focus recent", "space layout bsp", "space layout scroll", "space layout float",
        ]),
        Group(name: "Resize", commands: [
            "resize left 40", "resize right 40", "resize up 40", "resize down 40",
        ]),
        Group(name: "Modes", commands: ["mode default", "mode resize"]),
    ]
}

// MARK: - Integrations

private struct IntegrationsTab: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var health: EngineHealth

    var body: some View {
        VStack(spacing: 16) {
            Card(title: "JankyBorders", subtitle: "Draws the highlight around the focused window.") {
                HStack(spacing: 10) {
                    Toggle("Enable borders", isOn: $store.bordersEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: store.bordersEnabled) { _, _ in store.markDirty() }
                    Spacer()
                    InstallState(path: health.bordersPath, binary: "borders")
                }

                // Switching this on without the binary is a no-op that logs one
                // line to a file nobody reads. Say so here instead.
                if store.bordersEnabled, health.bordersPath == nil {
                    MissingBinary(
                        name: "borders",
                        install: "brew install FelixKratz/formulae/borders",
                        setting: "borders"
                    )
                }

                if store.bordersEnabled, health.bordersPath != nil {
                    Row(label: "Supervise", help: "weftd starts borders and restarts it if it dies.") {
                        Toggle("Keep borders running", isOn: $store.bordersSupervise)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                            .onChange(of: store.bordersSupervise) { _, _ in store.markDirty() }
                    }
                    Row(
                        label: "Arguments",
                        help: store.bordersArgsLocked
                            ? "This list is wrapped across several lines in weft.toml. Edit it there — this window leaves it alone."
                            : "Passed straight to the borders binary, space separated."
                    ) {
                        TextField("width=5.0 style=round", text: $store.bordersArgs)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(maxWidth: 420)
                            .disabled(store.bordersArgsLocked)
                            .onChange(of: store.bordersArgs) { _, _ in store.markDirty() }
                    }
                    Label(
                        "Colour tables — active-color and mode-color — stay in Advanced; this window leaves them untouched.",
                        systemImage: "paintpalette"
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                }
            }

            Card(title: "Sketchybar", subtitle: "Fires a weft_event trigger whenever the layout or focus changes.") {
                HStack(spacing: 10) {
                    Toggle("Enable sketchybar events", isOn: $store.sketchybarEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: store.sketchybarEnabled) { _, _ in store.markDirty() }
                    Spacer()
                    InstallState(path: health.sketchybarPath, binary: "sketchybar")
                }

                if store.sketchybarEnabled, health.sketchybarPath == nil {
                    MissingBinary(
                        name: "sketchybar",
                        install: "brew install FelixKratz/formulae/sketchybar",
                        setting: "sketchybar"
                    )
                }

                if store.sketchybarEnabled, health.sketchybarPath != nil {
                    Row(label: "Bar binary") {
                        TextField("sketchybar", text: $store.sketchybarBarName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .onChange(of: store.sketchybarBarName) { _, _ in store.markDirty() }
                    }
                    Row(label: "Coalesce", help: "Events closer together than this are collapsed into one.") {
                        HStack(spacing: 6) {
                            TextField("", value: $store.sketchybarCoalesceMs, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 62)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: store.sketchybarCoalesceMs) { _, _ in store.markDirty() }
                            Text("ms").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Where the binary is, or that it is not there. Shown whether or not the
/// integration is switched on: "installed but disabled" is useful too.
private struct InstallState: View {
    let path: String?
    let binary: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: path == nil ? "xmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 10))
            Text(path.map { "found at \($0)" } ?? "\(binary) not installed")
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(path == nil ? Color.orange : Color.green)
        .help(path ?? "Searched the usual prefixes and PATH.")
    }
}

private struct MissingBinary: View {
    let name: String
    let install: String
    let setting: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This is on, but \(name) is not installed — weft will do nothing for it.")
                .font(.system(size: 11.5, weight: .medium))
            HStack(spacing: 8) {
                Text(install)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(install, forType: .string)
                }
                .controlSize(.small)
                Spacer()
            }
            Text("Or switch it off above — nothing else in weft depends on it.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28))
        )
    }
}

// MARK: - Advanced

private struct AdvancedTab: View {
    @ObservedObject var store: ConfigStore
    @State private var preview = ""

    var body: some View {
        VStack(spacing: 16) {
            Card(title: "The file", subtitle: ConfigStore.configPath) {
                HStack(spacing: 10) {
                    Button("Open in your editor") { store.openExternally() }
                    Button("Reveal in Finder") { store.revealInFinder() }
                    Button("Reload from disk") { store.load(); preview = store.previewText() }
                    Spacer()
                }
                .controlSize(.small)

                Text("Weft watches this file and reloads it within 100 ms of a write — an external edit lands without restarting anything. Reload here to pull those changes into this window.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = store.validationError {
                Card(title: "Validation") {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                }
            }

            Card(
                title: "Preview",
                subtitle: "Exactly what Save would write. Comments and any key this window does not know about are carried through untouched."
            ) {
                ScrollView([.horizontal, .vertical]) {
                    Text(preview.isEmpty ? "—" : preview)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 330)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09))
                )
            }
        }
        .onAppear { preview = store.previewText() }
        .onChange(of: store.isDirty) { _, _ in preview = store.previewText() }
    }
}

// MARK: - Engine health

/// The daemon's state, for the sidebar card. Polled slowly: this is context,
/// not a control, and a settings window has no business hammering the socket.
@MainActor
final class EngineHealth: ObservableObject {
    @Published var running = false
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var isRestarting = false
    /// Labels of the desktops that actually exist right now. `[[space]]` names
    /// are handed out in Mission Control order, so a config with more entries
    /// than the machine has desktops leaves the extras with nowhere to land —
    /// and every keybind and rule naming one of them fails silently.
    @Published var liveSpaces: [String] = []

    /// Resolved once: a helper does not get installed while the window is open,
    /// and `which` on every poll is a process spawn for nothing.
    let bordersPath = ExternalBinary.find("borders")
    let sketchybarPath = ExternalBinary.find("sketchybar")

    private var timer: Timer?

    var needsPermissions: Bool { running && !(accessibility && inputMonitoring) }

    var tint: Color {
        if !running { return .orange }
        return needsPermissions ? .yellow : .green
    }

    var headline: String {
        if !running { return "Engine not running" }
        return needsPermissions ? "Missing permissions" : "Engine running"
    }

    var detail: String {
        if !running { return "Start it with weftctl service start." }
        if needsPermissions {
            var missing: [String] = []
            if !accessibility { missing.append("Accessibility") }
            if !inputMonitoring { missing.append("Input Monitoring") }
            return missing.joined(separator: " and ") + " is not granted to weftd."
        }
        return "Config changes apply within 100 ms."
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        Task.detached(priority: .utility) {
            let perms: DaemonPermissions? = {
                guard let json = BarIPC.send("query permissions"),
                      let data = json.data(using: .utf8)
                else { return nil }
                return try? JSONDecoder().decode(DaemonPermissions.self, from: data)
            }()
            struct LiveSpace: Decodable { var label: String }
            let spaces: [String] = {
                guard let json = BarIPC.send("query spaces"),
                      let data = json.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode([LiveSpace].self, from: data)
                else { return [] }
                return decoded.map(\.label)
            }()
            await MainActor.run {
                self.running = perms != nil
                self.accessibility = perms?.accessibility ?? false
                self.inputMonitoring = perms?.inputMonitoring ?? false
                self.liveSpaces = spaces
            }
        }
    }

    func restart() {
        isRestarting = true
        Task.detached(priority: .userInitiated) {
            ConfigEditorWindowController.restartWeftCtl()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                self.isRestarting = false
                self.refresh()
            }
        }
    }
}

// MARK: - Window

@MainActor
final class ConfigEditorWindowController: NSWindowController {
    static let shared = ConfigEditorWindowController()

    private let store = ConfigStore()
    private let health = EngineHealth()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Weft Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WeftSettings")
        super.init(window: window)

        let tab = SettingsTab(rawValue: Self.launchTab) ?? .general
        window.contentView = NSHostingView(
            rootView: SettingsView(store: store, health: health, tab: tab)
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    static func configPath() -> String { ConfigStore.configPath }

    /// `--tab spaces` on the command line, for `open -a WeftBar --args
    /// --settings --tab keys`.
    private static var launchTab: String {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--tab"), i + 1 < args.count else { return "general" }
        return args[i + 1]
    }

    func show() {
        store.load()
        health.refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    nonisolated static func restartWeftCtl() {
        guard let url = weftctlURL() else { return }
        let proc = Process()
        proc.executableURL = url
        proc.arguments = ["service", "restart"]
        try? proc.run()
        proc.waitUntilExit()
    }
}
