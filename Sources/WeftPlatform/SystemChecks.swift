import CoreGraphics
import Foundation

/// macOS settings that change what weft can do, read without asking anyone.
///
/// Shared by the daemon's startup log, `weftctl doctor` and WeftBar, so all
/// three say the same thing about the same machine.
public enum SystemChecks {
    /// Stage Manager arranges windows too. With it on, macOS and weft move
    /// the same windows, and the symptom — a tile snapping back a moment
    /// after weft placed it — reads as a weft bug, so the report arrives
    /// pointing at the wrong thing (DESIGN §11 risk 9).
    public static func stageManagerEnabled() -> Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
    }

    /// The lock screen is up. Every window reads as off screen behind it, so
    /// anything that judges windows by visibility has to stand down — or
    /// locking the Mac would empty every layout.
    public static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Where to turn it off, spelled the way the user will see it.
    public static let stageManagerSetting =
        "System Settings › Desktop & Dock › Stage Manager"

    /// macOS's own window tiling, each switch that is on. Dragging a window to
    /// a screen edge makes macOS resize it, and weft resizes the same window
    /// back — a tug of war that reads as weft being broken. All three are on
    /// on a stock Mac (absent from the domain means the default, on).
    public static func macOSTilingEnabled() -> [String] {
        let defaults = UserDefaults(suiteName: "com.apple.WindowManager")
        func on(_ key: String) -> Bool { defaults?.object(forKey: key) as? Bool ?? true }
        var out: [String] = []
        if on("EnableTilingByEdgeDrag") { out.append("Drag windows to screen edges to tile") }
        if on("EnableTopTilingByEdgeDrag") { out.append("Drag windows to menu bar to fill screen") }
        if on("EnableTilingOptionAccelerator") { out.append("Hold ⌥ key while dragging windows to tile") }
        return out
    }

    public static let macOSTilingSetting = "System Settings › Desktop & Dock › Windows"

    /// Opens the pane holding both macOS tiling and Stage Manager.
    public static let desktopAndDockURL = "x-apple.systempreferences:com.apple.Desktop-Settings.extension"

    /// "Displays have separate Spaces" (System Settings › Desktop & Dock).
    /// On by default. weft works either way; off, macOS has one desktop across
    /// every display, and weft still shows a workspace per display on it.
    public static func displaysHaveSeparateSpaces() -> Bool {
        !(UserDefaults(suiteName: "com.apple.spaces")?.bool(forKey: "spans-displays") ?? false)
    }
}
