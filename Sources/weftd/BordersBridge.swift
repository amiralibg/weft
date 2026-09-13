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
    /// Same, for the "already running externally" line: `applyConfig` runs on
    /// every config reload and never adopts the foreign process, so this used
    /// to print again on every save of weft.toml.
    private var warnedExternal = false
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
                warnedMissing = false
                warnedExternal = false
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
                    """
                    weftd: borders are enabled in weft.toml, but JankyBorders is not installed.
                      Weft draws borders with JankyBorders. Install it with:
                          brew install FelixKratz/formulae/borders
                      Then restart weft:
                          weftctl service restart
                      Or turn borders off in weft.toml:
                          [integrations.borders]
                          enabled = false
                      Searched \(ExternalBinary.searchedDescription())

                    """,
                    stderr
                )
            }
            return
        }
        warnedMissing = false
        if isBordersAlreadyRunning() {
            if !warnedExternal {
                warnedExternal = true
                fputs("weftd: borders is already running externally; managing dynamic colors\n", stderr)
            }
            return
        }
        warnedExternal = false

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = config.resolvedArgs
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        p.terminationHandler = { [weak self] proc in
            self?.lock.withLock {
                self?.process = nil
                self?.isSupervised = false
            }
            // Rapid crashes mean the arguments are invalid, the binary is
            // corrupt, or it is running on an unsupported OS version.
            // Spawning it again the next second is a 1 Hz fork bomb: back
            // off after three quick deaths.
            let crash = proc.terminationStatus != 0
            let delay: TimeInterval
            if crash {
                self?.crashRestarts += 1
                if let r = self?.crashRestarts, r > 3 {
                    fputs("weftd: borders has crashed repeatedly (\(r) times) — disabling supervision\n", stderr)
                    return
                }
                delay = Double(self?.crashRestarts ?? 1) * 2.0
            } else {
                self?.crashRestarts = 0
                delay = 1.0
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.lock.withLock {
                    guard let self = self, !self.stopped,
                          let c = self.lastConfig, c.enabled, c.supervise
                    else { return }
                    self.startProcess(c)
                }
            }
        }

        do {
            try p.run()
            process = p
            isSupervised = true
            fputs("weftd: started borders (pid \(p.processIdentifier))\n", stderr)
        } catch {
            fputs("weftd: failed to spawn borders: \(error)\n", stderr)
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
        guard let p = process else { return }
        process = nil
        isSupervised = false
        p.terminationHandler = nil
        p.terminate()
    }
}
