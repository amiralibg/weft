import Foundation

/// The one place the version number lives.
///
/// Hardcoded rather than generated at build time on purpose: SwiftPM has no
/// clean way to inject a value, and every workaround (a `sed` in CI, a
/// generated file, a plugin) means the number in a local `swift build` differs
/// from the number in a release — which is exactly the situation where you need
/// it to be trustworthy.
///
/// `.github/workflows/release.yml` refuses to publish a tag whose version does
/// not match this constant, so the two cannot silently drift.
public enum WeftVersion {
    public static let current = "0.7.9"

    /// Order two version strings the way a release feed means them.
    ///
    /// Deliberately not `String` comparison, which is the bug every hand-rolled
    /// update check ships with: "0.10.0" sorts *before* "0.9.0" as text, so the
    /// tenth release would never be offered to anyone. Compares numerically,
    /// component by component, treating a missing component as 0 so "0.2" and
    /// "0.2.0" are the same release. A leading "v" is accepted because that is
    /// how the tags are written.
    ///
    /// Anything non-numeric in a component makes it 0, so a pre-release tag
    /// sorts below the release it precedes rather than throwing.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let trimmed = v.hasPrefix("v") ? String(v.dropFirst()) : v
            // Drop any pre-release/build suffix: 1.2.3-beta.1 → 1.2.3
            let core = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// What `weftctl --version` prints, and what a bug report should quote.
    public static var full: String {
        var out = "weft \(current)"
        #if arch(arm64)
            out += " (arm64)"
        #elseif arch(x86_64)
            out += " (x86_64)"
        #endif
        return out
    }
}
