import Foundation
import WeftIPC

public enum Bench {
    public static func run(command: String, iterations: Int) {
        let sockPath = IPCPaths.socketPath()
        guard IPCClient.sendCommand(path: sockPath, command: "query state") != nil else {
            fputs("weftctl: cannot benchmark — daemon is not running at \(sockPath)\n", stderr)
            exit(1)
        }

        print("Benchmarking '\(command)' over \(iterations) iterations...")
        var samples: [Double] = []
        samples.reserveCapacity(iterations)

        // Warmup 5 iterations
        for _ in 0..<min(5, iterations) {
            _ = IPCClient.sendCommand(path: sockPath, command: command)
        }

        let startOverall = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = IPCClient.sendCommand(path: sockPath, command: command)
            let t1 = DispatchTime.now().uptimeNanoseconds
            let dtMs = Double(t1 - t0) / 1_000_000.0
            samples.append(dtMs)
        }
        let endOverall = DispatchTime.now().uptimeNanoseconds
        let totalSec = Double(endOverall - startOverall) / 1_000_000_000.0

        samples.sort()
        let count = samples.count
        guard count > 0 else { return }

        let minVal = samples.first!
        let maxVal = samples.last!
        let avg = samples.reduce(0, +) / Double(count)
        let p50 = samples[Int(Double(count) * 0.50)]
        let p90 = samples[Int(Double(count) * 0.90)]
        let p95 = samples[Int(Double(count) * 0.95)]
        let p99 = samples[min(count - 1, Int(Double(count) * 0.99))]

        print("\n--- Benchmark Results (\(count) iterations in \(String(format: "%.2f", totalSec))s) ---")
        print(String(format: "  min:  %6.3f ms", minVal))
        print(String(format: "  avg:  %6.3f ms", avg))
        print(String(format: "  p50:  %6.3f ms", p50))
        print(String(format: "  p90:  %6.3f ms", p90))
        print(String(format: "  p95:  %6.3f ms", p95))
        print(String(format: "  p99:  %6.3f ms", p99))
        print(String(format: "  max:  %6.3f ms", maxVal))

        // Simple 5-bucket distribution
        print("\nDistribution:")
        let bucketCount = 5
        let range = max(0.001, maxVal - minVal)
        let bucketSize = range / Double(bucketCount)
        var buckets = [Int](repeating: 0, count: bucketCount)
        for s in samples {
            let idx = min(bucketCount - 1, Int((s - minVal) / bucketSize))
            buckets[idx] += 1
        }
        for (i, b) in buckets.enumerated() {
            let bStart = minVal + Double(i) * bucketSize
            let bEnd = bStart + bucketSize
            let barLen = Int((Double(b) / Double(count)) * 40)
            let bar = String(repeating: "#", count: barLen)
            print(String(format: "  [%5.2f - %5.2f ms]: %5d (%4.1f%%) %@", bStart, bEnd, b, (Double(b) / Double(count)) * 100, bar))
        }
    }
}
