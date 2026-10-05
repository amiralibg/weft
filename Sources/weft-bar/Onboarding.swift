import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import SwiftUI
import WeftPlatform
import WeftBarConfig

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
    /// Screen Recording is deliberately not part of this. Titles come from
    /// Accessibility, so weft is fully working without it, and counting it
    /// here would leave weft reporting itself unfinished — and the menu bar
    /// carrying a permissions row — for a permission nothing is waiting on.
    var ready: Bool { accessibility && tapLive && !mustRestart }
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
        case .screenRecording:
            return "Optional. A faster path to window titles; weft reads them without it."
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

    /// Accessibility and Input Monitoring are required. Screen Recording is
    /// not.
    ///
    /// It was, and for a real reason: without it macOS redacts
    /// `kCGWindowName` for every window weftd does not own, so title rules
    /// never fired and the switcher listed blank rows. weftd reads titles
    /// through Accessibility now — the same string, a permission it cannot
    /// work without anyway — so nothing breaks when this is off.
    ///
    /// The grant is still worth having: the window list carries titles with no
    /// round trip. It just is not a thing to stop setup over, and it is the
    /// one of the three that asks the most of the user for the least.
    var isRequired: Bool { self != .screenRecording }

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
    @Published var page: Page = .welcome {
        // Set in the same transaction as the page, so the page that slides in
        // already knows which side to come from.
        willSet { movedForward = newValue.order >= page.order }
    }
    /// Whether the last page change went on through the flow or back.
    @Published private(set) var movedForward = true
    /// The permission the flow is currently waiting on, if any.
    @Published var activeStep: PermissionKind?
    @Published var isRestarting = false
    /// Opened by the user, or by the flow after a long enough wait. Holds the
    /// "weftd is not in the list" recovery: reveal, drag, paste the path.
    @Published var showsFallback = false
    /// The card whose instructions are showing. The flow opens the step it
    /// moves to; the user can open and close any unsatisfied row by clicking
    /// it. Kept apart from `activeStep` because that gets cleared by states
    /// this row knows nothing about — a pending engine restart, most of all —
    /// and expansion used to read straight off it, so the card someone was
    /// mid-way through following sealed itself shut a second after they
    /// opened it, with no way to prise it back open.
    @Published var openedCard: PermissionKind?
    /// Seconds the current step has been waiting. Drives the "still nothing?"
    /// hint rather than a spinner that says the same thing forever.
    @Published var waitedSeconds = 0
    /// Installing the engine this app carries: the step the installer is on,
    /// and — when it stopped — the last thing it said.
    @Published var installStep = ""
    @Published var installing = false
    @Published var installError: String?

    enum Page: Int {
        case welcome, workspacesIntro, keys, permissions, done, install

        /// The pages the progress dots count. Install comes before them all
        /// and only when the engine is missing, so it is not one of the steps.
        static let steps: [Page] = [.welcome, .workspacesIntro, .keys, .permissions, .done]

        var order: Int { Self.steps.firstIndex(of: self) ?? -1 }

        /// 0…1 through the flow: how far the cloth behind it has grown.
        var progress: Double { Double(max(order, 0)) / Double(Self.steps.count - 1) }
    }


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

    /// 0…1: how far the zip over the stage is pulled. Each page pulls it one
    /// notch; on the permissions page each switch that starts working pulls it
    /// most of the way to the next, so the last tug — Done — is a short one.
    var zipperProgress: Double {
        var notch = Double(max(page.order, 0))
        if page == .permissions, requiredCount > 0 {
            notch += 0.7 * Double(grantedCount) / Double(requiredCount)
        }
        return min(notch / Double(Page.steps.count - 1), 1)
    }

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

    /// Every required row is working. What the restart banner claims, and so
    /// what it has to wait for.
    var allRequiredSatisfied: Bool {
        PermissionKind.allCases.filter(\.isRequired).allSatisfy(satisfied)
    }

    /// Every switch is on and the engine still cannot work, because it was
    /// running before the switches were flipped. One button fixes it, so the
    /// page shows one button.
    ///
    /// weftd reports the pending restart the moment Accessibility lands, which
    /// is two steps before the flow is done. Taken at face value that put a
    /// banner reading "Everything is granted" above a Screen Recording row
    /// that plainly was not — and, because the restart branch clears
    /// `activeStep`, it collapsed the card the user was standing on a second
    /// after they opened it, so the drag-weftd-into-the-list instructions and
    /// the button that reveals the binary could not be reached at all. The
    /// restart is the last thing left, or it is not yet the thing to say.
    var needsEngineRestart: Bool { (perms?.mustRestart ?? false) && allRequiredSatisfied }

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

    func runInstall() {
        guard !installing else { return }
        installing = true
        installError = nil
        installStep = "Starting"
        Task { @MainActor [weak self] in
            let outcome = await EngineInstaller.install { step in
                Task { @MainActor in self?.installStep = step }
            }
            guard let self else { return }
            if outcome.ok {
                // The service was just bootstrapped; give it a moment to open
                // its socket before the permissions page asks it anything.
                _ = await OnboardingWindowController.awaitDaemon()
                self.installing = false
                self.refresh()
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    self.page = .welcome
                }
            } else {
                self.installing = false
                let lines = outcome.log.split(separator: "\n").map(String.init)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                self.installError = lines.suffix(3).joined(separator: "\n")
            }
        }
    }

    /// The engine is not answering. Install the one this app carries if none
    /// is in place yet; otherwise restart the one that is.
    func startEngine() {
        let installed = FileManager.default.isExecutableFile(
            atPath: EngineInstaller.binDir.appendingPathComponent("weftctl").path
        )
        if !installed, EngineInstaller.bundledWeftctl != nil {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { page = .install }
        } else {
            restartEngine()
        }
    }

    /// Welcome → the workspaces explainer. Permissions come after it, because
    /// the model is what every later screen is about and the permission panes
    /// take the user out to System Settings and back.
    func beginWorkspaces() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            page = .workspacesIntro
        }
    }

    func goTo(_ next: Page) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { page = next }
    }

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
            // Nothing left to switch on. If the engine still has to restart
            // before it can use any of it, "you are all set" is one page too
            // early — the banner that fixes it lives on this one.
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                activeStep = nil
                openedCard = nil
                if !needsEngineRestart { page = .done }
            }
            return
        }
        focusStep(next)
    }

    func focusStep(_ kind: PermissionKind) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            activeStep = kind
            openedCard = kind
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
        // Input Monitoring is the one permission where opening the pane is not
        // enough: TCC only puts a weftd row in that list once weftd has asked
        // for it, and weftd is a daemon with no window, so its own request
        // used to fire during startup and drop a system modal on top of this
        // window. Ask now instead — the user is looking at the Input
        // Monitoring step, so the modal explains itself, and the row is there
        // by the time the pane opens.
        // Every permission is asked for here, at the step the user is looking
        // at, and nowhere else: asking is what makes macOS list weftd, and it
        // puts up macOS's own dialog. Fire and forget — the request is weftd's
        // to make (the grant is per binary), and the pane opens either way.
        //
        // Waited on, not fired and forgotten. `post` hands the request to a
        // background queue and returns immediately, so the pane opened in the
        // same breath — and System Settings renders that list once, on open,
        // from whatever TCC holds at that instant. Losing the race meant the
        // pane appeared with no weftd row in it, which is precisely the state
        // the step exists to avoid: the user is told to flip a switch that is
        // not there, and ends up adding the binary by hand with the + button.
        // The reply costs a few milliseconds on a unix socket, and it means
        // the row is registered before anything is drawn.
        let command: String
        switch kind {
        case .accessibility: command = "request-accessibility"
        case .inputMonitoring: command = "request-input-access"
        case .screenRecording: command = "request-screen-recording"
        }
        Task.detached {
            let reply = BarIPC.send(command)
            // "prompted" means macOS is showing its own dialog right now. It
            // already explains the permission and carries a button to the
            // pane, so opening the pane as well just slides a window under a
            // modal — which is what made the first run feel like being asked
            // the same thing twice. Every other reply: open the pane, which is
            // the whole point of the step.
            guard reply?.trimmingCharacters(in: .whitespacesAndNewlines) != "prompted" else {
                return
            }
            await MainActor.run { NSWorkspace.shared.open(url) }
        }
    }

    func revealBinary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(weftdPath, forType: .string)
        let fileURL = URL(fileURLWithPath: weftdPath)
        if FileManager.default.fileExists(atPath: weftdPath) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            NSWorkspace.shared.open(fileURL.deletingLastPathComponent())
        }
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

/// Whether Setup's window can be seen. Everything on the stage that moves on
/// its own reads it, so a covered or hidden Setup costs nothing — WeftBar is
/// running all day and this window is kept between showings.
private struct StageVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isStageVisible: Bool {
        get { self[StageVisibleKey.self] }
        set { self[StageVisibleKey.self] = newValue }
    }
}

/// Reports whether the window is on screen and uncovered.
private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> NSView { Probe(isVisible: $isVisible) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        private let isVisible: Binding<Bool>
        private var observer: NSObjectProtocol?

        init(isVisible: Binding<Bool>) {
            self.isVisible = isVisible
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = window.map { window in
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        private func report() {
            // Hidden (ordered out) and fully covered both read as not visible;
            // showing the window posts the change that starts things again.
            let visible = window?.occlusionState.contains(.visible) ?? false
            if isVisible.wrappedValue != visible { isVisible.wrappedValue = visible }
        }
    }
}

/// A translucent card on the dark stage.
private struct StageCard: ViewModifier {
    var radius: CGFloat = 14
    var fill: Double = 0.05
    var stroke: Color = .white.opacity(0.08)

    func body(content: Content) -> some View {
        content
            .background(.white.opacity(fill), in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: 1))
    }
}

extension View {
    fileprivate func stageCard(radius: CGFloat = 14, fill: Double = 0.05, stroke: Color = .white.opacity(0.08)) -> some View {
        modifier(StageCard(radius: radius, fill: fill, stroke: stroke))
    }
}

/// A small secondary action on the stage: a quiet capsule.
private struct StageButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(.white.opacity(configuration.isPressed ? 0.18 : 0.11), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.hover, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

// MARK: - Root

struct SetupView: View {
    static let size = CGSize(width: 880, height: 640)

    @ObservedObject var model: SetupModel
    var onClose: () -> Void

    @State private var isStageVisible = true
    /// The Done page, laid out under the cloth. Held back a moment after the
    /// page changes, so its entrance plays while the halves part over it
    /// rather than before anyone can see it.
    @State private var revealsDone = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Back to front: the loom, the Done page waiting on it, the zipped
            // cloth over both, and the current page on the cloth.
            LoomBackdrop(accent: .weft, progress: model.page.progress, beatID: model.page.order)
                .animation(.easeInOut(duration: 1.2), value: model.page)
            stageLayout {
                if revealsDone && model.page == .done {
                    ScaleToFit { DonePage(model: model) }
                }
            }
            ZipperBackdrop(accent: .weft, progress: model.zipperProgress, isOpen: model.page == .done)
            stageLayout(top: topBar, bottom: controls) { page }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(\.isStageVisible, isStageVisible)
        .background(WindowVisibilityReader(isVisible: $isStageVisible))
        .tint(.weft)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.rightArrow) { forward(); return .handled }
        .onKeyPress(.leftArrow) { back(); return .handled }
        .onKeyPress(.escape) {
            if model.canDismiss { onClose() } else { model.flashBlockedDismiss() }
            return .handled
        }
        .task(id: model.page == .done) {
            guard model.page == .done else {
                revealsDone = false
                return
            }
            // Roughly when the slider reaches the bottom stop and the halves
            // start to part.
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(320)) }
            guard !Task.isCancelled else { return }
            revealsDone = true
        }
    }

    /// The stage's frame: a top bar, the page, the controls. The Done page
    /// under the cloth and the pages on it share it, so they line up exactly.
    private func stageLayout<Top: View, Bottom: View, Content: View>(
        top: Top, bottom: Bottom, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            top
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottom
        }
        .padding(.horizontal, 44)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    private func stageLayout<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        stageLayout(
            top: Color.clear.frame(height: 30),
            bottom: Color.clear.frame(height: 44),
            content: content
        )
    }

    // MARK: Chrome

    /// The window's traffic lights sit on the left; Close is on the right, and
    /// only while Setup may be closed at all.
    private var topBar: some View {
        HStack {
            Spacer()
            if showsClose {
                Button("Close", action: onClose)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(minHeight: 30)
                    .contentShape(.rect)
                    .help("Close Setup (esc)")
                    .transition(.opacity)
            }
        }
        .frame(height: 30)
        .animation(.chrome, value: showsClose)
    }

    private var showsClose: Bool { model.canDismiss && !model.installing }

    @ViewBuilder private var page: some View {
        Group {
            switch model.page {
            case .install: ScaleToFit { InstallPage(model: model) }
            case .welcome: ScaleToFit { WelcomePage(model: model) }
            case .workspacesIntro: ScaleToFit { WorkspacesIntroPage() }
            case .keys: ScaleToFit { KeysPage() }
            case .permissions: PermissionsPage(model: model)
            // Done is not on the cloth: it is under it, uncovered as the
            // halves part.
            case .done: Color.clear.allowsHitTesting(false)
            }
        }
        .id(model.page)
        .transition(.asymmetric(
            insertion: .offset(x: model.movedForward ? 60 : -60).combined(with: .opacity),
            removal: .offset(x: model.movedForward ? -60 : 60).combined(with: .opacity)
        ))
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button("Back", action: back)
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 80, height: 44, alignment: .leading)
                .contentShape(.rect)
                .opacity(previous == nil ? 0 : 1)
                .disabled(previous == nil)
                .help("Back (←)")
            Spacer()
            if model.page != .install {
                ProgressDots(page: model.page) { target in
                    guard target.order < model.page.order else { return }
                    model.goTo(target)
                }
                .transition(.opacity)
            }
            Spacer()
            if showsRestartEngine {
                Button(model.isRestarting ? "Restarting…" : "Restart engine", action: model.restartEngine)
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                    .disabled(model.isRestarting)
                    .help("Only if a switch you turned on still reads as missing here")
                    .transition(.opacity)
            }
            PrimaryButton(title: primaryTitle, isBusy: primaryIsBusy, action: primary)
                .disabled(!primaryIsEnabled)
        }
        .animation(.chrome, value: primaryTitle)
        .animation(.chrome, value: showsRestartEngine)
        .frame(maxWidth: 760)
    }

    // MARK: Flow

    /// Where Back goes, if anywhere. Done has no Back: by then the flow has
    /// granted everything and the only way on is Finish.
    private var previous: SetupModel.Page? {
        switch model.page {
        case .workspacesIntro: return .welcome
        case .keys: return .workspacesIntro
        case .permissions: return .keys
        case .install, .welcome, .done: return nil
        }
    }

    private var showsRestartEngine: Bool {
        model.page == .permissions && !model.needsEngineRestart && !model.allRequiredSatisfied
    }

    private var primaryTitle: String {
        switch model.page {
        case .install:
            if model.installing { return "Installing…" }
            return model.installError == nil ? "Install" : "Try again"
        case .welcome: return model.requiredGranted ? "Review setup" : "Get started"
        case .workspacesIntro, .keys: return "Continue"
        case .permissions:
            if model.needsEngineRestart { return model.isRestarting ? "Restarting…" : "Restart the engine" }
            return model.activeStep == nil ? "Continue" : "Reopen pane"
        case .done: return model.isRestarting ? "Restarting…" : "Finish"
        }
    }

    private var primaryIsBusy: Bool {
        switch model.page {
        case .install: return model.installing
        case .permissions: return model.needsEngineRestart && model.isRestarting
        case .done: return model.isRestarting
        case .welcome, .workspacesIntro, .keys: return false
        }
    }

    private var primaryIsEnabled: Bool {
        switch model.page {
        case .install: return !model.installing
        case .welcome: return model.daemonReachable
        case .workspacesIntro, .keys: return true
        case .permissions, .done: return !model.isRestarting
        }
    }

    private func primary() {
        guard primaryIsEnabled else { return }
        switch model.page {
        case .install: model.runInstall()
        case .welcome: model.beginWorkspaces()
        case .workspacesIntro: model.goTo(.keys)
        case .keys: model.beginPermissions()
        case .permissions:
            if model.needsEngineRestart {
                model.restartEngine()
            } else if let step = model.activeStep {
                model.focusStep(step)
            } else {
                model.advanceStep()
            }
        case .done: model.finish()
        }
    }

    /// → moves on only where that is just reading on. It never presses a
    /// button that opens System Settings or restarts anything.
    private func forward() {
        switch model.page {
        case .welcome where model.daemonReachable: model.beginWorkspaces()
        case .workspacesIntro: model.goTo(.keys)
        case .keys: model.beginPermissions()
        default: break
        }
    }

    private func back() {
        guard let previous else { return }
        model.goTo(previous)
    }
}

/// The one filled button on the stage: an accent capsule, ↩ to press.
private struct PrimaryButton: View {
    let title: String
    let isBusy: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().controlSize(.small).tint(.white)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.opacity)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(minWidth: 96, minHeight: 44)
            .background(Color.weft.gradient, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: Color.weft.opacity(isEnabled ? 0.45 : 0), radius: 18, y: 6)
            .opacity(isEnabled || isBusy ? 1 : 0.4)
            .contentShape(Capsule())
            .animation(.chrome, value: isBusy)
        }
        .buttonStyle(PressableStyle())
        .keyboardShortcut(.defaultAction)
        .help(title + " (↩)")
    }
}

private struct ProgressDots: View {
    let page: SetupModel.Page
    let onSelect: (SetupModel.Page) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SetupModel.Page.steps, id: \.self) { candidate in
                Button { onSelect(candidate) } label: {
                    Capsule()
                        .fill(candidate == page ? AnyShapeStyle(.tint)
                            : AnyShapeStyle(.white.opacity(candidate.order < page.order ? 0.5 : 0.18)))
                        .frame(width: candidate == page ? 28 : 8, height: 8)
                        .frame(height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(candidate.order >= page.order)
                .accessibilityLabel("Step \(candidate.order + 1) of \(SetupModel.Page.steps.count)")
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: page)
    }
}

/// Lays the page out at its natural size and shrinks it to fit, so nothing
/// truncates or clips when a page carries more than usual; it never scales up.
private struct ScaleToFit<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        GeometryReader { container in
            let scale = naturalHeight > 0 ? min(1, container.size.height / naturalHeight) : 1
            content
                .frame(width: min(container.size.width / max(scale, 0.01), 820))
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { naturalHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in naturalHeight = height }
                })
                .scaleEffect(scale)
                .frame(width: container.size.width, height: container.size.height)
        }
    }
}

/// An eyebrow, a big headline, a line of body copy, then the page's own
/// content, each arriving a beat after the last.
private struct StepLayout<Content: View>: View {
    let eyebrow: String
    let title: String
    let detail: String
    var titleSize: CGFloat = 44
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 13) {
                Eyebrow(text: eyebrow).arrive(after: 0)
                RevealText(text: title, size: titleSize, delay: 0.05)
                Text(.init(detail))
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 540)
                    .arrive(after: 0.25)
            }
            content.arrive(after: 0.4)
        }
        .frame(maxWidth: 760)
    }
}

private struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(.tint)
    }
}

/// A key (or a mark) and what it does, as a capsule.
private struct Hint: View {
    var keys: String?
    var symbol: String?
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            if let keys {
                Text(keys)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(.white.opacity(0.12), in: .rect(cornerRadius: 7, style: .continuous))
            }
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 24, height: 24)
            }
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.72))
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(height: 40)
        .background(.white.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.07), lineWidth: 1))
    }
}

/// An icon, a title and a sentence — the rows inside a stage card.
private struct FeatureRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(Color.weft.opacity(0.14), in: .rect(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(.init(text))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - The icon, at hero size

/// weft's icon, drawn rather than loaded: its four tiles fly in and settle
/// into the layout the icon shows, and the whole mark floats a little.
private struct TileHero: View {
    var size: CGFloat = 190

    @State private var isShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isStageVisible) private var isStageVisible

    /// The icon's tiles, in its own 840-point frame.
    private static let tiles: [(rect: CGRect, radius: CGFloat, color: Color)] = [
        (CGRect(x: 131, y: 131, width: 260, height: 577), 46, Color(.sRGB, red: 0.52, green: 0.63, blue: 0.94, opacity: 1)),
        (CGRect(x: 449, y: 131, width: 259, height: 260), 46, Color(.sRGB, red: 0.27, green: 0.32, blue: 0.49, opacity: 1)),
        (CGRect(x: 449, y: 449, width: 100, height: 259), 50, Color(.sRGB, red: 0.23, green: 0.28, blue: 0.43, opacity: 1)),
        (CGRect(x: 607, y: 449, width: 101, height: 259), 50, Color(.sRGB, red: 0.21, green: 0.25, blue: 0.37, opacity: 1)),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !isStageVisible)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let unit = size / 840
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 225 * unit, style: .continuous)
                    .fill(Color(.sRGB, red: 0.106, green: 0.118, blue: 0.176, opacity: 1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 225 * unit, style: .continuous)
                            .strokeBorder(
                                LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom),
                                lineWidth: 1
                            )
                    )
                    .scaleEffect(isShown ? 1 : 0.86)
                    .opacity(isShown ? 1 : 0)
                    .animation(reduceMotion ? .easeOut(duration: 0.3) : .spring(response: 0.8, dampingFraction: 0.8), value: isShown)
                ForEach(Self.tiles.indices, id: \.self) { index in
                    let tile = Self.tiles[index]
                    let depth = Double(index)
                    RoundedRectangle(cornerRadius: tile.radius * unit, style: .continuous)
                        .fill(tile.color.gradient)
                        .frame(width: tile.rect.width * unit, height: tile.rect.height * unit)
                        .shadow(color: .black.opacity(0.3), radius: 6 * unit * 10, y: 3)
                        .offset(
                            x: tile.rect.minX * unit + (isShown ? 0 : size * 0.9 + depth * 30),
                            y: tile.rect.minY * unit + (isShown ? 0 : -size * 0.25)
                        )
                        .rotation3DEffect(.degrees(isShown ? 0 : -40), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                        .opacity(isShown ? 1 : 0)
                        .animation(
                            reduceMotion ? .easeOut(duration: 0.3)
                                : .spring(response: 0.85, dampingFraction: 0.78).delay(0.15 + 0.09 * depth),
                            value: isShown
                        )
                }
            }
            .frame(width: size, height: size)
            .rotation3DEffect(.degrees(sin(t * 0.5) * 7), axis: (x: 0.2, y: 1, z: 0), perspective: 0.5)
            .offset(y: sin(t * 0.9) * 4)
            .background {
                // The icon's own light, spilling onto the stage.
                Circle()
                    .fill(Color.weft.opacity(0.35))
                    .frame(width: size * 1.1, height: size * 1.1)
                    .blur(radius: size * 0.32)
                    .opacity(isShown ? 1 : 0)
                    .animation(.easeOut(duration: 1.2).delay(0.3), value: isShown)
            }
            .shadow(color: .black.opacity(0.45), radius: 28, y: 18)
        }
        .onAppear { isShown = true }
        .accessibilityHidden(true)
    }
}

// MARK: - Page 0: the engine

/// Shown when this app carries an engine that is not installed yet, or when
/// catching it up after an app update failed. One button, and a plain account
/// of what it does: it registers a login service and pauses yabai/skhd, and
/// nobody should find either out afterwards.
private struct InstallPage: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 26) {
            TileHero(size: 150)
                .frame(height: 170)
            VStack(spacing: 12) {
                RevealText(text: "Install weft.", size: 54, weight: .bold, delay: 0.3)
                Text("One click puts the engine in place. No terminal.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.62))
                    .arrive(after: 0.6)
            }

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    symbol: "shippingbox",
                    title: "The engine",
                    text: "**weftd** and **weftctl** go in `~/.local/bin`, signed so macOS keeps their permissions when weft updates."
                )
                FeatureRow(
                    symbol: "doc.text",
                    title: "A starting config",
                    text: "weft's own defaults, written to `~/.config/weft/weft.toml`. A config you already have is kept. Coming from yabai? `weftctl migrate` converts yours."
                )
                FeatureRow(
                    symbol: "power",
                    title: "Runs at login",
                    text: "Starts by itself when you log in. Remove it any time with Uninstall Weft… in the menu bar."
                )
            }
            .padding(18)
            .frame(maxWidth: 540)
            .stageCard()
            .arrive(after: 0.8)

            Group {
                if model.installing {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.installStep)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.62))
                            .contentTransition(.opacity)
                    }
                    .transition(.opacity)
                } else if let error = model.installError {
                    VStack(spacing: 8) {
                        Label("The install stopped", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .textSelection(.enabled)
                        Button("Show the full log") { NSWorkspace.shared.open(EngineInstaller.logURL) }
                            .buttonStyle(StageButtonStyle())
                    }
                    .padding(14)
                    .frame(maxWidth: 540)
                    .stageCard(fill: 0.04, stroke: .orange.opacity(0.3))
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
            .animation(.chrome, value: model.installing)
            .animation(.chrome, value: model.installError)
        }
    }
}

// MARK: - Page 1

private struct WelcomePage: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 30) {
            TileHero()
                .frame(height: 210)
            VStack(spacing: 14) {
                RevealText(text: "Your windows, woven.", size: 62, weight: .bold, delay: 0.35)
                Text("weft tiles your windows as you open them, and gives every set of them a workspace of its own, a keypress away. Setup takes a minute: a couple of switches in System Settings, and weft opens each one for you.")
                    .font(.system(size: 15.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)
                    .arrive(after: 0.8)
            }
            if model.daemonReachable {
                HStack(spacing: 10) {
                    Hint(symbol: "lock.shield", text: "Granted to weftd, the engine")
                    Hint(symbol: "arrow.right.circle", text: "One pane at a time")
                    Hint(symbol: "bolt", text: "Noticed within a second")
                }
                .arrive(after: 1.0)
            } else {
                DaemonUnreachableNotice(model: model)
                    .arrive(after: 0.6)
            }
        }
    }
}

/// The one failure the flow cannot walk anyone through on its own: with no
/// daemon there is nothing to grant anything to. It used to name a command to
/// go and type; now it is a button — installing the engine if this app carries
/// one that is not in place, restarting it otherwise.
private struct DaemonUnreachableNotice: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("The weft engine isn’t answering.")
                .font(.system(size: 13, weight: .medium))
            Button(model.isRestarting ? "Starting…" : "Start the engine", action: model.startEngine)
                .buttonStyle(StageButtonStyle())
                .disabled(model.isRestarting)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(.orange.opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(.orange.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Page 1b: what a workspace is

/// The one concept weft cannot be used without understanding, shown rather
/// than told: a small desktop switching between three workspaces the way weft
/// really does it — the windows you are leaving slide into the corner, the
/// next set slides out of it.
private struct WorkspacesIntroPage: View {
    var body: some View {
        StepLayout(
            eyebrow: "Workspaces",
            title: "One desktop, many workspaces.",
            detail: "A workspace is a named set of windows with a layout of its own. Switching is instant, and works for every window, even a terminal with no title bar. Full-screen apps and your other macOS desktops keep working."
        ) {
            VStack(spacing: 24) {
                WorkspaceDemo()
                    .frame(width: 440, height: 232)
                HStack(spacing: 10) {
                    Hint(keys: "⌥1  ⌥2  ⌥3", text: "Switch")
                    Hint(keys: "⌥⇧1", text: "Send a window")
                    Hint(symbol: "checkmark.shield", text: "SIP left alone")
                }
            }
        }
    }
}

/// Three workspaces on one desktop, switching every couple of seconds.
///
/// Runs only while this page is showing and Setup can be seen. Each switch is
/// one spring: the outgoing windows shrink into the bottom-right corner, the
/// incoming ones grow out of it, and the pill in the menu bar follows.
private struct WorkspaceDemo: View {
    private struct DemoSet {
        let name: String
        let symbol: String
        let tint: Color
    }
    private let sets = [
        DemoSet(name: "code", symbol: "chevron.left.forwardslash.chevron.right", tint: Color(red: 0.49, green: 0.64, blue: 0.97)),
        DemoSet(name: "web", symbol: "globe", tint: Color(red: 0.36, green: 0.80, blue: 0.62)),
        DemoSet(name: "chat", symbol: "bubble.left.and.bubble.right.fill", tint: Color(red: 0.96, green: 0.62, blue: 0.40)),
    ]
    @State private var showing = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isStageVisible) private var isStageVisible

    var body: some View {
        GeometryReader { geo in
            let bar: CGFloat = 22
            let pad: CGFloat = 10
            let area = CGRect(x: pad, y: bar + pad, width: geo.size.width - pad * 2, height: geo.size.height - bar - pad * 2)
            ZStack(alignment: .topLeading) {
                Wallpaper()
                ForEach(sets.indices, id: \.self) { i in
                    ForEach(0..<3, id: \.self) { slot in
                        let frame = tile(slot, in: area)
                        let here = i == showing
                        DemoWindow(symbol: sets[i].symbol, tint: sets[i].tint, main: slot == 0)
                            .frame(width: frame.width, height: frame.height)
                            .scaleEffect(here ? 1 : 0.08, anchor: .bottomTrailing)
                            .offset(
                                x: here ? frame.minX : geo.size.width - frame.width - 2,
                                y: here ? frame.minY : geo.size.height - frame.height - 2
                            )
                            .opacity(here ? 1 : 0.0)
                            .zIndex(here ? 1 : 0)
                            .animation(
                                .spring(response: 0.6, dampingFraction: 0.82).delay(here ? 0.05 * Double(slot) : 0),
                                value: showing
                            )
                    }
                }
                HStack(spacing: 6) {
                    ForEach(sets.indices, id: \.self) { i in
                        Text("⌥\(i + 1) \(sets[i].name)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(i == showing ? .white : .white.opacity(0.6))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(i == showing ? sets[i].tint.opacity(0.9) : .white.opacity(0.1))
                            )
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: bar)
                .background(Color.black.opacity(0.28))
                .animation(.chrome, value: showing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        .task(id: isStageVisible && !reduceMotion) {
            // Ends with the page, and pauses while Setup is hidden: `.task`
            // is cancelled when either changes, so nothing ticks unseen.
            guard isStageVisible, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.2))
                guard !Task.isCancelled else { return }
                showing = (showing + 1) % sets.count
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Three workspaces on one desktop, switching between each other")
    }

    /// One big window on the left, two stacked on the right: weft's bsp.
    private func tile(_ slot: Int, in area: CGRect) -> CGRect {
        let gap: CGFloat = 6
        let half = (area.width - gap) / 2
        let halfHeight = (area.height - gap) / 2
        switch slot {
        case 0: return CGRect(x: area.minX, y: area.minY, width: half, height: area.height)
        case 1: return CGRect(x: area.minX + half + gap, y: area.minY, width: half, height: halfHeight)
        default: return CGRect(x: area.minX + half + gap, y: area.minY + halfHeight + gap, width: half, height: halfHeight)
        }
    }
}

private struct DemoWindow: View {
    let symbol: String
    let tint: Color
    let main: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(Color.white.opacity(0.13))
            shape.fill(tint.opacity(0.18))
            HStack(spacing: 3.5) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 5, height: 5)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 5, height: 5)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.26)).frame(width: 5, height: 5)
            }
            .padding(7)
            Image(systemName: symbol)
                .font(.system(size: main ? 26 : 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(shape.strokeBorder(tint.opacity(main ? 0.9 : 0.35), lineWidth: main ? 1.5 : 1))
    }
}

// MARK: - Page 1c: the keys

/// The handful of keys that make weft weft, from the config it ships with.
private struct KeysPage: View {
    private let keys: [(keys: [String], title: String, detail: String)] = [
        (["⌥", "H", "J", "K", "L"], "Focus", "The window left, below, above or right"),
        (["⌥", "⇧", "H", "J", "K", "L"], "Move", "Swap the window that way"),
        (["⌥", "1…8"], "Workspace", "Switch to it, instantly"),
        (["⌥", "⇧", "1…8"], "Send", "Put the window on that workspace"),
        (["⌥", "F"], "Fill the screen", "And back, on the same key"),
        (["⌥", "⇧", "Space"], "Float", "Take a window out of the tiling"),
    ]

    var body: some View {
        StepLayout(
            eyebrow: "The keys",
            title: "Six keys to remember.",
            detail: "weft is driven from the keyboard. These are the keys it starts with; keys you brought over from skhd take their place, and Settings › Shortcuts changes any of them."
        ) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    KeyCard(keys: key.keys, title: key.title, detail: key.detail, index: index, count: keys.count)
                }
            }
            .frame(maxWidth: 720)
        }
    }
}

/// A row of keycaps that presses itself in turn, so the grid reads like
/// someone typing.
private struct KeyCard: View {
    let keys: [String]
    let title: String
    let detail: String
    let index: Int
    let count: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isStageVisible) private var isStageVisible

    var body: some View {
        HStack(spacing: 14) {
            // A card changes every 0.6 s; redrawing more often is wasted work.
            TimelineView(.animation(minimumInterval: 0.6, paused: reduceMotion || !isStageVisible)) { timeline in
                let beat = Int(timeline.date.timeIntervalSinceReferenceDate / 0.6) % count
                let pressed = !reduceMotion && beat == index
                HStack(spacing: 4) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        Keycap(label: key, isPressed: pressed)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .stageCard(radius: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(keys.joined(separator: " ")): \(title). \(detail)")
    }
}

private struct Keycap: View {
    let label: String
    let isPressed: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, label.count > 1 ? 6 : 0)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isPressed ? AnyShapeStyle(Color.weft.gradient) : AnyShapeStyle(.white.opacity(0.11)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: Color.weft.opacity(isPressed ? 0.5 : 0), radius: 8)
            .offset(y: isPressed ? 1.5 : 0)
            .scaleEffect(isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: isPressed)
    }
}

// MARK: - Page 2

private struct PermissionsPage: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Eyebrow(text: "Permissions").arrive(after: 0)
                RevealText(text: "Let weft move your windows.", size: 36, delay: 0.05)
                Text(.init("If macOS asks first, choose **Open System Settings**. Then find **weftd** in the list and turn its switch on. Setup moves along by itself as you do."))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)
                    .arrive(after: 0.2)
            }
            .padding(.top, 6)

            VStack(spacing: 12) {
                if model.needsEngineRestart {
                    RestartBanner()
                        .transition(.opacity.combined(with: .offset(y: -8)))
                } else if model.showsStaleGrantWarning {
                    StaleGrantBanner()
                        .transition(.opacity.combined(with: .offset(y: -8)))
                }
                if model.showsBlockedDismissHint {
                    BlockedDismissNotice()
                        .transition(.opacity.combined(with: .offset(y: -8)))
                }
                ProgressBar(granted: model.grantedCount, total: model.requiredCount)
            }
            .frame(maxWidth: 640)
            .padding(.top, 20)
            .animation(.chrome, value: model.needsEngineRestart)
            .animation(.chrome, value: model.showsStaleGrantWarning)
            .animation(.chrome, value: model.showsBlockedDismissHint)
            .arrive(after: 0.3)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(PermissionKind.allCases.enumerated()), id: \.element) { index, kind in
                        PermissionCard(
                            kind: kind,
                            granted: model.granted(kind),
                            satisfied: model.satisfied(kind),
                            covered: model.coveredByAccessibility(kind),
                            model: model
                        )
                        .arrive(after: 0.35 + Double(index) * 0.07)
                    }
                    GrantingTo(model: model)
                        .padding(.top, 6)
                        .arrive(after: 0.6)
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                    .init(color: .black, location: 0.94), .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
        }
    }
}

/// The binary the switches belong to. It matters only in the fallback case,
/// so it sits quietly under the cards rather than inside one.
private struct GrantingTo: View {
    @ObservedObject var model: SetupModel

    var body: some View {
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
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.38))
    }
}

/// Shown when someone tries to close Setup with a permission still missing.
private struct BlockedDismissNotice: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Color.weft)
            Text("Weft cannot tile, resize or respond to a keybind until these are granted — so this window stays until they are. Quit WeftBar from the menu bar icon if you would rather stop here.")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .stageCard(radius: 12, fill: 0.04, stroke: Color.weft.opacity(0.3))
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
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(Color.weft)
                .font(.system(size: 17))
            VStack(alignment: .leading, spacing: 4) {
                Text("One restart and weft is ready")
                    .font(.system(size: 13, weight: .semibold))
                Text("Everything is granted. The engine was already running when you granted it, and macOS only hands out that access at launch — restart the engine to finish setup.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .stageCard(radius: 12, fill: 0.04, stroke: Color.weft.opacity(0.4))
        .background(Color.weft.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
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
                Text(.init("weft was rebuilt since you granted it, and macOS ties a permission to the exact program it was granted to. The switches are on for the old one. **Turn each switch off and back on** — that is the whole fix, and it only happens on this build."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .stageCard(radius: 12, fill: 0.04, stroke: .orange.opacity(0.35))
        .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// The required switches as segments that light up one by one.
private struct ProgressBar: View {
    let granted: Int
    let total: Int

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<max(total, 1), id: \.self) { index in
                    let lit = index < granted
                    Capsule()
                        .fill(lit ? AnyShapeStyle(Color.weft.gradient) : AnyShapeStyle(.white.opacity(0.1)))
                        .frame(height: 5)
                        .shadow(color: Color.weft.opacity(lit ? 0.7 : 0), radius: 6)
                        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(Double(index) * 0.06), value: lit)
                }
            }
            Text("\(granted) of \(total) required")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.chrome, value: granted)
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
    @ObservedObject var model: SetupModel
    @State private var isHovering = false

    // Not `model.activeStep == kind`: the flow's own pointer is cleared by
    // states that have nothing to do with this row, and while expansion read
    // off it a card could collapse under the user mid-instruction. The open
    // card is its own piece of state, set by the flow and by the user, and
    // only ever changed by one of them.
    private var expanded: Bool { !satisfied && model.openedCard == kind }

    /// Anything still ungranted can be opened and closed by hand.
    private var expandable: Bool { !satisfied }

    private func toggle() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
            model.openedCard = expanded ? nil : kind
        }
    }

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
                .fill(.white.opacity(expanded ? 0.075 : isHovering && expandable ? 0.065 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    satisfied ? Color.green.opacity(0.4)
                        : expanded ? Color.weft.opacity(0.6)
                        : Color.white.opacity(0.08),
                    lineWidth: 1
                )
        )
        .shadow(color: expanded ? Color.weft.opacity(0.18) : .clear, radius: 18, y: 6)
        .onHover { hovering in withAnimation(.hover) { isHovering = hovering } }
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: satisfied)
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: expanded)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(satisfied ? Color.green.opacity(0.18) : Color.weft.opacity(0.16))
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
                        tint: kind.isRequired ? Color.weft : Color.white.opacity(0.55)
                    )
                }
                Text(covered ? "Working — but the Input Monitoring switch is still off." : kind.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.6))
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.green)
                    .help(covered
                        ? "Accessibility already lets weftd read your keybinds. Turning Input Monitoring on as well is optional."
                        : "The switch is on in System Settings.")
                    .transition(.scale.combined(with: .opacity))
            } else if expanded {
                WaitingPip()
            } else {
                Button("Open") { model.focusStep(kind) }
                    .buttonStyle(StageButtonStyle())
            }

            if expandable {
                // Says the row has more behind it, and gives the tap target a
                // shape people already know how to read.
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .padding(.leading, 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if expandable { toggle() } }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.vertical, 13)

            Text("In System Settings › \(kind.settingsPath)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 10)

            standardInstructions
            fallback
                .padding(.top, 14)
        }
    }

    private var standardInstructions: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Setup asks macOS for the permission as this step opens, and the
            // first time that is macOS's own dialog. Said first, because it
            // arrives first.
            Step(1, "If macOS asks, choose **Open System Settings**.")
            Step(2, "Find the row named **weftd** in the list.")
            if model.showsStaleGrantWarning {
                // The only instruction that works when the switch is
                // already on. Telling someone to "turn it on" in that
                // state is not a hard instruction, it is an impossible
                // one, and they conclude weft is broken — correctly.
                Step(3, "Its switch is probably **already on**. Turn it **off**, then **on** again.")
                Step(4, "If macOS offers to quit and reopen, choose **Later**.")
            } else {
                Step(3, "Turn its switch **on**. If it is already on, turn it **off and on again**.")
                Step(4, "If macOS offers to quit and reopen, choose **Later** — weft picks the grant up on its own.")
            }
        }
    }

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
            .foregroundStyle(model.isStuck ? Color.orange : Color.white.opacity(0.55))

            if model.showsFallback {
                VStack(alignment: .leading, spacing: 9) {
                    // `~/.local/bin` is a hidden directory, so the pane's `+`
                    // picker will not browse to it. Dragging or ⌘⇧G are the
                    // only two ways in, and both need the path — which the
                    // reveal button puts on the clipboard on the way past.
                    Step(1, "Click **Open folder with weftd** — Finder opens with the file selected and its path copied.")
                    Step(2, "Drag **weftd** from that Finder window onto the list in System Settings.")
                    Step(3, "Or click **+** in the list, press **⌘⇧G**, and paste the path.")

                    HStack(spacing: 8) {
                        Button {
                            model.revealBinary()
                        } label: {
                            Label("Open folder with weftd", systemImage: "folder")
                        }
                        Button {
                            model.copyPath()
                        } label: {
                            Label("Copy path", systemImage: "doc.on.doc")
                        }
                    }
                    .buttonStyle(StageButtonStyle())
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
                .background(Circle().fill(Color.weft.opacity(0.18)))
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4.5 }
            Text(.init(text))
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.7))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isStageVisible) private var isStageVisible

    var body: some View {
        HStack(spacing: 7) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !isStageVisible)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let pulse = reduceMotion ? 1 : (sin(t * 3.4) + 1) / 2
                ZStack {
                    Circle()
                        .stroke(Color.weft.opacity(0.5 * (1 - pulse)), lineWidth: 1)
                        .frame(width: 7 + 10 * pulse, height: 7 + 10 * pulse)
                    Circle()
                        .fill(Color.weft)
                        .frame(width: 7, height: 7)
                        .opacity(0.55 + 0.45 * pulse)
                }
                .frame(width: 18, height: 18)
            }
            Text("Waiting")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.weft)
        }
    }
}

// MARK: - Page 3

private struct DonePage: View {
    @ObservedObject var model: SetupModel
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                Ripples(tint: .green)
                Circle()
                    .fill(Color.green.opacity(0.14))
                    .overlay(Circle().strokeBorder(Color.green.opacity(0.35), lineWidth: 1))
                    .frame(width: 112, height: 112)
                    .scaleEffect(appeared ? 1 : 0.5)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.6, dampingFraction: 0.62), value: appeared)
                CheckmarkShape()
                    .trim(from: 0, to: appeared ? 1 : 0)
                    .stroke(.green, style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 44, height: 34)
                    .animation(.easeOut(duration: 0.45).delay(0.25), value: appeared)
            }
            .frame(height: 190)

            VStack(spacing: 14) {
                RevealText(text: "Weft is ready.", size: 62, weight: .bold, delay: 0.2)
                Text("Windows tile, keybinds fire. Every key is on the cheatsheet in the menu-bar icon, and everything else lives there too.")
                    .font(.system(size: 15.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
                    .arrive(after: 0.55)
            }

            // Named, not summarised. "Everything required is granted" is the
            // one sentence a user cannot check, and when it was wrong — a live
            // event tap counted as an Input Monitoring grant — there was
            // nothing on the page to catch it. Three pills saying what each
            // switch actually reads cost the same space and cannot lie.
            HStack(spacing: 10) {
                ForEach(PermissionKind.allCases) { kind in
                    SummaryPill(
                        kind: kind,
                        satisfied: model.satisfied(kind),
                        covered: model.coveredByAccessibility(kind)
                    )
                }
            }
            .arrive(after: 0.75)

            VStack(spacing: 12) {
                ConflictingMacOSSettings()
                ExtraDesktopsCard()
            }
            .frame(maxWidth: 600)
            .arrive(after: 0.9)

            Text("Finish restarts the engine once, so it starts clean.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .arrive(after: 1.0)
        }
        .onAppear { appeared = true }
    }
}

/// Rings spreading out from the middle, like a thread plucked taut.
private struct Ripples: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isStageVisible) private var isStageVisible

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !isStageVisible)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    let phase = (t / 2.4 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(tint.opacity(0.5 * (1 - phase)), lineWidth: 1.5)
                        .frame(width: 112, height: 112)
                        .scaleEffect(0.95 + phase * 1.6)
                }
            }
            .opacity(reduceMotion ? 0 : 1)
        }
        .accessibilityHidden(true)
    }
}

/// A checkmark drawn as one stroke, so it can draw itself in.
private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

/// macOS features that arrange the same windows weft does. Said here, once,
/// with the button that fixes it, because the symptom — a window snapping
/// back — reads as weft being broken.
private struct ConflictingMacOSSettings: View {
    @State private var tiling = SystemChecks.macOSTilingEnabled()
    @State private var stageManager = SystemChecks.stageManagerEnabled()

    var body: some View {
        if !tiling.isEmpty || stageManager {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "rectangle.split.2x1.slash")
                    .font(.system(size: 15))
                    .foregroundStyle(.orange)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 6) {
                    Text(stageManager ? "Turn off Stage Manager and macOS window tiling"
                        : "Turn off macOS window tiling")
                        .font(.system(size: 13, weight: .semibold))
                    Text("They move the same windows weft does, so a window can snap back after you drag it.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Desktop & Dock") {
                        if let url = URL(string: SystemChecks.desktopAndDockURL) { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(StageButtonStyle())
                }
                Spacer(minLength: 0)
            }
            .padding(13)
            .stageCard(radius: 12, fill: 0.04, stroke: .orange.opacity(0.3))
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    tiling = SystemChecks.macOSTilingEnabled()
                    stageManager = SystemChecks.stageManagerEnabled()
                }
            }
        }
    }
}

// MARK: - Icon

/// The real app icon — the one in the Dock, the Finder and the About box —
/// rather than a second drawing of it. Falls back to the accent tile when
/// running unbundled (`swift run`).
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

/// One permission, on the final page: what it reads, as a capsule.
private struct SummaryPill: View {
    let kind: PermissionKind
    let satisfied: Bool
    let covered: Bool

    private var status: (text: String, tint: Color, symbol: String) {
        if covered { return ("Covered", .green, "checkmark.circle.fill") }
        if satisfied { return ("Granted", .green, "checkmark.circle.fill") }
        if kind.isRequired { return ("Missing", .orange, "exclamationmark.circle.fill") }
        return ("Off, optional", .white.opacity(0.45), "minus.circle")
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: status.symbol)
                .font(.system(size: 13))
                .foregroundStyle(status.tint)
            Text(kind.title)
                .font(.system(size: 12.5, weight: .medium))
            Text(status.text)
                .font(.system(size: 12))
                .foregroundStyle(status.tint)
        }
        .padding(.horizontal, 13)
        .frame(height: 34)
        .background(.white.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.07), lineWidth: 1))
        .help(covered
            ? "Accessibility already lets weftd read your keybinds. Turning Input Monitoring on as well is optional."
            : "")
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
            contentRect: NSRect(origin: .zero, size: SetupView.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The stage runs up under the title bar. Its separator drew a hairline
        // across the cloth there, which read as a seam between two fabrics.
        window.titlebarSeparatorStyle = .none
        // Setup is a dark stage whatever the system appearance, and the title
        // bar has to agree with it or the traffic lights sit on a pale strip.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(LoomBackdrop.ink)
        window.isMovableByWindowBackground = true
        window.title = "Weft Setup"
        window.center()
        window.isReleasedWhenClosed = false
        // A window AppKit keeps alive between showings stays filed under the
        // space it was first ordered into, so reopening it from another space
        // either yanks the user back to the old one or shows nothing at all.
        // `moveToActiveSpace` brings it to whichever space is in front now.
        window.collectionBehavior.insert(.moveToActiveSpace)
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
            if !(ConfigEditorWindowController.shared.window?.isVisible ?? false) {
                NSApp.setActivationPolicy(.accessory)
            }
            return true
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            model.stopPolling()
            if !(ConfigEditorWindowController.shared.window?.isVisible ?? false) {
                NSApp.setActivationPolicy(.accessory)
            }
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
        var delayMs = 50
        while true {
            if let p = await Task.detached(priority: .utility, operation: {
                query()
            }).value {
                return p
            }
            guard Date() < deadline else { return nil }
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            delayMs = min(delayMs * 2, 250)
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
        if !FileManager.default.isExecutableFile(atPath: EngineInstaller.binDir.appendingPathComponent("weftctl").path)
            && EngineInstaller.bundledWeftctl != nil {
            model.page = .install
        }
        NSApp.setActivationPolicy(.regular)
        model.startPolling()
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open on the engine page: nothing is installed yet, or catching it up
    /// after an app update failed.
    func showInstall() {
        model.page = .install
        show()
    }

    /// Open at the start, for someone who wants the whole tour again.
    func showTour() {
        model.page = .welcome
        show()
    }

    /// Open on the workspaces explainer, for someone who wants to read it
    /// again or change their mind.
    ///
    /// Setup is otherwise a one-time flow — it is gated by `.onboarded`, and
    /// the menu only offers it while a permission is missing — so without this
    /// the only real explanation of the model in the whole app would be
    /// unreachable the moment it had been read once.
    func showWorkspaces() {
        model.page = .workspacesIntro
        show()
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
        if !(ConfigEditorWindowController.shared.window?.isVisible ?? false) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
