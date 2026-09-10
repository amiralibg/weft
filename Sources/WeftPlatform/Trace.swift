import Foundation

/// Phase timing for the paths a user actually waits on.
///
/// Weft's latency is not one number. A retile is a WindowServer sweep, a pure
/// layout computation, one atomic `SLSTransaction` of positions and then a
/// cross-process AX write per app — and only the last of those is slow. An
/// end-to-end figure hides which, so "weft feels slow" could never be
/// answered with anything but a guess.
///
/// So: named phases, each one a bounded ring of samples, readable over IPC by
/// `weftctl bench`. Collection is **always on** — an append into a fixed
/// array behind an uncontended lock, a few times per user action, is not a
/// cost worth a feature flag, and a profiler you have to enable is a profiler
/// nobody has running when the slow thing happens. `WEFT_TRACE=1` adds the
/// per-operation stderr line on top.
///
/// Everything here is safe to call from any queue.
public enum Trace {
    /// Per-operation logging to stderr. Collection happens regardless.
    public static let logging = ProcessInfo.processInfo.environment["WEFT_TRACE"] == "1"

    /// Samples kept per phase. 512 doubles is 4 KB per phase and enough to
    /// make a p99 mean something over a benchmark run.
    private static let capacity = 512

    private final class Ring {
        var values = [Double](repeating: 0, count: Trace.capacity)
        var next = 0
        var total = 0
        /// Slowest sample since the last reset, and what it was doing.
        var worst: Double = 0
        var worstDetail: String = ""

        func add(_ ms: Double, detail: String?) {
            values[next] = ms
            next = (next + 1) % Trace.capacity
            total += 1
            if ms > worst {
                worst = ms
                worstDetail = detail ?? ""
            }
        }

        var samples: [Double] {
            total < Trace.capacity ? Array(values[0..<total]) : values
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var rings: [String: Ring] = [:]

    // MARK: - Recording

    /// Record one sample, in milliseconds. `detail` is kept only for the
    /// slowest sample — enough to name the app behind a p99 without paying
    /// for a string per sample.
    public static func record(_ phase: String, ms: Double, detail: String? = nil) {
        lock.lock()
        let ring = rings[phase] ?? {
            let r = Ring()
            rings[phase] = r
            return r
        }()
        ring.add(ms, detail: detail)
        lock.unlock()
        if logging {
            let suffix = detail.map { " \($0)" } ?? ""
            fputs(String(format: "weftd: trace %@ %.2fms%@\n", phase, ms, suffix), stderr)
        }
    }

    /// An open measurement. Value type on purpose: starting one allocates
    /// nothing, so a phase that turns out not to matter costs a clock read.
    public struct Span: Sendable {
        let phase: String
        let start: UInt64

        /// Close the span and file the sample.
        public func end(detail: String? = nil) {
            Trace.record(phase, ms: Trace.elapsedMs(since: start), detail: detail)
        }

        /// Milliseconds since the span opened, without closing it. For a
        /// caller that files the sample under a name it only learns later.
        public var elapsedMs: Double { Trace.elapsedMs(since: start) }
    }

    public static func start(_ phase: String) -> Span {
        Span(phase: phase, start: DispatchTime.now().uptimeNanoseconds)
    }

    /// Time a synchronous body and return its result.
    @discardableResult
    public static func time<T>(_ phase: String, detail: String? = nil, _ body: () throws -> T) rethrows -> T {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { record(phase, ms: elapsedMs(since: t0), detail: detail) }
        return try body()
    }

    private static func elapsedMs(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000.0
    }

    // MARK: - Reading

    public struct PhaseStats: Codable, Sendable, Equatable {
        public var phase: String
        /// Samples taken since the last reset — may exceed `kept`.
        public var count: Int
        /// Samples the percentiles were computed over.
        public var kept: Int
        public var min: Double
        public var p50: Double
        public var p90: Double
        public var p99: Double
        public var max: Double
        public var mean: Double
        /// What the slowest sample was doing, when the caller said.
        public var worstDetail: String
    }

    /// Every phase seen since the last reset, slowest p50 first — the order
    /// you want when the question is "what should I fix".
    public static func stats() -> [PhaseStats] {
        let snapshot: [(String, [Double], Int, Double, String)] = lock.withLock {
            rings.map { ($0.key, $0.value.samples, $0.value.total, $0.value.worst, $0.value.worstDetail) }
        }
        return snapshot.compactMap { phase, values, total, worst, worstDetail -> PhaseStats? in
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            func pct(_ p: Double) -> Double {
                let i = Swift.min(sorted.count - 1, Swift.max(0, Int((Double(sorted.count) * p).rounded(.down))))
                return sorted[i]
            }
            return PhaseStats(
                phase: phase,
                count: total,
                kept: sorted.count,
                min: sorted.first!,
                p50: pct(0.50),
                p90: pct(0.90),
                p99: pct(0.99),
                max: worst,
                mean: sorted.reduce(0, +) / Double(sorted.count),
                worstDetail: worstDetail
            )
        }
        .sorted { $0.p50 > $1.p50 }
    }

    /// Drop every sample. `weftctl bench` calls this before a run so the
    /// numbers describe the run and not the last hour of desktop use.
    public static func reset() {
        lock.withLock { rings.removeAll() }
    }
}
