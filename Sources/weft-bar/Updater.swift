import AppKit
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
enum Updater {
    static func promptAndInstall(_ update: UpdateCheck.Result) {
        let releasePage = URL(string: update.url)
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        guard let script = Bundle.main.url(forResource: "install-release", withExtension: "sh"),
              FileManager.default.isWritableFile(atPath: appDir.path)
        else {
            if let releasePage { NSWorkspace.shared.open(releasePage) }
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
        let log = EngineInstaller.logURL.deletingLastPathComponent()
            .appendingPathComponent("weft-update.log")
        try? FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else {
            if let releasePage { NSWorkspace.shared.open(releasePage) }
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
            if let releasePage { NSWorkspace.shared.open(releasePage) }
        }
    }
}
