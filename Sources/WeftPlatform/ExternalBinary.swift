import Foundation

/// Where weft looks for the optional helpers it drives — `borders`,
/// `sketchybar`.
///
/// This exists because three places each had their own copy of the list, they
/// had drifted (`/usr/bin` in one, not the others), and every one of them
/// reported "not found in PATH" without ever having looked at PATH. Anyone
/// who installed borders outside Homebrew's prefix — cargo, a manual build,
/// Nix — got a message naming the one place their binary provably was not.
public enum ExternalBinary {
    /// The usual prefixes, then the real PATH. Order matters only in that the
    /// fixed list is free and PATH costs a `stat` per entry.
    public static func find(_ name: String) -> String? {
        let prefixes = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for prefix in prefixes {
            let path = prefix + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let raw = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for entry in raw.split(separator: ":") where !entry.isEmpty {
            let path = (String(entry) as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// For the "we looked here" half of an error message. A daemon started by
    /// launchd inherits a minimal PATH, so saying which places were searched
    /// is the difference between "install it" and "it *is* installed".
    public static func searchedDescription() -> String {
        let raw = ProcessInfo.processInfo.environment["PATH"] ?? "(empty)"
        return "/opt/homebrew/bin, /usr/local/bin, /usr/bin, /bin, and PATH (\(raw))"
    }
}
