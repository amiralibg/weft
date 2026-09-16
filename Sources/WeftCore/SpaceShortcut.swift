import Foundation

/// The keyboard shortcut macOS uses to move one desktop left or right, and how
/// far a window has to travel to reach a given desktop.
///
/// weft moves a window to another desktop the way a person does: hold it by the
/// title bar, change desktop, let go. That is the only route that works with
/// SIP on. Every SkyLight call for it refuses an ordinary connection on macOS
/// 27 — sixteen probes across direct calls, the window's owner connection,
/// transactions, space ownership, the drag pipeline and per-process assignment,
/// three of which return `kCGErrorSuccess` and do nothing (spikes/RESULTS.md
/// §S8). A *gesture* is also refused while a drag is in flight: a synthetic
/// Dock swipe never lands while the button is held. A bound keyboard shortcut
/// does, and the window travels with it.
///
/// Which makes the binding load-bearing, and it cannot be assumed. "Move
/// left/right a space" are symbolic hot keys 79 and 81; on the machine this was
/// developed against they are remapped to ⌘⌥H and ⌘⌥L, and a posted ⌃→ reached
/// nothing at all. So weft reads what the user actually has, the same way
/// `SpaceControl.missionControlSwitchShortcuts()` reads 118…126 for ⌃N.
///
/// One asymmetry with those: "Switch to Desktop N" ships **off**, so an absent
/// id means unavailable. 79 and 81 ship **on**, so an absent id means enabled
/// with the default key — absence is the common case on a stock Mac, not a gap.
public struct SpaceShortcut: Equatable, Sendable {
    /// Hardware key code, layout-independent, as `CGEvent` wants it.
    public var keyCode: UInt16
    /// Modifier mask exactly as `com.apple.symbolichotkeys` stores it:
    /// shift `0x20000`, control `0x40000`, option `0x80000`, command `0x100000`.
    public var modifiers: UInt64

    public init(keyCode: UInt16, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum SpaceShortcuts {
    /// Symbolic hot key ids for "Move left a space" and "Move right a space".
    public static let moveLeftID = 79
    public static let moveRightID = 81

    /// What macOS ships these as when nobody has changed them: ⌃← and ⌃→.
    public static let defaultLeft = SpaceShortcut(keyCode: 123, modifiers: 0x4_0000)
    public static let defaultRight = SpaceShortcut(keyCode: 124, modifiers: 0x4_0000)

    /// `keyCode` macOS writes when an entry exists but carries no key.
    static let noKey: UInt16 = 65535

    /// Read one shortcut out of an `AppleSymbolicHotKeys` dictionary.
    ///
    /// Takes the dictionary rather than reading defaults itself, so the parsing
    /// — which is all the interesting behaviour — is testable without a Mac in
    /// a particular state. `nil` means "there is no keystroke weft can send":
    /// the entry is disabled, or present with no key bound.
    public static func read(
        id: Int, from hotkeys: [String: Any], fallback: SpaceShortcut
    ) -> SpaceShortcut? {
        // Absent means untouched, and these two ship enabled.
        guard let entry = hotkeys["\(id)"] as? [String: Any] else { return fallback }
        if let enabled = entry["enabled"] as? Bool, !enabled { return nil }
        if let enabled = entry["enabled"] as? NSNumber, enabled.intValue == 0 { return nil }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any], parameters.count >= 3
        else { return fallback }
        // parameters = (ascii, key code, modifier mask). The ascii entry is
        // 65535 for keys that have none, which is why the key code is read
        // from index 1 and never derived from the character.
        guard let rawKey = (parameters[1] as? NSNumber)?.uint16Value, rawKey != noKey else {
            return nil
        }
        let mods = (parameters[2] as? NSNumber)?.uint64Value ?? fallback.modifiers
        return SpaceShortcut(keyCode: rawKey, modifiers: mods)
    }

    /// Both directions at once, as a stock Mac or a remapped one has them.
    public static func read(from hotkeys: [String: Any]) -> (left: SpaceShortcut?, right: SpaceShortcut?) {
        (
            read(id: moveLeftID, from: hotkeys, fallback: defaultLeft),
            read(id: moveRightID, from: hotkeys, fallback: defaultRight)
        )
    }

    /// How many desktops, and which way, from `current` to `target`.
    ///
    /// Positive is rightward. `0` means there is nothing to do, and `nil` means
    /// one of them is not on this display's list, which is the caller's signal
    /// to stop rather than to press a key hopefully.
    ///
    /// The list must be the display's **full** space list, fullscreen spaces
    /// included. The shortcut steps through those exactly as a swipe does, so
    /// counting weft's ordinary-desktop ordinals instead would stop short by
    /// one for every fullscreen app in between.
    public static func steps(from current: SpaceID, to target: SpaceID, in list: [SpaceID]) -> Int? {
        guard let here = list.firstIndex(of: current), let there = list.firstIndex(of: target)
        else { return nil }
        return there - here
    }
}
