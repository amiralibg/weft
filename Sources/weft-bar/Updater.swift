import AppKit
import Combine
import Foundation
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
    /// Why the update did not start, in words worth showing.
    @Published private(set) var failure: String?

    var isRunning: Bool { step != nil }

    private var poll: Timer?
    private var process: Process?

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
        poll = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readProgress() }
        }
    }

    private func readProgress() {
        if let text = try? String(contentsOf: logURL, encoding: .utf8) {
            let stages = text.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("==> ") }
                .map { String($0.dropFirst(4)) }
            if let last = stages.last {
                step = last.prefix(1).uppercased() + last.dropFirst() + "…"
            }
            if let error = text.components(separatedBy: .newlines)
                .last(where: { $0.hasPrefix("ERROR: ") })
            {
                finish(withFailure: String(error.dropFirst(7)))
                return
            }
        }
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
        failure = message
    }
}
