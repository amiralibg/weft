import AppKit
import Foundation
import WeftCore
import WeftPlatform

// `weftctl doctor --selftest` — the native-desktop routes, end to end, on
// this Mac. Run on every macOS beta before a release ships (docs/TESTING.md):
// they are what weft's desktops rest on, and what a macOS update could
// quietly change.
//
// The private-symbol self-test, then each route (NATIVE.md, "Self-tests and
// degradation"): the symbol walk, a bridged move of a never-shown window of
// weftctl's own, and the visible switch test — a display with two desktops
// switches to its neighbour and back, once by the bridged switch and once by
// Dock swipe. No window of the user's is moved.
enum LiveSelfTest {
    static func run() -> Bool {
        print("=== weft self-test === \(WeftVersion.full)")
        let report = PrivateAPI.selfTest()
        print("[\(report.failed.isEmpty ? "\u{2713}" : "!")] \(report.macOS): \(report.summary)")
        print("Testing the native-desktop routes; a display may flicker twice.")
        let routes = NativeSelfTest.routes(allowVisible: true, force: true)
        let ok = NativeRoutesReport.print(routes) && report.failed.isEmpty
        print(ok ? "---\nThis macOS does what weft relies on."
                 : "---\nSomething weft relies on has changed. Please report the lines above.")
        return ok
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
