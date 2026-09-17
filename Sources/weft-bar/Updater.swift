import AppKit
import Combine
import Foundation
import WeftCore
import WeftPlatform

/// Updating weft in place, from the Settings window or the menu bar.
///
/// `install-release.sh` already downloads, checks the checksum, keeps the
/// signing identity, restarts the service and reopens the app — the same path
/// the curl one-liner takes, not a second updater to keep in step with it. The
/// release page is still the answer when the app sits somewhere this user
/// cannot replace it, or the build carries no script.
///
/// Shared rather than living on the menu's delegate: Settings offers the same
/// update, and two copies of a flow that replaces the running application is
/// one more than anyone should maintain.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// What the installer is doing, as its own `==>` lines report it. Nil when
    /// nothing is running.
    @Published private(set) var step: String?
    /// How far through the current stage, 0…1, when the stage can say — which
    /// in practice means the download, and the download is nearly all of the
    /// wall-clock time. Nil for stages that are over in a moment.
    @Published private(set) var fraction: Double?
    /// How long the update has been running. Shown beside the stage so a slow
    /// download is visibly *slow* rather than visibly *stuck*.
    @Published private(set) var elapsed: TimeInterval = 0
    /// Why the update did not start, in words worth showing.
    @Published private(set) var failure: String?

    var isRunning: Bool { step != nil }

    private var poll: Timer?
    private var process: Process?
    private var startedAt: Date?

    /// The version an update was started for, kept across the app dying.
    ///
    /// The installer quits WeftBar before it replaces the bundle, so this
    /// process is killed half way through every successful update. Nothing in
    /// memory survives that — including `failure`, which meant an update that
    /// broke *after* the app was killed told the user nothing at all: weft
    /// simply did not update, silently, and the Settings window looked the same
    /// as before. Recording the attempt is what makes the next launch able to
    /// say so.
    private static let pendingKey = "weft.update.pending"

    init() {
        guard let target = UserDefaults.standard.string(forKey: Self.pendingKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        // Running the version we were installing, or newer: it worked, and
        // saying so after the fact would only be noise.
        guard WeftVersion.isNewer(target, than: WeftVersion.current) else { return }
        failure = "The update to \(target) did not complete — weft is still "
            + "\(WeftVersion.current). See \(logURL.path)."
    }

    private var logURL: URL {
        EngineInstaller.logURL.deletingLastPathComponent()
            .appendingPathComponent("weft-update.log")
    }

    /// Ask, then run. Reports progress rather than going quiet for the thirty
    /// seconds it takes — pressing Update used to change nothing on screen
    /// until the app vanished and came back, which reads as a button that does
    /// nothing.
    func promptAndInstall(_ update: UpdateCheck.Result) {
        guard !isRunning else { return }
        failure = nil
        let releasePage = URL(string: update.url)
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()

        guard let script = Bundle.main.url(forResource: "install-release", withExtension: "sh") else {
            // Said out loud, not swallowed. This used to open the release page
            // with no explanation, so the button looked broken rather than
            // unavailable.
            fail("This build carries no installer. Update from the release page.", open: releasePage)
            return
        }
        guard FileManager.default.isWritableFile(atPath: appDir.path) else {
            fail(
                "weft cannot replace itself in \(appDir.path) — no permission. "
                    + "Update from the release page.",
                open: releasePage
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = "Update weft to \(update.latest)?"
        alert.informativeText = "Weft downloads the release, checks it, and restarts itself. "
            + "Your settings and permissions are kept."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            break
        case .alertSecondButtonReturn:
            if let releasePage { NSWorkspace.shared.open(releasePage) }
            return
        default:
            return
        }

        // Output to a file, never a pipe: the installer quits WeftBar before
        // replacing it, and a write into a pipe whose reader has exited kills
        // the writer — half-way through swapping the app.
        let log = logURL
        try? FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else {
            fail("weft could not open its update log at \(log.path).", open: releasePage)
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["WEFT_VERSION"] = "v\(update.latest)"
        // Replace *this* copy, wherever the user put it — not a second one
        // in ~/Applications next to an old one in /Applications.
        env["WEFT_APP_DIR"] = appDir.path
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = handle
        p.standardError = handle
        do {
            try p.run()
        } catch {
            fail("weft could not start the installer: \(error.localizedDescription)", open: releasePage)
            return
        }
        process = p
        // Before any of it can go wrong, and deliberately not cleared on the
        // way out: this process does not live to see the end of a successful
        // update, so the next launch clears it by comparing versions.
        UserDefaults.standard.set(update.latest, forKey: Self.pendingKey)
        // Forced to disk now, not whenever the next flush happens. The
        // installer sends this process a signal partway through, and an
        // unflushed default dies with it — so the marker that exists precisely
        // to survive being killed was the thing most likely not to. An update
        // that then broke after the app went away reported nothing at all on
        // the next launch.
        UserDefaults.standard.synchronize()
        startedAt = Date()
        elapsed = 0
        fraction = nil
        step = "Starting…"
        startPolling()
    }

    private func fail(_ message: String, open page: URL?) {
        failure = message
        step = nil
        if let page { NSWorkspace.shared.open(page) }
    }

    /// Follow the installer's own output. It prints `==> <what it is doing>`
    /// for each stage, so the last such line is the honest answer to "what is
    /// happening", with no second progress protocol to keep in step.
    ///
    /// The app does not live to see the end of this: the installer quits
    /// WeftBar before replacing the bundle. That is the intended finish, not a
    /// crash, and the last step shown before it happens says so.
    private func startPolling() {
        poll?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readProgress() }
        }
        // `.common`, not the default mode. A timer scheduled the ordinary way
        // stops firing the moment the run loop enters tracking — scrolling the
        // Settings list, or holding a menu open — so progress froze exactly
        // when someone was looking at it and moving the pointer.
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func readProgress() {
        if let started = startedAt { elapsed = Date().timeIntervalSince(started) }
        // Read bytes and decode lossily, never `String(contentsOf:encoding:)`.
        // curl's progress bar shares this file and writes partial lines with
        // carriage returns; catching the file mid-write can leave a byte
        // sequence that is not valid UTF-8, and a strict decode then returns
        // nil for the whole log. That is not a cosmetic difference — it makes
        // progress stop dead and stay stopped, with nothing to say why.
        guard let data = try? Data(contentsOf: logURL) else { return }
        let text = String(decoding: data, as: UTF8.self)
        // `.newlines` covers the carriage return curl rewrites its progress
        // line with, so each redraw of the bar is its own entry and the newest
        // is the last one.
        let lines = text.components(separatedBy: .newlines)
        if let error = lines.last(where: { $0.hasPrefix("ERROR: ") }) {
            finish(withFailure: String(error.dropFirst(7)))
            return
        }
        if let last = lines.last(where: { $0.hasPrefix("==> ") }).map({ String($0.dropFirst(4)) }) {
            step = last.prefix(1).uppercased() + last.dropFirst() + "…"
        }
        // The percentage, if the stage in flight is publishing one.
        //
        // Without this the download — which on a slow link to GitHub's CDN is
        // minutes, and is nearly all of the time an update takes — showed one
        // unchanging line for the whole of it. Measured on the machine this
        // was reported from: 45% after two and a half minutes. A static
        // sentence for that long is indistinguishable from a hang, which is
        // exactly what it was reported as.
        fraction = UpdateProgress.percent(in: lines)
        guard let p = process, !p.isRunning else { return }
        // Ran to completion without replacing us: on the happy path the
        // installer quits this app first, so reaching here at all means it
        // stopped early.
        if let p = process, p.terminationStatus != 0 {
            finish(withFailure: "The installer stopped with status \(p.terminationStatus). "
                + "See \(logURL.path).")
        } else {
            finish(withFailure: nil)
        }
    }

    private func finish(withFailure message: String?) {
        poll?.invalidate()
        poll = nil
        process = nil
        step = nil
        fraction = nil
        startedAt = nil
        // A nil message used to mean "say nothing", and that is the one
        // outcome this window must never produce: on the happy path the
        // installer *quits this app* before it finishes, so an update that
        // reaches here has stopped early without replacing anything. Silence
        // put the Update button back exactly as it was, which is the report —
        // "it did not work and showed no progress".
        failure = message
            ?? "The installer finished without replacing weft, which is still "
                + "\(WeftVersion.current). See \(logURL.path)."
    }
}
