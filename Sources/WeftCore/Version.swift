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
    public static let current = "0.1.0"

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
