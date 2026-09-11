import AppKit

/// Removing weft, from the app — no terminal, no hunting for files.
///
/// The work is `uninstall.sh`, carried in the bundle: the same script the
/// README gives terminal users, so there is one list of what weft puts on a
/// Mac and one way of taking it off.
@MainActor
enum Uninstaller {
    static var script: URL? {
        Bundle.main.url(forResource: "uninstall", withExtension: "sh")
    }

    /// Ask, then remove. The one choice worth offering is whether settings go
    /// too: keeping them is what makes a reinstall pick up where it left off.
    static func confirmAndRun() {
        guard let script else {
            // A build with no bundle behind it (`swift run`) carries no script.
            if let docs = URL(string: "https://github.com/amiralibg/weft#uninstall") {
                NSWorkspace.shared.open(docs)
            }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall Weft?"
        alert.informativeText = "This stops weft and removes it, its login service and this app. "
            + "Your windows stay exactly where they are."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Also remove my settings and permissions"
        alert.suppressionButton?.state = .off
        let uninstall = alert.addButton(withTitle: "Uninstall")
        uninstall.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(script, purge: alert.suppressionButton?.state == .on)
    }

    /// Detached, with output to a file rather than a pipe: the script quits
    /// this app part-way through, and a write into a pipe whose reader has
    /// gone would kill the script with it.
    private static func run(_ script: URL, purge: Bool) {
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("weft-uninstall.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + (purge ? ["--purge"] : [])
        var env = ProcessInfo.processInfo.environment
        env["WEFT_APP_PATH"] = Bundle.main.bundlePath
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try? process.run()
    }
}
