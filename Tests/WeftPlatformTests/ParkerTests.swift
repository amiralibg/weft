import CoreGraphics
import Foundation
import Testing
@testable import WeftCore
@testable import WeftPlatform

// Moving a window is a SkyLight call against a live window and is not testable
// here, exactly as `AXApplier`'s frame-set protocol is not. What is testable is
// everything that decides WHETHER to move one — the corner, and the two guards
// that stand between a ledger entry and a window that does not belong to it.

private func tempParker() -> Parker {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("weft-parker-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return Parker(ledger: ParkLedger(url: dir.appendingPathComponent("parked.json")))
}

/// A window id the WindowServer will not know. `SLSGetWindowBounds` answers
/// nothing for it, which is what a dead window looks like.
private let deadWID: WindowID = 0xFFFF_FFF0

// MARK: - The corner

@Test func theParkSpotIsTheBottomRightCornerOnePointIn() {
    let display = Frame(x: 0, y: 0, width: 1728, height: 1117)
    #expect(Parker.spot(in: display) == CGPoint(x: 1727, y: 1116))
}

@Test func theParkSpotFollowsTheDisplayItIsOn() {
    // A second display west of the primary has a negative origin, and its
    // corner is still its own bottom-right — not the main display's, and not
    // a large negative x, which is the direction Accessibility clamps.
    let west = Frame(x: -1920, y: -200, width: 1920, height: 1080)
    #expect(Parker.spot(in: west) == CGPoint(x: -1, y: 879))
}

// MARK: - Nothing moves that was not written down first

@Test func aWindowWhoseBoundsCannotBeReadIsNotParked() throws {
    let parker = tempParker()
    let outcome = try parker.park([deadWID], on: Frame(x: 0, y: 0, width: 1728, height: 1117))
    #expect(outcome.unreadable == [deadWID])
    #expect(outcome.parked.isEmpty)
    // And no ledger was written, because there was nothing true to say in it.
    #expect(parker.ledger.load() == .nothingParked)
}

@Test func parkingRefusesOutrightWhenTheLedgerCannotBeRead() throws {
    let parker = tempParker()
    try Data("not a ledger".utf8).write(to: parker.ledger.url)
    #expect(throws: Parker.ParkError.self) {
        // Overwriting a ledger weft cannot read would make whatever it held
        // unrecoverable, so parking more windows on top of it is refused.
        try parker.park([1], on: Frame(x: 0, y: 0, width: 1728, height: 1117))
    }
}

// MARK: - A ledger entry is not a licence to move whatever holds that id

@Test func anEntryForAWindowThatIsGoneIsDiscardedRatherThanActedOn() {
    let parker = tempParker()
    try! parker.ledger.save([
        ParkedWindow(
            wid: deadWID,
            frame: Frame(x: 10, y: 20, width: 800, height: 600),
            parkedAt: ParkedWindow.Spot(x: 1727, y: 1116)
        )
    ])
    let outcome = parker.unparkAll()
    // The WindowServer recycles window ids and a crashed daemon never ran
    // `forgetWindow`. Whatever holds this id now is not the window weft
    // parked, and it is not dragged to a dead window's frame.
    #expect(outcome.notOurs == [deadWID])
    #expect(outcome.restored.isEmpty)
    #expect(parker.ledger.load() == .nothingParked)
}

@Test func anUnreadableLedgerIsReportedAndLeftAloneRatherThanDeleted() throws {
    let parker = tempParker()
    try Data("not a ledger".utf8).write(to: parker.ledger.url)
    let outcome = parker.unparkAll()
    #expect(outcome.note != nil)
    #expect(outcome.restored.isEmpty)
    // Left on disk: this build cannot read it, a later one may be able to,
    // and it is the only record that those windows are off screen at all.
    #expect(FileManager.default.fileExists(atPath: parker.ledger.url.path))
}

@Test func nothingParkedIsSilent() {
    #expect(tempParker().unparkAll().isEmpty)
}

@Test func unparkingWindowsTheLedgerDoesNotHoldRewritesNothing() {
    let parker = tempParker()
    let entry = ParkedWindow(
        wid: deadWID,
        frame: Frame(x: 10, y: 20, width: 800, height: 600),
        parkedAt: ParkedWindow.Spot(x: 1727, y: 1116)
    )
    try! parker.ledger.save([entry])
    #expect(parker.unpark([7, 8]).isEmpty)
    #expect(parker.ledger.load() == .parked([entry]))
}

@Test func parkerTracksParkedWindowIDs() {
    let parker = tempParker()
    #expect(parker.parkedWIDs.isEmpty)
    #expect(!parker.isParked(42))

    let entry = ParkedWindow(
        wid: 42,
        frame: Frame(x: 10, y: 20, width: 800, height: 600),
        parkedAt: ParkedWindow.Spot(x: 1727, y: 1116)
    )
    try! parker.ledger.save([entry])

    #expect(parker.parkedWIDs == [42])
    #expect(parker.isParked(42))
    #expect(!parker.isParked(43))
}

@Test func unparkOutsideLeavesInBoundsWindowsAlone() {
    let parker = tempParker()
    let insideEntry = ParkedWindow(
        wid: deadWID,
        frame: Frame(x: 10, y: 20, width: 800, height: 600),
        parkedAt: ParkedWindow.Spot(x: 100, y: 100)
    )
    try! parker.ledger.save([insideEntry])

    // Display frame contains (100, 100)
    let displays = [Frame(x: 0, y: 0, width: 1728, height: 1117)]
    let outcome = parker.unparkOutside(displays: displays)
    #expect(outcome.isEmpty)
    #expect(parker.ledger.load() == .parked([insideEntry]))
}

@Test func unparkOutsideRestoresWindowsOnRemovedDisplays() {
    let parker = tempParker()
    let outsideEntry = ParkedWindow(
        wid: deadWID,
        frame: Frame(x: -1000, y: 100, width: 800, height: 600),
        parkedAt: ParkedWindow.Spot(x: -1, y: 879)
    )
    try! parker.ledger.save([outsideEntry])

    // Only primary display remains, outsideEntry was on external display
    let displays = [Frame(x: 0, y: 0, width: 1728, height: 1117)]
    let outcome = parker.unparkOutside(displays: displays)
    // deadWID fails live frame check (notOurs), so it gets purged
    #expect(outcome.notOurs == [deadWID])
    #expect(parker.ledger.load() == .nothingParked)
}
