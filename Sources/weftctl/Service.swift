import Foundation

public enum ServiceManager {
    public static let label = "com.weft.weftd"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    /// Where the daemon's output goes.
    ///
    /// `~/Library/Logs` rather than `/tmp`: a log that a reboot deletes is no
    /// use for the bugs worth reporting, which are the ones that took a day to
    /// show up. It is also where Console.app looks, so the log is reachable
    /// without knowing a path.
    public static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/weft")
    }

    public static var logURL: URL { logDirectory.appendingPathComponent("weftd.log") }
    public static var errLogURL: URL { logDirectory.appendingPathComponent("weftd.err.log") }

    /// Where older installs wrote, still read by `weftctl logs` so an upgrade
    /// does not hide the log that has the problem in it.
    public static let legacyLogPaths = ["/tmp/weftd.err.log", "/tmp/weftd.out.log"]

    public static func locateWeftd() -> String {
        // 1. Check same directory as weftctl
        let execPath = CommandLine.arguments[0]
        let execURL = URL(fileURLWithPath: execPath).resolvingSymlinksInPath()
        let candidateSameDir = execURL.deletingLastPathComponent().appendingPathComponent("weftd").path
        if FileManager.default.isExecutableFile(atPath: candidateSameDir) {
            return candidateSameDir
        }

        // 2. Common install paths
        let candidates = [
            "/opt/homebrew/bin/weftd",
            "/usr/local/bin/weftd",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/weftd").path,
        ]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) {
                return c
            }
        }

        return candidateSameDir
    }

    public static func generatePlist(weftdPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(weftdPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logURL.path)</string>
            <key>StandardErrorPath</key>
            <string>\(errLogURL.path)</string>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> (code: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func install() {
        // launchd will not create it, and a StandardErrorPath it cannot open
        // is dropped silently — the daemon runs with no log at all.
        try? FileManager.default.createDirectory(
            at: logDirectory, withIntermediateDirectories: true
        )
        let weftdPath = locateWeftd()
        let plistContent = generatePlist(weftdPath: weftdPath)
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
            print("weftctl: wrote launchd plist to \(plistURL.path)")
            let uid = getuid()
            // Bootout first, so installing over an existing install actually
            // installs. `bootstrap` on an already-loaded service fails with
            // "5: Input/output error" and changes nothing — which left the
            // PREVIOUS weftd running from the previous binary. Every reinstall
            // and every upgrade then appeared to do nothing at all: new
            // binaries on disk, the old one still driving the windows.
            // Harmless when nothing is loaded; launchctl just reports no such
            // service, which is the state we want anyway.
            _ = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
            let (code, out) = runLaunchctl(["bootstrap", "gui/\(uid)", plistURL.path])
            if code == 0 {
                print("weftctl: service \(label) installed and bootstrapped")
            } else {
                print("weftctl: service written. launchctl bootstrap reported: \(out)")
            }
        } catch {
            fputs("weftctl: failed to write plist: \(error)\n", stderr)
            exit(1)
        }
    }

    public static func uninstall() {
        let uid = getuid()
        _ = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        print("weftctl: service \(label) uninstalled")
    }

    public static func start() {
        let uid = getuid()
        let (code, out) = runLaunchctl(["kickstart", "-k", "gui/\(uid)/\(label)"])
        if code == 0 {
            print("weftctl: service started")
        } else {
            // If not bootstrapped, try bootstrap
            if FileManager.default.fileExists(atPath: plistURL.path) {
                _ = runLaunchctl(["bootstrap", "gui/\(uid)", plistURL.path])
                print("weftctl: bootstrapped service \(label)")
            } else {
                fputs("weftctl: launchctl error: \(out)\nRun 'weftctl service install' first.\n", stderr)
            }
        }
    }

    public static func stop() {
        let uid = getuid()
        let (code, out) = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        if code == 0 {
            print("weftctl: service stopped")
        } else {
            print("weftctl: \(out)")
        }
    }

    public static func restart() {
        let uid = getuid()
        let (code, _) = runLaunchctl(["kickstart", "-k", "gui/\(uid)/\(label)"])
        if code == 0 {
            print("weftctl: service restarted")
        } else {
            stop()
            start()
        }
    }

    public static func status() {
        let uid = getuid()
        let (code, out) = runLaunchctl(["print", "gui/\(uid)/\(label)"])
        if code == 0 {
            print("weftctl: service is ACTIVE")
            // Print state line if available
            for line in out.components(separatedBy: "\n") {
                if line.contains("state =") || line.contains("pid =") || line.contains("path =") {
                    print("  \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        } else {
            print("weftctl: service is NOT RUNNING (or not installed)")
            if FileManager.default.fileExists(atPath: plistURL.path) {
                print("  plist exists at: \(plistURL.path)")
            }
        }
    }
}
