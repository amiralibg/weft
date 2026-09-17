/// Reading the installer's output back as progress.
///
/// `install-release.sh` is the one updater weft has — the same script the curl
/// one-liner runs, rather than a second implementation in Swift that could
/// drift from it. So the only progress signal available is what that script
/// prints, and this is where it is interpreted.
///
/// Two channels, and the second is the one that matters:
///
/// - `==> <stage>` lines, printed once per stage. They name what is happening.
/// - curl's `--progress-bar`, a line of hashes and a percentage rewritten in
///   place after every chunk, with a carriage return and no newline.
///
/// Only the first was read at one point, and the download publishes exactly one
/// stage line before going quiet for the whole transfer. On a slow link to
/// GitHub's CDN that is minutes — measured at 45% after two and a half on the
/// machine this was reported from — and a sentence that does not change for
/// that long is indistinguishable from a hang.
///
/// Here rather than in WeftBar because an executable target cannot have tests,
/// and this decides what a progress bar claims. A parser that reports a stale
/// percentage shows a bar that sticks or goes backwards, which is worse than
/// showing none.
public enum UpdateProgress {
    /// How far through the stage in flight, 0…1, or nil when nothing in the
    /// output is currently reporting a figure.
    ///
    /// `lines` is the log split on `CharacterSet.newlines`, which includes the
    /// carriage return curl overwrites its own line with — so each rewrite of
    /// the bar arrives here as its own entry and the newest is simply the last.
    public static func percent(in lines: [String]) -> Double? {
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A stage line *after* the bar means the download finished and the
            // figure behind it describes something that is over. Reporting it
            // would leave the bar parked at whatever it last read, through
            // every stage that follows.
            if trimmed.hasPrefix("==> ") { return nil }
            // Only curl's own bar: hashes, spaces, then the figure. A message
            // that merely contains a percentage is not progress, and matching
            // one would let arbitrary text drive the bar.
            guard trimmed.hasSuffix("%"), trimmed.contains("#") else { continue }
            let value = trimmed.dropLast().drop { $0 == "#" || $0 == " " }
            guard let percent = Double(value), (0...100).contains(percent) else { continue }
            return percent / 100
        }
        return nil
    }
}
