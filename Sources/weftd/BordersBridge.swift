import Foundation
import WeftPlatform
import WeftConfig
import WeftCore

final class BordersBridge: @unchecked Sendable {
    /// Weft's own renderer. Always constructed, only fed when the config asks
    /// for it — it costs nothing until the first window gets a border.
    let renderer = BorderRenderer()
    /// True when weft is drawing the borders itself, so the apply path can
    /// skip computing frames nobody is going to paint.
    private(set) var drawsBorders = false
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
        let native = config.enabled && config.backend == .native
        drawsBorders = native
        // Never both. Two renderers drawing the same rectangle is two
        // rectangles, one of them a frame behind the other.
        if native {
            lock.withLock { stopInternal() }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.retireExternalBorders(supervised: config.supervise)
            }
        }
        renderer.setEnabled(native)
        if native {
            renderer.setStyle(BorderRenderer.Style(
                width: config.resolvedWidth,
                radius: config.radius ?? 10,
                activeColor: BorderRenderer.parseColor(config.resolvedActiveColor) ?? 0xff7a_a2f7,
                inactiveColor: BorderRenderer.parseColor(config.resolvedInactiveColor) ?? 0x4041_4868,
                showInactive: config.showInactive
            ))
        }
        lock.withLock {
            lastConfig = config
            if !config.enabled || config.backend == .native {
                if !native { stopInternal() }
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

    /// Switching to the native renderer while a `borders` process is still up
    /// means every window wears two rectangles.
    ///
    /// If weft was supervising it, weft started it and weft ends it — an
    /// upgrade that changes the default backend must not leave the old
    /// renderer running forever. If it was not, someone else started it and
    /// it is not weft's to kill: say so instead.
    private func retireExternalBorders(supervised: Bool) {
        guard isBordersAlreadyRunning() else {
            warnedExternal = false
            return
        }
        // Native borders and JankyBorders cannot run concurrently. When native
        // is active, terminate any external borders instance and its parent script
        // to prevent duplicate outlines or compositor ghost lines.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-9", "-x", "borders"]
        try? proc.run()
        proc.waitUntilExit()

        let killrc = Process()
        killrc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killrc.arguments = ["-9", "-f", "bordersrc"]
        try? killrc.run()
        killrc.waitUntilExit()

        fputs("weftd: stopped external borders and bordersrc processes — weft draws its own now\n", stderr)
    }

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
            if !warnedExternal {
                warnedExternal = true
                fputs("weftd: borders is already running externally; managing dynamic colors\n", stderr)
            }
            return
        }
        warnedExternal = false

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = config.args
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
        if config.backend == .native {
            // In process: an assignment and, if it actually changed, a
            // repaint. The external path below is a `fork` + `exec` of a CLI,
            // which is what this used to cost on every focus change.
            let resolved = targetColor ?? config.resolvedActiveColor
            if let rgba = BorderRenderer.parseColor(resolved) {
                renderer.setActiveColor(rgba)
            }
            return
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
        drawsBorders = false
        renderer.setEnabled(false)
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
