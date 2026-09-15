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
    /// The argument list last handed to a live `borders`, whether at spawn or
    /// as a runtime message. `applyConfig` used to only ever *spawn*, so
    /// every setting but the colour needed a daemon restart to take effect —
    /// and when borders was already running (a user's own `bordersrc`, or
    /// `brew services`) nothing weft's Settings window offered took effect at
    /// all, while the window said the settings were passed through.
    private var appliedArgs: [String]?
    /// One "not installed" line per outage, not one per retry.
    private var warnedMissing = false
    /// Same, for the "already running outside weft" line: `applyConfig` runs
    /// on every config reload and never takes the foreign process over, so
    /// this used to print again on every save of weft.toml.
    private var warnedExternal = false
    /// Consecutive crash restarts. A borders that dies on its own arguments
    /// dies again in a millisecond, and the old handler respawned it every
    /// second forever — a permanent 1 Hz fork bomb in a background daemon,
    /// with a line of log each time, for a decorative border.
    private var crashRestarts = 0
    /// Weft's own renderer. Idle — no windows, no work — until borders are
    /// on with `backend = "native"`, which is the default.
    let renderer = BorderRenderer()
    private var drawsNative = false
    /// One "JankyBorders is running too" line per launch of it, not per reload.
    private var warnedDoubleBorders = false

    /// Whether weft is drawing the borders itself, so the layout path knows
    /// to hand it frames.
    var drawsBorders: Bool { lock.withLock { drawsNative } }

    func applyConfig(_ config: BordersIntegrationConfig, currentLayout: LayoutKind? = nil, currentMode: String? = nil) {
        let native = config.enabled && config.backend == .native
        lock.withLock { drawsNative = native }
        if native {
            // Never both: two renderers drawing the same ring is two rings,
            // one of them a frame behind. A `borders` weft started, weft
            // stops; one someone else started is theirs, so say so instead.
            lock.withLock {
                stopInternal()
                currentActiveColor = nil
            }
            renderer.setStyle(Self.style(config))
            if let currentLayout, let currentMode {
                updateColor(layout: currentLayout, mode: currentMode, config: config)
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let running = self.isBordersAlreadyRunning()
                let warn: Bool = self.lock.withLock {
                    defer { self.warnedDoubleBorders = running }
                    return running && !self.warnedDoubleBorders
                }
                if warn {
                    fputs(
                        "weftd: JankyBorders is running outside weft while weft draws its own borders, "
                            + "so windows get two. Quit it, or set backend = \"janky\" under "
                            + "[integrations.borders] to keep using it.\n",
                        stderr
                    )
                }
            }
            return
        }
        renderer.setStyle(nil)
        var toSend: [String]?
        lock.withLock {
            lastConfig = config
            if !config.enabled {
                stopInternal()
                appliedArgs = nil
                currentActiveColor = nil
                warnedMissing = false
                warnedExternal = false
                return
            }
            let wanted = config.resolvedArgs
            if config.supervise && process == nil && !stopped {
                // Spawning carries the arguments itself; nothing to send.
                if startProcess(config) {
                    appliedArgs = wanted
                    currentActiveColor = nil
                    return
                }
            }
            // Either we supervise a process that is already up, or borders is
            // running outside weft. Both take new settings the same way: `man
            // borders` — "If an instance of borders is already running,
            // subsequent invocations will update the existing process with
            // the new arguments."
            //
            // Only when one *is* running, though. The same invocation with no
            // instance up starts one, and doing that here would start borders
            // behind the back of someone who set `supervise = false` precisely
            // so weft would not.
            guard appliedArgs != wanted, process != nil || isAnyBordersRunning() else { return }
            appliedArgs = wanted
            // The colour this pushes is the fallback one; a layout or mode
            // with its own entry re-sends below and must not be suppressed.
            currentActiveColor = nil
            toSend = wanted
        }
        if let toSend { send(toSend) }
        if let currentLayout, let currentMode {
            updateColor(layout: currentLayout, mode: currentMode, config: config)
        }
    }

    /// Hand a `key=value` list to the running borders. Fire and forget: it is
    /// a message to another process, and weft has nothing to do with the
    /// answer.
    ///
    /// Serial, and that matters. A config reload sends the whole argument set
    /// — which carries the *fallback* colour — and then immediately sends the
    /// colour for the current layout or mode. On a concurrent queue those two
    /// can land in either order, and the wrong order leaves the border on the
    /// fallback colour until something else changes.
    private func send(_ arguments: [String]) {
        guard !arguments.isEmpty, let bin = findBordersBinary() else { return }
        sends.async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = arguments
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            // Reaped, not raced: without this the next send can overtake this
            // one inside borders itself.
            //
            // Bounded, because this invocation only *messages* a running
            // borders when there is one to message. If it died in the moment
            // between the check and here, the same command becomes a new
            // long-lived borders that never exits — and an unbounded wait
            // would wedge this queue for the life of the daemon.
            let deadline = Date().addingTimeInterval(2)
            while proc.isRunning, Date() < deadline { usleep(2_000) }
        }
    }

    private let sends = DispatchQueue(label: "weft.borders.send", qos: .utility)

    /// Any `borders` at all, ours included — the question `applyConfig` asks
    /// before messaging one.
    private func isAnyBordersRunning() -> Bool {
        process != nil || isBordersAlreadyRunning()
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

    /// True when a `borders` of our own is now running. False means we did
    /// not spawn one — it is missing, already running outside weft, or it
    /// failed to launch — and the caller should fall back to messaging
    /// whatever instance is there.
    @discardableResult
    private func startProcess(_ config: BordersIntegrationConfig) -> Bool {
        guard let bin = findBordersBinary() else {
            // Say it once. `enabled = true` with borders not installed is a
            // perfectly normal config — the example ships with it on — and it
            // must not turn into a line of log per retry.
            if !warnedMissing {
                warnedMissing = true
                fputs(
                    """
                    weftd: [integrations.borders] has backend = "janky", but JankyBorders is not installed.
                      Let weft draw them instead — remove that line, or set:
                          backend = "native"
                      Or install JankyBorders and restart weft:
                          brew install FelixKratz/formulae/borders
                          weftctl service restart
                      Searched \(ExternalBinary.searchedDescription())

                    """,
                    stderr
                )
            }
            return false
        }
        warnedMissing = false
        if isBordersAlreadyRunning() {
            if !warnedExternal {
                warnedExternal = true
                fputs(
                    "weftd: borders is already running outside weft — not supervising it, "
                        + "but applying [integrations.borders] to it\n",
                    stderr
                )
            }
            return false
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
                    fputs(
                        "weftd: borders exited \(r) times in a row — giving up on supervising it. "
                            + "Run `\(proc.executableURL?.path ?? "borders") "
                            + "\((proc.arguments ?? []).joined(separator: " "))` to see why.\n",
                        stderr
                    )
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
            fputs(
                "weftd: started borders (pid \(p.processIdentifier)) "
                    + "\(config.resolvedArgs.joined(separator: " "))\n",
                stderr
            )
            return true
        } catch {
            fputs("weftd: failed to spawn borders: \(error)\n", stderr)
            return false
        }
    }

    /// Weft's renderer takes what `[integrations.borders]` says. A radius set
    /// in the file is drawn as written; none follows each window's corners.
    static func style(_ config: BordersIntegrationConfig) -> BorderRenderer.Style {
        BorderRenderer.Style(
            width: config.resolvedWidth,
            radius: config.radius,
            square: config.resolvedStyle == "square",
            activeColor: BorderRenderer.parseColor(config.resolvedActiveColor) ?? 0xff7a_a2f7,
            inactiveColor: BorderRenderer.parseColor(config.resolvedInactiveColor) ?? 0x4041_4868,
            showInactive: config.showInactive
        )
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
            // In process: an assignment, and a repaint if it changed. The path
            // below is a fork + exec of a CLI.
            let resolved = targetColor ?? config.resolvedActiveColor
            if let argb = BorderRenderer.parseColor(resolved) { renderer.setActiveColor(argb) }
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
        guard shouldSend else { return }
        send(["active_color=\(color)"])
    }

    func stop() {
        lock.withLock {
            stopped = true
            drawsNative = false
            stopInternal()
        }
        renderer.setStyle(nil)
    }

    private func stopInternal() {
        appliedArgs = nil
        guard let p = process else { return }
        process = nil
        isSupervised = false
        p.terminationHandler = nil
        p.terminate()
    }
}
