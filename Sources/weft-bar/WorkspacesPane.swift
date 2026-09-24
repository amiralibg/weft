import AppKit
import SwiftUI
import WeftCore
import WeftIPC
import WeftPlatform

// The Workspaces pane: weft's workspaces drawn on this Mac's real displays.
//
// It is built around a picture because the model is about places — which
// display shows what, where the hidden windows go, which apps land where —
// and a list of rows could only describe that. Everything here edits the same
// `[[space]]` and `[[rule]]` blocks the file holds, through `ConfigStore`, so
// comments and anything the pane does not understand survive untouched.
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
    /// Global, top-left origin, in points.
    var frame: CGRect
    /// What `display = …` should say to mean this display: "main" for the
    /// main one, its name when no other display shares it, else its number.
    var pinValue: String
}

enum DisplayCatalog {
    static func current() -> [CanvasDisplay] {
        let identities = SpaceControl.displayIdentities()
        var nameCount: [String: Int] = [:]
        for i in identities { nameCount[i.name, default: 0] += 1 }
        return SpaceControl.displayLayout().enumerated().map { i, d in
            let identity = identities.first { $0.uuid == d.uuid }
            let name = identity?.name.isEmpty == false ? identity!.name : "Display \(i + 1)"
            let unique = nameCount[name] == 1
            return CanvasDisplay(
                id: d.uuid,
                index: i + 1,
                name: name,
                isMain: identity?.isMain ?? false,
                frame: CGRect(x: d.frame.x, y: d.frame.y, width: d.frame.width, height: d.frame.height),
                pinValue: identity?.isMain == true ? "main" : (unique ? name : "\(i + 1)")
            )
        }
    }

    /// Which connected display a `display = …` value means, resolved the way
    /// weftd resolves it.
    static func resolve(_ value: String, in displays: [CanvasDisplay]) -> CanvasDisplay? {
        guard !value.isEmpty else { return nil }
        let ids = displays.map { DisplayIdentity(uuid: $0.id, name: $0.name, isMain: $0.isMain) }
        let uuid = resolvePin(DisplayPin(value), among: ids)
        return displays.first { $0.id == uuid }
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
    @SwiftUI.State private var selection: SpaceRow.ID?
    @Namespace private var cards

    private var spring: Animation { .spring(response: 0.38, dampingFraction: 0.82) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                DisplayCanvas(
                    displays: displays,
                    spaces: store.spaces,
                    status: health.workspaces,
                    running: health.running,
                    onPin: { label, display in pin(label, to: display) }
                )
                .frame(height: 250)

                cardsSection

                if let id = selection, let index = store.spaces.firstIndex(where: { $0.id == id }) {
                    WorkspaceInspector(
                        store: store,
                        row: store.spaces[index],
                        number: index + 1,
                        displays: displays,
                        engineRunning: health.running,
                        onRemove: {
                            withAnimation(spring) {
                                selection = nil
                                store.removeSpace(id)
                            }
                        }
                    )
                    .id(id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                WorkspaceWarnings(displays: displays, status: health.workspaces)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .animation(spring, value: store.spaces)
        .animation(spring, value: selection)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in
            withAnimation(spring) { displays = DisplayCatalog.current() }
        }
        .onAppear {
            if selection == nil { selection = store.spaces.first?.id }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Workspaces").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Instant, on every window, with System Integrity Protection left alone. "
                    + "Drag a workspace onto a display to keep it there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(spring) {
                    store.addSpace()
                    selection = store.spaces.last?.id
                }
            } label: {
                Label("Add Workspace", systemImage: "plus")
            }
            .weftProminentButton()
        }
    }

    private var cardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("In order").font(.headline)
                Text("— ⌥1, ⌥2, … count in this order. Drag to reorder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if store.spaces.isEmpty {
                EmptyState(
                    symbol: "rectangle.3.group",
                    title: "Numbered workspaces",
                    text: "With none named, ⌥1…⌥9 go to workspaces 1–9, each created the first "
                        + "time you use it. Add one to give it a name, a layout, a display and apps."
                )
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 176), spacing: 12)], spacing: 12) {
                    ForEach(Array(store.spaces.enumerated()), id: \.element.id) { index, row in
                        card(row, number: index + 1)
                    }
                }
            }
        }
    }

    private func card(_ row: SpaceRow, number: Int) -> some View {
        let live = health.liveWorkspaces.first { $0.label == row.label }
        return WorkspaceCard(
            number: number,
            row: row,
            apps: store.rules(for: row.label).map(AssignedApp.of),
            pinnedTo: DisplayCatalog.resolve(row.display, in: displays)?.name
                ?? (row.display.isEmpty ? nil : "\(row.display) (not connected)"),
            showing: live?.current ?? false,
            windows: live?.windows.count ?? 0,
            selected: selection == row.id
        )
        .matchedGeometryEffect(id: row.id, in: cards)
        .onTapGesture {
            withAnimation(spring) { selection = selection == row.id ? nil : row.id }
        }
        .draggable(row.label)
        .dropDestination(for: String.self) { labels, _ in
            guard let label = labels.first,
                  let moving = store.spaces.first(where: { $0.label == label })
            else { return false }
            withAnimation(spring) { store.moveSpace(moving.id, before: row.id) }
            return true
        }
    }

    private func pin(_ label: String, to display: CanvasDisplay) {
        guard let row = store.spaces.first(where: { $0.label == label }) else { return }
        withAnimation(spring) {
            store.pinSpace(row.id, to: display.pinValue)
            selection = row.id
        }
    }
}

// MARK: - The display map

/// The displays as they are arranged, to scale, each showing the workspace
/// on it now and the ones pinned to it. A drop target: a workspace dropped
/// on a display is pinned there.
private struct DisplayCanvas: View {
    let displays: [CanvasDisplay]
    let spaces: [SpaceRow]
    let status: WorkspacesStatus?
    let running: Bool
    let onPin: (String, CanvasDisplay) -> Void

    private func tile(_ d: CanvasDisplay) -> DisplayTile {
        let pinned: [String] = spaces
            .filter { DisplayCatalog.resolve($0.display, in: displays)?.id == d.id }
            .map(\.label)
        return DisplayTile(
            display: d,
            live: status?.displays.first { $0.uuid == d.id },
            pinned: pinned,
            multiple: displays.count > 1,
            running: running,
            onPin: { onPin($0, d) }
        )
    }

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
                    tile(d)
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
        .accessibilityLabel("Your displays, arranged as they are")
    }
}

private struct DisplayTile: View {
    let display: CanvasDisplay
    let live: WorkspacesStatus.Display?
    let pinned: [String]
    let multiple: Bool
    let running: Bool
    let onPin: (String) -> Void
    @SwiftUI.State private var targeted = false
    @SwiftUI.State private var hovering = false

    private var corner: Corner? { live?.parkCorner.flatMap(Corner.init(rawValue:)) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            Wallpaper()
            // Two tiles, faintly: a desktop, not an empty rectangle.
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.12))
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.10))
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.08))
                }
            }
            .padding(EdgeInsets(top: 13, leading: 6, bottom: 6, trailing: 6))
            VStack(spacing: 0) {
                Rectangle().fill(Color.black.opacity(0.3)).frame(height: 7)
                Spacer(minLength: 0)
            }
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                if let showing = live?.showing, running {
                    Text(showing)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.opacity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.black.opacity(0.28)))
                }
                if !pinned.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "pin.fill").font(.system(size: 8))
                        Text(pinned.joined(separator: " · ")).lineLimit(1)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            VStack {
                HStack {
                    Text(display.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.25)))
                    Spacer(minLength: 0)
                    if live?.paused == true {
                        Label("Paused", systemImage: "pause.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.35)))
                            .help("Another macOS desktop or a fullscreen app is showing here. weft picks up again when you come back.")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 11)
            .padding(.horizontal, 7)
            if let corner {
                ParkMarker(corner: corner)
            } else if multiple, live != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .padding(6)
                            .help("Every corner of this display touches another one. Its hidden windows are parked at another display's corner.")
                    }
                }
            }
        }
        .clipShape(shape)
        .overlay(
            shape.stroke(
                targeted ? Color.weft : Color.white.opacity(hovering ? 0.35 : 0.16),
                lineWidth: targeted ? 3 : 1
            )
        )
        .shadow(color: .black.opacity(targeted ? 0.35 : 0.18), radius: targeted ? 14 : 6, y: 3)
        .scaleEffect(targeted ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: targeted)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .dropDestination(for: String.self) { labels, _ in
            guard let label = labels.first else { return false }
            onPin(label)
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityLabel("\(display.name)\(live?.showing.map { ", showing \($0)" } ?? "")")
    }
}

/// A small triangle in the corner where this display's hidden windows go.
private struct ParkMarker: View {
    let corner: Corner

    var body: some View {
        let top = corner == .topLeft || corner == .topRight
        let left = corner == .topLeft || corner == .bottomLeft
        VStack {
            if !top { Spacer() }
            HStack {
                if !left { Spacer() }
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(5)
                    .help("Hidden windows wait in this corner")
                if left { Spacer() }
            }
            if top { Spacer() }
        }
    }
}

// MARK: - A workspace, as a card

private struct WorkspaceCard: View {
    let number: Int
    let row: SpaceRow
    let apps: [AssignedApp]
    let pinnedTo: String?
    let showing: Bool
    let windows: Int
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
                Text(row.label.isEmpty ? "Untitled" : row.label)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: row.layout == "float" ? "square.on.square" : "rectangle.split.2x1")
                    .foregroundStyle(.secondary)
                    .help(row.layout == "float" ? "Floating" : "Tiling")
            }
            HStack(spacing: -7) {
                ForEach(apps.prefix(5)) { app in
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
                        .help(app.name)
                }
                if apps.count > 5 {
                    Text("+\(apps.count - 5)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }
                if apps.isEmpty {
                    Text("No apps")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if windows > 0 {
                    Text("\(windows) open")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .frame(height: 24)
            if let pinnedTo {
                Label(pinnedTo, systemImage: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .weftGlass(shape, tint: selected ? Color.weft.opacity(0.16) : nil, interactive: true)
        .overlay {
            if showing {
                shape.stroke(Color.weft, lineWidth: 2)
                    .shadow(color: Color.weft.opacity(0.6), radius: 6)
                    .phaseAnimator([0.55, 1.0]) { view, phase in
                        view.opacity(phase)
                    } animation: { _ in .easeInOut(duration: 1.4) }
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
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(showing ? "Showing now" : "")
    }
}

// MARK: - Inspector

private struct WorkspaceInspector: View {
    @ObservedObject var store: ConfigStore
    let row: SpaceRow
    let number: Int
    let displays: [CanvasDisplay]
    let engineRunning: Bool
    let onRemove: () -> Void
    @SwiftUI.State private var name: String

    init(
        store: ConfigStore, row: SpaceRow, number: Int, displays: [CanvasDisplay],
        engineRunning: Bool, onRemove: @escaping () -> Void
    ) {
        self.store = store
        self.row = row
        self.number = number
        self.displays = displays
        self.engineRunning = engineRunning
        self.onRemove = onRemove
        _name = State(initialValue: row.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .onSubmit { store.renameSpace(row.id, to: name) }
                    // A plain field sizes itself for body text; without this a
                    // title-sized name is drawn half cut off.
                    .frame(maxWidth: 320, minHeight: 34)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Press Return to rename — rules and shortcuts naming it follow")
                Spacer()
                if engineRunning {
                    Button {
                        BarIPC.post("space focus \(row.label)")
                    } label: {
                        Label("Show Now", systemImage: "eye")
                    }
                    .weftGlassButton()
                    .help("Switch to this workspace")
                }
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .weftGlassButton()
                .help("Remove this workspace. Windows in it stay open and join the one showing.")
            }

            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    FieldTitle("Layout")
                    Picker("Layout", selection: Binding(
                        get: { row.layout },
                        set: { store.setLayout(row.id, to: $0) }
                    )) {
                        Label("Tiling", systemImage: "rectangle.split.2x1").tag("bsp")
                        Label("Floating", systemImage: "square.on.square").tag("float")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    DesktopPreview(
                        layout: row.layout,
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
                    VStack(alignment: .leading, spacing: 8) {
                        FieldTitle("Display")
                        Picker("Display", selection: Binding(
                            get: { row.display },
                            set: { store.pinSpace(row.id, to: $0) }
                        )) {
                            Text("Whichever display I'm on").tag("")
                            ForEach(displays) { d in
                                Text(d.isMain ? "\(d.name) (main)" : d.name).tag(d.pinValue)
                            }
                            if !row.display.isEmpty, !displays.contains(where: { $0.pinValue == row.display }) {
                                Text("\(row.display) (as written)").tag(row.display)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }

                    AppsEditor(store: store, label: row.label)

                    ShortcutsSummary(store: store, label: row.label, number: number)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .weftGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onChange(of: row.label) { _, new in name = new }
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

    var body: some View {
        let apps = store.rules(for: label).map(AssignedApp.of)
        VStack(alignment: .leading, spacing: 8) {
            FieldTitle("Opens here")
            if apps.isEmpty {
                Text("Apps you add open in this workspace, wherever you are.")
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

private struct WorkspaceWarnings: View {
    let displays: [CanvasDisplay]
    let status: WorkspacesStatus?
    @SwiftUI.State private var tiling = SystemChecks.macOSTilingEnabled()
    @SwiftUI.State private var stageManager = SystemChecks.stageManagerEnabled()

    var body: some View {
        let extra = status?.displaysWithExtraDesktops ?? []
        let boxedIn = displays.count > 1
            ? (status?.displays.filter { $0.parkCorner == nil } ?? []) : []
        let anything = !extra.isEmpty || !boxedIn.isEmpty || !tiling.isEmpty || stageManager
        if anything {
            VStack(alignment: .leading, spacing: 10) {
                Text("Worth knowing").font(.headline)
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
                ForEach(extra, id: \.uuid) { d in
                    WarningRow(
                        symbol: "square.stack.3d.up", tint: .secondary,
                        title: "\(d.name ?? "Display \(d.index)") has \(d.desktops) macOS desktops",
                        text: "That is fine: weft works on desktop \(d.managedDesktop ?? 1) and pauses while another "
                            + "one is showing. Remove the others in Mission Control to keep every window managed.",
                        action: nil
                    )
                }
                ForEach(boxedIn, id: \.uuid) { d in
                    WarningRow(
                        symbol: "exclamationmark.triangle", tint: .orange,
                        title: "\(d.name ?? "Display \(d.index)") has no free corner",
                        text: "Every corner touches another display, so its hidden windows wait at another "
                            + "display's corner. Arranging the displays so one corner is clear avoids that.",
                        action: nil
                    )
                }
            }
            .transition(.opacity)
            .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
                // The same cadence the rest of the window already refreshes
                // at, and only while this pane is open.
                tiling = SystemChecks.macOSTilingEnabled()
                stageManager = SystemChecks.stageManagerEnabled()
            }
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
