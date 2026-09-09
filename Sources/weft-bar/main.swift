import AppKit
import WeftPlatform
import Carbon.HIToolbox
import Foundation

struct BarSpace: Decodable {
    let id: UInt64
    let label: String
    let layout: String
    let windows: [Int]
    let current: Bool
    let display: String
}

struct BarWindow: Decodable {
    let id: Int
    let app: String
    let title: String
    let pid: Int
    let spaces: [UInt64]
}

@MainActor
final class SpaceRowView: NSView {
    private let space: BarSpace
    private let displayIndex: Int
    private let icons: [NSImage]
    private let onClick: () -> Void

    init(space: BarSpace, displayIndex: Int, icons: [NSImage], onClick: @escaping () -> Void) {
        self.space = space
        self.displayIndex = displayIndex
        self.icons = icons
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { needsDisplay = true }
    override func mouseExited(with e: NSEvent) { needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        onClick()
    }

    override func draw(_ dirtyRect: NSRect) {
        let hot = enclosingMenuItem?.isHighlighted ?? false
        if hot {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        let fg: NSColor = hot ? .white : .labelColor

        // Pill with space index
        let pill = NSRect(x: 12, y: 7, width: 20, height: 18)
        (space.current ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        drawCentered("\(displayIndex)", in: pill, color: .white, size: 11)

        // Space label
        let name = space.label.isEmpty ? "\(space.id)" : space.label
        drawText(name, at: NSPoint(x: 40, y: 8), color: fg, size: 13, bold: space.current)

        // Layout badge
        let badge = space.layout.uppercased()
        let bAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: hot ? NSColor.white.withAlphaComponent(0.8) : NSColor.tertiaryLabelColor
        ]
        (badge as NSString).draw(at: NSPoint(x: 100, y: 10), withAttributes: bAttrs)

        // App icons
        var x = bounds.width - 12 - 20
        for img in icons.prefix(6).reversed() {
            img.draw(in: NSRect(x: x, y: 6, width: 20, height: 20))
            x -= 24
        }
    }

    private func drawText(_ s: String, at p: NSPoint, color: NSColor, size: CGFloat, bold: Bool) {
        let f = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        (s as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: color])
    }
    private func drawCentered(_ s: String, in r: NSRect, color: NSColor, size: CGFloat) {
        let a: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: size),
            .foregroundColor: color
        ]
        let sz = (s as NSString).size(withAttributes: a)
        (s as NSString).draw(at: NSPoint(x: r.midX - sz.width/2, y: r.midY - sz.height/2), withAttributes: a)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let state = BarState()
    private let switcher = WindowSwitcher()
    /// The update line, kept hidden unless there is a newer release.
    private var updateItem: NSMenuItem?
    private var latestUpdate: UpdateCheck.Result?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // The status item redraws from a cached snapshot; nothing on this
        // thread ever waits for the daemon to answer.
        state.onChange = { [weak self] in self?.updateTitle() }
        state.start()
        updateTitle()

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
        case "scroll": name = "rectangle.split.3x1"
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

        let spaces = state.spaces
        guard state.daemonUp != false, !spaces.isEmpty else {
            let item = NSMenuItem(title: "weftd not responding", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            addControls(menu)
            return
        }

        let byID = Dictionary(state.windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var lastDisplay = ""
        var displayCount = 1
        var spaceIdx = 1

        for space in spaces {
            if space.display != lastDisplay {
                if !lastDisplay.isEmpty { menu.addItem(.separator()) }
                let h = NSMenuItem(title: "Display \(displayCount)", action: nil, keyEquivalent: "")
                h.isEnabled = false
                menu.addItem(h)
                lastDisplay = space.display
                displayCount += 1
            }

            let icons: [NSImage] = space.windows.compactMap { wid in
                guard let pid = byID[wid]?.pid,
                      let icon = NSRunningApplication(processIdentifier: pid_t(pid))?.icon
                else { return nil }
                let copy = icon.copy() as! NSImage
                copy.size = NSSize(width: 20, height: 20)
                return copy
            }

            let item = NSMenuItem()
            let sName = space.label.isEmpty ? "\(space.id)" : space.label
            item.view = SpaceRowView(space: space, displayIndex: spaceIdx, icons: icons) { [weak self] in
                BarIPC.post("space focus \(sName)")
                self?.state.refresh()
            }
            menu.addItem(item)
            spaceIdx += 1
        }

        addControls(menu)
    }

    private func addControls(_ menu: NSMenu) {
        menu.addItem(.separator())

        // Layout Switchers
        let bspItem = NSMenuItem(title: "BSP Layout", action: #selector(setLayoutBSP), keyEquivalent: "")
        bspItem.target = self
        menu.addItem(bspItem)

        let scrollItem = NSMenuItem(title: "Scroll Layout", action: #selector(setLayoutScroll), keyEquivalent: "")
        scrollItem.target = self
        menu.addItem(scrollItem)

        let floatItem = NSMenuItem(title: "Float Layout", action: #selector(setLayoutFloat), keyEquivalent: "")
        floatItem.target = self
        menu.addItem(floatItem)

        menu.addItem(.separator())

        // Floating one window, rather than the whole space. Bindable as
        // `float toggle`, but it needs to be reachable without a keybind —
        // a config migrated from a skhdrc that never bound it had no way in.
        let floatWindowItem = NSMenuItem(
            title: "Float Focused Window", action: #selector(toggleFloatWindow), keyEquivalent: ""
        )
        floatWindowItem.target = self
        floatWindowItem.image = NSImage(
            systemSymbolName: "macwindow.badge.plus", accessibilityDescription: nil
        )
        menu.addItem(floatWindowItem)

        menu.addItem(.separator())

        // Window Switcher
        let switchItem = NSMenuItem(title: "Window Switcher…", action: #selector(openSwitcher), keyEquivalent: " ")
        switchItem.keyEquivalentModifierMask = [.control, .option]
        switchItem.target = self
        switchItem.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        menu.addItem(switchItem)

        // Cheatsheet
        let cheatItem = NSMenuItem(title: "Keybindings Cheatsheet…", action: #selector(openCheatsheet), keyEquivalent: "k")
        cheatItem.keyEquivalentModifierMask = [.command]
        cheatItem.target = self
        cheatItem.image = NSImage(systemSymbolName: "command", accessibilityDescription: nil)
        menu.addItem(cheatItem)

        // Setup & Permissions
        let setupItem = NSMenuItem(title: "Permissions…", action: #selector(openOnboarding), keyEquivalent: "")
        setupItem.target = self
        setupItem.image = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: nil)
        menu.addItem(setupItem)

        // Config Editor
        let configItem = NSMenuItem(title: "Settings…", action: #selector(openConfigEditor), keyEquivalent: ",")
        configItem.keyEquivalentModifierMask = [.command]
        configItem.target = self
        configItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(configItem)

        menu.addItem(.separator())

        // Retry / Restart Weft
        let retryItem = NSMenuItem(title: "Resync Displays & Restart Weft", action: #selector(resyncAndRestart), keyEquivalent: "r")
        retryItem.keyEquivalentModifierMask = [.command]
        retryItem.target = self
        retryItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(retryItem)

        // Update — only ever present when there is actually one, so the menu
        // does not carry a permanent "you are up to date" line nobody reads.
        updateItem = NSMenuItem(
            title: "", action: #selector(openUpdatePage), keyEquivalent: ""
        )
        updateItem?.target = self
        updateItem?.image = NSImage(
            systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil
        )
        updateItem?.isHidden = true
        if let updateItem { menu.addItem(updateItem) }

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)
    }

    @objc private func setLayoutBSP() { send("space layout bsp") }
    @objc private func setLayoutScroll() { send("space layout scroll") }
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

    @objc private func openUpdatePage() {
        guard let update = latestUpdate, let url = URL(string: update.url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Ask once per launch; `UpdateCheck` decides whether that turns into a
    /// request or a cached answer.
    ///
    /// Nothing here blocks and nothing here nags: no dialog, no badge that
    /// cannot be dismissed, no download. A menu item appears saying which
    /// version exists, and clicking it opens the release page. Anyone who
    /// wants none of it sets `check-for-updates = false`.
    private func checkForUpdate() {
        let enabled = ConfigStore.readCheckForUpdates()
        UpdateCheck.refreshIfNeeded(enabled: enabled) { [weak self] result in
            guard let result, result.isNewerThanRunning else { return }
            Task { @MainActor in
                self?.latestUpdate = result
                self?.updateItem?.title = "Update to weft \(result.latest)…"
                self?.updateItem?.isHidden = false
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
