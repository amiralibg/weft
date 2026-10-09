// WeftBarConfig/ConfigTidy.swift — the settings weft no longer reads, and
// taking them out of a weft.toml without touching anything else.
//
// `weftctl config tidy` and every installer run this. Here rather than in
// weftctl because it rewrites the user's config file, and code that can eat a
// config file needs tests.

public enum ConfigTidy {
    /// `[general]` keys that only produce a warning now:
    /// - `workspaces`, `workspace-anchor`: 0.9.11–0.9.14 chose between two
    ///   workspace models;
    /// - `workspace-swipe-fingers`: weft's own swipe between virtual
    ///   workspaces; macOS's swipe moves between its desktops now.
    public static let retiredGeneralKeys = ["workspaces", "workspace-anchor", "workspace-swipe-fingers"]
    /// `[[space]]` keys likewise: `display`, because macOS decides which
    /// display a desktop is on (docs/NATIVE.md).
    public static let retiredSpaceKeys = ["display"]

    /// `text` with every retired key removed, and the keys removed ("[[space]]
    /// display" for one inside a space). Unchanged text and no keys when there
    /// was nothing to do.
    public static func tidy(_ text: String) -> (String, [String]) {
        var doc = TomlDocument(text)
        var removed: [String] = []
        if let i = doc.firstIndex(ofHeader: "[general]") {
            for key in retiredGeneralKeys where doc.sections[i].rawValue(key) != nil {
                doc.sections[i].remove(key)
                removed.append(key)
            }
        }
        for i in doc.indices(ofHeader: "[[space]]") {
            for key in retiredSpaceKeys where doc.sections[i].rawValue(key) != nil {
                doc.sections[i].remove(key)
                if !removed.contains("[[space]] \(key)") { removed.append("[[space]] \(key)") }
            }
        }
        return (removed.isEmpty ? text : doc.render(), removed)
    }
}
