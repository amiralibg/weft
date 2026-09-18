import Foundation
import Testing
@testable import WeftCore
@testable import WeftPlatform

// The park ledger is read exactly once — at startup, to find windows that are
// off screen and in no layout. Nothing downstream of that read can tell a
// wrong answer from a right one, so the shape and the three ways of having
// nothing to say are pinned here.

private func tempLedger() -> ParkLedger {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("weft-park-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return ParkLedger(url: dir.appendingPathComponent("parked.json"))
}

private func entry(_ wid: WindowID, x: Double = 100, y: Double = 200) -> ParkedWindow {
    ParkedWindow(
        wid: wid,
        frame: Frame(x: x, y: y, width: 800, height: 600),
        parkedAt: ParkedWindow.Spot(x: 1727, y: 1116)
    )
}

@Test func aSavedLedgerComesBackTheSame() throws {
    let ledger = tempLedger()
    let entries = [entry(11), entry(22, x: 7, y: 9)]
    try ledger.save(entries)
    #expect(ledger.load() == .parked(entries))
}

@Test func noFileMeansNothingIsParked() {
    #expect(tempLedger().load() == .nothingParked)
}

@Test func anEmptyLedgerMeansNothingIsParked() throws {
    let ledger = tempLedger()
    try ledger.save([])
    #expect(ledger.load() == .nothingParked)
}

// The two that matter. A file weft cannot read is NOT a file that says
// nothing is parked: the windows may be sitting at the corner, and reporting
// "nothing parked" is how that becomes silent.

@Test func aTruncatedLedgerIsUnreadableRatherThanEmpty() throws {
    let ledger = tempLedger()
    try ledger.save([entry(11), entry(22)])
    let data = try Data(contentsOf: ledger.url)
    try data.prefix(data.count / 2).write(to: ledger.url)
    guard case .unreadable = ledger.load() else {
        Issue.record("a half-written ledger read as \(ledger.load())")
        return
    }
}

@Test func aLedgerFromAnotherVersionIsUnreadableRatherThanEmpty() throws {
    let ledger = tempLedger()
    let future = #"{"version":\#(ParkLedger.version + 1),"parked":[]}"#
    try Data(future.utf8).write(to: ledger.url)
    guard case .unreadable(let why) = ledger.load() else {
        Issue.record("a future ledger read as \(ledger.load())")
        return
    }
    #expect(why.contains("version"))
}

@Test func garbageIsUnreadableRatherThanEmpty() throws {
    let ledger = tempLedger()
    try Data("not json at all".utf8).write(to: ledger.url)
    guard case .unreadable = ledger.load() else {
        Issue.record("garbage read as \(ledger.load())")
        return
    }
}

// Every park rewrites the whole ledger, so what is on disk is the current
// parked set and never an accumulation of everything ever parked.

@Test func savingReplacesTheWholeLedger() throws {
    let ledger = tempLedger()
    try ledger.save([entry(11), entry(22)])
    try ledger.save([entry(33)])
    #expect(ledger.load() == .parked([entry(33)]))
}

@Test func aLeftoverTempFileIsNotMistakenForTheLedger() throws {
    let ledger = tempLedger()
    try ledger.save([entry(11)])
    let tmp = ledger.url.deletingLastPathComponent()
        .appendingPathComponent(ledger.url.lastPathComponent + ".tmp")
    try Data("half a lednfe".utf8).write(to: tmp)
    #expect(ledger.load() == .parked([entry(11)]))
}

@Test func clearingRemovesTheFileAndSayingItTwiceIsFine() throws {
    let ledger = tempLedger()
    try ledger.save([entry(11)])
    #expect(ledger.clear())
    #expect(ledger.load() == .nothingParked)
    #expect(ledger.clear())
}

// A write that cannot land has to say so. The caller's whole contract is that
// it moves no windows unless this returned.

@Test func aWriteThatCannotLandThrows() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("weft-park-ro-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ledger = ParkLedger(url: dir.appendingPathComponent("parked.json"))
    try ledger.save([entry(11)])
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path
        )
    }
    #expect(throws: ParkLedger.WriteError.self) {
        try ledger.save([entry(22)])
    }
    // …and the ledger that was already there is untouched, which is what lets
    // a failed park leave the previous park recoverable.
    #expect(ledger.load() == .parked([entry(11)]))
}
