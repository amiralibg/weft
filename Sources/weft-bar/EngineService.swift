import Foundation

/// weftd's login service, as WeftBar needs it: stopped by Quit Weft, started
/// again when WeftBar opens.
///
/// launchctl directly, not `weftctl service`: the service runs with
/// `KeepAlive`, so only `bootout` stops it for good — a kill brings it straight
/// back — and quitting must work even when weftctl is missing or broken.
enum EngineService {
    static let label = "com.weft.weftd"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var target: String { "gui/\(getuid())/\(label)" }

    /// Whether launchd has the service loaded (running, or about to be).
    static func isLoaded() -> Bool {
        launchctl(["print", target]) == 0
    }

    /// Stop weftd and keep it stopped until `startIfStopped` or the next
    /// login. Its SIGTERM handler saves the layouts before it exits.
    static func stop() {
        launchctl(["bootout", target])
    }

    /// Bring back a service Quit Weft stopped. Does nothing on a machine
    /// where the engine was never installed: that is Setup's to do, with a
    /// button the user presses.
    static func startIfStopped() {
        guard FileManager.default.fileExists(atPath: plistURL.path), !isLoaded() else { return }
        launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
