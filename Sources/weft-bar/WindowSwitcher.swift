import AppKit
import Carbon.HIToolbox
import WeftCore
import WeftIPC

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct SwitcherItem {
    let wid: WindowID
    let pid: Int32
    let app: String
    let title: String
    let spaceLabel: String
}

@MainActor
final class WindowRow: NSView {
    private let icon: NSImage?
    private let app: String
    private let title: String
    private let desktop: String

    init(icon: NSImage?, app: String, title: String, desktop: String) {
        self.icon = icon
        self.app = app
        self.title = title
        self.desktop = desktop
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        icon?.draw(in: NSRect(x: 16, y: (h - 20) / 2, width: 20, height: 20))

        // desktop badge, right-aligned
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let bSize = (desktop as NSString).size(withAttributes: badgeAttrs)
        let pad: CGFloat = 8
        let badge = NSRect(
            x: bounds.width - 16 - bSize.width - pad * 2,
            y: (h - 20) / 2,
            width: bSize.width + pad * 2,
            height: 20
        )
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        (desktop as NSString).draw(
            at: NSPoint(x: badge.minX + pad, y: (h - bSize.height) / 2),
            withAttributes: badgeAttrs
        )

        // app name
        let appAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let appStr = app as NSString
        let appW = appStr.size(withAttributes: appAttrs).width
        let textX: CGFloat = 48
        let textY = (h - 16) / 2
        appStr.draw(at: NSPoint(x: textX, y: textY), withAttributes: appAttrs)

        // title
        guard !title.isEmpty else { return }
        let titleX = textX + appW + 8
        let maxW = badge.minX - 14 - titleX
        guard maxW > 24 else { return }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(
            in: NSRect(x: titleX, y: textY, width: maxW, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para
            ]
        )
    }
}

@MainActor
final class WindowSwitcher: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private let panel = KeyPanel(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let field = NSTextField()
    private let table = NSTableView()
    private var all: [SwitcherItem] = []
    private var shown: [SwitcherItem] = []

    override init() {
        super.init()
        panel.level = .floating
        // A panel AppKit keeps alive between showings stays filed under the
        // space it was first ordered into, so reopening it from another space
        // either yanks the user back to the old one or shows nothing at all.
        // `moveToActiveSpace` brings it to whichever space is in front now.
        panel.collectionBehavior.insert(.moveToActiveSpace)
        panel.hasShadow = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.delegate = self

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 600, height: 380))
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        let mag = NSImageView(frame: NSRect(x: 18, y: 343, width: 22, height: 22))
        mag.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        mag.contentTintColor = .secondaryLabelColor
        blur.addSubview(mag)

        field.frame = NSRect(x: 50, y: 334, width: 530, height: 34)
        field.font = .systemFont(ofSize: 18, weight: .regular)
        field.placeholderString = "Search windows across spaces…"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        blur.addSubview(field)

        let line = NSBox(frame: NSRect(x: 0, y: 330, width: 600, height: 1))
        line.boxType = .separator
        blur.addSubview(line)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 330))
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        let col = NSTableColumn(identifier: .init("c"))
        col.width = 600
        col.minWidth = 600
        col.maxWidth = 600
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 36
        table.backgroundColor = .clear
        table.style = .fullWidth
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.action = #selector(rowClicked)
        table.target = self
        table.doubleAction = #selector(focusSelected)
        scroll.documentView = table
        blur.addSubview(scroll)
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        // Open first, load second. The list is two socket round trips against
        // a daemon that may be mid-sweep, and doing them before the panel
        // appears made ⌃⌥Space feel like it had not registered the keypress.
        // The window list arrives a few milliseconds later, into a panel that
        // is already on screen and already taking typing.
        field.stringValue = ""
        filter("")
        if let s = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: s.frame.midX - 300, y: s.frame.midY - 120))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        reload()
    }

    private func reload() {
        Task.detached(priority: .userInitiated) {
            let items = Self.fetch()
            await MainActor.run { [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.all = items
                self.filter(self.field.stringValue)
            }
        }
    }

    private nonisolated static func fetch() -> [SwitcherItem] {
        // `--no-ax`: the switcher never reads `bound`. The plain form is the
        // fallback for a daemon older than the flag.
        guard let jsonStr = BarIPC.send("query windows --no-ax") ?? BarIPC.send("query windows"),
              let data = jsonStr.data(using: .utf8),
              let wins = try? JSONDecoder().decode([WindowStatus].self, from: data)
        else { return [] }

        var spacesMap: [SpaceID: String] = [:]
        if let sJson = BarIPC.send("query spaces"),
           let sData = sJson.data(using: .utf8),
           let parsed = try? JSONDecoder().decode([SpaceStatus].self, from: sData)
        {
            for s in parsed { spacesMap[s.id] = s.label.isEmpty ? "\(s.id)" : s.label }
        }
        return wins.filter { !$0.app.isEmpty }.map {
            let sLabel = $0.spaces.first.flatMap { spacesMap[$0] } ?? "space"
            return SwitcherItem(
                wid: $0.id, pid: $0.pid, app: $0.app, title: $0.title, spaceLabel: sLabel
            )
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func filter(_ q: String) {
        let q = q.lowercased().trimmingCharacters(in: .whitespaces)
        shown = q.isEmpty ? all : all.filter {
            $0.app.lowercased().contains(q) || $0.title.lowercased().contains(q) || $0.spaceLabel.lowercased().contains(q)
        }
        table.reloadData()
        if !shown.isEmpty { select(0) }
    }

    private func select(_ row: Int) {
        guard row >= 0, row < shown.count else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func focusSelected() {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return }
        let target = shown[row]
        // `set-focus <id>`, not `focus <id>`: `focus` takes a direction, so
        // every pick from this list parsed as an error and did nothing. The
        // daemon switches space for us when the window is on another one.
        BarIPC.post("set-focus \(target.wid)")
        hide()
    }

    @objc private func rowClicked() {
        if table.clickedRow >= 0 { focusSelected() }
    }

    func controlTextDidChange(_ obj: Notification) {
        filter(field.stringValue)
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)):
            select(min(shown.count - 1, table.selectedRow + 1)); return true
        case #selector(NSResponder.moveUp(_:)):
            select(max(0, table.selectedRow - 1)); return true
        case #selector(NSResponder.insertNewline(_:)):
            focusSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        default:
            return false
        }
    }

    func windowDidResignKey(_ n: Notification) {
        hide()
    }

    func numberOfRows(in t: NSTableView) -> Int { shown.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let item = shown[row]
        let icon = NSRunningApplication(processIdentifier: pid_t(item.pid))?.icon
        return WindowRow(icon: icon, app: item.app, title: item.title, desktop: item.spaceLabel)
    }
}
