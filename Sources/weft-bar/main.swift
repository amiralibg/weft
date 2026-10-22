import WeftCore
import AppKit
import WeftPlatform
import WeftIPC
import Carbon.HIToolbox
import Foundation

// The socket's shapes come from WeftIPC, which is also what weftd encodes
// from. They used to be redeclared here, field for field, with `id` as UInt64
// and `windows` as [Int] — a separate spelling of the same wire that decoded
// happily whatever the daemon had started meaning by those numbers.

/// A desktop's row in the menu: a standard item, so it gets the system's
/// highlight, keyboard navigation and VoiceOver. It used to be a hand-drawn
/// view, which drew its own highlight, a "BSP" badge on every row, and was
/// one more thing to keep in step with how macOS draws menus.
@MainActor
enum DesktopMenuRow {
    /// `ordinal` is what `space focus N` counts.
    static func make(_ space: SpaceStatus, ordinal: Int, icons: [NSImage], target: AnyObject, action: Selector) -> NSMenuItem {
        let name = space.label.isEmpty ? "Desktop \(ordinal)" : space.label
        let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
        item.target = target
        item.tag = ordinal
        item.image = badge(ordinal, showing: space.current)

        let title = NSMutableAttributedString(
            string: name,
            attributes: [.font: space.current ? NSFont.menuFont(ofSize: 0).bold : NSFont.menuFont(ofSize: 0)]
        )
        if space.layout == "float" {
            title.append(NSAttributedString(
                string: "  floating",
                attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        // The apps on it, right-aligned: one tab to a right tab stop.
        if !icons.isEmpty {
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .right, location: 250)]
            title.append(NSAttributedString(string: "\t"))
            for icon in icons.prefix(5) {
                let attachment = NSTextAttachment()
                attachment.image = icon
                attachment.bounds = NSRect(x: 0, y: -4, width: 18, height: 18)
                title.append(NSAttributedString(attachment: attachment))
                title.append(NSAttributedString(string: " "))
            }
            title.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: title.length))
        }
        item.attributedTitle = title

        let count = space.windows.count
        item.setAccessibilityLabel(
            "Desktop \(ordinal), \(name)" + (space.current ? ", showing" : "")
                + ", \(count == 0 ? "empty" : count == 1 ? "1 window" : "\(count) windows")"
        )
        return item
    }

    /// The desktop's number on a rounded tile: the accent colour when it is
    /// the one showing on its display. Drawn per appearance.
    private static func badge(_ n: Int, showing: Bool) -> NSImage {
        let text = "\(n)" as NSString
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let width = max(18, ceil(text.size(withAttributes: [.font: font]).width) + 8)
        let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { rect in
            (showing ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
            return true
        }
        image.isTemplate = false
        return image
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let state = BarState()
    private let switcher = WindowSwitcher()
    /// The newest release the launch-time check found, if it found one.
    private var latestUpdate: UpdateCheck.Result?
    /// `check-for-updates`, as of the last check. Gates the cache read on the
    /// menu path: turning checking off has to stop the row appearing, and a
    /// cached answer from before it was turned off would otherwise outlive it.
    private var updatesEnabled = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // The status item redraws from a cached snapshot; nothing on this
        // thread ever waits for the daemon to answer.
        state.onChange = { [weak self] in self?.updateTitle() }
        state.onCommandFailed = { command, message in
            Toast.shared.show(Toast.headline(for: command), message)
        }
        state.start()
        updateTitle()
        FocusSinkWindow.shared.install()

        // Quit Weft stopped the engine; opening WeftBar is how it comes back.
        Task { @MainActor in
            await Task.detached { EngineService.startIfStopped() }.value
            self.state.refresh()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        // Install keybindings via Carbon HotKeyManager
        installKeybindings()

        checkForUpdate()

        // `open -a WeftBar --args --settings` / `--setup`. The menu-bar icon
        // is the normal way in, but a support answer that begins "click the
        // icon, then…" is not one you can paste into a terminal.
        let args = CommandLine.arguments
        if args.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                ConfigEditorWindowController.shared.show()
            }
            return
        }
        if args.contains("--cheatsheet") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                CheatsheetWindowController.shared.show()
            }
            return
        }
        if args.contains("--setup") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                OnboardingWindowController.shared.show()
            }
            return
        }

        // First-run gate: permissions until onboarded, then stay quiet.
        // Async because the decision needs an answer from weftd, and at login
        // weftd may still be starting — blocking the main thread on that gave
        // a menu bar that appears late, and giving up on it gave a Setup
        // window that reappears forever.
        Task { @MainActor in
            // The engine this app carries goes in first. A fresh machine has
            // no weftd to grant anything to, and an app that was updated by
            // replacing it is running against an older engine until it does.
            let needsInstall = await Task.detached { EngineInstaller.needsInstall() }.value
            if needsInstall {
                let installed = FileManager.default.isExecutableFile(
                    atPath: EngineInstaller.binDir.appendingPathComponent("weftctl").path
                )
                guard installed else {
                    // First run: say what is about to happen and let them
                    // press the button — it starts a login service and pauses
                    // yabai/skhd, which is not something to do unannounced.
                    OnboardingWindowController.shared.showInstall()
                    return
                }
                // An update. Replacing the app *was* the decision; catching
                // the engine up is not worth a question. Only a failure is.
                let outcome = await EngineInstaller.install(step: { _ in })
                self.state.refresh()
                guard outcome.ok else {
                    OnboardingWindowController.shared.showInstall()
                    return
                }
            }
            guard await OnboardingWindowController.shouldShow() else { return }
            OnboardingWindowController.shared.show()
        }
    }

    private func installKeybindings() {
        // 1. Install ⌃⌥Space window switcher
        HotKeyManager.shared.register(keyString: "ctrl-alt-space") { [weak self] in
            self?.switcher.toggle()
        }

        // 2. Load and register keybindings from ~/.config/weft/weft.toml
        let path = ("~/.config/weft/weft.toml" as NSString).expandingTildeInPath
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        var inKeys = false
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.starts(with: "[keys]") {
                inKeys = true; continue
            } else if line.starts(with: "[") {
                inKeys = false; continue
            }

            if inKeys, line.contains("=") {
                let parts = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\"")))
                }
                if parts.count == 2 {
                    let chord = parts[0]
                    let cmd = parts[1]
                    // Off the main thread: these are a fallback for when
                    // weftd's own event tap is not up, and a keypress that
                    // blocks the UI thread on a socket is worse than one that
                    // does nothing.
                    HotKeyManager.shared.register(keyString: chord) {
                        BarIPC.post(cmd)
                    }
                }
            }
        }
    }

    /// Menu-bar glyph for the current layout. SF Symbols rather than the box
    /// characters this used ("⊞ term"): those render at whatever weight and
    /// baseline the user's menu-bar font happens to give them, next to real
    /// icons from every other item. A template symbol inverts correctly in
    /// dark and light and in the menu bar's own highlight.
    private static func layoutIcon(_ layout: String?) -> NSImage? {
        let name: String
        switch layout {
        case "bsp": name = "rectangle.split.2x2"
        case "float": name = "macwindow.on.rectangle"
        default: name = "questionmark.square.dashed"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: layout ?? "unknown")
        image?.isTemplate = true
        return image
    }

    @objc private func spaceChanged() {
        state.refresh()
    }

    @objc func updateTitle() {
        guard let button = statusItem.button else { return }
        guard state.daemonUp != false else {
            button.title = " —"
            button.image = NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: "weftd not responding"
            )
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            return
        }
        if let current = state.currentSpace {
            let name = current.label.isEmpty ? "\(current.id)" : current.label
            button.title = " \(name)"
            button.image = state.needsRestart
                ? Self.restartIcon()
                : Self.layoutIcon(current.layout)
        } else {
            button.title = " —"
            button.image = Self.layoutIcon(nil)
        }
        button.imagePosition = .imageLeading
    }

    /// Replaces the layout glyph while a restart is pending, so the one thing
    /// standing between the user and a working weft is visible from the menu
    /// bar rather than only inside a window they have already closed.
    private static func restartIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "arrow.clockwise.circle.fill",
            accessibilityDescription: "restart needed"
        )
        image?.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Built entirely from the cached snapshot. Opening a menu must not
        // block on a socket: AppKit is holding the run loop while this runs,
        // and a daemon mid-sweep would hang the pointer.
        state.refresh()

        if state.needsRestart {
            let item = NSMenuItem(
                title: "Restart engine to finish setup",
                action: #selector(restartForPermissions), keyEquivalent: ""
            )
            item.target = self
            item.image = NSImage(
                systemSymbolName: "arrow.clockwise.circle.fill", accessibilityDescription: nil
            )
            menu.addItem(item)
            let note = NSMenuItem(
                title: "Permissions were granted after weftd started.",
                action: nil, keyEquivalent: ""
            )
            note.isEnabled = false
            menu.addItem(note)
            menu.addItem(.separator())
        }

        if SystemChecks.stageManagerEnabled() {
            let item = NSMenuItem(
                title: "Stage Manager is on — turn it off for weft",
                action: #selector(openStageManagerSettings), keyEquivalent: ""
            )
            item.target = self
            item.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil
            )
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // Desktop numbers are Mission Control's order; this setting shuffles
        // it as you work, and ⌥3 stops meaning one desktop.
        if SystemChecks.rearrangesSpacesByUse() {
            let item = NSMenuItem(
                title: "macOS reorders desktops by recent use — turn it off…",
                action: #selector(openStageManagerSettings), keyEquivalent: ""
            )
            item.target = self
            item.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil
            )
            item.toolTip = "Desktop & Dock › Mission Control › Automatically rearrange Spaces based on most recent use"
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let spaces = state.spaces
        guard state.daemonUp != false, !spaces.isEmpty else {
            let item = NSMenuItem(title: "weftd not responding", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            addControls(menu)
            return
        }

        let byID = Dictionary(state.windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // One section per display, in the order displays first appear, with
        // each workspace under its own display wherever it sits in the list.
        // Starting a section at every change of display counted a display
        // again each time the list went back to it — "Display 3" on a Mac
        // with two.
        var displayOrder: [String] = []
        for space in spaces where !displayOrder.contains(space.display) {
            displayOrder.append(space.display)
        }
        let grouped = displayOrder.flatMap { d in spaces.filter { $0.display == d } }
        let titles = DisplayIdentity.titles(for: displayOrder, among: SpaceControl.displayIdentities())
        var lastDisplay = ""

        for space in grouped {
            if space.display != lastDisplay {
                if !lastDisplay.isEmpty { menu.addItem(.separator()) }
                let n = displayOrder.firstIndex(of: space.display) ?? 0
                let h = NSMenuItem(title: titles[n], action: nil, keyEquivalent: "")
                h.isEnabled = false
                menu.addItem(h)
                lastDisplay = space.display
            }

            var seen = Set<Int32>()
            let icons: [NSImage] = space.windows.compactMap { wid in
                guard let pid = byID[wid]?.pid, seen.insert(pid).inserted,
                      let icon = NSRunningApplication(processIdentifier: pid_t(pid))?.icon
                else { return nil }
                return icon
            }

            // The workspace's own ordinal — what `space focus <n>` counts —
            // not its row, which grouping by display can move.
            let ordinal = (spaces.firstIndex { $0.label == space.label && $0.display == space.display } ?? 0) + 1
            let item = DesktopMenuRow.make(
                space, ordinal: ordinal, icons: icons, target: self, action: #selector(focusDesktop(_:))
            )
            menu.addItem(item)
        }

        addControls(menu)
    }

    private func addControls(_ menu: NSMenu) {
        menu.addItem(.separator())

        // This desktop, then this window: each one toggle that says which way
        // it goes. Two radio items for the desktop's layout read as settings
        // rather than actions, and "BSP" is a word nobody else uses.
        let floats = state.daemonUp != false && state.currentSpace?.layout == "float"
        let layoutItem = NSMenuItem(
            title: floats ? "Tile This Desktop" : "Float This Desktop",
            action: floats ? #selector(setLayoutBSP) : #selector(setLayoutFloat), keyEquivalent: ""
        )
        layoutItem.target = self
        layoutItem.image = Self.layoutIcon(floats ? "bsp" : "float")
        menu.addItem(layoutItem)

        // Floating one window, rather than the whole desktop. Bindable as
        // `float toggle`, but it needs to be reachable without a keybind —
        // a config migrated from a skhdrc that never bound it had no way in.
        let tiles = state.focusedFloating == true
        let floatWindowItem = NSMenuItem(
            title: tiles ? "Tile Focused Window" : "Float Focused Window",
            action: #selector(toggleFloatWindow), keyEquivalent: ""
        )
        floatWindowItem.target = self
        floatWindowItem.image = NSImage(
            systemSymbolName: tiles ? "rectangle.split.2x1" : "macwindow.badge.plus", accessibilityDescription: nil
        )
        menu.addItem(floatWindowItem)

        menu.addItem(.separator())

        let switchItem = NSMenuItem(title: "Window Switcher…", action: #selector(openSwitcher), keyEquivalent: " ")
        switchItem.keyEquivalentModifierMask = [.control, .option]
        switchItem.target = self
        switchItem.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        menu.addItem(switchItem)

        let cheatItem = NSMenuItem(title: "Keyboard Shortcuts…", action: #selector(openCheatsheet), keyEquivalent: "k")
        cheatItem.keyEquivalentModifierMask = [.command]
        cheatItem.target = self
        cheatItem.image = NSImage(systemSymbolName: "command", accessibilityDescription: nil)
        menu.addItem(cheatItem)

        menu.addItem(.separator())

        // Setup & Permissions — only while a permission is still missing.
        // A granted permission is settled; the menu is for what needs doing
        // now. `permissionsReady` is false when the daemon cannot be asked,
        // which is exactly when someone needs the row most.
        if !state.permissionsReady {
            let setupItem = NSMenuItem(
                title: "Finish setting up permissions…",
                action: #selector(openOnboarding), keyEquivalent: ""
            )
            setupItem.target = self
            setupItem.image = NSImage(
                systemSymbolName: "exclamationmark.shield.fill", accessibilityDescription: nil
            )
            menu.addItem(setupItem)
        }

        let configItem = NSMenuItem(title: "Settings…", action: #selector(openConfigEditor), keyEquivalent: ",")
        configItem.keyEquivalentModifierMask = [.command]
        configItem.target = self
        configItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(configItem)

        // Help and repair, out of the way until wanted. How Weft Works stays
        // reachable here weeks after Setup ran once.
        let help = NSMenu()
        let guideItem = NSMenuItem(title: "How Weft Works…", action: #selector(openWorkspacesGuide), keyEquivalent: "")
        guideItem.target = self
        guideItem.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        help.addItem(guideItem)
        help.addItem(.separator())
        let retryItem = NSMenuItem(title: "Restart Weft", action: #selector(resyncAndRestart), keyEquivalent: "r")
        retryItem.keyEquivalentModifierMask = [.command]
        retryItem.target = self
        retryItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        retryItem.toolTip = "Read the displays again and restart the engine"
        help.addItem(retryItem)
        let diagItem = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
        diagItem.target = self
        diagItem.image = NSImage(systemSymbolName: "stethoscope", accessibilityDescription: nil)
        help.addItem(diagItem)
        let helpItem = NSMenuItem(title: "Help & Troubleshooting", action: nil, keyEquivalent: "")
        helpItem.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        helpItem.submenu = help
        menu.addItem(helpItem)

        menu.addItem(.separator())

        // Update — only ever present when there is actually one, so the menu
        // does not carry a permanent "you are up to date" line nobody reads.
        //
        // Read from the cached answer on disk every time the menu opens, not
        // from an item held in a property. `menuNeedsUpdate` calls
        // `removeAllItems` and rebuilds, so the item the launch-time check
        // unhid was thrown away before it was ever drawn and a fresh hidden
        // one took its place: the update row could not appear at all. The
        // cache is a small local file and this is the same read `weftctl
        // doctor` does, so there is no network on the menu path.
        if updatesEnabled, let update = latestUpdate ?? UpdateCheck.cached(),
           update.isNewerThanRunning {
            let item = NSMenuItem(
                title: "Update to weft \(update.latest)…",
                action: #selector(openUpdatePage), keyEquivalent: ""
            )
            item.target = self
            item.image = NSImage(
                systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil
            )
            menu.addItem(item)
        }

        // Quit means weft, not just this icon: the engine stops too, so
        // tiling and keybinds go with it. Opening WeftBar starts it again.
        // Hold ⌥ for the old behaviour, the icon alone.
        let quitItem = NSMenuItem(title: "Quit Weft", action: #selector(quitWeft), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quitItem.toolTip = "Stop tiling and keybinds, and close the menu bar app"
        menu.addItem(quitItem)
        let quitBarItem = NSMenuItem(
            title: "Quit Menu Bar Only", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        quitBarItem.keyEquivalentModifierMask = [.command, .option]
        quitBarItem.isAlternate = true
        quitBarItem.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)
        quitBarItem.toolTip = "Close the menu bar app and leave weft tiling"
        menu.addItem(quitBarItem)
    }

    /// Stop the engine, then this app. The engine first and waited for: a
    /// WeftBar that exits before `bootout` returns would leave weftd running
    /// with nothing on screen to say so.
    @objc private func quitWeft() {
        Task { @MainActor in
            await Task.detached { EngineService.stop() }.value
            NSApp.terminate(nil)
        }
    }

    @objc private func focusDesktop(_ sender: NSMenuItem) { send("space focus \(sender.tag)") }
    @objc private func setLayoutBSP() { send("space layout bsp") }
    @objc private func setLayoutFloat() { send("space layout float") }
    @objc private func toggleFloatWindow() { send("float toggle") }

    private func send(_ command: String) {
        BarIPC.post(command)
        state.refresh()
    }

    /// The one-click fix for a grant that landed after weftd was already up.
    @objc private func restartForPermissions() {
        DispatchQueue.global(qos: .userInitiated).async {
            ConfigEditorWindowController.restartWeftCtl()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.state.refresh()
            }
        }
    }
    @objc private func openSwitcher() {
        switcher.toggle()
    }
    @objc private func openCheatsheet() {
        CheatsheetWindowController.shared.show()
    }
    @objc private func openConfigEditor() {
        ConfigEditorWindowController.shared.show()
    }
    @objc private func openOnboarding() {
        OnboardingWindowController.shared.show()
    }

    @objc private func openWorkspacesGuide() {
        OnboardingWindowController.shared.showWorkspaces()
    }

    @objc private func openStageManagerSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Everything a bug report needs, on the clipboard, with no terminal:
    /// `weftctl doctor`, the versions, and the end of the last install.
    @objc private func copyDiagnostics() {
        DispatchQueue.global(qos: .userInitiated).async {
            var parts: [String] = [
                "weft \(WeftVersion.current) — \(ProcessInfo.processInfo.operatingSystemVersionString)",
                "WeftBar: \(Bundle.main.bundlePath)",
                "Stage Manager: \(SystemChecks.stageManagerEnabled() ? "ON" : "off")",
            ]
            if let url = ConfigEditorWindowController.weftctlURL() {
                parts.append("--- weftctl doctor ---\n" + Self.output(of: url, ["doctor"]))
            } else {
                parts.append("--- weftctl not found ---")
            }
            if let log = try? String(contentsOf: EngineInstaller.logURL, encoding: .utf8) {
                let tail = log.split(separator: "\n", omittingEmptySubsequences: false).suffix(40)
                parts.append("--- last install ---\n" + tail.joined(separator: "\n"))
            }
            let text = parts.joined(separator: "\n\n")
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    nonisolated private static func output(of url: URL, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = url
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "could not run \(url.path): \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @objc private func openUpdatePage() {
        // Same fallback the row is built from: the row can come from the
        // cache, so acting on it must not require the in-memory copy.
        guard let update = latestUpdate ?? UpdateCheck.cached() else { return }
        Updater.shared.promptAndInstall(update)
    }

    /// Ask once per launch; `UpdateCheck` decides whether that turns into a
    /// request or a cached answer.
    ///
    /// Nothing here blocks and nothing here nags: no dialog, no badge that
    /// cannot be dismissed, no download. A menu item appears saying which
    /// version exists; clicking it asks, then updates in place
    /// (`openUpdatePage`). Anyone who wants none of it sets
    /// `check-for-updates = false`.
    private func checkForUpdate() {
        let enabled = ConfigStore.readCheckForUpdates()
        updatesEnabled = enabled
        UpdateCheck.refreshIfNeeded(enabled: enabled) { [weak self] result in
            guard let result, result.isNewerThanRunning else { return }
            Task { @MainActor in
                self?.latestUpdate = result
            }
        }
    }
    @objc private func resyncAndRestart() {
        DispatchQueue.global(qos: .userInitiated).async {
            if let url = ConfigEditorWindowController.weftctlURL() {
                let proc = Process()
                proc.executableURL = url
                proc.arguments = ["service", "restart"]
                try? proc.run()
                proc.waitUntilExit()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.state.refresh()
            }
        }
    }
}

#if DEBUG
if let i = CommandLine.arguments.firstIndex(of: "--render-snapshots"), i + 1 < CommandLine.arguments.count {
    NSApplication.shared.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { SnapshotRenderer.run(into: CommandLine.arguments[i + 1]) }
}
if CommandLine.arguments.contains("--preview-setup") {
    NSApplication.shared.setActivationPolicy(.accessory)
    MainActor.assumeIsolated { SnapshotRenderer.previewSetup() }
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
