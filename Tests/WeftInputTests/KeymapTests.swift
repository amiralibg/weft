import CoreGraphics
import Testing
@testable import WeftInput

@Test func chordLetters() throws {
    let chord = try parseChord("alt-h")
    #expect(chord.mods == CGEventFlags.maskAlternate.rawValue)
    #expect(chord.keycode == 4)  // ANSI H position
}

@Test func chordMultiModifier() throws {
    let chord = try parseChord("alt-shift-h")
    #expect(chord.mods == CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue)
    #expect(chord.keycode == 4)
}

@Test func chordNamedKeys() throws {
    #expect(try parseChord("alt-bracketleft").keycode == 33)
    #expect(try parseChord("alt-bracketright").keycode == 30)
    #expect(try parseChord("escape").mods == 0)
    #expect(try parseChord("escape").keycode == 53)
    #expect(try parseChord("alt-v").keycode == 9)
}

@Test func chordRejectsGarbage() {
    #expect(throws: ChordParseError.self) { try parseChord("alt-hyper-h") }
    #expect(throws: ChordParseError.self) { try parseChord("alt-f19") }
    #expect(throws: ChordParseError.self) { try parseChord("") }
}

@Test func modeResolution() {
    #expect(KeyAction.resolve("mode resize") == .mode("resize"))
    #expect(KeyAction.resolve("mode default") == .mode("default"))
    #expect(KeyAction.resolve("focus west") == .send("focus west"))
    #expect(KeyAction.resolve("resize right 60") == .send("resize right 60"))
}

@Test func defaultKeymapSpaces() throws {    let map = Keymap.default
    func action(_ mode: String, _ chord: String) throws -> KeyAction? {
        map.modes[mode]?[try parseChord(chord)]
    }
    #expect(try action("default", "alt-1") == .send("space focus 1"))
    #expect(try action("default", "alt-9") == .send("space focus 9"))
    #expect(try action("default", "alt-shift-1") == .send("space move-window 1"))
    #expect(try action("default", "alt-shift-9") == .send("space move-window 9"))
}

@Test func defaultKeymapStacks() throws {
    let map = Keymap.default
    func action(_ mode: String, _ chord: String) throws -> KeyAction? {
        map.modes[mode]?[try parseChord(chord)]
    }
    #expect(try action("default", "alt-s") == .send("stack toggle"))
    #expect(try action("default", "alt-shift-s") == .send("stack split east"))
    #expect(try action("default", "alt-bracketleft") == .send("stack prev"))
    #expect(try action("default", "alt-bracketright") == .send("stack next"))
    #expect(try action("default", "alt-u") == .send("stack unstack"))
}

@Test func defaultKeymapCoversM2() throws {
    let map = Keymap.default
    func action(_ mode: String, _ chord: String) throws -> KeyAction? {
        map.modes[mode]?[try parseChord(chord)]
    }
    // Focus + warp in every direction.
    #expect(try action("default", "alt-h") == .send("focus west"))
    #expect(try action("default", "alt-l") == .send("focus east"))
    #expect(try action("default", "alt-shift-k") == .send("move north"))
    #expect(try action("default", "alt-shift-j") == .send("move south"))
    // Split / balance / resize entry.
    #expect(try action("default", "alt-v") == .send("split vertical"))
    #expect(try action("default", "alt-shift-v") == .send("split horizontal"))
    #expect(try action("default", "alt-b") == .send("balance"))
    #expect(try action("default", "alt-shift-r") == .mode("resize"))
    // Resize layer is vim-consistent and exits cleanly.
    #expect(try action("resize", "h") == .send("resize left 60"))
    #expect(try action("resize", "l") == .send("resize right 60"))
    #expect(try action("resize", "shift-l") == .send("resize right 120"))
    #expect(try action("resize", "escape") == .mode("default"))
    // Exact-modifier discipline: alt-h must NOT match alt-shift-h.
    #expect(try parseChord("alt-h") != parseChord("alt-shift-h"))
}

@Test func defaultKeymapScroll() throws {
    let map = Keymap.default
    func action(_ mode: String, _ chord: String) throws -> KeyAction? {
        map.modes[mode]?[try parseChord(chord)]
    }
    #expect(try action("default", "alt-shift-bracketleft") == .send("scroll focus prev-column"))
    #expect(try action("default", "alt-shift-bracketright") == .send("scroll focus next-column"))
    #expect(try action("default", "alt-r") == .send("scroll width cycle"))
}

@Test func mouseGestureAndModifier() {
    let input = InputManager()
    input.updateMouseModifier("alt")
    var received: MouseGesture?
    input.onMouseGesture = { gesture in
        received = gesture
    }
    input.onMouseGesture?(.down(button: .left, location: CGPoint(x: 100, y: 150)))
    #expect(received == .down(button: .left, location: CGPoint(x: 100, y: 150)))
    input.onMouseGesture?(.drag(button: .left, location: CGPoint(x: 120, y: 170)))
    #expect(received == .drag(button: .left, location: CGPoint(x: 120, y: 170)))
    input.onMouseGesture?(.up(button: .left, location: CGPoint(x: 120, y: 170)))
    #expect(received == .up(button: .left, location: CGPoint(x: 120, y: 170)))
}
