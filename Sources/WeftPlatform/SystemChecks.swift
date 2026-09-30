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

    /// What macOS itself does with a horizontal swipe of `fingers` fingers,
    /// when it does something — the swipe weft's workspace swipe would share.
    ///
    /// `…HorizSwipeGesture` is 2 for "Swipe between full-screen applications"
    /// (desktops) and, for three fingers, 1 for "Swipe between pages". Both
    /// trackpad domains, since a Magic Trackpad keeps its own. A key absent
    /// from both is the stock setting: four fingers switch desktops, three do
    /// nothing.
    public static func systemSwipe(fingers: Int) -> String? {
        let key = fingers == 3 ? "TrackpadThreeFingerHorizSwipeGesture"
            : fingers == 4 ? "TrackpadFourFingerHorizSwipeGesture" : nil
        guard let key else { return nil }
        let values = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
            .compactMap { UserDefaults(suiteName: $0)?.object(forKey: key) as? Int }
        let value = values.first { $0 != 0 } ?? (values.isEmpty && fingers == 4 ? 2 : 0)
        switch value {
        case 2: return "switches between desktops"
        case 1 where fingers == 3: return "swipes between pages"
        default: return nil
        }
    }

    public static let trackpadGesturesSetting = "System Settings › Trackpad › More Gestures"
}
