#if DEBUG
import AppKit
import SwiftUI
import WeftBarConfig

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
            // The shortcut builder: a new shortcut, which opens on the list of
            // everything a shortcut can do, and one with two steps.
            let context = ShortcutContext(
                workspaces: store.spaces.map(\.label), modes: ["resize"], displays: DisplayCatalog.current()
            )
            render(
                ShortcutEditor(row: nil, isModeLayer: false, context: context, others: [],
                               onSave: { _, _ in }, onDelete: nil, onCancel: {}),
                size: CGSize(width: 620, height: ShortcutEditor.height), appearance: appearance,
                to: dir.appendingPathComponent("shortcut-new-\(tag).png")
            )
            render(
                ShortcutEditor(
                    row: KeyRow(chord: "alt-shift-m", steps: ["space move-window 3", "app toggle com.apple.mail"]),
                    isModeLayer: false, context: context,
                    others: [KeyRow(chord: "alt-shift-m", steps: ["stack all"])],
                    onSave: { _, _ in }, onDelete: {}, onCancel: {}
                ),
                size: CGSize(width: 620, height: ShortcutEditor.height), appearance: appearance,
                to: dir.appendingPathComponent("shortcut-edit-\(tag).png")
            )
            // Setup is dark either way; once is enough.
            if appearance == .darkAqua {
                for page in [SetupModel.Page.install, .welcome, .workspacesIntro, .keys, .permissions, .done] {
                    let model = SetupModel()
                    model.page = page
                    render(
                        SetupView(model: model) {},
                        size: SetupView.size,
                        appearance: appearance,
                        // Long enough for every headline and card to arrive.
                        settleFor: 2.4,
                        to: dir.appendingPathComponent("setup-\(page).png")
                    )
                }
            }
        }
        exit(0)
    }

    /// `weft-bar --preview-setup`: Setup on screen, on its own, walking
    /// through every page a few seconds apart and then quitting. For watching
    /// what a still cannot show — the stage's motion between pages — without
    /// starting a second WeftBar: no menu-bar item, no hotkeys, no engine.
    /// Prints the window number, so `screencapture -l` can film it.
    static func previewSetup() -> Never {
        let model = SetupModel()
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: SetupView.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: SetupView(model: model) {})
        window.center()
        window.orderFrontRegardless()
        print("window \(window.windowNumber)")
        fflush(stdout)
        // Under the real event loop, not `settle`: window occlusion — what
        // the stage's animations start and stop on — only arrives through it.
        for (index, page) in SetupModel.Page.steps.dropFirst().enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + 3 * Double(index)) {
                print("page \(page)")
                fflush(stdout)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { model.page = page }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + 3 * Double(SetupModel.Page.steps.count - 1)) {
            exit(0)
        }
        NSApplication.shared.run()
        exit(0)
    }

    private static func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func render<V: View>(
        _ view: V, size: CGSize, appearance: NSAppearance.Name, settleFor seconds: TimeInterval = 0.9, to url: URL
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
        settle(seconds)
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
