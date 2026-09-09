import CoreGraphics
import Foundation

// MARK: - Chord

/// A keypress: exact modifier set + hardware keycode. Modifiers compare as an
/// exact set (caps lock / fn / numpad are masked out before matching), so
/// `alt-h` never fires for `alt-shift-h`.
public struct Chord: Hashable, Sendable {
    /// Raw CGEventFlags restricted to cmd/alt/ctrl/shift.
    public var mods: UInt64
    public var keycode: Int64

    public init(mods: UInt64, keycode: Int64) {
        self.mods = mods
        self.keycode = keycode
    }
}

public enum ChordParseError: Error, Sendable, Equatable {
    case empty
    case noKey(String)
    case badModifier(String)
    case badKey(String)
}

/// Parse `"alt-shift-h"`, `"alt-bracketleft"`, `"escape"`, `"shift-h"`.
/// Modifiers: alt, shift, cmd, ctrl. Key: a-z, 0-9, or a named key below.
/// Keycodes are hardware (layout-independent) ANSI positions.
public func parseChord(_ input: String) throws -> Chord {
    let lowered = input.lowercased()
    let parts = lowered.split(separator: "-").map(String.init)
    guard !parts.isEmpty else { throw ChordParseError.empty }

    var mods: UInt64 = 0
    for token in parts.dropLast() {
        switch token {
        case "alt", "opt": mods |= CGEventFlags.maskAlternate.rawValue
        case "shift": mods |= CGEventFlags.maskShift.rawValue
        case "cmd", "command": mods |= CGEventFlags.maskCommand.rawValue
        case "ctrl", "control": mods |= CGEventFlags.maskControl.rawValue
        default: throw ChordParseError.badModifier(token)
        }
    }
    guard let keyToken = parts.last, !keyToken.isEmpty else {
        throw ChordParseError.noKey(input)
    }
    guard let keycode = keycode(for: keyToken) else {
        throw ChordParseError.badKey(keyToken)
    }
    return Chord(mods: mods, keycode: keycode)
}

/// Hardware ANSI keycodes (positions, not glyphs — Colemak-safe).
private func keycode(for name: String) -> Int64? {
    if name.count == 1, let scalar = name.unicodeScalars.first {
        let c = scalar.value
        // a-z
        if c >= 97, c <= 122 {
            let table: [UInt32: Int64] = [
                97: 0, 98: 11, 99: 8, 100: 2, 101: 14, 102: 3, 103: 5,
                104: 4, 105: 34, 106: 38, 107: 40, 108: 37, 109: 46, 110: 45,
                111: 31, 112: 35, 113: 12, 114: 15, 115: 1, 116: 17, 117: 32,
                118: 9, 119: 13, 120: 7, 121: 16, 122: 6,
            ]
            return table[c]
        }
        // 0-9
        if c >= 48, c <= 57 {
            let table: [UInt32: Int64] = [
                48: 29, 49: 18, 50: 19, 51: 20, 52: 21, 53: 23,
                54: 22, 55: 26, 56: 28, 57: 25,
            ]
            return table[c]
        }
    }
    switch name {
    case "minus": return 27
    case "equal": return 24
    case "bracketleft": return 33
    case "bracketright": return 30
    case "semicolon": return 41
    case "quote": return 39
    case "comma": return 43
    case "period": return 47
    case "slash": return 44
    case "backslash": return 42
    case "grave": return 50
    case "space": return 49
    case "tab": return 48
    case "return": return 36
    case "delete": return 51
    case "escape": return 53
    case "left": return 123
    case "right": return 124
    case "down": return 125
    case "up": return 126
    default: return nil
    }
}

// MARK: - Keymap

/// What a matched chord does: forward a command to the daemon core, or switch
/// the input mode locally. `"mode resize"` in config/CLI resolves to `.mode`
/// here — modes live in the input layer, layout commands in the core.
public enum KeyAction: Sendable, Equatable {
    case send(String)
    case mode(String)

    public static func resolve(_ command: String) -> KeyAction {
        let parts = command.split(separator: " ").map(String.init)
        if parts.count == 2, parts[0] == "mode" {
            return .mode(parts[1])
        }
        return .send(command)
    }
}

/// Mode name → chord → action. Mirrors the `[keys]` / `[mode.x]` TOML shape
/// from DESIGN §7 so M6 config parsing produces this struct directly.
public struct Keymap: Sendable, Equatable {
    public var modes: [String: [Chord: KeyAction]]
    public var initialMode: String

    public init(modes: [String: [Chord: KeyAction]], initialMode: String = "default") {
        self.modes = modes
        self.initialMode = initialMode
    }

    /// M2 defaults. Vim-flavoured: h/j/k/l move focus, shift variants warp,
    /// a modal resize layer (vim-style: h narrows, l widens).
    public static var `default`: Keymap {
        func binds(_ pairs: [(String, String)]) -> [Chord: KeyAction] {
            var out: [Chord: KeyAction] = [:]
            for (chord, command) in pairs {
                // Default keymap is static and validated by tests; a bad entry
                // is a programming error, so force-try is honest here.
                // swiftlint:disable:next force_try
                out[try! parseChord(chord)] = KeyAction.resolve(command)
            }
            return out
        }
        return Keymap(modes: [
            "default": binds([
                ("alt-h", "focus west"),
                ("alt-j", "focus south"),
                ("alt-k", "focus north"),
                ("alt-l", "focus east"),
                ("alt-shift-h", "move west"),
                ("alt-shift-j", "move south"),
                ("alt-shift-k", "move north"),
                ("alt-shift-l", "move east"),
                ("alt-v", "split vertical"),
                ("alt-shift-v", "split horizontal"),
                ("alt-b", "balance"),
                ("alt-shift-r", "mode resize"),
                ("alt-s", "stack toggle"),
                ("alt-shift-s", "stack split east"),
                ("alt-bracketleft", "stack prev"),
                ("alt-bracketright", "stack next"),
                ("alt-u", "stack unstack"),
                // M5a: plain brackets stay stack-cycle (bsp spaces); scroll
                // columns take alt-shift-brackets. Per-space conditional
                // binds (DESIGN §6) land with M6 config and reunite these.
                ("alt-shift-bracketleft", "scroll focus prev-column"),
                ("alt-shift-bracketright", "scroll focus next-column"),
                ("alt-r", "scroll width cycle"),
                ("alt-1", "space focus 1"),
                ("alt-2", "space focus 2"),
                ("alt-3", "space focus 3"),
                ("alt-4", "space focus 4"),
                ("alt-5", "space focus 5"),
                ("alt-6", "space focus 6"),
                ("alt-7", "space focus 7"),
                ("alt-8", "space focus 8"),
                ("alt-9", "space focus 9"),
                ("alt-shift-1", "space move-window 1"),
                ("alt-shift-2", "space move-window 2"),
                ("alt-shift-3", "space move-window 3"),
                ("alt-shift-4", "space move-window 4"),
                ("alt-shift-5", "space move-window 5"),
                ("alt-shift-6", "space move-window 6"),
                ("alt-shift-7", "space move-window 7"),
                ("alt-shift-8", "space move-window 8"),
                ("alt-shift-9", "space move-window 9"),
            ]),
            "resize": binds([
                ("h", "resize left 60"),
                ("j", "resize down 60"),
                ("k", "resize up 60"),
                ("l", "resize right 60"),
                ("shift-h", "resize left 120"),
                ("shift-j", "resize down 120"),
                ("shift-k", "resize up 120"),
                ("shift-l", "resize right 120"),
                ("escape", "mode default"),
            ]),
        ])
    }
}
