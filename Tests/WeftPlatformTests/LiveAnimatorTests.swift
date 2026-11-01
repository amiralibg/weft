import CoreGraphics
import Testing
@testable import WeftPlatform

/// The spring arrives, snapped exactly onto the target, in about a third of
/// a second at 120 Hz — and never overshoots (critically damped).
@Test func springSettlesOnTargetWithoutOvershoot() {
    var current = CGRect(x: 0, y: 0, width: 800, height: 600)
    let target = CGRect(x: 960, y: 0, width: 400, height: 600)
    var v = LiveAnimator.Velocity()
    var steps = 0
    var settled = false
    while !settled, steps < 600 {
        settled = LiveAnimator.step(&current, toward: target, velocity: &v, dt: 1.0 / 120)
        #expect(current.minX <= target.minX + 0.01)
        #expect(current.width >= target.width - 0.01)
        steps += 1
    }
    #expect(settled)
    #expect(current == target)
    #expect(Double(steps) / 120 < 0.6)
    #expect(Double(steps) / 120 > 0.15)
}

/// A dropped frame is a bigger step, not a different path.
@Test func springIsFrameRateIndependent() {
    func position(after t: Double, hz: Double) -> CGFloat {
        var r = CGRect(x: 0, y: 0, width: 100, height: 100)
        var v = LiveAnimator.Velocity()
        for _ in 0..<Int(t * hz) {
            _ = LiveAnimator.step(&r, toward: CGRect(x: 500, y: 0, width: 100, height: 100), velocity: &v, dt: 1 / hz)
        }
        return r.minX
    }
    #expect(abs(position(after: 0.1, hz: 60) - position(after: 0.1, hz: 120)) < 2)
}

@Test func liveFramesAreWholePoints() {
    let f = LiveAnimator.rounded(CGRect(x: 10.4, y: 20.6, width: 99.5, height: 50.2))
    #expect(f.x == 10 && f.y == 21 && f.width == 100 && f.height == 50)
}
