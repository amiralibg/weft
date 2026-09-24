import AppKit
import SwiftUI
import WeftPlatform

// Extra macOS desktops, shown as a problem with a fix rather than a footnote.
//
// weft keeps its workspaces on one macOS desktop per display. Another desktop
// is somewhere its windows are not arranged and where weft stops until the
// user comes back, and nothing on screen says so: the windows just stop
// tiling. Someone who is not interested in how that works needs three things,
// in this order: what is wrong, the button that starts fixing it, and what to
// click once there. The card says exactly that, and turns into "All set" by
// itself once the last extra desktop is gone.
//
// The count is read here, straight from the WindowServer, rather than from
// the engine: Setup shows this before the engine may be running.

/// A display with more than one macOS desktop.
struct ExtraDesktops: Identifiable, Equatable {
    var id: String
    var name: String
    var count: Int
}

enum DesktopCensus {
    /// Displays with more than one ordinary desktop, west to east.
    static func extras() -> [ExtraDesktops] {
        let counts = SpaceControl.desktopsByDisplay()
        let displays = DisplayCatalog.current()
        return counts.compactMap { entry in
            guard entry.count > 1 else { return nil }
            // "Main" is what macOS reports when all displays share one set of
            // desktops ("Displays have separate Spaces" off).
            let name = displays.first { $0.id == entry.uuid }?.name
                ?? (displays.count > 1 ? "Your displays" : "This Mac")
            return ExtraDesktops(id: entry.uuid, name: name, count: entry.count)
        }
    }

    static func openMissionControl() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The notice, for Settings › Workspaces and the last page of Setup.
struct ExtraDesktopsCard: View {
    /// Show "All set" when there is nothing to fix, not only after a fix.
    var confirmWhenClear = false
    @SwiftUI.State private var extras = DesktopCensus.extras()
    @SwiftUI.State private var fixedHere = false

    var body: some View {
        Group {
            if !extras.isEmpty {
                problem
            } else if fixedHere || confirmWhenClear {
                allSet
            }
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            let now = DesktopCensus.extras()
            guard now != extras else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                if !extras.isEmpty, now.isEmpty { fixedHere = true }
                extras = now
            }
        }
    }

    private var extraCount: Int { extras.reduce(0) { $0 + $1.count - 1 } }

    private var title: String {
        if extras.count == 1, let only = extras.first {
            return "\(only.name) has \(only.count) desktops. weft needs just one."
        }
        return "Remove \(extraCount) extra desktops. weft needs one per display."
    }

    private var problem: some View {
        HStack(alignment: .top, spacing: 16) {
            DesktopStrip(count: extras.map(\.count).max() ?? 2)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("weft gives you as many workspaces as you like on one desktop. "
                    + "On any other desktop your windows aren't arranged, and weft waits until you come back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Click **Open Mission Control**.")
                    step(2, "Move the pointer to the row of desktops at the top of the screen.")
                    step(3, "Hold it over each extra desktop and click the **✕**. "
                        + "Its windows move to the desktop you keep.")
                }
                HStack(spacing: 10) {
                    Button {
                        DesktopCensus.openMissionControl()
                    } label: {
                        Label("Open Mission Control", systemImage: "rectangle.3.group")
                    }
                    .weftProminentButton()
                    if extras.count > 1 {
                        Text(extras.map { "\($0.name): \($0.count)" }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var allSet: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.green)
            Text("One desktop per display. You're all set.")
                .font(.callout.weight(.medium))
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.green.opacity(0.08))
        )
        .transition(.opacity)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption2.weight(.bold))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.orange.opacity(0.2)))
            Text(LocalizedStringKey(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Mission Control's row of desktops, drawn small: the one to keep, and the
/// others with the ✕ the user is about to click. Four at most, then "+N".
private struct DesktopStrip: View {
    let count: Int

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                thumb(keep: true)
                ForEach(0..<min(count - 1, 3), id: \.self) { _ in thumb(keep: false) }
                if count > 4 {
                    Text("+\(count - 4)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 0) {
                Text("Keep")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.weft)
                    .frame(width: 30)
                Spacer(minLength: 0)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func thumb(keep: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(keep ? Color.weft.opacity(0.85) : Color.primary.opacity(0.12))
            .frame(width: 30, height: 20)
            .overlay(alignment: .topLeading) {
                if !keep {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.red)
                        .offset(x: -5, y: -5)
                }
            }
    }
}
