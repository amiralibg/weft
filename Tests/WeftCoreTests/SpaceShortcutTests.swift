import Foundation
import Testing

@testable import WeftCore

/// Shaped like the real `AppleSymbolicHotKeys` entries, which nest the key
/// under value.parameters as (ascii, key code, modifier mask).
private func entry(enabled: Bool, ascii: Int, keyCode: Int, modifiers: Int) -> [String: Any] {
    [
        "enabled": enabled,
        "value": ["parameters": [ascii as NSNumber, keyCode as NSNumber, modifiers as NSNumber]],
    ]
}

@Test func anAbsentEntryMeansTheShippedDefault() {
    // Unlike "Switch to Desktop N", move-left/right ship enabled, so a Mac
    // nobody has touched has no entry at all and still has the shortcut.
    let (left, right) = SpaceShortcuts.read(from: [:])
    #expect(left == SpaceShortcuts.defaultLeft)
    #expect(right == SpaceShortcuts.defaultRight)
    #expect(right?.keyCode == 124)
    #expect(right?.modifiers == 0x4_0000)
}

@Test func aRemappedShortcutIsReadRatherThanAssumed() {
    // ⌘⌥H / ⌘⌥L — the binding on the machine this was developed against, and
    // the reason a hardcoded ⌃→ moved nothing.
    let hotkeys: [String: Any] = [
        "79": entry(enabled: true, ascii: 104, keyCode: 4, modifiers: 0x18_0000),
        "81": entry(enabled: true, ascii: 108, keyCode: 37, modifiers: 0x18_0000),
    ]
    let (left, right) = SpaceShortcuts.read(from: hotkeys)
    #expect(left == SpaceShortcut(keyCode: 4, modifiers: 0x18_0000))
    #expect(right == SpaceShortcut(keyCode: 37, modifiers: 0x18_0000))
}

@Test func aDisabledShortcutIsNotAKeystrokeWeftCanSend() {
    let hotkeys: [String: Any] = [
        "81": entry(enabled: false, ascii: 108, keyCode: 37, modifiers: 0x18_0000)
    ]
    #expect(SpaceShortcuts.read(from: hotkeys).right == nil)
}

@Test func anEntryWithNoKeyBoundIsNotUsable() {
    // 65535 is what macOS writes for "no key", and pressing it would be a
    // keystroke that silently reaches nothing — the failure this check exists
    // to turn into an honest error.
    let hotkeys: [String: Any] = [
        "81": entry(enabled: true, ascii: 65535, keyCode: 65535, modifiers: 0x4_0000)
    ]
    #expect(SpaceShortcuts.read(from: hotkeys).right == nil)
}

@Test func stepsCountsInBothDirections() {
    let list: [SpaceID] = [4, 5, 6, 7, 8]
    #expect(SpaceShortcuts.steps(from: 5, to: 7, in: list) == 2)
    #expect(SpaceShortcuts.steps(from: 7, to: 5, in: list) == -2)
    #expect(SpaceShortcuts.steps(from: 5, to: 5, in: list) == 0)
}

@Test func stepsRefusesADesktopThatIsNotOnThisDisplay() {
    #expect(SpaceShortcuts.steps(from: 5, to: 99, in: [4, 5, 6]) == nil)
    #expect(SpaceShortcuts.steps(from: 99, to: 5, in: [4, 5, 6]) == nil)
}

@Test func stepsCountsFullscreenSpacesItPassesThrough() {
    // The shortcut steps through a fullscreen space like any other, so the
    // count comes from the display's full list. Counting only ordinary
    // desktops would stop one short for every fullscreen app in between.
    let withFullscreen: [SpaceID] = [4, 99, 5]
    #expect(SpaceShortcuts.steps(from: 4, to: 5, in: withFullscreen) == 2)
}
