import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import SwiftUI

// First-run Setup: the permissions gate, as a three-page flow.
//
// Every permission shown belongs to **weftd**, read back over the socket.
// WeftBar needs none of them itself — its hotkeys are Carbon
// `RegisterEventHotKey` and every window it lists comes from the daemon. TCC is
// per binary, so a check WeftBar runs on itself answers a different question
// than the one that matters, and this window used to ask exactly that one.

// MARK: - Model

/// weftd's own TCC status. Only the daemon can answer for the daemon.
struct DaemonPermissions: Decodable, Equatable {
    var binary: String
    var accessibility: Bool
    /// The Input Monitoring switch itself, as TCC has it.
    var inputMonitoring: Bool
    /// The live event tap — what keybinds and mouse gestures actually run on.
    ///
    /// Kept apart from `inputMonitoring` because the two genuinely differ:
    /// macOS lets an Accessibility-trusted process open an event tap, so the
    /// tap comes up while the Input Monitoring switch is still off. This flow
    /// used to report the tap under the Input Monitoring heading, which meant
    /// granting Accessibility alone turned every row green and marched the
    /// user straight to "Everything is granted" for a switch they had never
    /// seen. Optional so a newer WeftBar still reads an older daemon.
    var keybindsLive: Bool?
    var screenRecording: Bool
    /// Whether weftd is signed with a stable identity. When false, a rebuild
    /// has invalidated every grant TCC still shows as on — the switch in the
    /// pane is enabled and doing nothing. Optional for older daemons.
    var stableIdentity: Bool?
    /// weftd was already running when Accessibility was granted, so its AX
    /// connections predate the grant and every window operation is refused
    /// until it restarts. Optional so a newer WeftBar still reads an older
    /// daemon (which simply never reports it).
    var needsRestart: Bool?

    /// The pane will contradict us: it shows a switch that is on for a
    /// program this binary no longer is.
    var switchesMayLie: Bool { !(stableIdentity ?? true) }

    /// What keybinds actually run on.
    var tapLive: Bool { keybindsLive ?? inputMonitoring }
    /// The grants are all in place but the daemon holding them is the one
    /// that started before they were.
    var mustRestart: Bool { needsRestart ?? false }
    /// Functional readiness — the only thing worth gating Setup on.
    /// Screen Recording counts: without it every window title is empty.
    /// So does a pending restart: a weft that cannot move a window is not
    /// ready, however green the switches are.
    var ready: Bool { accessibility && tapLive && screenRecording && !mustRestart }
}

enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility, inputMonitoring, screenRecording
    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen Recording"
        }
    }

    var detail: String {
        switch self {
        case .accessibility: return "Move, resize and focus your windows."
        case .inputMonitoring: return "See your keybinds and mouse gestures."
        case .screenRecording: return "Read window titles, for rules and the switcher."
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "macwindow.on.rectangle"
        case .inputMonitoring: return "keyboard"
        case .screenRecording: return "sparkles.rectangle.stack"
        }
    }

    /// The exact trail through System Settings, spelled out rather than
    /// implied. "Open the pane and grant it" was the whole instruction here
    /// before, which leaves the two things people actually get stuck on — what
    /// row to look for, and that the row says *weftd* and not *Weft* — unsaid.
    var settingsPath: String {
        "Privacy & Security › \(title)"
    }

    /// All three. Screen Recording used to be waved through as "only the
    /// focus highlight" — it is not. Without it macOS redacts `kCGWindowName`
    /// for every window weftd does not own, so every window title comes back
    /// empty: rules that match on title never fire, the window switcher lists
    /// blank rows, and sketchybar shows nothing. Skipping it does not cost a
    /// highlight, it costs a working install, and the people most likely to
    /// skip it are the ones least likely to connect the two.
    var isRequired: Bool { true }

    var settingsURL: URL? {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var perms: DaemonPermissions?
    @Published var page: Page = .welcome
    /// The permission the flow is currently waiting on, if any.
    @Published var activeStep: PermissionKind?
    @Published var isRestarting = false
    /// Opened by the user, or by the flow after a long enough wait. Holds the
    /// "weftd is not in the list" recovery: reveal, drag, paste the path.
    @Published var showsFallback = false
    /// Seconds the current step has been waiting. Drives the "still nothing?"
    /// hint rather than a spinner that says the same thing forever.
    @Published var waitedSeconds = 0

    enum Page: Int { case welcome, permissions, done }

    private var timer: Timer?
    private var stepStarted: Date?

    var daemonReachable: Bool { perms != nil }

    /// Path the user would have to add by hand — the Reveal fallback only.
    var weftdPath: String {
        perms?.binary
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/weftd").path
    }

    /// The switch in System Settings, as TCC has it. What the user did.
    func granted(_ kind: PermissionKind) -> Bool {
        guard let p = perms else { return false }
        switch kind {
        case .accessibility: return p.accessibility
        case .inputMonitoring: return p.inputMonitoring
        case .screenRecording: return p.screenRecording
        }
    }

    /// Whether the thing this permission buys actually works. What the user
    /// gets.
    ///
    /// The two come apart on exactly one row: Accessibility is enough for
    /// macOS to let weftd open an event tap, so keybinds fire with the Input
    /// Monitoring switch still off. The flow advances on this — nobody should
    /// be stopped on a step that is already working — while every label the
    /// user reads comes from `granted`, so no one is told they flipped a
    /// switch they never saw.
    func satisfied(_ kind: PermissionKind) -> Bool {
        guard let p = perms else { return false }
        switch kind {
        case .inputMonitoring: return p.tapLive
        default: return granted(kind)
        }
    }

    /// Working, but not because of its own switch — the note the card shows so
    /// a green row and an off switch stop contradicting each other.
    func coveredByAccessibility(_ kind: PermissionKind) -> Bool {
        kind == .inputMonitoring && satisfied(kind) && !granted(kind)
    }

    var requiredGranted: Bool { perms?.ready ?? false }

    var grantedCount: Int {
        PermissionKind.allCases.filter(\.isRequired).filter(satisfied).count
    }

    var requiredCount: Int { PermissionKind.allCases.filter(\.isRequired).count }

    /// After this long on one step, the likeliest explanation stops being
    /// "they are still reading" and starts being "the row is not there".
    var isStuck: Bool { waitedSeconds >= 20 }

    /// Whether Setup may be dismissed at all.
    ///
    /// It may not, while weftd is answering and something it needs is still
    /// missing. A half-granted weft is not a degraded weft — it is windows
    /// that float free, keybinds that do nothing and empty window titles, with
    /// no hint anywhere that a permission is the reason. Letting the one
    /// window that explains that be closed on the first page is how people
    /// ended up with an installed weft they concluded was broken.
    ///
    /// The exception is a daemon that is not answering: there is nothing to
    /// grant against, Setup says so, and trapping someone in a window that
    /// cannot help them is its own bug.
    var canDismiss: Bool { requiredGranted || !daemonReachable }

    /// Set briefly when a dismiss is refused, so the page can explain itself
    /// instead of the window simply not closing.
    @Published var blockedDismissAt: Date?

    var showsBlockedDismissHint: Bool {
        guard let at = blockedDismissAt else { return false }
        return Date().timeIntervalSince(at) < 6
    }

    func flashBlockedDismiss() {
        blockedDismissAt = Date()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_200_000_000)
            withAnimation(.easeOut(duration: 0.3)) { self?.blockedDismissAt = nil }
        }
    }

    /// weftd was rebuilt since it was granted, so the pane is showing switches
    /// that are on and inert. Worth saying before anything else on the page:
    /// the instruction "turn it on" is unfollowable when it already is.
    var showsStaleGrantWarning: Bool {
        guard let p = perms else { return false }
        return p.switchesMayLie && !p.ready
    }

    /// Every switch is on and the engine still cannot work, because it was
    /// running before the switches were flipped. One button fixes it, so the
    /// page shows one button.
    var needsEngineRestart: Bool { perms?.mustRestart ?? false }

    // MARK: Polling

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
                self?.refresh()
            }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard page == .permissions, activeStep != nil, let started = stepStarted else {
            if waitedSeconds != 0 { waitedSeconds = 0 }
            return
        }
        let elapsed = Int(Date().timeIntervalSince(started))
        guard elapsed != waitedSeconds else { return }
        let wasStuck = isStuck
        waitedSeconds = elapsed
        if isStuck && !wasStuck {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { showsFallback = true }
        }
    }

    /// The socket read blocks, so it never runs on the main thread — a wedged
    /// daemon would otherwise freeze the window it is being diagnosed in.
    func refresh() {
        Task.detached(priority: .utility) {
            let decoded: DaemonPermissions? = {
                guard let json = BarIPC.send("query permissions"),
                      let data = json.data(using: .utf8)
                else { return nil }
                return try? JSONDecoder().decode(DaemonPermissions.self, from: data)
            }()
            await MainActor.run { self.apply(decoded) }
        }
    }

    private func apply(_ next: DaemonPermissions?) {
        let wasGranted = requiredGranted
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            perms = next
        }
        guard page == .permissions else { return }
        if needsEngineRestart {
            // Not done, and not stuck on a switch either: the switches are all
            // on. Stay on this page — the restart banner is on it — rather
            // than marching to a "you are all set" screen for a weft that
            // cannot move a window yet.
            if activeStep != nil {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    activeStep = nil
                }
            }
            return
        }
        if requiredGranted {
            guard !wasGranted else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                activeStep = nil
                page = .done
            }
        } else if let current = activeStep, satisfied(current) {
            advanceStep()
        }
    }

    // MARK: Actions

    func beginPermissions() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            page = requiredGranted ? .done : .permissions
        }
        if !requiredGranted { advanceStep() }
    }

    /// Open the pane for the first ungranted required permission.
    func advanceStep() {
        guard let next = PermissionKind.allCases.first(where: { $0.isRequired && !satisfied($0) })
        else {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { page = .done }
            return
        }
        focusStep(next)
    }

    func focusStep(_ kind: PermissionKind) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            activeStep = kind
            showsFallback = false
        }
        stepStarted = Date()
        waitedSeconds = 0
        open(kind)
    }

    /// Open the Settings pane, and nothing else.
    ///
    /// This used to yank a Finder window open at the same time, every time.
    /// weftd asks the system for these grants on launch, and that request is
    /// what makes macOS *list* it — so in the normal case there is already a
    /// weftd row waiting to be switched on and nothing whatsoever to find. A
    /// Finder window appearing unasked next to it read as the instruction:
    /// people went looking for a file to drag whether or not they needed to,
    /// and the one sentence that mattered ("switch weftd on") was buried.
    /// The reveal is still here, one click away, under the heading for the
    /// case it actually solves.
    func open(_ kind: PermissionKind) {
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    func revealBinary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(weftdPath, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: weftdPath)])
    }

    func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(weftdPath, forType: .string)
    }

    /// The escape hatch for the one case retrying cannot fix. weftd re-tries
    /// the event tap on every poll, so a grant normally lands within a second
    /// without this — but a daemon that was wedged before the grant will not
    /// notice either way.
    func restartEngine() {
        isRestarting = true
        Task.detached(priority: .userInitiated) {
            ConfigEditorWindowController.restartWeftCtl()
            // Wait for the socket to answer again rather than guessing at a
            // sleep. `launchctl kickstart -k` returns as soon as it has
            // signalled, and asking into that gap reads as "daemon gone" —
            // which is how a restart button could leave the window looking
            // worse than before it was pressed.
            _ = await OnboardingWindowController.awaitDaemon()
            await MainActor.run {
                self.isRestarting = false
                self.refresh()
            }
        }
    }

    func finish() {
        isRestarting = true
        try? "onboarded".write(
            to: OnboardingWindowController.flagURL, atomically: true, encoding: .utf8
        )
        Task.detached(priority: .userInitiated) {
            ConfigEditorWindowController.restartWeftCtl()
            // Wait for the daemon to answer again before handing over.
            //
            // `launchctl kickstart -k` returns the moment it has signalled, so
            // for a second or so after this there is no socket to talk to. The
            // relaunched WeftBar used to ask straight into that gap, read the
            // silence as "permissions missing", and reopen Setup — on a
            // machine where everything was already granted. Finish, relaunch,
            // "Everything is granted", Finish: the loop had no exit, because
            // nothing about it depended on the permissions at all.
            _ = await OnboardingWindowController.awaitDaemon()
            await MainActor.run {
                // Relaunch so hotkeys re-register under the new grants.
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                proc.arguments = ["-n", Bundle.main.bundlePath]
                try? proc.run()
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - Shared style

extension Color {
    /// Weft's own accent — the same `0x7aa2f7` the icon and the focus border
    /// use. Tinting the window with it rather than inheriting the system
    /// accent keeps the controls, the progress bar and the app icon reading as
    /// one thing; inheriting made a blue icon sit above red buttons.
    static let weft = Color(.sRGB, red: 0.478, green: 0.635, blue: 0.968, opacity: 1)
    static let weftDeep = Color(.sRGB, red: 0.361, green: 0.502, blue: 0.855, opacity: 1)
}

/// Placed inside each page's own bottom row: one shared overlay cannot line up
/// with two pages that anchor their buttons at different heights.
private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button("Close", action: action)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Root

struct SetupView: View {
    @ObservedObject var model: SetupModel
    var onClose: () -> Void

    var body: some View {
        ZStack {
            SetupBackdrop()

            Group {
                switch model.page {
                case .welcome: WelcomePage(model: model, onClose: onClose).transition(pageTransition)
                case .permissions:
                    PermissionsPage(model: model, onClose: onClose).transition(pageTransition)
                case .done:
                    DonePage(model: model, onClose: onClose).transition(pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 700, height: 660)
        .tint(.weft)
    }

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }
}

/// A quiet wash rather than flat chrome: depth without competing with the
/// content. The accent pools at the bottom, under the buttons, so the eye
/// lands where the next action is.
private struct SetupBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [Color.weft.opacity(0.14), .clear],
                startPoint: .bottom,
                endPoint: .center
            )
            RadialGradient(
                colors: [Color.weft.opacity(0.10), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 460
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Page 1

private struct WelcomePage: View {
    @ObservedObject var model: SetupModel
    let onClose: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            AppIcon()
                .frame(width: 108, height: 108)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                .scaleEffect(appeared ? 1 : 0.7)
                .opacity(appeared ? 1 : 0)

            Text("Welcome to Weft")
                .font(.system(size: 32, weight: .semibold))
                .padding(.top, 24)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)

            Text("A tiling window manager for macOS.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)

            VStack(alignment: .leading, spacing: 16) {
                Bullet(
                    symbol: "lock.shield",
                    title: "Three switches to flip",
                    text: "All belong to **weftd**, the engine — not to this menu-bar app."
                )
                Bullet(
                    symbol: "arrow.right.circle",
                    title: "Guided, one at a time",
                    text: "Each pane opens in turn and moves on by itself the moment you grant it."
                )
                Bullet(
                    symbol: "bolt",
                    title: "Nothing to hunt for",
                    text: "Weft notices each switch within a second, and asks for one restart at the end if macOS needs it."
                )
            }
            .padding(.top, 34)
            .frame(maxWidth: 430, alignment: .leading)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)

            Spacer()

            VStack(spacing: 14) {
                Button(action: model.beginPermissions) {
                    Text(model.requiredGranted ? "Review permissions" : "Get started")
                        .frame(width: 190)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.daemonReachable)

                if !model.daemonReachable {
                    DaemonUnreachableNotice()
                } else if model.canDismiss {
                    CloseButton(action: onClose)
                }
            }
            .padding(.bottom, 44)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.72)) { appeared = true }
        }
    }
}

/// The one failure the flow cannot walk anyone out of: with no daemon there is
/// nothing to grant anything to, and every row below would read "missing" for
/// the wrong reason. Say which command fixes it rather than just flagging it.
private struct DaemonUnreachableNotice: View {
    var body: some View {
        VStack(spacing: 8) {
            Label("The weft engine isn’t answering", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            HStack(spacing: 6) {
                Text("Start it with")
                Text("weftctl service start")
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .textSelection(.enabled)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct Bullet: View {
    let symbol: String
    var title: String?
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Color.weft)
                .frame(width: 22, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                }
                Text(.init(text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Page 2

private struct PermissionsPage: View {
    @ObservedObject var model: SetupModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Grant weft access")
                    .font(.system(size: 25, weight: .semibold))
                Text("System Settings is opening for each one. Look for the row named **weftd** and turn its switch on — the flow moves itself along as you do.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .padding(.top, 38)

            if model.needsEngineRestart {
                RestartBanner(model: model)
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
            } else if model.showsStaleGrantWarning {
                StaleGrantBanner()
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
            }

            if model.showsBlockedDismissHint {
                BlockedDismissNotice()
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            ProgressBar(granted: model.grantedCount, total: model.requiredCount)
                .padding(.horizontal, 32)
                .padding(.top, 18)

            ScrollView {
                VStack(spacing: 11) {
                    ForEach(PermissionKind.allCases) { kind in
                        PermissionCard(
                            kind: kind,
                            granted: model.granted(kind),
                            satisfied: model.satisfied(kind),
                            covered: model.coveredByAccessibility(kind),
                            isActive: model.activeStep == kind,
                            model: model
                        )
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider().opacity(0.5)

            FooterBar(model: model, onClose: onClose)
        }
    }
}

/// Shown when someone tries to close Setup with a permission still missing.
private struct BlockedDismissNotice: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Color.weft)
            Text("Weft cannot tile, resize or respond to a keybind until these are granted — so this window stays until they are. Quit WeftBar from the menu bar icon if you would rather stop here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.weft.opacity(0.10))
        )
    }
}

/// Shown when the switches are all on and the engine still cannot use them.
///
/// macOS decides whether a process is Accessibility-trusted when that process
/// opens its connections, not when you ask. A daemon that was already running
/// when the switch flipped therefore reports the grant *and* fails every call
/// — a state weft used to sit in silently, looking installed and doing
/// nothing, until the user happened to restart it. There is exactly one fix
/// and it is one click, so it goes on screen as one button.
private struct RestartBanner: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(Color.weft)
                .font(.system(size: 17))
            VStack(alignment: .leading, spacing: 8) {
                Text("One restart and weft is ready")
                    .font(.system(size: 13, weight: .semibold))
                Text("Everything is granted. The engine was already running when you granted it, and macOS only hands out that access at launch — so it needs to start once more to pick it up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.restartEngine()
                } label: {
                    HStack(spacing: 6) {
                        if model.isRestarting { ProgressView().controlSize(.small) }
                        Text(model.isRestarting ? "Restarting…" : "Restart the engine")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRestarting)
                .keyboardShortcut(.defaultAction)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.weft.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.weft.opacity(0.32), lineWidth: 1)
        )
    }
}

/// Shown when weftd was rebuilt after being granted.
///
/// Without this the flow is unwinnable and looks like weft's fault: the pane
/// says granted, Setup says missing, and there is no third thing on screen to
/// explain how both can be true.
private struct StaleGrantBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 4) {
                Text("System Settings will show these as already on")
                    .font(.system(size: 13, weight: .semibold))
                Text("weft was rebuilt since you granted it, and macOS ties a permission to the exact program it was granted to. The switches are on for the old one. **Turn each switch off and back on** — that is the whole fix, and it only happens on this build.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

private struct FooterBar: View {
    @ObservedObject var model: SetupModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The path is here rather than in a card: it is what the user needs
            // only in the fallback case, and it belongs with the machinery
            // rather than shouting from inside a step.
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("Granting to")
                Text(model.weftdPath)
                    .textSelection(.enabled)
                    .truncationMode(.middle)
                    .lineLimit(1)
                Button {
                    model.copyPath()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy the path")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)

            HStack(spacing: 12) {
                if model.canDismiss { CloseButton(action: onClose) }
                Spacer()
                Button {
                    model.restartEngine()
                } label: {
                    HStack(spacing: 6) {
                        if model.isRestarting { ProgressView().controlSize(.small) }
                        Text(model.isRestarting ? "Restarting…" : "Restart engine")
                    }
                }
                .controlSize(.large)
                .disabled(model.isRestarting)
                .help("Only if a granted switch still reads as missing here")

                Button {
                    if let step = model.activeStep { model.focusStep(step) } else { model.advanceStep() }
                } label: {
                    Text(model.activeStep == nil ? "Continue" : "Reopen pane")
                        .frame(minWidth: 108)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 14)
        .padding(.bottom, 22)
    }
}

private struct ProgressBar: View {
    let granted: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.weft, .weftDeep],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        // No floor on the width: a minimum left a filled pip
                        // sitting at "0 of 2", which reads as partial progress
                        // before anything has been granted.
                        .frame(width: geo.size.width * CGFloat(granted) / CGFloat(max(total, 1)))
                }
            }
            .frame(height: 6)
            .animation(.spring(response: 0.55, dampingFraction: 0.8), value: granted)

            Text("\(granted) of \(total) required")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Permission card

private struct PermissionCard: View {
    let kind: PermissionKind
    /// The switch in System Settings.
    let granted: Bool
    /// Whether what this row buys actually works.
    let satisfied: Bool
    /// Working, with its own switch still off.
    let covered: Bool
    let isActive: Bool
    @ObservedObject var model: SetupModel

    private var expanded: Bool { isActive && !satisfied }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                instructions
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(expanded ? 0.06 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    satisfied ? Color.green.opacity(0.35)
                        : expanded ? Color.weft.opacity(0.55)
                        : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        )
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: satisfied)
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: expanded)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(satisfied ? Color.green.opacity(0.16) : Color.weft.opacity(0.15))
                Image(systemName: satisfied ? "checkmark" : kind.symbol)
                    .font(.system(size: 16, weight: satisfied ? .bold : .regular))
                    .foregroundStyle(satisfied ? Color.green : Color.weft)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(kind.title)
                        .font(.system(size: 14, weight: .semibold))
                    Chip(
                        text: kind.isRequired ? "Required" : "Optional",
                        tint: kind.isRequired ? Color.weft : Color.secondary
                    )
                }
                Text(covered ? "Working — but the Input Monitoring switch is still off." : kind.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if satisfied {
                // "Granted" is a claim about what the user did, so it is only
                // used when they actually did it. Accessibility is enough for
                // macOS to let weftd open the event tap, and reporting that as
                // a grant sent people looking for a switch they had never
                // touched — and finding it off.
                Text(covered ? "Covered" : "Granted")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                    .help(covered
                        ? "Accessibility already lets weftd read your keybinds. Turning Input Monitoring on as well is optional."
                        : "The switch is on in System Settings.")
                    .transition(.scale.combined(with: .opacity))
            } else if expanded {
                WaitingPip()
            } else {
                Button("Open") { model.focusStep(kind) }
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 13)

            Text("In System Settings › \(kind.settingsPath)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 9) {
                Step(1, "Find the row named **weftd** in the list.")
                if model.showsStaleGrantWarning {
                    // The only instruction that works when the switch is
                    // already on. Telling someone to "turn it on" in that
                    // state is not a hard instruction, it is an impossible
                    // one, and they conclude weft is broken — correctly.
                    Step(2, "Its switch is probably **already on**. Turn it **off**, then **on** again.")
                    Step(3, "If macOS offers to quit and reopen, choose **Later**.")
                } else {
                    Step(2, "Turn its switch **on**. If it is already on, turn it **off and on again**.")
                    Step(3, "If macOS offers to quit and reopen, choose **Later** — weft picks the grant up on its own.")
                }
            }

            fallback
                .padding(.top, 14)
        }
    }

    @ViewBuilder
    private var fallback: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    model.showsFallback.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(model.showsFallback ? 90 : 0))
                    Text("No weftd row in the list?")
                        .font(.system(size: 12, weight: .medium))
                    if model.isStuck && !model.showsFallback {
                        Chip(text: "Still waiting", tint: .orange)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isStuck ? Color.orange : Color.secondary)

            if model.showsFallback {
                VStack(alignment: .leading, spacing: 9) {
                    // `~/.local/bin` is a hidden directory, so the pane's `+`
                    // picker will not browse to it. Dragging or ⌘⇧G are the
                    // only two ways in, and both need the path — which the
                    // reveal button puts on the clipboard on the way past.
                    Step(1, "Click **Reveal weftd** — Finder opens with the file selected and its path copied.")
                    Step(2, "Drag **weftd** from that Finder window onto the list in System Settings.")
                    Step(3, "Or click **+** in the list, press **⌘⇧G**, and paste the path.")

                    HStack(spacing: 10) {
                        Button("Reveal weftd", action: model.revealBinary)
                        Button("Copy path", action: model.copyPath)
                    }
                    .controlSize(.small)
                    .padding(.top, 3)
                }
                .padding(.top, 11)
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 3)
    }
}

private struct Step: View {
    let index: Int
    let text: String

    init(_ index: Int, _ text: String) {
        self.index = index
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(index)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.weft)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.weft.opacity(0.15)))
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4.5 }
            Text(.init(text))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.16)))
            .foregroundStyle(tint)
    }
}

/// A breathing dot rather than a spinner: the flow is not working on anything,
/// it is watching. A spinner here reads as "wait for me", which is the wrong
/// instruction — the next move is the user's.
private struct WaitingPip: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color.weft)
                .frame(width: 7, height: 7)
                .scaleEffect(pulse ? 1.0 : 0.55)
                .opacity(pulse ? 1 : 0.4)
            Text("Waiting")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.weft)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Page 3

private struct DonePage: View {
    @ObservedObject var model: SetupModel
    let onClose: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.14))
                    .frame(width: 106, height: 106)
                    .scaleEffect(appeared ? 1 : 0.5)
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.green)
                    .scaleEffect(appeared ? 1 : 0.3)
                    .opacity(appeared ? 1 : 0)
            }

            Text("Weft is ready")
                .font(.system(size: 29, weight: .semibold))
                .padding(.top, 24)
                .opacity(appeared ? 1 : 0)

            Text("Windows tile, keybinds fire.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .opacity(appeared ? 1 : 0)

            // Named, not summarised. "Everything required is granted" is the
            // one sentence a user cannot check, and when it was wrong — a live
            // event tap counted as an Input Monitoring grant — there was
            // nothing on the page to catch it. Three rows saying what each
            // switch actually reads costs the same space and cannot lie.
            VStack(alignment: .leading, spacing: 11) {
                ForEach(PermissionKind.allCases) { kind in
                    SummaryRow(
                        kind: kind,
                        granted: model.granted(kind),
                        satisfied: model.satisfied(kind),
                        covered: model.coveredByAccessibility(kind)
                    )
                }
            }
            .padding(.top, 30)
            .frame(maxWidth: 420, alignment: .leading)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)

            Text("Press **⌘K** for the cheatsheet. Everything else lives in the menu-bar icon.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 22)
                .frame(maxWidth: 420, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(appeared ? 1 : 0)

            Spacer()

            VStack(spacing: 12) {
                Button(action: model.finish) {
                    HStack(spacing: 8) {
                        if model.isRestarting { ProgressView().controlSize(.small) }
                        Text(model.isRestarting ? "Restarting…" : "Finish")
                    }
                    .frame(width: 190)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRestarting)

                Text("Restarts the engine once so it starts clean.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                CloseButton(action: onClose)
                    .padding(.top, 2)
            }
            .padding(.bottom, 42)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.62)) { appeared = true }
        }
    }
}

// MARK: - Icon

/// The app icon from the bundle, so Setup and the Dock never disagree. Falls
/// back to the accent tile when running unbundled (`swift run`).
/// The real app icon — the one in the Dock, the Finder and the About box —
/// rather than a second drawing of it.
///
/// Shared with the Settings sidebar. A hand-rolled SF Symbol in a gradient
/// square is a *different* mark from the one the app actually ships, so the
/// window that is most obviously "this app's settings" was the one place the
/// app's own icon did not appear.
struct AppIcon: View {
    var body: some View {
        if let icon = NSImage(named: "WeftBar") ?? NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.weft)
        }
    }
}

/// One permission, on the final page: what it reads and what that buys.
private struct SummaryRow: View {
    let kind: PermissionKind
    let granted: Bool
    let satisfied: Bool
    let covered: Bool

    private var status: (text: String, tint: Color, symbol: String) {
        if covered {
            return ("Covered by Accessibility", .green, "checkmark.circle.fill")
        }
        if satisfied { return ("Granted", .green, "checkmark.circle.fill") }
        if kind.isRequired { return ("Missing", .orange, "exclamationmark.circle.fill") }
        return ("Off — optional", .secondary, "minus.circle")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.symbol)
                .font(.system(size: 15))
                .foregroundStyle(status.tint)
                .frame(width: 18)
            Text(kind.title)
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            Text(status.text)
                .font(.system(size: 12))
                .foregroundStyle(status.tint == .secondary ? .secondary : status.tint)
        }
    }
}

// MARK: - Window

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var dismissWatch: AnyCancellable?

    static var flagURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/weft/.onboarded")
    }

    private let model = SetupModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 660),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.title = "Weft Setup"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.contentView = NSHostingView(
            rootView: SetupView(model: model) { [weak self] in self?.hide() }
        )
        window.delegate = self
        // The title bar has its own close button, and it does not consult the
        // view. Keep it in step with whether Setup is dismissable at all.
        dismissWatch = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.syncCloseButton() }
        }
        syncCloseButton()
    }

    private func syncCloseButton() {
        window?.standardWindowButton(.closeButton)?.isEnabled = model.canDismiss
    }

    /// The red button and ⌘W, gated the same way as the in-page Close.
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            guard model.canDismiss else {
                // Say why, rather than swallowing the click and looking broken.
                NSSound.beep()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                    model.flashBlockedDismiss()
                }
                return false
            }
            model.stopPolling()
            return true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Off the main thread: the socket read blocks, and at login it blocks
    /// while the daemon is still coming up.
    ///
    /// Silence is not an answer. Once the flag is written, Setup reopens only
    /// when weftd *says* something is missing — never because it was too busy
    /// starting to reply, which is the state WeftBar is in every single time
    /// it is relaunched right after a service restart.
    static func shouldShow() async -> Bool {
        if !FileManager.default.fileExists(atPath: flagURL.path) { return true }
        guard let p = await awaitDaemon() else { return false }
        return !p.ready
    }

    /// Poll the socket until the daemon answers, up to `timeout`. Returns nil
    /// if it never does.
    static func awaitDaemon(timeout: TimeInterval = 6) async -> DaemonPermissions? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let p = await Task.detached(priority: .utility, operation: {
                query()
            }).value {
                return p
            }
            guard Date() < deadline else { return nil }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// One blocking round trip. Never call on the main thread.
    nonisolated static func query() -> DaemonPermissions? {
        guard let json = BarIPC.send("query permissions"),
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(DaemonPermissions.self, from: data)
    }

    func show() {
        model.startPolling()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        guard model.canDismiss else {
            NSSound.beep()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                model.flashBlockedDismiss()
            }
            return
        }
        model.stopPolling()
        window?.orderOut(nil)
    }
}
