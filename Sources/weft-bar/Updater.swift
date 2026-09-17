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
    /// The version this run is installing, and the directory holding the
    /// bundle it replaces. Both are needed to answer "did it work", and
    /// neither can be recovered from `Bundle.main` once it has.
    private var installing: String?
    private var installingInto: URL?

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
        installing = update.latest
        installingInto = appDir
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
        // The installer is done and this app is still here. On the happy path
        // it quits WeftBar first, so that is either an update that stopped
        // early or one whose quit did not take — and only the bundle on disk
        // can tell the two apart. `finish` asks it.
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
        fraction = nil
        startedAt = nil
        let target = installing
        let appDir = installingInto
        installing = nil
        installingInto = nil
        if message == nil, let target, let appDir,
           let onDisk = Self.installedVersion(in: appDir),
           !WeftVersion.isNewer(target, than: onDisk)
        {
            // It worked. This process is the copy that got left behind.
            //
            // Reaching here at all means the installer's quit did not take, so
            // the old build is still running on top of a bundle that is now
            // the new one — and `open` at the end of the installer only
            // activated it rather than starting anything. The window then
            // reported failure and *proved* it with `WeftVersion.current`,
            // which is this binary's compile-time constant and cannot change
            // however well the update went. Ask the bundle on disk, which is
            // the only thing here that knows.
            step = "Restarting…"
            relaunch(appDir)
            return
        }
        step = nil
        // A nil message used to mean "say nothing", and that is the one
        // outcome this window must never produce: on the happy path the
        // installer *quits this app* before it finishes, so an update that
        // reaches here and finds the old build still on disk has stopped early
        // without replacing anything. Silence put the Update button back
        // exactly as it was, which is the report — "it did not work and showed
        // no progress".
        failure = message
            ?? "The installer finished without replacing weft. "
                + (appDir.flatMap { Self.installedVersion(in: $0) }
                    .map { "\($0) is still the version on disk. " } ?? "")
                + "See \(logURL.path)."
    }

    /// The version of the WeftBar.app sitting in `appDir` right now.
    ///
    /// Read from the bundle rather than from `Bundle.main`: after a successful
    /// update the two are different builds, and it is the difference that says
    /// the update worked.
    private static func installedVersion(in appDir: URL) -> String? {
        let plist = appDir
            .appendingPathComponent("WeftBar.app/Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String
        else { return nil }
        return version
    }

    /// Start the newly installed build and stand down.
    ///
    /// `createsNewApplicationInstance`, because the bundle being launched is
    /// the one this process came from as far as LaunchServices is concerned —
    /// without it the request is answered by activating *this* copy, which is
    /// exactly the old build the relaunch exists to replace. The new one is up
    /// before this one goes, so the menu bar never empties.
    private func relaunch(_ appDir: URL) {
        let app = appDir.appendingPathComponent("WeftBar.app")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        // Back to the window the user was watching. They pressed Update in
        // Settings and have been looking at a progress bar ever since; coming
        // back as a bare menu-bar icon reads as the app having given up.
        config.arguments = ["--settings"]
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
            Task { @MainActor in
                guard error == nil else {
                    self.step = nil
                    self.failure = "weft updated, but could not restart itself: "
                        + "\(error!.localizedDescription). Quit weft and open it again."
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}
