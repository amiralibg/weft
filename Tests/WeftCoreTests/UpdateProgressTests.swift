import Foundation
import Testing

@testable import WeftCore

/// Reading a percentage back out of the installer's log.
///
/// The cases are taken from a real log captured while reproducing "the update
/// showed no progress": `WEFT_VERSION=v0.9.5 bash install-release.sh`, whose
/// download sat at 44.9% two and a half minutes in.
private func split(_ raw: String) -> [String] {
    raw.components(separatedBy: .newlines)
}

@Test func readsTheLivePercentageFromCurlsBar() {
    // Exactly what the log holds: one stage line, then the bar rewritten in
    // place with carriage returns and no newline in sight.
    let raw = "==> downloading weft 0.9.5\n"
        + "#####                                                                     7.1%\r"
        + "################################                                          44.8%\r"
        + "################################                                          44.9%"
    #expect(UpdateProgress.percent(in: split(raw)) == 0.449)
}

@Test func carriageReturnsSeparateTheRedraws() {
    // curl writes no newline at all while it works — it rewrites one line with
    // `\r`. `CharacterSet.newlines` includes the carriage return, so each
    // redraw lands here as its own entry; the first draft of this file
    // asserted the opposite and the test said otherwise.
    let raw = "==> downloading weft 0.9.5\n###  10.0%\r###  20.0%"
    #expect(split(raw).count == 3)
    #expect(UpdateProgress.percent(in: split(raw)) == 0.2)
}

@Test func aStageAfterTheBarEndsTheProgress() {
    // The download is over. Reporting the figure behind the newer stage line
    // would leave the bar parked at 44.9% through verifying, installing,
    // signing and everything else.
    let raw = "==> downloading weft 0.9.5\n"
        + "#########  44.9%\r"
        + "######################################  100.0%\n"
        + "==> verifying checksum\n"
    #expect(UpdateProgress.percent(in: split(raw)) == nil)
}

@Test func onlyCurlsBarDrivesTheBar() {
    // A percentage inside a sentence is not progress. Letting arbitrary text
    // move the bar means any message with a number in it can drag it
    // backwards.
    let raw = "==> downloading weft 0.9.5\n"
        + "###  30.0%\r"
        + "WARNING: only 90% of mirrors responded\n"
    #expect(UpdateProgress.percent(in: split(raw)) == 0.3)
}

@Test func nothingToReportIsNil() {
    #expect(UpdateProgress.percent(in: []) == nil)
    #expect(UpdateProgress.percent(in: split("")) == nil)
    #expect(UpdateProgress.percent(in: split("==> stopping any running weft\n")) == nil)
    // Hashes with no figure, and a figure with no hashes: neither is the bar.
    #expect(UpdateProgress.percent(in: split("#######")) == nil)
    #expect(UpdateProgress.percent(in: split("  44.9%")) == nil)
}

@Test func theBoundsAreTheBoundsOfAPercentage() {
    #expect(UpdateProgress.percent(in: split("#  0.0%")) == 0)
    #expect(UpdateProgress.percent(in: split("#  100.0%")) == 1)
    // Not a percentage, whatever it is — a bar told to draw 4.5 would run off
    // the end of the row.
    #expect(UpdateProgress.percent(in: split("#  450.0%")) == nil)
    #expect(UpdateProgress.percent(in: split("#  -3.0%")) == nil)
}
