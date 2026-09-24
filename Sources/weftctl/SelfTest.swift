import AppKit
import Foundation
import WeftCore
import WeftPlatform

// `weftctl doctor --selftest` — the hiding mechanism, end to end, on a window
// of weftctl's own. Run on every macOS beta before a release ships
// (docs/TESTING.md): it is the one thing weft's workspaces rest on, and the
// one thing a macOS update could quietly change.
//
// A small window titled "weft self-test" appears for about a second. It
// belongs to a second weftctl process, as every window weft hides belongs to
// another app — and because Accessibility requests to a process are answered
// on its main thread, which a process waiting on its own answer is blocking.
// No other window is touched, and the ledger it writes is a temporary one.
enum LiveSelfTest {
    /// The child: show the window, say its number, wait to be told to go.
    static func serveWindow() -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: 240, y: 240, width: 360, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "weft self-test"
        window.orderFrontRegardless()
        print(window.windowNumber)
        fflush(stdout)
        // Exit when the parent closes our stdin, or kills us.
        DispatchQueue.global().async {
            _ = FileHandle.standardInput.readDataToEndOfFile()
            exit(0)
        }
        NSApp.run()
        exit(0)
    }

    /// Hiding one window must cost less than this on the WindowServer path
    /// (S9 measured 0.2 ms) — generous, because a beta may be slower and that
    /// is worth knowing without being a failure.
    static let parkBudgetMs = 10.0

    static func run() -> Bool {
        print("=== weft self-test === \(WeftVersion.full)")
        let report = PrivateAPI.selfTest()
        print("[\(report.failed.isEmpty ? "\u{2713}" : "!")] \(report.macOS): \(report.summary)")

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["__selftest-window"]
        let out = Pipe(), input = Pipe()
        child.standardOutput = out
        child.standardInput = input
        do { try child.run() } catch {
            print("[\u{2717}] Could not start the test window: \(error)")
            return false
        }
        defer { try? input.fileHandleForWriting.close(); child.waitUntilExit() }
        let line = String(data: out.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        guard let number = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            print("[\u{2717}] The test window did not appear")
            return false
        }
        pump(0.4)
        let wid = WindowID(number)
        guard let before = WorldReader.frame(of: wid) else {
            print("[\u{2717}] Could not read the test window's frame")
            return false
        }
        let layout = SpaceControl.displayLayout()
        let frames = layout.map(\.frame)
        let display = layout.first { $0.frame.intersects(before) }?.frame ?? frames.first ?? before
        let corner = freeCorner(of: display, among: frames) ?? .bottomRight

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("weft-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let parker = Parker(
            ledger: ParkLedger(url: dir.appendingPathComponent("parked.json")),
            fallback: AXParkMover(applier: AXApplier())
        )
        let path = PrivateAPI.canMoveWindows ? "WindowServer" : "Accessibility (public path)"
        var ok = true

        // Park.
        let t0 = Date()
        do {
            let outcome = try parker.park([wid], on: display, corner: corner)
            guard outcome.parked == [wid] else {
                print("[\u{2717}] Hide: the window was not moved (\(path))")
                return false
            }
        } catch {
            print("[\u{2717}] Hide: \(error)")
            return false
        }
        let parkMs = Date().timeIntervalSince(t0) * 1000
        pump(0.2)
        let parked = WorldReader.frame(of: wid)
        let onScreen = WorldReader.onScreenWindowIDs().contains(wid)
        let visible = parked.map { display.intersects($0) } ?? false
        print("[\(visible && onScreen ? "\u{2713}" : "\u{2717}")] Hide at the \(corner.rawValue) corner via \(path): "
            + String(format: "%.2f ms", parkMs)
            + (visible ? ", one point still on screen" : ", NOT on screen")
            + (onScreen ? ", still in the on-screen list" : ", DROPPED from the on-screen list"))
        ok = ok && visible && onScreen
        if PrivateAPI.canMoveWindows, parkMs > parkBudgetMs {
            print("    slower than the \(Int(parkBudgetMs)) ms budget — worth a look on this macOS")
        }

        // Unpark.
        let t1 = Date()
        let back = parker.unpark([wid])
        let unparkMs = Date().timeIntervalSince(t1) * 1000
        pump(0.2)
        let after = WorldReader.frame(of: wid)
        let home = after.map { abs($0.x - before.x) <= 1 && abs($0.y - before.y) <= 1 } ?? false
        print("[\(home && back.restored == [wid] ? "\u{2713}" : "\u{2717}")] Show: "
            + String(format: "%.2f ms", unparkMs)
            + (home ? ", back exactly where it was" : ", NOT back where it was"))
        ok = ok && home

        print(ok ? "---\nThis macOS hides and shows windows the way weft relies on."
                 : "---\nSomething weft relies on has changed. Please report the lines above.")
        return ok
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

// `weftctl bench idle [seconds]` — what weftd costs while nothing happens.
enum IdleBench {
    static let cpuBudgetPercent = 0.5
    static let memoryBudgetMB = 40.0

    static func run(seconds: Int) -> Bool {
        guard let pid = weftdPID() else {
            fputs("weftctl: weftd is not running\n", stderr)
            return false
        }
        print("Sampling weftd (pid \(pid)) for \(seconds) s. Leave the machine alone…")
        guard let start = sample(pid) else { return false }
        Thread.sleep(forTimeInterval: TimeInterval(seconds))
        guard let end = sample(pid) else { return false }
        let cpu = (end.cpuSeconds - start.cpuSeconds) / Double(seconds) * 100
        let cpuOK = cpu <= cpuBudgetPercent
        let memOK = end.rssMB <= memoryBudgetMB
        print(String(format: "[%@] CPU while idle: %.2f%% (budget %.1f%%)", cpuOK ? "\u{2713}" : "\u{2717}", cpu, cpuBudgetPercent))
        print(String(format: "[%@] Memory: %.1f MB resident (budget %.0f MB)", memOK ? "\u{2713}" : "\u{2717}", end.rssMB, memoryBudgetMB))
        return cpuOK && memOK
    }

    private static func weftdPID() -> Int32? {
        let out = shell("/usr/bin/pgrep", ["-x", "weftd"])
        return out.split(separator: "\n").first.flatMap { Int32($0) }
    }

    /// Accumulated CPU time and resident memory, from `ps`.
    private static func sample(_ pid: Int32) -> (cpuSeconds: Double, rssMB: Double)? {
        let out = shell("/bin/ps", ["-o", "cputime=,rss=", "-p", "\(pid)"])
        let parts = out.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard parts.count >= 2, let rss = Double(parts[1]) else { return nil }
        // cputime is [[dd-]hh:]mm:ss.cc
        var seconds = 0.0
        for component in parts[0].split(separator: "-").last!.split(separator: ":") {
            seconds = seconds * 60 + (Double(component) ?? 0)
        }
        return (seconds, rss / 1024)
    }

    private static func shell(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
