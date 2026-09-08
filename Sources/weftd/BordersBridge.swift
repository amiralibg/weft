import Foundation
import WeftPlatform
import WeftConfig
import WeftCore

final class BordersBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isSupervised = false
    private var lastConfig: BordersIntegrationConfig?
    private var stopped = false
    private var currentActiveColor: String?
    /// One "not installed" line per outage, not one per retry.
    private var warnedMissing = false
    /// Consecutive crash restarts. A borders that dies on its own arguments
    /// dies again in a millisecond, and the old handler respawned it every
    /// second forever — a permanent 1 Hz fork bomb in a background daemon,
    /// with a line of log each time, for a decorative border.
    private var crashRestarts = 0

    func applyConfig(_ config: BordersIntegrationConfig, currentLayout: LayoutKind? = nil, currentMode: String? = nil) {
        lock.withLock {
            lastConfig = config
            if !config.enabled {
                stopInternal()
                return
            }
            if config.supervise && process == nil && !stopped {
                startProcess(config)
            }
        }
        if let currentLayout, let currentMode {
            updateColor(layout: currentLayout, mode: currentMode, config: config)
        }
    }

        private func isBordersAlreadyRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", "borders"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // If there is an output PID and it is not our own child process
        let pids = out.components(separatedBy: .whitespacesAndNewlines).compactMap { Int32($0) }
        if let ourPid = process?.processIdentifier {
            return pids.contains { $0 != ourPid }
        }
        return !pids.isEmpty
    }

    private func findBordersBinary() -> String? { ExternalBinary.find("borders") }

    private func startProcess(_ config: BordersIntegrationConfig) {
        guard let bin = findBordersBinary() else {
            // Say it once. `enabled = true` with borders not installed is a
            // perfectly normal config — the example ships with it on — and it
            // must not turn into a line of log per retry.
            if !warnedMissing {
                warnedMissing = true
                fputs(
                    "weftd: borders is enabled in weft.toml but the binary is not installed. "
                        + "Install it (brew install FelixKratz/formulae/borders) or set "
                        + "[integrations.borders] enabled = false. Searched \(ExternalBinary.searchedDescription())\n",
                    stderr
                )
            }
            return
        }
        warnedMissing = false
        if isBordersAlreadyRunning() {
            fputs("weftd: borders is already running externally; managing dynamic colors\n", stderr)
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = config.args
        proc.terminationHandler = { [weak self] p in
            self?.handleTermination(status: p.terminationStatus)
        }
        do {
            try proc.run()
            self.process = proc
            self.isSupervised = true
            fputs("weftd: borders supervised (pid=\(proc.processIdentifier))\n", stderr)
        } catch {
            fputs("weftd: failed to launch borders: \(error)\n", stderr)
        }
    }

    private static let maxCrashRestarts = 5

    private func handleTermination(status: Int32) {
        lock.withLock {
            self.process = nil
            if status == 0 {
                fputs("weftd: borders exited normally (status=0)\n", stderr)
                crashRestarts = 0
                return
            }
            guard !stopped, let cfg = lastConfig, cfg.enabled, cfg.supervise else { return }

            crashRestarts += 1
            guard crashRestarts <= Self.maxCrashRestarts else {
                fputs(
                    "weftd: borders has crashed \(crashRestarts) times in a row (status=\(status)); "
                        + "giving up. Check its arguments in [integrations.borders] args, then "
                        + "`weftctl service restart` to try again.\n",
                    stderr
                )
                return
            }
            // Back off rather than hammering: a bad `args` value fails
            // instantly and identically every time.
            let delay = pow(2.0, Double(crashRestarts - 1))
            fputs(
                "weftd: borders crashed (status=\(status)), restart \(crashRestarts)/\(Self.maxCrashRestarts) in \(Int(delay))s\n",
                stderr
            )
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.lock.withLock {
                    guard let self = self, !self.stopped,
                          let c = self.lastConfig, c.enabled, c.supervise
                    else { return }
                    self.startProcess(c)
                }
            }
        }
    }

    func updateColor(layout: LayoutKind, mode: String, config: BordersIntegrationConfig) {
        guard config.enabled else { return }
        var targetColor: String? = nil
        if mode != "default", let mc = config.modeColor[mode] {
            targetColor = mc
        } else if let ac = config.activeColor[layout.rawValue] {
            targetColor = ac
        }
        guard let color = targetColor else { return }
        let shouldSend: Bool = lock.withLock {
            if currentActiveColor != color {
                currentActiveColor = color
                return true
            }
            return false
        }
        guard shouldSend, let bin = findBordersBinary() else { return }
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = ["active_color=\(color)"]
            try? proc.run()
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            stopInternal()
        }
    }

    private func stopInternal() {
        if let proc = process, proc.isRunning {
            proc.terminate()
            fputs("weftd: stopped borders\n", stderr)
        }
        process = nil
        isSupervised = false
    }
}
