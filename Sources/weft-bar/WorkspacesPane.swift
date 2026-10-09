import AppKit
import SwiftUI
import WeftCore
import WeftIPC
import WeftPlatform

// The Workspaces pane: your macOS desktops — each one a workspace — drawn on
// this Mac's real displays (docs/NATIVE.md, "Settings, Setup, bar").
//
// The desktops themselves are macOS's: which exist, their order and their
// display come from the WindowServer, and are changed in Mission Control.
// What the pane edits is weft's part of each — its label, its layout, the
// apps that open there — through the same `[[space]]` and `[[rule]]` blocks
// the file holds, via `ConfigStore`, so comments and anything the pane does
// not understand survive untouched. `[[space]]` blocks label desktops by
// number: the first names desktop 1.
//
// Motion is springs on state changes only; nothing animates while the pane
// sits still, so it costs nothing to leave open.

// MARK: - Displays

/// A connected display, as the canvas draws it.
struct CanvasDisplay: Identifiable, Equatable {
    var id: String
    /// 1-based, west to east — what `focus display N` counts.
    var index: Int
    var name: String
    var isMain: Bool
    var isBuiltIn: Bool = false
    /// Global, top-left origin, in points.
    var frame: CGRect
}

enum DisplayCatalog {
    static func current() -> [CanvasDisplay] {
        let identities = SpaceControl.displayIdentities()
        return SpaceControl.displayLayout().enumerated().map { i, d in
            let identity = identities.first { $0.uuid == d.uuid }
            return CanvasDisplay(
                id: d.uuid,
                index: i + 1,
                name: identity?.name.isEmpty == false ? identity!.name : "Display \(i + 1)",
                isMain: identity?.isMain ?? false,
                isBuiltIn: identity?.isBuiltIn ?? false,
                frame: CGRect(x: d.frame.x, y: d.frame.y, width: d.frame.width, height: d.frame.height)
            )
        }
    }
}

// MARK: - Apps

/// An app a rule sends to a workspace, with its icon.
struct AssignedApp: Identifiable, Equatable {
    var id: RuleRow.ID
    var name: String
    var icon: NSImage

    static func == (a: AssignedApp, b: AssignedApp) -> Bool { a.id == b.id && a.name == b.name }

    @MainActor private static var iconCache: [String: NSImage] = [:]

    @MainActor static func of(_ rule: RuleRow) -> AssignedApp {
        let key = rule.bundleID.isEmpty ? "name:" + rule.app : rule.bundleID
        var name = rule.app.isEmpty ? rule.bundleID : rule.app
        var url: URL?
        if !rule.bundleID.isEmpty {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleID)
            if let url { name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
        } else {
            url = locate(appNamed: rule.app)
        }
        let icon = iconCache[key] ?? {
            let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSWorkspace.shared.icon(for: .applicationBundle)
            iconCache[key] = image
            return image
        }()
        return AssignedApp(id: rule.id, name: name.replacingOccurrences(of: "|", with: " or "), icon: icon)
    }

    /// An app a rule names — `app` is a pattern, so "Code|Cursor" is either
    /// — found running, or where apps are installed.
    @MainActor private static func locate(appNamed pattern: String) -> URL? {
        let names = pattern.split(separator: "|").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "^$ ")).replacingOccurrences(of: "\\", with: "")
        }
        let running = NSWorkspace.shared.runningApplications
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       "\(home)/Applications", "/Applications/Utilities"]
        for name in names where !name.isEmpty {
            if let app = running.first(where: { $0.localizedName == name }), let url = app.bundleURL { return url }
            for folder in folders {
                let path = "\(folder)/\(name).app"
                if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }
}

// MARK: - The pane

struct WorkspacesPane: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var health: EngineHealth
    @SwiftUI.State private var displays = DisplayCatalog.current()
    @SwiftUI.State private var desktops = Desktops.current()
    /// The desktop number the inspector shows.
    @SwiftUI.State private var selection: Int?
    @Namespace private var cards

    private var spring: Animation { .spring(response: 0.38, dampingFraction: 0.82) }

    /// Displays in numbering order: main first, then west to east — the
    /// order the cards and numbers read in.
    private var numbered: [CanvasDisplay] {
        displays.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            return a.frame.minX < b.frame.minX
        }
    }

    private var desktopCount: Int { desktops.values.flatMap { $0 }.filter { !$0.fullscreen }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                WorkspaceWarnings()
                DisplayCanvas(displays: displays, desktops: desktops, label: label(of:), running: health.running)
                    .frame(height: 230)

                ForEach(numbered) { display in
                    displaySection(display)
                }
                waitingSection

                if let n = selection, n <= desktopCount {
                    WorkspaceInspector(
                        store: store,
                        number: n,
                        label: label(of: n),
                        engineRunning: health.running
                    )
                    .id(n)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .animation(spring, value: store.spaces)
        .animation(spring, value: selection)
        .animation(spring, value: desktops)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            withAnimation(spring) {
                displays = DisplayCatalog.current()
                desktops = Desktops.current()
            }
        }
        // Switching, adding or removing a desktop in Mission Control.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)) { _ in
            withAnimation(spring) { desktops = Desktops.current() }
        }
        .onChange(of: health.liveWorkspaces) { _, _ in desktops = Desktops.current() }
        .onAppear {
            desktops = Desktops.current()
            if selection == nil { selection = desktopCount > 0 ? 1 : nil }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Workspaces").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Each workspace is one of your macOS desktops, numbered as Mission Control shows them. "
                    + "Add, remove and reorder desktops in Mission Control — weft follows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                Desktops.openMissionControl()
            } label: {
                Label("Open Mission Control", systemImage: "rectangle.3.group")
            }
            .weftProminentButton()
        }
    }

    /// The label desktop `n` goes by: its `[[space]]` label, or its number.
    private func label(of n: Int) -> String {
        n - 1 < store.spaces.count && !store.spaces[n - 1].label.isEmpty ? store.spaces[n - 1].label : "\(n)"
    }

    private func layout(of n: Int) -> String {
        n - 1 < store.spaces.count ? store.layout(of: store.spaces[n - 1]) : store.defaultLayout
    }

    private func displaySection(_ display: CanvasDisplay) -> some View {
        let spaces = desktops[display.id] ?? []
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .foregroundStyle(.secondary)
                Text(display.name).font(.headline)
                if numbered.count > 1, display.isMain {
                    Text("main").font(.caption).foregroundStyle(.secondary)
                }
            }
            if spaces.isEmpty {
                Text("No desktops reported for this display.").font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 176), spacing: 12)], spacing: 12) {
                    ForEach(spaces) { desktop in
                        if let n = desktop.number {
                            card(n, desktop: desktop)
                        } else {
                            FullscreenCard()
                        }
                    }
                }
            }
        }
    }

    private func card(_ n: Int, desktop: CanvasDesktop) -> some View {
        let live = health.liveWorkspaces.first { $0.id == desktop.id }
        return DesktopCard(
            number: n,
            label: label(of: n),
            layout: layout(of: n),
            apps: LiveApps.icons(for: live?.windows ?? []),
            showing: desktop.current,
            selected: selection == n
        )
        .matchedGeometryEffect(id: n, in: cards)
        .onTapGesture(count: 2) {
            // Live mode: the editor doubles as a check. Settings follows to the
            // desktop it switched to, so the result is behind it.
            guard health.running else { return }
            BarIPC.post("space focus \(n)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSApp.activate()
                NSApp.keyWindow?.orderFrontRegardless()
            }
        }
        .onTapGesture {
            withAnimation(spring) { selection = selection == n ? nil : n }
        }
        // A tap gesture is invisible to VoiceOver and Full Keyboard Access:
        // without these a card could be read but never opened.
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            withAnimation(spring) { selection = selection == n ? nil : n }
        }
        .help(health.running ? "Click to edit, double-click to switch to it" : "Click to edit")
    }

    /// Labels in weft.toml past the last desktop: they wait for one.
    @ViewBuilder private var waitingSection: some View {
        let waiting = Array(store.spaces.enumerated()).filter { $0.offset >= desktopCount }
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Waiting for a desktop").font(.headline)
                    Text("— weft cannot create desktops; add them in Mission Control.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 176), spacing: 12)], spacing: 12) {
                    ForEach(waiting, id: \.element.id) { index, row in
                        WaitingCard(number: index + 1, label: row.label.isEmpty ? "\(index + 1)" : row.label) {
                            withAnimation(spring) { store.removeSpace(row.id) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - The display map

/// The displays as they are arranged, to scale, each with its desktops in
/// Mission Control order: numbered, the one showing lit, fullscreen spaces
/// greyed with no number.
private struct DisplayCanvas: View {
    let displays: [CanvasDisplay]
    let desktops: [String: [CanvasDesktop]]
    let label: (Int) -> String
    let running: Bool

    /// How the displays' global frames map into the canvas: one scale, and
    /// the offset that centres the arrangement.
    private struct Placement {
        var bounds: CGRect
        var scale: CGFloat
        var origin: CGPoint

        init(_ displays: [CanvasDisplay], in size: CGSize) {
            let bounds = displays.reduce(CGRect.null) { $0.union($1.frame) }
            let inset: CGFloat = 12
            let sx = (size.width - inset * 2) / max(bounds.width, 1)
            let sy = (size.height - inset * 2) / max(bounds.height, 1)
            let scale: CGFloat = bounds.isNull ? 1 : min(sx, sy)
            self.bounds = bounds
            self.scale = scale
            self.origin = CGPoint(
                x: (size.width - bounds.width * scale) / 2,
                y: (size.height - bounds.height * scale) / 2
            )
        }

        func size(of d: CanvasDisplay) -> CGSize {
            CGSize(width: max(40, d.frame.width * scale - 10), height: max(30, d.frame.height * scale - 10))
        }

        func center(of d: CanvasDisplay) -> CGPoint {
            CGPoint(
                x: origin.x + (d.frame.midX - bounds.minX) * scale,
                y: origin.y + (d.frame.midY - bounds.minY) * scale
            )
        }
    }

    var body: some View {
        GeometryReader { geo in
            let placement = Placement(displays, in: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(displays) { d in
                    DisplayTile(
                        display: d,
                        desktops: desktops[d.id] ?? [],
                        label: label,
                        compact: placement.size(of: d).height < 110
                    )
                    .frame(width: placement.size(of: d).width, height: placement.size(of: d).height)
                    .position(placement.center(of: d))
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your displays and their desktops, arranged as they are")
    }
}

private struct DisplayTile: View {
    let display: CanvasDisplay
    let desktops: [CanvasDesktop]
    let label: (Int) -> String
    /// Too small for the name along the top: chips only, smaller.
    let compact: Bool

    private var showing: CanvasDesktop? { desktops.first(where: \.current) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            Wallpaper()
            VStack(spacing: 0) {
                Rectangle().fill(Color.black.opacity(0.3)).frame(height: 7)
                Spacer(minLength: 0)
            }
            VStack(spacing: compact ? 4 : 8) {
                if !compact {
                    HStack {
                        Text(display.name)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.25)))
                        Spacer(minLength: 0)
                    }
                }
                Spacer(minLength: 0)
                if let n = showing?.number {
                    Text(label(n))
                        .font(.system(size: compact ? 12 : 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.opacity)
                        .padding(.horizontal, compact ? 8 : 12)
                        .padding(.vertical, compact ? 2 : 4)
                        .background(Capsule().fill(.black.opacity(0.28)))
                } else if showing?.fullscreen == true {
                    Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: compact ? 10 : 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                HStack(spacing: compact ? 3 : 4) {
                    ForEach(desktops) { d in
                        DesktopChip(desktop: d, compact: compact)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, compact ? 10 : 11)
            .padding(.bottom, 6)
            .padding(.horizontal, 7)
        }
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .accessibilityLabel("\(display.name)\(showing?.number.map { ", showing \(label($0))" } ?? "")")
    }
}

/// One space in a display tile: a desktop's number, or a greyed fullscreen
/// space with none.
private struct DesktopChip: View {
    let desktop: CanvasDesktop
    let compact: Bool

    var body: some View {
        Group {
            if let n = desktop.number {
                Text("\(n)").font(.system(size: compact ? 9 : 11, weight: .bold, design: .rounded))
            } else {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: compact ? 7 : 8, weight: .bold))
            }
        }
        .foregroundStyle(desktop.current ? Color.black.opacity(0.8) : .white.opacity(desktop.fullscreen ? 0.45 : 0.85))
        .frame(minWidth: compact ? 15 : 20, minHeight: compact ? 13 : 17)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(desktop.current ? Color.white.opacity(0.9) : .black.opacity(desktop.fullscreen ? 0.15 : 0.3))
        )
        .help(desktop.fullscreen ? "A fullscreen app — not a workspace" : "Desktop \(desktop.number ?? 0)")
    }
}

// MARK: - A desktop, as a card

private struct DesktopCard: View {
    let number: Int
    let label: String
    let layout: String
    let apps: [LiveApps.App]
    let showing: Bool
    let selected: Bool
    @SwiftUI.State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(number <= 9 ? "⌥\(number)" : "\(number)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(selected ? .white : Color.weft)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(selected ? Color.weft : Color.weft.opacity(0.14)))
                Text(label)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: layout == "float" ? "square.on.square" : "rectangle.split.2x1")
                    .foregroundStyle(.secondary)
                    .help(layout == "float" ? "Floating" : "Tiling")
            }
            HStack(spacing: -7) {
                ForEach(apps.prefix(6)) { app in
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
                        .help(app.name)
                }
                if apps.count > 6 {
                    Text("+\(apps.count - 6)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }
                if apps.isEmpty {
                    Text("Empty")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 24)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .weftGlass(shape, tint: selected ? Color.weft.opacity(0.16) : nil, interactive: true)
        .overlay {
            if showing {
                shape.stroke(Color.weft, lineWidth: 2)
                    .shadow(color: Color.weft.opacity(0.6), radius: 6)
            } else if selected {
                shape.stroke(Color.weft.opacity(0.7), lineWidth: 1.5)
            }
        }
        .scaleEffect(hovering ? 1.025 : 1)
        .shadow(color: .black.opacity(hovering ? 0.12 : 0), radius: 10, y: 4)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Desktop \(number), \(label)\(showing ? ", showing" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A fullscreen or Split View space: drawn where Mission Control has it,
/// greyed, with no number, because it is not a workspace.
private struct FullscreenCard: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
            Text("Fullscreen app").font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.tertiary)
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(shape.fill(Color.primary.opacity(0.03)))
        .overlay(shape.stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .help("A fullscreen app's space. It has no number and weft does not tile it.")
    }
}

/// A label in weft.toml with no desktop at its number yet.
private struct WaitingCard: View {
    let number: Int
    let label: String
    let onRemove: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(number <= 9 ? "⌥\(number)" : "\(number)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Text(label).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1)
                Spacer(minLength: 0)
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Remove this label")
            }
            .foregroundStyle(.secondary)
            Button("Open Mission Control") { Desktops.openMissionControl() }
                .weftGlassButton()
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(shape.fill(Color.primary.opacity(0.03)))
        .overlay(shape.stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

// MARK: - Inspector

private struct WorkspaceInspector: View {
    @ObservedObject var store: ConfigStore
    let number: Int
    let label: String
    let engineRunning: Bool
    @SwiftUI.State private var name: String

    init(store: ConfigStore, number: Int, label: String, engineRunning: Bool) {
        self.store = store
        self.number = number
        self.label = label
        self.engineRunning = engineRunning
        _name = State(initialValue: label)
    }

    /// The `[[space]]` row for this desktop, made (with the rows before it,
    /// labelled by number) the first time something is set on it.
    private func row() -> SpaceRow.ID { store.spaceRow(number: number) }

    private var layout: String {
        number - 1 < store.spaces.count ? store.layout(of: store.spaces[number - 1]) : store.defaultLayout
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Text("Desktop \(number)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .onSubmit { store.renameSpace(row(), to: name) }
                    // A plain field sizes itself for body text; without this a
                    // title-sized name is drawn half cut off.
                    .frame(maxWidth: 320, minHeight: 34)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Press Return to rename — rules and shortcuts naming it follow")
                Spacer()
                if engineRunning {
                    Button {
                        BarIPC.post("space focus \(number)")
                    } label: {
                        Label("Show Now", systemImage: "eye")
                    }
                    .weftGlassButton()
                    .help("Switch to this desktop")
                }
            }

            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    FieldTitle("Layout")
                    Picker("Layout", selection: Binding(
                        get: { layout },
                        set: { store.setLayout(row(), to: $0) }
                    )) {
                        Label("Tiling", systemImage: "rectangle.split.2x1").tag("bsp")
                        Label("Floating", systemImage: "square.on.square").tag("float")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    DesktopPreview(
                        layout: layout,
                        inner: store.innerGap,
                        outer: store.outerTop,
                        bordersOn: store.bordersEnabled,
                        border: store.bordersWidth,
                        corner: store.bordersStyle == "square" ? 0 : nil,
                        accent: Color(hex: store.bordersActiveColor) ?? .weft,
                        inactive: store.bordersShowInactive
                            ? (Color(hex: store.bordersInactiveColor) ?? Color.white.opacity(0.18)) : nil
                    )
                    .frame(width: 280, height: 170)
                }

                VStack(alignment: .leading, spacing: 16) {
                    AppsEditor(store: store, label: label, ensure: { _ = row() })
                    ShortcutsSummary(store: store, label: label, number: number)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .weftGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onChange(of: label) { _, new in name = new }
    }
}

private struct FieldTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// The apps a workspace receives when they open: `[[rule]] … space =`.
private struct AppsEditor: View {
    @ObservedObject var store: ConfigStore
    let label: String
    /// Make sure the desktop has a `[[space]]` row before a rule names it.
    var ensure: () -> Void = {}

    var body: some View {
        let apps = store.rules(for: label).map(AssignedApp.of)
        VStack(alignment: .leading, spacing: 8) {
            FieldTitle("Opens here")
            if apps.isEmpty {
                Text("Apps you add open on this desktop, wherever you are.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(apps) { app in
                HStack(spacing: 8) {
                    Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.unassign(app.id) }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop sending \(app.name) here")
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            Menu {
                let running = NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                    .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
                ForEach(running, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                        ensure()
                        store.assignApp(name: app.localizedName ?? "", bundleID: app.bundleIdentifier, to: label)
                    }
                }
                Divider()
                Button("Choose an App…") { chooseApp() }
            } label: {
                Label("Add App", systemImage: "plus.app")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .frame(maxWidth: 300, alignment: .leading)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ensure()
        let bundle = Bundle(url: url)
        store.assignApp(
            name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
            bundleID: bundle?.bundleIdentifier,
            to: label
        )
    }
}

private struct ShortcutsSummary: View {
    @ObservedObject var store: ConfigStore
    let label: String
    let number: Int

    var body: some View {
        let chords = store.chords(for: label, number: number)
        VStack(alignment: .leading, spacing: 8) {
            FieldTitle("Shortcuts")
            if chords.focus.isEmpty && chords.move.isEmpty {
                Text("None yet — add them under Shortcuts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let focus = chords.focus.first {
                HStack { KeyCaps(chord: focus); Text("go here").foregroundStyle(.secondary) }
            }
            if let move = chords.move.first {
                HStack { KeyCaps(chord: move); Text("send the window here").foregroundStyle(.secondary) }
            }
        }
        .font(.callout)
    }
}

// MARK: - Warnings, where they apply

/// What could make desktops behave other than this pane says, each with the
/// way to fix it (NATIVE.md, "Settings, Setup, bar").
private struct WorkspaceWarnings: View {
    @SwiftUI.State private var tiling = SystemChecks.macOSTilingEnabled()
    @SwiftUI.State private var stageManager = SystemChecks.stageManagerEnabled()
    @SwiftUI.State private var rearranges = SystemChecks.rearrangesSpacesByUse()
    @SwiftUI.State private var separate = SystemChecks.displaysHaveSeparateSpaces()
    @SwiftUI.State private var routes = NativeRoutesCache().load(build: NativeSelfTest.macOSBuild)

    var body: some View {
        let cannotMove = routes.map { $0[.move].state == .failed || $0[.symbols].state == .failed } ?? false
        let cannotSwitch = routes.map { $0[.switchDesktop].state == .failed && $0[.dockSwipe].state == .failed } ?? false
        let anything = rearranges || !separate || stageManager || !tiling.isEmpty || cannotMove || cannotSwitch
        if anything {
            VStack(alignment: .leading, spacing: 10) {
                if rearranges {
                    WarningRow(
                        symbol: "arrow.left.arrow.right", tint: .orange,
                        title: "macOS rearranges your desktops",
                        text: "“Automatically rearrange Spaces based on most recent use” is on, so desktop numbers — "
                            + "and ⌥1, ⌥2, … — change as you work. Turn it off in Desktop & Dock › Mission Control.",
                        action: ("Open Desktop & Dock", SystemChecks.desktopAndDockURL)
                    )
                }
                if cannotMove {
                    WarningRow(
                        symbol: "xmark.octagon", tint: .red,
                        title: "This macOS does not let weft move windows between desktops",
                        text: "Sending a window to a desktop and rules that place apps are off; tiling works. "
                            + "`weftctl doctor` says why.",
                        action: nil
                    )
                }
                if cannotSwitch {
                    WarningRow(
                        symbol: "xmark.octagon", tint: .red,
                        title: "This macOS does not let weft switch desktops",
                        text: "Use ⌃← and ⌃→, or swipe. `weftctl doctor` says why.",
                        action: nil
                    )
                }
                if !separate {
                    WarningRow(
                        symbol: "display.2", tint: .orange,
                        title: "“Displays have separate Spaces” is off",
                        text: "Your displays share one set of desktops. weft works, but each desktop spans every "
                            + "display. Turning it on needs a log out.",
                        action: ("Open Desktop & Dock", SystemChecks.desktopAndDockURL)
                    )
                }
                if stageManager {
                    WarningRow(
                        symbol: "rectangle.3.offgrid", tint: .orange,
                        title: "Stage Manager is on",
                        text: "It arranges the same windows weft does. Turn it off in Desktop & Dock.",
                        action: ("Open Desktop & Dock", SystemChecks.desktopAndDockURL)
                    )
                }
                if !tiling.isEmpty {
                    WarningRow(
                        symbol: "rectangle.split.2x1.slash", tint: .orange,
                        title: "macOS window tiling is on",
                        text: "Dragging a window to a screen edge makes macOS resize it and weft puts it back. "
                            + "Turn off: " + tiling.joined(separator: ", ") + ".",
                        action: ("Open Desktop & Dock", SystemChecks.desktopAndDockURL)
                    )
                }
            }
            .transition(.opacity)
        }
        EmptyView()
            .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
                // The same cadence the rest of the window already refreshes
                // at, and only while this pane is open.
                tiling = SystemChecks.macOSTilingEnabled()
                stageManager = SystemChecks.stageManagerEnabled()
                rearranges = SystemChecks.rearrangesSpacesByUse()
                separate = SystemChecks.displaysHaveSeparateSpaces()
                routes = NativeRoutesCache().load(build: NativeSelfTest.macOSBuild)
            }
    }
}

private struct WarningRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    let action: (String, String)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let action {
                Button(action.0) {
                    if let url = URL(string: action.1) { NSWorkspace.shared.open(url) }
                }
                .weftGlassButton()
            }
        }
        .padding(14)
        .weftGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
