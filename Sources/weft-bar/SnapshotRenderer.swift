#if DEBUG
import AppKit
import SwiftUI

/// `weft-bar --render-snapshots <dir>`: draw every Settings pane and Setup
/// page to PNG, in light and dark, and exit. For looking at the windows while
/// changing them without launching the app for real — it creates no menu-bar
/// item, starts nothing, installs nothing, and writes nothing but the images.
/// Debug builds only.
@MainActor
enum SnapshotRenderer {
    static func run(into directory: String) -> Never {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConfigStore()
        store.load()
        let health = EngineHealth()
        health.refresh()
        settle(1.0)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let tag = appearance == .aqua ? "light" : "dark"
            for section in SettingsSection.allCases {
                render(
                    SettingsView(store: store, health: health, section: section),
                    size: CGSize(width: 980, height: 720),
                    appearance: appearance,
                    to: dir.appendingPathComponent("settings-\(section.rawValue)-\(tag).png")
                )
            }
            // Tall enough to show the whole Workspaces pane, inspector and all.
            render(
                SettingsView(store: store, health: health, section: .workspaces),
                size: CGSize(width: 980, height: 1500),
                appearance: appearance,
                to: dir.appendingPathComponent("settings-workspaces-tall-\(tag).png")
            )
            for page in [SetupModel.Page.welcome, .workspacesIntro, .permissions, .done] {
                let model = SetupModel()
                model.page = page
                render(
                    SetupView(model: model) {},
                    size: CGSize(width: 700, height: 660),
                    appearance: appearance,
                    to: dir.appendingPathComponent("setup-\(page)-\(tag).png")
                )
            }
        }
        exit(0)
    }

    private static func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func render<V: View>(
        _ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL
    ) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        // Far off every display, so nothing is seen and nothing is tiled.
        let window = NSWindow(
            contentRect: CGRect(x: -30000, y: -30000, width: size.width, height: size.height),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        settle(0.9)
        // Composited by the WindowServer, so SwiftUI's own layers, materials
        // and glass are all in it — `cacheDisplay` captures only the
        // AppKit-drawn half of a SwiftUI view.
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
        try? shot.run()
        shot.waitUntilExit()
        window.orderOut(nil)
    }
}
#endif
