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
}
