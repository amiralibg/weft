import AppKit

/// A short message at the top of the screen the pointer is on, for a keybind
/// or gesture weft could not carry out.
///
/// Without it a refused keybind looks exactly like one weft never heard: the
/// reason — a display paused on another macOS desktop, secure input hiding the
/// keys — was only ever written to a log nobody reads while using the desktop.
///
/// Never key, never in the way: a non-activating panel that ignores the mouse,
/// above the menu bar's level so it is not a window weft would tile, and on
/// every desktop including a fullscreen app's, since that is one of the places
/// a switch gets refused.
@MainActor
final class Toast {
    static let shared = Toast()

    private let panel: NSPanel
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private var hide: DispatchWorkItem?

    private static let width: CGFloat = 380
    private static let visibleFor: TimeInterval = 4

    private init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .systemOrange
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 4
        body.preferredMaxLayoutWidth = Self.width - 62

        for view in [icon, title, body] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            blur.addSubview(view)
        }
        NSLayoutConstraint.activate([
            blur.widthAnchor.constraint(equalToConstant: Self.width),
            icon.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: blur.topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -16),
            title.topAnchor.constraint(equalTo: blur.topAnchor, constant: 14),
            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            body.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -14),
        ])
    }

    /// The first line, from the command that failed.
    static func headline(for command: String) -> String {
        if command == "secure-input" { return "Shortcuts are blocked" }
        let words = command.split(separator: " ").map(String.init)
        if words.count >= 3, words[0] == "space", words[1] == "focus" {
            return "Couldn’t switch to \(words[2...].joined(separator: " "))"
        }
        if words.count >= 3, words[0] == "space", words[1] == "move-window" {
            return "Couldn’t move the window to \(words[2...].joined(separator: " "))"
        }
        return "Couldn’t \(command)"
    }

    func show(_ headline: String, _ message: String) {
        let symbol = headline == Self.headline(for: "secure-input") ? "lock.fill" : "exclamationmark.triangle.fill"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        title.stringValue = headline
        body.stringValue = message
        body.isHidden = message.isEmpty

        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: content.fittingSize.height)
        // The screen the pointer is on: that is where the user is looking,
        // and on two displays the key window's screen can be the other one.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let origin = NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 12)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        hide?.cancel()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    // A newer message may have arrived during the fade.
                    if self.panel.alphaValue == 0 { self.panel.orderOut(nil) }
                }
            })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleFor, execute: work)
    }
}
