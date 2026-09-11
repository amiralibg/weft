import Foundation

/// Installs weft's engine from inside WeftBar.app.
///
/// This is what lets installing weft be "open the app": the bundle carries
/// `weftd` and `weftctl`, and on launch WeftBar puts them in place, signs
/// them, seeds a config and starts the service. The work itself is
/// `app-install.sh`, shipped in the bundle next to the same `lib-codesign.sh`
/// and `lib-agents.sh` that install.sh uses — one implementation of the
/// signing that keeps permissions alive across updates, not a Swift port of
/// it that could quietly drift from the shell one.
enum EngineInstaller {
    static var binDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/weft-install.log")
    }

    /// The `weftctl` this app carries, if it carries one. A bare `swift run`
    /// build carries none, and never installs anything.
    static var bundledWeftctl: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/weftctl")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var script: URL? {
        Bundle.main.url(forResource: "app-install", withExtension: "sh")
    }

    /// The engine is missing, or is a different version from the one this
    /// app carries — the app was updated by replacing it, and the engine has
    /// not caught up. Either way the app installs what it carries.
    static func needsInstall() -> Bool {
        guard let bundled = bundledWeftctl, script != nil else { return false }
        let installed = binDir.appendingPathComponent("weftctl")
        guard FileManager.default.isExecutableFile(atPath: installed.path) else { return true }
        // An unreadable bundled version is a broken bundle, not a reason to
        // overwrite a working engine.
        guard let want = version(of: bundled) else { return false }
        return version(of: installed) != want
    }

    /// `weftctl --version`, trimmed. Nil when it does not run.
    static func version(of weftctl: URL) -> String? {
        let p = Process()
        p.executableURL = weftctl
        p.arguments = ["--version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    struct Outcome: Sendable {
        let ok: Bool
        let log: String
    }

    /// Run the installer. `step` receives each `==> ` line as it happens —
    /// the thing Setup shows while it works. The full output goes to
    /// `logURL`, which is what "Copy diagnostics" and a bug report want.
    static func install(step: @escaping @Sendable (String) -> Void) async -> Outcome {
        guard let script else {
            return Outcome(ok: false, log: "this WeftBar.app has no installer")
        }
        return await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path]
            var env = ProcessInfo.processInfo.environment
            env["WEFT_BUNDLE"] = Bundle.main.bundleURL.path
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let lines = LineCollector(onStep: step)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { lines.feed(data) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                lines.feed(pipe.fileHandleForReading.readDataToEndOfFile())
                let log = lines.finish()
                try? FileManager.default.createDirectory(
                    at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try? log.write(to: logURL, atomically: true, encoding: .utf8)
                continuation.resume(returning: Outcome(ok: proc.terminationStatus == 0, log: log))
            }
            do {
                try p.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: Outcome(ok: false, log: "could not start the installer: \(error)"))
            }
        }
    }
}

/// Splits installer output into lines as it streams, keeps all of it for the
/// log, and forwards the `==> ` step lines as they arrive.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var log = ""
    private let onStep: @Sendable (String) -> Void

    init(onStep: @escaping @Sendable (String) -> Void) {
        self.onStep = onStep
    }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        let complete: [String] = lock.withLock {
            buffer.append(data)
            var out: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                log += line + "\n"
                out.append(line)
            }
            return out
        }
        for line in complete where line.hasPrefix("==> ") {
            onStep(String(line.dropFirst(4)))
        }
    }

    func finish() -> String {
        lock.withLock {
            if !buffer.isEmpty {
                log += String(decoding: buffer, as: UTF8.self)
                buffer.removeAll()
            }
            return log
        }
    }
}
