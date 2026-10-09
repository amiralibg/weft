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
        // A pattern reads as the app it names: "^Happ$" is Happ.
        let plain = name.split(separator: "|").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "^$ ")).replacingOccurrences(of: "\\", with: "")
        }.joined(separator: " or ")
        return AssignedApp(id: rule.id, name: plain, icon: icon)
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
    // Read on appearing and on change, never in the initialisers: SwiftUI
    // evaluates those each time the window redraws, and these ask the
    // WindowServer.
    @SwiftUI.State private var displays: [CanvasDisplay] = []
    @SwiftUI.State private var desktops: [String: [CanvasDesktop]] = [:]
    /// Each desktop's apps, read when the engine reports a change.
    @SwiftUI.State private var apps: [SpaceID: [LiveApps.App]] = [:]
    /// The desktop number the inspector shows.
    @SwiftUI.State private var selection: Int?
    /// Counts cards picked by hand.
    @SwiftUI.State private var picked = 0

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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    WorkspaceWarnings()
                    DisplayCanvas(displays: displays, desktops: desktops, label: label(of:))
                        .frame(height: 170)

                    ForEach(numbered) { display in
                        displaySection(display)
                    }

                    if let n = selection, n <= desktopCount {
                        // One place for the scroll to land; the inspector
                        // inside crossfades from one desktop to the next.
                        ZStack {
                            WorkspaceInspector(
                                store: store,
                                number: n,
                                label: label(of: n),
                                engineRunning: health.running
                            )
                            .id(n)
                            .transition(.opacity)
                        }
                        .id(Self.inspectorAnchor)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                    }

                    waitingSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // Only when a card is picked: opening the pane selects desktop 1
            // and must not scroll.
            .onChange(of: picked) { _, _ in
                guard selection != nil else { return }
                withAnimation(.chrome) { proxy.scrollTo(Self.inspectorAnchor) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            withAnimation(.chrome) {
                displays = DisplayCatalog.current()
                desktops = Desktops.current()
            }
        }
        // Switching, adding or removing a desktop in Mission Control.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)) { _ in
            withAnimation(.chrome) { desktops = Desktops.current() }
        }
        .onChange(of: health.liveWorkspaces) { _, live in
            desktops = Desktops.current()
            apps = LiveApps.byDesktop(live)
        }
        .onAppear {
            displays = DisplayCatalog.current()
            desktops = Desktops.current()
            apps = LiveApps.byDesktop(health.liveWorkspaces)
            if selection == nil { selection = desktopCount > 0 ? 1 : nil }
        }
    }

    /// What the scroll lands on when a card is picked: the inspector, which
    /// sits below the cards and was easy to miss.
    static let inspectorAnchor = "inspector"

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("Each workspace is one of your macOS desktops, numbered as Mission Control shows them. "
                + "Add, remove and reorder desktops in Mission Control — weft follows.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                Desktops.openMissionControl()
            } label: {
                Label("Mission Control", systemImage: "rectangle.3.group")
            }
            .weftGlassButton()
            .help("Add, remove and reorder desktops")
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 10)], spacing: 10) {
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
        let name = label(of: n)
        return DesktopCard(
            number: n,
            label: name,
            chord: store.chords(for: name, number: n).focus.first,
            layout: layout(of: n),
            apps: apps[desktop.id] ?? [],
            showing: desktop.current,
            selected: selection == n
        )
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
        .onTapGesture { select(n) }
        // A tap gesture is invisible to VoiceOver and Full Keyboard Access:
        // without these a card could be read but never opened.
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select(n) }
        .help(health.running ? "Click to edit, double-click to switch to it" : "Click to edit")
    }

    private func select(_ n: Int) {
        withAnimation(.chrome) { selection = selection == n ? nil : n }
        picked += 1
    }

    /// Labels in weft.toml past the last desktop: they wait for one. Small,
    /// because they are leftovers more often than plans.
    @ViewBuilder private var waitingSection: some View {
        let waiting = Array(store.spaces.enumerated()).filter { $0.offset >= desktopCount }
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Labels with no desktop yet").font(.headline)
                    Text("Each gets the next desktop you add in Mission Control. Remove the ones you don't need.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(waiting, id: \.element.id) { index, row in
                        WaitingChip(number: index + 1, label: row.label.isEmpty ? "\(index + 1)" : row.label) {
                            withAnimation(.chrome) { store.removeSpace(row.id) }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
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
    /// The shortcut that goes here, if weft.toml has one.
    let chord: String?
    let layout: String
    let apps: [LiveApps.App]
    let showing: Bool
    let selected: Bool
    @SwiftUI.State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(chord.map { ChordNaming.caps(for: $0).joined() } ?? "\(number)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(selected ? .white : Color.weft)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(selected ? Color.weft : Color.weft.opacity(0.14)))
                    .help(chord == nil ? "Desktop \(number) — no shortcut goes here" : "Desktop \(number)")
                Text(label)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if showing {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .help("Showing now")
                }
                Image(systemName: layout == "float" ? "square.on.square" : "rectangle.split.2x1")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help(layout == "float" ? "Floating" : "Tiling")
            }
            HStack(spacing: -6) {
                ForEach(apps.prefix(6)) { app in
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 22, height: 22)
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
            .frame(height: 22)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        // Flat fills, not glass: a grid of glass cards in a scroll view was
        // composited again on every frame of every scroll and hover.
        .background(shape.fill(fill))
        .overlay(shape.strokeBorder(stroke, lineWidth: selected ? 1.5 : 1))
        .contentShape(shape)
        .animation(.hover, value: hovering)
        .animation(.chrome, value: selected)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Desktop \(number), \(label)\(showing ? ", showing" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fill: Color {
        if selected { return Color.weft.opacity(0.16) }
        return Color.primary.opacity(hovering ? 0.08 : 0.045)
    }

    private var stroke: Color {
        selected ? Color.weft.opacity(0.8) : Color.primary.opacity(hovering ? 0.14 : 0.08)
    }
}

/// A fullscreen or Split View space: drawn where Mission Control has it,
/// greyed, with no number, because it is not a workspace.
private struct FullscreenCard: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
            Text("Fullscreen app").font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.tertiary)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .background(shape.fill(Color.primary.opacity(0.03)))
        .overlay(shape.stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .help("A fullscreen app's space. It has no number and weft does not tile it.")
    }
}

/// A label in weft.toml with no desktop at its number yet.
private struct WaitingChip: View {
    let number: Int
    let label: String
    let onRemove: () -> Void
    @SwiftUI.State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovering ? .primary : .tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove the label “\(label)”")
            .accessibilityLabel("Remove \(label)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(Capsule().fill(Color.primary.opacity(hovering ? 0.07 : 0.04)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .onHover { hovering = $0 }
        .animation(.hover, value: hovering)
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

            // Side by side when there is room, stacked when the window is
            // narrow: side by side only, it made the pane wider than the
            // window and cut the cards off at both edges.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 22) {
                    layoutColumn
                    editors
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 18) {
                    layoutColumn
                    editors
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08))
        )
        .onChange(of: label) { _, new in name = new }
    }

    private var layoutColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldTitle("Layout")
            Picker("Layout", selection: Binding(
                get: { layout },
                set: { new in withAnimation(.tile) { store.setLayout(row(), to: new) } }
            )) {
                Label("Tiling", systemImage: "rectangle.split.2x1").tag("bsp")
                Label("Floating", systemImage: "square.on.square").tag("float")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
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
            .frame(width: 260, height: 158)
        }
    }

    private var editors: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppsEditor(store: store, label: label, ensure: { _ = row() })
            ShortcutsSummary(store: store, label: label, number: number)
        }
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
    // Read on appearing and every few seconds, not in the initialisers,
    // which SwiftUI evaluates each time the window redraws.
    @SwiftUI.State private var tiling: [String] = []
    @SwiftUI.State private var stageManager = false
    @SwiftUI.State private var rearranges = false
    @SwiftUI.State private var separate = true
    @SwiftUI.State private var routes: NativeRoutes?

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
            .onAppear(perform: read)
            // The same cadence the rest of the window already refreshes at,
            // and only while this pane is open.
            .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in read() }
    }

    private func read() {
        let next = (
            SystemChecks.macOSTilingEnabled(), SystemChecks.stageManagerEnabled(),
            SystemChecks.rearrangesSpacesByUse(), SystemChecks.displaysHaveSeparateSpaces()
        )
        withAnimation(.chrome) {
            if tiling != next.0 { tiling = next.0 }
            if stageManager != next.1 { stageManager = next.1 }
            if rearranges != next.2 { rearranges = next.2 }
            if separate != next.3 { separate = next.3 }
        }
        routes = NativeRoutesCache().load(build: NativeSelfTest.macOSBuild)
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
