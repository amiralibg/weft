import Foundation
import WeftCore

/// `weftctl logs` — the daemon's output, without anyone having to know where
/// it lives.
///
/// Reads the current location and the one older installs used, because the
/// log worth reading is often the one written before the upgrade that was
/// supposed to fix the problem.
public enum Logs {
    static func sources() -> [URL] {
        var out = [ServiceManager.errLogURL, ServiceManager.logURL]
        out += ServiceManager.legacyLogPaths.map { URL(fileURLWithPath: $0) }
        return out.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func run(follow: Bool, lines: Int) {
        let found = sources()
        guard !found.isEmpty else {
            fputs(
                "weftctl: no log yet at \(ServiceManager.logDirectory.path)\n"
                    + "         weftd writes one as soon as it starts — "
                    + "check 'weftctl service status'.\n",
                stderr
            )
            return
        }
        // Version first: a log that does not name its build wastes the first
        // exchange of every bug report.
        print("# weftctl \(WeftVersion.current) — \(found.map(\.path).joined(separator: ", "))")
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        var argv = ["-n", String(lines)]
        if follow { argv.append("-f") }
        argv += found.map(\.path)
        tail.arguments = argv
        do {
            try tail.run()
            tail.waitUntilExit()
        } catch {
            fputs("weftctl: could not read the log: \(error)\n", stderr)
        }
    }
}
