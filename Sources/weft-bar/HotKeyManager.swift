import AppKit
import Carbon.HIToolbox

@MainActor
public final class HotKeyManager {
    public static let shared = HotKeyManager()

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var isHandlerInstalled = false

    private init() {}

    private func ensureHandlerInstalled() {
        guard !isHandlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return noErr }
                DispatchQueue.main.async {
                    HotKeyManager.shared.dispatch(id: hotKeyID.id)
                }
                return noErr
            },
            1,
            &spec,
            nil,
            nil
        )
        isHandlerInstalled = true
    }

    public func dispatch(id: UInt32) {
        actions[id]?()
    }

    public func unregisterAll() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        actions.removeAll()
        nextID = 1
    }

    @discardableResult
    public func register(keyString: String, action: @escaping @MainActor () -> Void) -> Bool {
        ensureHandlerInstalled()
        guard let (keyCode, modifiers) = parseKeyString(keyString) else {
            return false
        }

        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x57454654), id: id) // 'WEFT'
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard err == noErr, let validRef = ref else {
            return false
        }
        hotKeyRefs[id] = validRef
        actions[id] = action
        return true
    }

    private func parseKeyString(_ str: String) -> (keyCode: Int, modifiers: Int)? {
        let parts = str.lowercased().split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return nil }

        var mods = 0
        for mod in parts.dropLast() {
            switch mod {
            case "cmd", "command": mods |= cmdKey
            case "shift": mods |= shiftKey
            case "alt", "opt", "option": mods |= optionKey
            case "ctrl", "control": mods |= controlKey
            default: return nil
            }
        }

        guard let keyName = parts.last else { return nil }
        guard let code = keycode(for: keyName) else { return nil }
        return (code, mods)
    }

    private func keycode(for name: String) -> Int? {
        let table: [String: Int] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
            "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
            "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
            "equal": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "minus": 0x1B, "8": 0x1C, "0": 0x1D,
            "]": 0x1E, "bracketright": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "bracketleft": 0x21,
            "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "quote": 0x27, "k": 0x28,
            ";": 0x29, "semicolon": 0x29, "\\": 0x2A, "backslash": 0x2A, ",": 0x2B, "comma": 0x2B,
            "/": 0x2C, "slash": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "period": 0x2F,
            "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33,
            "backspace": 0x33, "escape": 0x35, "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E
        ]
        return table[name]
    }
}
