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
        case .integrations: return "Window borders and Sketchybar."
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
                .frame(width: Metrics.sidebar)
                // The sidebar is navigation: it is the last thing that should
                // give way when a detail pane wants more room than exists.
                .layoutPriority(1)

            Divider()

            VStack(spacing: 0) {
                DetailHeader(tab: tab, store: store)
                Divider().opacity(0.6)

                // Vertical only. The old version scrolled both ways as a
                // backstop against panes that overflowed — which turned a
                // layout bug into a horizontal scrollbar instead of fixing
                // it, and cost a full re-measure of every card on every
                // keystroke. Nothing in here is allowed to be wider than the
                // content column now, so there is nothing to scroll sideways.
                ScrollView(.vertical) {
                    Group {
                        switch tab {
                        case .general: GeneralTab(store: store, health: health)
                        case .spaces: SpacesTab(store: store, health: health)
                        case .rules: RulesTab(store: store, health: health)
                        case .keys: KeysTab(store: store)
                        case .integrations: IntegrationsTab(store: store, health: health)
                        case .advanced: AdvancedTab(store: store)
                        }
                    }
                    .frame(maxWidth: Metrics.content, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.35))

                Divider().opacity(0.6)
                ActionBar(store: store, health: health)
            }
            .frame(minWidth: Metrics.content + Metrics.gutter * 2, maxWidth: .infinity)
        }
        .frame(
            minWidth: Metrics.sidebar + Metrics.content + Metrics.gutter * 2 + 1,
            minHeight: 620
        )
        .tint(.weft)
        .onAppear { health.start() }
        .onDisappear { health.stop() }
    }
}

/// The three numbers the whole window is laid out against.
///
/// They exist as constants because the window's minimum width has to be
/// derived from them rather than guessed. It used to be guessed — 880, with a
/// 218pt sidebar and a content column that could ask for 830 — and the
/// overflow came out of the sidebar, which slid off the left edge of the
/// window the moment the outer-gap fields unlinked into four.
enum Metrics {
    static let sidebar: CGFloat = 208
    static let content: CGFloat = 660
    static let gutter: CGFloat = 24
    /// Label column in a form row. Everything lines up on this.
    static let label: CGFloat = 132
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Binding var tab: SettingsTab
    @ObservedObject var health: EngineHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppIcon()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Weft").font(.system(size: 14, weight: .semibold))
                    Text("Settings").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 16)

            VStack(spacing: 2) {
                ForEach(Array(SettingsTab.allCases.enumerated()), id: \.element) { i, item in
                    SidebarRow(item: item, selected: tab == item, index: i + 1) { tab = item }
                }
            }
            .padding(.horizontal, 9)

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
    let index: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12.5))
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
                // ⌘1…⌘6, shown where a keyboard-first user looks for them.
                Text("⌘\(index)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(selected ? Color.white.opacity(0.65) : Color.secondary)
                    .opacity(selected || hovering ? 1 : 0)
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
        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(health.tint)
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle().stroke(health.tint.opacity(0.25), lineWidth: 3)
                    )
                Text(health.headline)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer(minLength: 0)
            }
            Text(health.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if health.needsRestart {
                Button {
                    health.restart()
                } label: {
                    Text(health.isRestarting ? "Restarting…" : "Restart engine")
                }
                .controlSize(.small)
                .disabled(health.isRestarting)
            } else if health.needsPermissions {
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
    @ObservedObject var store: ConfigStore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.title).font(.system(size: 17, weight: .semibold))
                Text(tab.blurb)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if store.isDirty {
                Text("UNSAVED")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Color.weft)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.weft.opacity(0.14))
                    )
                    .overlay(Capsule().strokeBorder(Color.weft.opacity(0.3)))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .animation(.easeOut(duration: 0.15), value: store.isDirty)
    }
}

// MARK: - Action bar

private struct ActionBar: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var health: EngineHealth

    var body: some View {
        HStack(spacing: 10) {
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
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.bar)
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

private struct Card<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    // Small caps for the card title: it is a section marker,
                    // not prose, and setting it apart from the body text is
                    // what stops six stacked cards reading as one grey wall.
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                accessory
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 10)

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 13) {
                content
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        )
    }
}

extension Card where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, content: content, accessory: { EmptyView() })
    }
}

/// Label on the left at a fixed width, control on the right — the one thing the
/// old absolute-frame layout got right, kept.
private struct Row<Content: View>: View {
    let label: String
    var help: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(width: Metrics.label, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                content
                if let help {
                    Text(help)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A number with a unit, in monospaced digits so a column of them lines up
/// and a value does not jitter sideways as you hold the stepper.
private struct NumberField: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...400
    var unit: String = "px"
    var width: CGFloat = 54
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 0) {
                TextField("", value: $value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: width)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $value, in: range).labelsHidden()
            }
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .onChange(of: value) { _, _ in onChange() }
    }
}

/// The same, for a measurement that is allowed a half. Border thickness is
/// the one setting where 1.5 and 2 look meaningfully different.
private struct DecimalField: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var unit: String = "px"
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 0) {
                TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 54)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $value, in: range, step: 0.5).labelsHidden()
            }
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .onChange(of: value) { _, _ in onChange() }
    }
}

/// Four edge values laid out as a cross — top above, left and right either
/// side, bottom below.
///
/// The version this replaces was four labelled fields in a row. Four fields
/// need about 350 points, the row label spends another 150, and the gap
/// preview sat beside all of that: unlinking the outer gap asked for more
/// width than the window had, the HStack overflowed, and what got pushed out
/// was the sidebar. The cross says the same thing in 190 points, and says it
/// better — the position of each field is which edge it is.
private struct EdgeCross: View {
    @Binding var top: Int
    @Binding var bottom: Int
    @Binding var left: Int
    @Binding var right: Int
    var range: ClosedRange<Int> = 0...400
    let onChange: () -> Void

    /// One column. Three of them plus two gaps is the whole control, which is
    /// what makes the top and bottom fields land dead centre over the screen
    /// rectangle: every cell is the same width, so "centred in the control"
    /// and "centred over the middle column" are the same place. The version
    /// this replaces sized each cell to a field *plus a stepper*, and the
    /// stepper is only on one side — so the middle column was off-centre by
    /// half a stepper and the diagram visibly leaned right.
    private static let cell: CGFloat = 58
    private static let spacing: CGFloat = 8

    var body: some View {
        VStack(spacing: Self.spacing) {
            field($top, "Top")
            HStack(spacing: Self.spacing) {
                field($left, "Left")
                // The screen. No arrows anywhere in this control: a field
                // above the rectangle is the top edge and a field to its left
                // is the left edge, and saying so again with an arrow was
                // four more glyphs competing with the four numbers that are
                // the actual content.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(0.22),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
                    .frame(width: Self.cell, height: 32)
                field($right, "Right")
            }
            field($bottom, "Bottom")
        }
        .frame(width: Self.cell * 3 + Self.spacing * 2)
    }

    /// Steppers are gone too. Four of them, each hard against one side of its
    /// field, put eight chevrons around a control whose entire content is
    /// four numbers — and these are numbers you type, not ones you nudge one
    /// point at a time. Losing them means the range has to be enforced here
    /// rather than by the control.
    private func field(_ binding: Binding<Int>, _ name: String) -> some View {
        TextField("", value: binding, format: .number)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .multilineTextAlignment(.center)
            .frame(width: Self.cell)
            .onChange(of: binding.wrappedValue) { _, value in
                let clamped = min(max(value, range.lowerBound), range.upperBound)
                if clamped != value { binding.wrappedValue = clamped }
                onChange()
            }
            .help("\(name) — px")
            .accessibilityLabel(name)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var health: EngineHealth

    var body: some View {
        VStack(spacing: 14) {
            if health.needsRestart {
                RestartNotice(health: health)
            }

            Card(
                title: "Layout",
                subtitle: "How weft arranges a space that has not named a layout of its own."
            ) {
                Row(label: "Default") {
                    LayoutChooser(selection: $store.defaultLayout) { store.markDirty() }
                }
                Row(label: "Inner gap", help: "Between neighbouring windows.") {
                    NumberField(value: $store.innerGap, range: 0...200) { store.markDirty() }
                }
                Row(
                    label: "Stack offset",
                    help: "How far each window in a stack peeks out from the front of the pile. 0 for a flat stack."
                ) {
                    NumberField(value: $store.stackOffset, range: 0...120) { store.markDirty() }
                }
            }

            Card(
                title: "Screen edges",
                subtitle: "Outer gap is breathing room. Reserve is space weft refuses to use — for a bar or a dock that is always on screen."
            ) {
                // Editor and preview side by side, and *both* fixed-size, so
                // the row can never ask for more than the content column has.
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 7) {
                            FieldCaption("Outer gap")
                            Toggle("Same on all sides", isOn: $store.linkOuterGaps)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 11.5))
                                .onChange(of: store.linkOuterGaps) { _, linked in
                                    if linked { spreadOuter(store.outerTop) }
                                    store.markDirty()
                                }
                            if store.linkOuterGaps {
                                NumberField(
                                    value: Binding(
                                        get: { store.outerTop },
                                        set: { spreadOuter($0) }
                                    ),
                                    range: 0...400
                                ) { store.markDirty() }
                            } else {
                                EdgeCross(
                                    top: $store.outerTop, bottom: $store.outerBottom,
                                    left: $store.outerLeft, right: $store.outerRight,
                                    onChange: { store.markDirty() }
                                )
                            }
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            FieldCaption("Reserve")
                            EdgeCross(
                                top: $store.reserveTop, bottom: $store.reserveBottom,
                                left: $store.reserveLeft, right: $store.reserveRight,
                                onChange: { store.markDirty() }
                            )
                        }
                    }
                    .frame(width: 210, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        LayoutPreview(
                            inner: store.innerGap,
                            outer: (store.outerTop, store.outerBottom, store.outerLeft, store.outerRight),
                            reserve: (store.reserveTop, store.reserveBottom, store.reserveLeft, store.reserveRight),
                            layout: store.defaultLayout
                        )
                        .frame(width: 320, height: 200)
                        Text(anyReserve
                             ? "Live preview — the orange bands are reserved."
                             : "Live preview, drawn at roughly half a screen's width.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Card(title: "Mouse") {
                Row(
                    label: "Border drag",
                    help: "Weft claims a plain click only when it lands on a border. Every other click reaches the app untouched."
                ) {
                    Toggle("Drag the border between two tiled windows to resize them",
                           isOn: $store.mouseBorderResize)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .onChange(of: store.mouseBorderResize) { _, _ in store.markDirty() }
                }
                Row(label: "Modifier", help: "Hold this and drag a window's body to move it, or right-drag to resize.") {
                    Picker("", selection: $store.mouseModifier) {
                        Text("⌥ Option").tag("alt")
                        Text("⌘ Command").tag("cmd")
                        Text("⌃ Control").tag("ctrl")
                        Text("⇧ Shift").tag("shift")
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .onChange(of: store.mouseModifier) { _, _ in store.markDirty() }
                }
                Row(label: "Cursor") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Warp the cursor to a window when it takes focus",
                               isOn: $store.mouseFollowsFocus)
                            .onChange(of: store.mouseFollowsFocus) { _, _ in store.markDirty() }
                        Toggle("Focus whatever window the cursor is over",
                               isOn: $store.focusFollowsMouse)
                            .onChange(of: store.focusFollowsMouse) { _, _ in store.markDirty() }
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                }
            }

            Card(title: "Behaviour") {
                Row(
                    label: "Menu-bar apps",
                    help: "Their windows are usually dropdown panels: tiling one gives it a slot and swallows the click that would dismiss it."
                ) {
                    Toggle("Tile windows belonging to apps with no Dock icon",
                           isOn: $store.manageMenubarApps)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .onChange(of: store.manageMenubarApps) { _, _ in store.markDirty() }
                }
                Row(
                    label: "Updates",
                    help: "Asks GitHub once a day. Downloads nothing — it shows the version and the command to run."
                ) {
                    Toggle("Tell me when a newer weft is released", isOn: $store.checkForUpdates)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .onChange(of: store.checkForUpdates) { _, _ in store.markDirty() }
                }
            }
        }
    }

    private var anyReserve: Bool {
        store.reserveTop > 0 || store.reserveBottom > 0
            || store.reserveLeft > 0 || store.reserveRight > 0
    }

    private func spreadOuter(_ value: Int) {
        store.outerTop = value
        store.outerBottom = value
        store.outerLeft = value
        store.outerRight = value
    }
}

/// A small all-caps label above a control group. Same role as `Row`'s label,
/// for the places where the control is too tall to sit beside one.
private struct FieldCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

/// The three layouts as pictures rather than a dropdown of words.
///
/// "Scroll — columns" in a popup tells you nothing you did not already know
/// from the word; the shape does. Three buttons also means the choice is
/// visible without opening anything, which is what makes it feel like a
/// control panel rather than a form.
private struct LayoutChooser: View {
    @Binding var selection: String
    let onChange: () -> Void

    private struct Option {
        let id: String
        let title: String
        let detail: String
        let symbol: String
    }

    private static let options = [
        Option(id: "bsp", title: "BSP", detail: "New windows halve the focused one",
               symbol: "rectangle.split.2x2"),
        Option(id: "scroll", title: "Scroll", detail: "One column each, scrolling sideways",
               symbol: "rectangle.split.3x1"),
        Option(id: "float", title: "Float", detail: "No tiling at all",
               symbol: "macwindow.on.rectangle"),
    ]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Self.options, id: \.id) { option in
                let on = selection == option.id
                Button {
                    guard !on else { return }
                    selection = option.id
                    onChange()
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: option.symbol)
                            .font(.system(size: 15, weight: .regular))
                        Text(option.title)
                            .font(.system(size: 11, weight: on ? .semibold : .regular))
                    }
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .frame(width: 74, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                on
                                    ? AnyShapeStyle(LinearGradient(
                                        colors: [.weft, .weftDeep],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                                    : AnyShapeStyle(Color.primary.opacity(0.06))
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(on ? 0 : 0.08))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.detail)
            }
        }
    }
}

/// The Settings-window twin of Setup's restart banner. Someone who granted a
/// permission and then came straight here should not have to find their way
/// back to Setup to be told the one thing that is wrong.
private struct RestartNotice: View {
    @ObservedObject var health: EngineHealth

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.weft)
            VStack(alignment: .leading, spacing: 6) {
                Text("The engine needs one restart")
                    .font(.system(size: 12, weight: .semibold))
                Text("Accessibility was granted after weftd started, and macOS only hands out that access at launch. Nothing weft does will work until it starts again.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    health.restart()
                } label: {
                    HStack(spacing: 6) {
                        if health.isRestarting { ProgressView().controlSize(.small) }
                        Text(health.isRestarting ? "Restarting…" : "Restart the engine")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(health.isRestarting)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.weft.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.weft.opacity(0.3))
        )
    }
}

/// What the gap numbers actually do, at a glance.
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
            // Scaled against a nominal 520-point-wide screen. Real numbers at
            // real scale are unreadable — an 8px gap on a 1440-wide display is
            // under two points here — and the drawing exists to answer "is
            // that bigger or smaller than I wanted", not to be a ruler. At
            // this scale the default 8px outer gap is a visible margin, which
            // is the whole reason the picture is here.
            let scale = geo.size.width / 520
            let r = (
                top: CGFloat(reserve.top) * scale,
                bottom: CGFloat(reserve.bottom) * scale,
                left: CGFloat(reserve.left) * scale,
                right: CGFloat(reserve.right) * scale
            )
            let top = CGFloat(outer.top) * scale + r.top
            let bottom = CGFloat(outer.bottom) * scale + r.bottom
            let left = CGFloat(outer.left) * scale + r.left
            let right = CGFloat(outer.right) * scale + r.right
            let gap = max(0.5, CGFloat(inner) * scale)
            let usable = CGRect(
                x: left, y: top,
                width: max(6, geo.size.width - left - right),
                height: max(6, geo.size.height - top - bottom)
            )

            ZStack(alignment: .topLeading) {
                // The screen.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14))

                // Reserved strips, on whichever edges have one. Drawn under
                // the windows so an over-large reserve is obvious: the
                // windows visibly stop short of it.
                band(w: geo.size.width, h: r.top, x: 0, y: 0)
                band(w: geo.size.width, h: r.bottom, x: 0, y: geo.size.height - r.bottom)
                band(w: r.left, h: geo.size.height, x: 0, y: 0)
                band(w: r.right, h: geo.size.height, x: geo.size.width - r.right, y: 0)

                ForEach(Array(tiles(in: usable, gap: gap).enumerated()), id: \.offset) { i, rect in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(i == 0 ? Color.weft.opacity(0.8) : Color.weft.opacity(0.34))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
    }

    @ViewBuilder
    private func band(w: CGFloat, h: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        if w > 0.5 && h > 0.5 {
            Rectangle()
                .fill(Color.orange.opacity(0.24))
                .frame(width: w, height: h)
                .offset(x: x, y: y)
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
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 12))
        }
        .buttonStyle(.borderless)
        // Explicit, not `.secondary`: the window is tinted weft blue, and a
        // borderless button inherits the tint — so every delete button in the
        // table rendered as the brightest, most inviting thing on it.
        .foregroundStyle(hovering ? Color.red : Color.secondary)
        .onHover { hovering = $0 }
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
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 14) {
            Card(
                title: "Window rules",
                subtitle: "Checked top to bottom; the first rule that matches wins. App and Title are regular expressions — “Brave|Zen” matches either.",
                content: {
                    if store.rules.isEmpty {
                        EmptyHint(
                            symbol: "line.3.horizontal.decrease.circle",
                            text: "No rules. Every window is tiled on whatever space it opens on."
                        )
                    } else {
                        if store.rules.count > 6 {
                            SearchField(text: $filter, prompt: "Filter by app, title or space")
                                .padding(.bottom, 2)
                        }
                        VStack(spacing: 6) {
                            ForEach($store.rules) { $rule in
                                if matches(rule) {
                                    RuleRowView(rule: $rule, store: store, live: liveLabels)
                                }
                            }
                        }
                    }

                    Button { store.addRule() } label: { Label("Add rule", systemImage: "plus") }
                        .controlSize(.small)
                },
                accessory: {
                    Text("\(store.rules.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
            )
        }
    }

    private func matches(_ rule: RuleRow) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return rule.app.lowercased().contains(needle)
            || rule.title.lowercased().contains(needle)
            || rule.bundleID.lowercased().contains(needle)
            || rule.space.lowercased().contains(needle)
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

    private var managed: Bool { rule.manage ?? true }

    var body: some View {
        // Two lines, not one. Four fields on a line plus their labels came to
        // more than the content column, and the row it lived in had nothing
        // that could shrink — so it overflowed instead. Matching above,
        // outcome below, with the outcome stated in words.
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: managed ? "square.grid.2x2" : "macwindow.on.rectangle")
                    .font(.system(size: 11))
                    .foregroundStyle(managed ? Color.weft : .secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(managed ? Color.weft.opacity(0.13) : Color.primary.opacity(0.06))
                    )

                LabeledField(label: "App matches", text: $rule.app, width: 168,
                             placeholder: "Ghostty|kitty") { store.markDirty() }
                LabeledField(label: "Title matches", text: $rule.title, width: 150,
                             placeholder: "any") { store.markDirty() }
                LabeledField(label: "Bundle id", text: $rule.bundleID, width: 172,
                             placeholder: "optional") { store.markDirty() }

                Spacer(minLength: 0)

                DeleteButton {
                    store.rules.removeAll { $0.id == rule.id }
                    store.markDirty()
                }
            }

            HStack(spacing: 8) {
                Spacer().frame(width: 20)

                Picker("", selection: Binding(
                    get: { managed },
                    set: { rule.manage = $0 ? nil : false; store.markDirty() }
                )) {
                    Text("Tile it").tag(true)
                    Text("Leave it alone").tag(false)
                }
                .labelsHidden()
                .frame(width: 130)

                Text("on")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(
                    get: { rule.space },
                    set: { rule.space = $0; store.markDirty() }
                )) {
                    Text("whichever space it opens on").tag("")
                    ForEach(store.spaceLabels, id: \.self) { Text($0).tag($0) }
                    if !rule.space.isEmpty && !store.spaceLabels.contains(rule.space) {
                        Text("\(rule.space) — not in Spaces").tag(rule.space)
                    }
                }
                .labelsHidden()
                .frame(width: 186)

                if targetIsUnreachable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help("No desktop is labelled “\(rule.space)”, so this rule moves nothing.")
                }

                Spacer(minLength: 0)
            }

            if !rule.isValid {
                Label(
                    "Give this rule an app, a title or a bundle id to match — weftd rejects a rule that matches nothing.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    rule.isValid && !targetIsUnreachable
                        ? Color.primary.opacity(0.03)
                        : Color.orange.opacity(0.07)
                )
        )
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
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
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
        VStack(spacing: 14) {
            // Sixty binds is a normal weft.toml, and finding the one you meant
            // to change by scrolling is the reason people give up and open the
            // file instead.
            SearchField(text: $filter, prompt: "Filter by chord or command")

            ForEach($store.modes) { $mode in
                // Matches and duplicates computed once per mode, not once per
                // row. Both used to run inside the row loop, which made
                // rendering a mode quadratic in its own bindings — on every
                // keystroke in the filter field.
                let view = ModeView(mode: mode, filter: filter)
                if view.isVisible {
                    Card(
                        title: mode.isDefault ? "Default bindings" : "Mode · \(mode.name)",
                        subtitle: mode.isDefault
                            ? "Always live. Bind “mode <name>” to enter one of the layers below."
                            : "Only live after entering this mode. Bind “mode default” to get back out.",
                        content: {
                            if mode.rows.isEmpty {
                                EmptyHint(symbol: "keyboard", text: "No bindings in this mode yet.")
                            } else if view.shown.isEmpty {
                                EmptyHint(
                                    symbol: "magnifyingglass",
                                    text: "Nothing in this mode matches “\(filter)”."
                                )
                            }
                            VStack(spacing: 4) {
                                ForEach($mode.rows) { $row in
                                    if view.shown.contains(row.id) {
                                        KeyRowView(
                                            row: $row, store: store, mode: $mode,
                                            duplicate: view.duplicates.contains(row.chord.lowercased())
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
                            }
                            .controlSize(.small)
                        },
                        accessory: {
                            Text("\(mode.rows.count)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                    )
                }
            }

            Card(title: "New mode", subtitle: "A modal layer — like vim's, but for window management.") {
                HStack(spacing: 10) {
                    TextField("resize", text: $newMode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
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
}

/// Everything one mode's card needs to know about the current filter, worked
/// out once.
private struct ModeView {
    let shown: Set<KeyRow.ID>
    /// Two rows on the same chord is a silent bug: the file is a TOML table,
    /// so the second one wins and the first simply never fires.
    let duplicates: Set<String>
    let isVisible: Bool

    init(mode: KeyMode, filter: String) {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty {
            shown = Set(mode.rows.map(\.id))
            isVisible = true
        } else {
            let hits = mode.rows.filter {
                $0.chord.lowercased().contains(needle) || $0.command.lowercased().contains(needle)
            }
            shown = Set(hits.map(\.id))
            isVisible = !hits.isEmpty
        }
        var seen: Set<String> = []
        var dupes: Set<String> = []
        for row in mode.rows where !row.chord.isEmpty {
            let key = row.chord.lowercased()
            if !seen.insert(key).inserted { dupes.insert(key) }
        }
        duplicates = dupes
    }
}

private struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

private struct KeyRowView: View {
    @Binding var row: KeyRow
    @ObservedObject var store: ConfigStore
    @Binding var mode: KeyMode
    var duplicate = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            ChordField(chord: $row.chord, showsRecorder: hovering) { store.markDirty() }

            if duplicate {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Another binding in this mode uses the same chord — only the last one fires.")
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.quaternary)

            TextField("focus west", text: $row.command)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
                .onChange(of: row.command) { _, _ in store.markDirty() }

            CommandPicker { command in
                row.command = command
                store.markDirty()
            }

            // Revealed on hover. Sixty rows each ending in a delete button is
            // sixty invitations to lose a binding by mis-clicking, and the
            // column of them was the loudest thing in the table.
            DeleteButton {
                mode.rows.removeAll { $0.id == row.id }
                store.markDirty()
            }
            .opacity(hovering ? 1 : 0.18)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .onHover { hovering = $0 }
    }
}

/// The command catalogue, as a searchable popover.
///
/// This used to be a `Menu` per row holding eight submenus and every command
/// in each. SwiftUI builds a menu's content as part of the row's body, so a
/// sixty-bind config was building roughly three thousand throwaway views —
/// and rebuilding all of them on every keystroke, because the rows are bound
/// into one array and a change to any of them invalidates the lot. That is
/// the settings lag. A popover's content is built when it opens and at no
/// other time, so a closed picker costs one button.
private struct CommandPicker: View {
    let onPick: (String) -> Void
    @State private var showing = false
    @State private var query = ""

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Pick from the commands weftd understands")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                SearchField(text: $query, prompt: "Search commands")
                    .padding(10)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(CommandCatalog.groups, id: \.name) { group in
                            let hits = group.commands.filter(matches)
                            if !hits.isEmpty {
                                Text(group.name.uppercased())
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .tracking(0.6)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 10)
                                    .padding(.bottom, 3)
                                ForEach(hits, id: \.self) { command in
                                    CommandRow(command: command) {
                                        onPick(command)
                                        showing = false
                                        query = ""
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .frame(width: 320, height: 380)
        }
    }

    private func matches(_ command: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty || command.lowercased().contains(needle)
    }
}

private struct CommandRow: View {
    let command: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(command)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.weft.opacity(hovering ? 0.16 : 0))
                        .padding(.horizontal, 6)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Type a chord, or press one. The recorder is the point: weft's chord syntax
/// is hardware keycodes spelled out in words (`alt-bracketleft`), which nobody
/// guesses correctly for a bracket, a backslash or an arrow key.
private struct ChordField: View {
    @Binding var chord: String
    /// The record button is only worth its space while the pointer is on the
    /// row it belongs to; the rest of the time it is a column of identical
    /// targets running down a table nobody is aiming at.
    var showsRecorder = true
    let onChange: () -> Void

    @State private var recording = false
    @State private var editing = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            // Two faces for one value: key caps when you are reading, a text
            // field when you are editing. `alt-bracketright` is the spelling
            // the file needs and ⌥] is the thing on your keyboard, and the
            // table is much easier to scan in the second.
            if editing {
                TextField("alt-h", text: $chord)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(width: 132)
                    .onChange(of: chord) { _, _ in onChange() }
                    .onSubmit { editing = false }
            } else {
                Button { editing = true } label: {
                    KeyCaps(chord: chord)
                        .frame(width: 132, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to type the chord, or use the record button")
            }

            Button {
                recording ? stop() : start()
            } label: {
                Image(systemName: recording ? "record.circle.fill" : "record.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(recording ? Color.red : Color.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(recording || showsRecorder ? 1 : 0)
            .help(recording ? "Press a chord, or click again to cancel" : "Record a chord")
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        editing = false
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

/// `alt-shift-bracketright` drawn as ⌥ ⇧ ].
private struct KeyCaps: View {
    let chord: String

    var body: some View {
        HStack(spacing: 3) {
            if chord.isEmpty {
                Text("unbound")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(ChordNaming.caps(for: chord).enumerated()), id: \.offset) { _, cap in
                    Text(cap)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .frame(minWidth: 18)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12))
                        )
                }
            }
        }
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

    /// The glyph shown on the physical key, per chord token. Modifiers get
    /// their symbols; named keys get the character or the short word that is
    /// actually printed on the cap.
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
            "move display west --follow", "move display east --follow",
            "move display next --follow", "move display cycle --follow",
        ]),
        Group(name: "Window", commands: [
            "window toggle zoom-fullscreen", "window toggle split",
            "float toggle", "float on", "float off",
            "sticky toggle", "balance",
            "split vertical", "split horizontal",
            "insertion bsp", "insertion manual",
        ]),
        Group(name: "Stack", commands: [
            "stack toggle", "stack next", "stack prev", "stack unstack",
            "stack split west", "stack split east",
            "stack split north", "stack split south",
        ]),
        Group(name: "Scroll layout", commands: [
            "scroll focus next-column", "scroll focus prev-column",
            "scroll move-window next-column", "scroll move-window prev-column",
            "scroll width cycle",
        ]),
        Group(name: "Spaces", commands: [
            "space focus 1", "space focus 2", "space focus 3",
            "space focus recent",
            "space move-window 1", "space move-window 2", "space move-window 3",
            "space layout bsp", "space layout scroll",
            "space layout float", "space layout toggle",
            "move space display west", "move space display east",
        ]),
        Group(name: "Resize", commands: [
            "resize left 40", "resize right 40", "resize up 40", "resize down 40",
            "resize left 120", "resize right 120", "resize up 120", "resize down 120",
        ]),
        Group(name: "Apps", commands: [
            "app toggle com.apple.finder",
            "app toggle com.mitchellh.ghostty",
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
            Card(title: "Window borders", subtitle: "Draws the highlight around the focused window.") {
                HStack(spacing: 10) {
                    Toggle("Enable borders", isOn: $store.bordersEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: store.bordersEnabled) { _, _ in store.markDirty() }
                    Spacer()
                    if store.bordersBackend == "janky" {
                        InstallState(path: health.bordersPath, binary: "borders")
                    }
                }

                if store.bordersEnabled {
                    Row(
                        label: "Drawn by",
                        help: store.bordersBackend == "native"
                            ? "Weft's own renderer. Borders only around windows weft is managing, so menu-bar popovers and system panels never get one."
                            : "The external borders binary. It outlines anything that looks like a window, including menu-bar popovers."
                    ) {
                        Picker("", selection: $store.bordersBackend) {
                            Text("Built into weft").tag("native")
                            Text("JankyBorders").tag("janky")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 260)
                        .onChange(of: store.bordersBackend) { _, _ in store.markDirty() }
                    }
                }

                if store.bordersEnabled, store.bordersBackend == "native" {
                    Row(label: "Thickness") {
                        DecimalField(value: $store.bordersWidth, range: 0...20, unit: "px") {
                            store.markDirty()
                        }
                    }
                    Row(label: "Corner radius", help: "Match your windows' own corners. macOS rounds them by about 10px.") {
                        DecimalField(value: $store.bordersRadius, range: 0...40, unit: "px") {
                            store.markDirty()
                        }
                    }
                    Row(label: "Unfocused windows", help: "Outline every window in the layout, not just the focused one.") {
                        Toggle("Outline them too", isOn: $store.bordersShowInactive)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                            .onChange(of: store.bordersShowInactive) { _, _ in store.markDirty() }
                    }
                    if store.bordersShowInactive {
                        Row(label: "Unfocused colour", help: "0xaarrggbb. Blank uses a dim grey-blue.") {
                            TextField("0x40414868", text: $store.bordersInactiveColor)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5, design: .monospaced))
                                .frame(maxWidth: 160)
                                .onChange(of: store.bordersInactiveColor) { _, _ in store.markDirty() }
                        }
                    }
                    Label(
                        "The focused colour comes from active-color, per layout, in Advanced — the same table JankyBorders used.",
                        systemImage: "paintpalette"
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                }

                // Switching this on without the binary is a no-op that logs one
                // line to a file nobody reads. Say so here instead.
                if store.bordersEnabled, store.bordersBackend == "janky", health.bordersPath == nil {
                    MissingBinary(
                        name: "borders",
                        install: "brew install FelixKratz/formulae/borders",
                        setting: "borders"
                    )
                }

                if store.bordersEnabled, store.bordersBackend == "janky", health.bordersPath != nil {
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
    /// The event tap, not the Input Monitoring switch. This card is about
    /// whether weft works, and Accessibility alone is enough for macOS to let
    /// weftd open the tap — flagging "missing permissions" at someone whose
    /// keybinds all fire is just wrong.
    @Published var keybindsLive = false
    @Published var isRestarting = false
    /// weftd is running with grants it cannot use, because it was started
    /// before they were made. One restart is the whole fix.
    @Published var needsRestart = false
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

    var needsPermissions: Bool { running && !(accessibility && keybindsLive) }

    var tint: Color {
        if !running { return .orange }
        if needsRestart { return .weft }
        return needsPermissions ? .yellow : .green
    }

    var headline: String {
        if !running { return "Engine not running" }
        if needsRestart { return "Restart pending" }
        return needsPermissions ? "Missing permissions" : "Engine running"
    }

    var detail: String {
        if !running { return "Start it with weftctl service start." }
        if needsRestart { return "Granted after weftd started — it needs to start once more." }
        if needsPermissions {
            var missing: [String] = []
            if !accessibility { missing.append("Accessibility") }
            if !keybindsLive { missing.append("Input Monitoring") }
            return missing.joined(separator: " and ") + " is not granted to weftd."
        }
        return "Config changes apply within 100 ms."
    }

    func start() {
        refresh()
        timer?.invalidate()
        // Five seconds, not three. This card is context, and the window it
        // sits in is one the user is typing into: every poll is two socket
        // round trips, and a settings window has no business talking to the
        // daemon more often than it has to.
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
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
                self.keybindsLive = perms?.tapLive ?? false
                self.needsRestart = perms?.mustRestart ?? false
                self.liveSpaces = spaces
            }
        }
    }

    func restart() {
        isRestarting = true
        Task.detached(priority: .userInitiated) {
            ConfigEditorWindowController.restartWeftCtl()
            // Wait for the socket rather than a fixed sleep: `launchctl
            // kickstart -k` returns as soon as it has signalled, and asking
            // into that gap reads back as "engine not running".
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
