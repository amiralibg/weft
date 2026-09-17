import Foundation

/// Running a shell command on a keybind.
///
/// This is the half of skhd weft did not replace. Every other verb weft has is
/// a window-manager verb, and a config migrated from skhd carries a pile of
/// lines that are not — `open -a`, a screenshot, a `pmset` toggle, a script.
/// Before this they had nowhere to go, and `weftctl migrate` dropped them.
///
/// Three properties matter more than the feature:
///
/// - **It never blocks the thing that asked.** The event tap has a deadline
///   macOS enforces by *disabling the tap* when it is missed, and the socket
///   handler is shared with every other command. A fork and an exec are
///   milliseconds on a good day and a page-in storm on a bad one, so they
///   happen on a queue of their own and nobody waits for the result.
/// - **It is reaped.** A child nobody waits on is a zombie for the life of the
///   daemon, and a window manager runs for weeks. `Process.terminationHandler`
///   is what does the waiting here.
/// - **It cannot run away.** A key held down repeats, and a bind that launches
///   something slow would spawn one process per repeat until the machine gave
///   up. Past `maxConcurrent` in flight, new launches are refused with a line
///   of log rather than queued — queueing turns a fork bomb into a fork bomb
///   that also fires for the next ten minutes.
public enum Exec {
    /// Deliberately generous: this is a guard against a runaway key repeat,
    /// not a scheduler. A person who binds eight things and presses them all
    /// must not hit it.
    public static let maxConcurrent = 32

    private static let queue = DispatchQueue(label: "weft.exec", qos: .utility)
    private static let lock = NSLock()
    private nonisolated(unsafe) static var inFlight = 0
    /// One line per outage, not one per keypress: a bind at the cap is usually
    /// being held down, and logging each refusal is its own flood.
    private nonisolated(unsafe) static var warnedSaturated = false
    /// Strong references to the children, dropped when each exits.
    ///
    /// Foundation does keep a launched `Process` alive on its own, but that is
    /// an implementation detail of a class whose lifetime rules have changed
    /// before, and the cost of not relying on it is one dictionary.
    ///
    /// Keyed by a token rather than by pid, because the pid does not exist
    /// until `run()` — so an entry keyed by it could only be written *after*
    /// launching, and a command that exits in under a millisecond would have
    /// its termination handler remove nothing and then be inserted, dead,
    /// forever. The token is known first, so the insert always precedes the
    /// removal.
    private nonisolated(unsafe) static var children: [Int: Process] = [:]
    private nonisolated(unsafe) static var nextToken = 0

    /// How many children are running. Read by `query state` and the tests.
    public static var running: Int { lock.withLock { inFlight } }

    /// Run `command` through `/bin/sh -c`, with `env` added to weftd's own
    /// environment. Returns immediately; false means nothing was launched.
    ///
    /// `sh -c` rather than a tokenised argv, because the whole point is to run
    /// what the user would have typed: pipes, quotes, `&&`, `$HOME` and a
    /// trailing `&` all have to mean what they mean in a shell. weft does not
    /// parse the string at all — anything that can reach this can already run
    /// commands as the user, since the socket lives in a mode-700 `$TMPDIR`
    /// and a keybind is the user pressing a key.
    @discardableResult
    public static func run(_ command: String, env: [String: String] = [:]) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let admitted: Bool = lock.withLock {
            guard inFlight < maxConcurrent else { return false }
            inFlight += 1
            warnedSaturated = false
            return true
        }
        guard admitted else {
            let warn: Bool = lock.withLock {
                defer { warnedSaturated = true }
                return !warnedSaturated
            }
            if warn {
                fputs(
                    "weftd: exec refused — \(maxConcurrent) commands already running. "
                        + "A key repeating on a bind that starts something slow looks like this; "
                        + "the refusal is what stops it becoming a fork bomb.\n",
                    stderr
                )
            }
            return false
        }

        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", trimmed]
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in env { environment[key] = value }
            process.environment = environment
            // weftd's stdout and stderr are its log. A command that chatters
            // would bury every line weft writes, and one that reads from stdin
            // would block forever on a descriptor nobody is typing into.
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            // Set before `run`, or a command that fails instantly can finish
            // first and leave the count raised for good.
            let token: Int = lock.withLock {
                nextToken &+= 1
                children[nextToken] = process
                return nextToken
            }
            process.terminationHandler = { finished in
                lock.withLock {
                    inFlight -= 1
                    children.removeValue(forKey: token)
                }
                guard Trace.logging else { return }
                fputs(
                    "weftd: exec finished (\(finished.terminationStatus)): \(trimmed)\n", stderr)
            }
            do {
                try process.run()
            } catch {
                lock.withLock {
                    inFlight -= 1
                    children.removeValue(forKey: token)
                }
                // Named, because the failure people actually hit is a typo in
                // the command and `sh` reporting it into /dev/null.
                fputs("weftd: exec could not start '\(trimmed)': \(error)\n", stderr)
            }
        }
        return true
    }
}
