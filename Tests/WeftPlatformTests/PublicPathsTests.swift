import Testing
@testable import WeftCore
@testable import WeftPlatform

@Test func aSyntheticDesktopIsStableAndClearOfRealIds() {
    let a = PublicPaths.syntheticDesktop(for: "37D8832A-2D66-02CA-B9F7-8F30A301B230")
    #expect(a == PublicPaths.syntheticDesktop(for: "37D8832A-2D66-02CA-B9F7-8F30A301B230"))
    #expect(a != PublicPaths.syntheticDesktop(for: "OTHER"))
    #expect(a >= (1 << 62))
}

@Test func aWindowIsOnTheDisplayHoldingMostOfIt() {
    let left = SpaceControl.DisplayFrames(
        uuid: "L", frame: Frame(x: 0, y: 0, width: 1000, height: 800),
        visible: Frame(x: 0, y: 25, width: 1000, height: 775)
    )
    let right = SpaceControl.DisplayFrames(
        uuid: "R", frame: Frame(x: 1000, y: 0, width: 1000, height: 800),
        visible: Frame(x: 1000, y: 25, width: 1000, height: 775)
    )
    #expect(PublicPaths.display(of: Frame(x: 850, y: 0, width: 400, height: 300), among: [left, right]) == "R")
    // Parked: one point on screen, and that is enough to say where.
    #expect(PublicPaths.display(of: Frame(x: 999, y: 799, width: 600, height: 400), among: [left]) == "L")
    #expect(PublicPaths.display(of: Frame(x: 5000, y: 5000, width: 10, height: 10), among: [left, right]) == nil)
}
