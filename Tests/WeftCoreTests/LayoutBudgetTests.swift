import Foundation
import Testing
@testable import WeftCore

/// The one performance property that can be checked without a WindowServer.
///
/// Everything else weft's latency is made of — the world sweep, the AX writes
/// — needs a real desktop and lives in `weftctl bench`. The pure layout pass
/// does not, and it is the piece that has to stay negligible: it runs on the
/// core queue, which every keybind blocks on, and it runs once per space per
/// apply. If it ever creeps into the milliseconds, every other optimisation
/// in the apply path is being spent to cover for it.
///
/// The budget is deliberately loose — 50 µs per pass for twenty windows, when
/// the real figure is two orders of magnitude under that. This is a tripwire
/// for an accidental quadratic, not a microbenchmark, and it has to stay
/// quiet on a loaded CI runner.
///
/// Which means the *median* of several batches, not one batch's mean. A shared
/// runner deschedules a batch now and then, and a single mean carries that
/// straight into the result: this failed a release at 61 µs on a machine where
/// the honest figure is a fraction of one. Raising the number instead would
/// have blunted the tripwire to keep the noise out. A quadratic blows every
/// batch, so the median still catches it on the first run.
@Test func layoutOfTwentyWindowsStaysNegligible() {
    var tree = Tree()
    for id in 1...20 as ClosedRange<WindowID> {
        tree = tree.inserting(id, in: screen, config: TilingConfig())
    }
    #expect(tree.windows.count == 20)

    let perPassUs = medianPerPassUs {
        let frames = layout(tree, in: screen, config: TilingConfig())
        #expect(frames.count == 20)
    }
    #expect(perPassUs < 50, "layout of 20 windows took \(perPassUs)µs per pass")
}

/// Median per-pass microseconds over several batches. See the note above on
/// why the median and not the mean.
private func medianPerPassUs(
    batches: Int = 7, iterations: Int = 200, _ body: () -> Void
) -> Double {
    // One warm pass: the first call pays for whatever the allocator does on
    // the way up, and that is not what is being measured.
    body()
    var samples: [Double] = []
    for _ in 0..<batches {
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { body() }
        let elapsed = DispatchTime.now().uptimeNanoseconds - t0
        samples.append(Double(elapsed) / 1000.0 / Double(iterations))
    }
    samples.sort()
    return samples[samples.count / 2]
}

/// Deep stacks were the plausible quadratic: every member of a stack shares
/// one slot, and the peek offset is computed per member per pass.
@Test func layoutOfADeepStackStaysNegligible() {
    var tree = Tree()
    tree = tree.inserting(1, in: screen, config: TilingConfig())
    tree = tree.togglingStack()
    for id in 2...20 as ClosedRange<WindowID> {
        tree = tree.inserting(id, in: screen, config: TilingConfig())
    }

    let perPassUs = medianPerPassUs {
        _ = layout(tree, in: screen, config: TilingConfig())
    }
    #expect(perPassUs < 50, "layout of a 20-member stack took \(perPassUs)µs per pass")
}
