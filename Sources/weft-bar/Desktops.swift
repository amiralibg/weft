import AppKit
import SwiftUI
import WeftCore
import WeftPlatform

// Your macOS desktops, as Settings and Setup draw them: read straight from the
// WindowServer, so they show whether or not the engine is running, and
// numbered the way weft numbers them (docs/NATIVE.md) — the main display's
// desktops first, then each other display west to east, fullscreen spaces
// skipped.

/// One space on a display, in Mission Control's order.
struct CanvasDesktop: Identifiable, Equatable {
    var id: SpaceID
    /// The desktop's global number; nil for a fullscreen or Split View space,
    /// which is not a workspace.
    var number: Int?
    /// Showing on its display now.
    var current: Bool
    var fullscreen: Bool { number == nil }
}

enum Desktops {
    /// Each display's spaces, by display uuid. With "Displays have separate
    /// Spaces" off macOS reports one display, "Main"; it is drawn on the main
    /// display.
    static func current() -> [String: [CanvasDesktop]] {
        let topology = SpaceControl.topology()
        let layout = SpaceControl.displayLayout()
        let main = SpaceControl.mainDisplayUUID()
        func uuid(_ reported: String) -> String {
            layout.contains { $0.uuid == reported } ? reported : (main ?? reported)
        }
        let reported = topology.map { d in
            DisplayDesktops(
                uuid: uuid(d.uuid),
                desktops: d.spaces.filter { !$0.fullscreen }.map(\.id),
                current: d.current,
                isMain: uuid(d.uuid) == main,
                originX: layout.first { $0.uuid == uuid(d.uuid) }?.frame.x ?? 0
            )
        }
        var numbers: [SpaceID: Int] = [:]
        for sid in numberingOrder(reported).flatMap(\.desktops) { numbers[sid] = numbers.count + 1 }
        var out: [String: [CanvasDesktop]] = [:]
        for d in topology {
            out[uuid(d.uuid), default: []] += d.spaces.map {
                CanvasDesktop(id: $0.id, number: $0.fullscreen ? nil : numbers[$0.id], current: $0.id == d.current)
            }
        }
        return out
    }

    /// How many desktops there are, fullscreen spaces not counted.
    static var count: Int { current().values.flatMap { $0 }.filter { !$0.fullscreen }.count }

    /// Where desktops are added, removed and reordered — weft cannot do it.
    static func openMissionControl() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The apps with windows open on a desktop, for its card: one icon per app.
enum LiveApps {
    struct App: Identifiable {
        var id: pid_t
        var name: String
        var icon: NSImage
    }

    @MainActor static func icons(for windows: [WindowID]) -> [App] {
        guard !windows.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let wanted = Set(windows)
        var seen = Set<pid_t>()
        var out: [App] = []
        for w in info {
            guard let n = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value, wanted.contains(n),
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, seen.insert(pid).inserted,
                  let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon
            else { continue }
            out.append(App(id: pid, name: app.localizedName ?? "App", icon: icon))
        }
        return out
    }
}

/// The end of Setup: how many desktops there are, that each is a workspace,
/// and whether macOS will reorder them (NATIVE.md, "Settings, Setup, bar").
/// Never blocks: weft cannot create desktops, so it only says how to add them.
struct DesktopCountCard: View {
    @SwiftUI.State private var count = Desktops.count
    @SwiftUI.State private var rearranges = SystemChecks.rearrangesSpacesByUse()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.weft)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(count == 1 ? "You have 1 desktop" : "You have \(count) desktops")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Each one is a workspace: ⌥1 to ⌥\(max(min(count, 9), 1)). Want more? Add them in "
                        + "Mission Control — weft picks them up straight away.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Open Mission Control") { Desktops.openMissionControl() }
                    .weftGlassButton()
            }
            if rearranges {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("macOS reorders desktops by recent use").font(.system(size: 13, weight: .semibold))
                        Text("Then ⌥3 is not always the same desktop. Turn off “Automatically rearrange Spaces "
                            + "based on most recent use” in Desktop & Dock › Mission Control.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button("Open Desktop & Dock") {
                        if let url = URL(string: SystemChecks.desktopAndDockURL) { NSWorkspace.shared.open(url) }
                    }
                    .weftGlassButton()
                }
            }
        }
        .padding(16)
        .weftGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)) { _ in
            count = Desktops.count
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            count = Desktops.count
            rearranges = SystemChecks.rearrangesSpacesByUse()
        }
    }
}
