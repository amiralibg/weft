import Testing
@testable import WeftCore

// Which display a name means (`focus display`, Settings), and where 0.9.21's
// parked windows sat. weft no longer parks; the startup unpark reads the
// ledger, and `parkOrigin` is what that ledger's corners mean.

private let laptop = Frame(x: 0, y: 0, width: 1728, height: 1117)

@Test func parkingAtATopLeftCornerLeavesOnePointOnScreen() {
    let o = parkOrigin(width: 800, height: 600, corner: .topLeft, in: laptop)
    #expect(o.x + 800 - 1 == laptop.x && o.y + 600 - 1 == laptop.y)
}

// MARK: - Pins

private let displays = [
    DisplayIdentity(uuid: "L", name: "Built-in Retina Display", isMain: false),
    DisplayIdentity(uuid: "S", name: "Studio Display", isMain: true),
    DisplayIdentity(uuid: "R", name: "LG UltraFine", isMain: false),
]

@Test func pinsResolveByRoleNumberAndName() {
    #expect(resolvePin(DisplayPin("main"), among: displays) == "S")
    #expect(resolvePin(DisplayPin("secondary"), among: displays) == "L")
    #expect(resolvePin(DisplayPin("3"), among: displays) == "R")
    #expect(resolvePin(DisplayPin("studio"), among: displays) == "S")
    #expect(resolvePin(DisplayPin("built-in"), among: displays) == "L")
    // Not connected: nil, and the workspace behaves as unpinned.
    #expect(resolvePin(DisplayPin("4"), among: displays) == nil)
    #expect(resolvePin(DisplayPin("Dell"), among: displays) == nil)
}

/// A laptop with its lid open under a monitor that has the menu bar: "main"
/// is the monitor, and "built-in" and "external" name the displays by what
/// they are. "external" used to mean "not main", which on this arrangement
/// is the laptop.
@Test func builtInAndExternalNameTheDisplayNotItsRole() {
    let desk = [
        DisplayIdentity(uuid: "M", name: "SAMSUNG", isMain: true),
        DisplayIdentity(uuid: "L", name: "Built-in Retina Display", isMain: false, isBuiltIn: true),
    ]
    #expect(resolvePin(DisplayPin("main"), among: desk) == "M")
    #expect(resolvePin(DisplayPin("built-in"), among: desk) == "L")
    #expect(resolvePin(DisplayPin("external"), among: desk) == "M")
    #expect(resolvePin(DisplayPin("secondary"), among: desk) == "L")
}

/// Asked of the display, so a built-in screen whose name was not read (or is
/// localized) still resolves.
@Test func builtInDoesNotNeedTheName() {
    let ids = [
        DisplayIdentity(uuid: "E", name: "", isMain: false),
        DisplayIdentity(uuid: "L", name: "", isMain: true, isBuiltIn: true),
    ]
    #expect(resolvePin(DisplayPin("built-in"), among: ids) == "L")
    #expect(resolvePin(DisplayPin("external"), among: ids) == "E")
}

/// A Mac with no screen of its own: "external" is the first that is not main.
@Test func externalOnADesktopMacIsTheOneWithoutTheMenuBar() {
    let ids = [
        DisplayIdentity(uuid: "A", name: "Dell", isMain: true),
        DisplayIdentity(uuid: "B", name: "LG", isMain: false),
    ]
    #expect(resolvePin(DisplayPin("external"), among: ids) == "B")
    #expect(resolvePin(DisplayPin("built-in"), among: ids) == nil)
}

@Test func displaysAreTitledByNameNumberedWhenTwoShareOne() {
    let displays = [
        DisplayIdentity(uuid: "A", name: "Built-in Retina Display", isMain: true, isBuiltIn: true),
        DisplayIdentity(uuid: "B", name: "DELL U2720Q", isMain: false),
        DisplayIdentity(uuid: "C", name: "DELL U2720Q", isMain: false),
    ]
    #expect(DisplayIdentity.titles(for: ["A", "B", "C"], among: displays)
        == ["Built-in Retina Display", "DELL U2720Q 1", "DELL U2720Q 2"])
    // Not connected, or nameless: its place in the list.
    #expect(DisplayIdentity.titles(for: ["A", "Z"], among: displays) == ["Built-in Retina Display", "Display 2"])
}

/// A second display's menu bar comes off its tiling area; the main one's,
/// already off, does not come off twice; another display's bar is not this
/// one's.
@Test func menuBarsComeOffTheTopOfTheirOwnDisplay() {
    let samsung = Frame(x: -1063, y: -2160, width: 3840, height: 2160)
    let laptop = Frame(x: 0, y: 0, width: 1710, height: 1112)
    let bars = [
        Frame(x: -1063, y: -2160, width: 3840, height: 30),
        Frame(x: 0, y: 0, width: 1710, height: 38),
    ]
    #expect(belowMenuBars(samsung, display: samsung, menuBars: bars)
        == Frame(x: -1063, y: -2130, width: 3840, height: 2130))
    let laptopVisible = Frame(x: 0, y: 38, width: 1710, height: 1074)
    #expect(belowMenuBars(laptopVisible, display: laptop, menuBars: bars) == laptopVisible)
    // Menu bar hidden: nothing to take off.
    #expect(belowMenuBars(samsung, display: samsung, menuBars: []) == samsung)
}

/// Positions come from CoreGraphics and only the insets from AppKit, so a
/// display that moved since AppKit last looked still tiles where it is.
@Test func usableAreaPlacesAppKitInsetsOnLiveBounds() {
    // AppKit, bottom-left: the laptop with a 38pt menu bar and a 60pt Dock.
    let frame = Frame(x: 0, y: 0, width: 1710, height: 1112)
    let visible = Frame(x: 0, y: 60, width: 1710, height: 1014)
    let here = Frame(x: 0, y: 0, width: 1710, height: 1112)
    #expect(usableArea(bounds: here, screenFrame: frame, screenVisible: visible)
        == Frame(x: 0, y: 38, width: 1710, height: 1014))
    // The same laptop after the arrangement changed under a stale NSScreen.
    let moved = Frame(x: 3840, y: 1048, width: 1710, height: 1112)
    #expect(usableArea(bounds: moved, screenFrame: frame, screenVisible: visible)
        == Frame(x: 3840, y: 1086, width: 1710, height: 1014))
}

/// A display AppKit has not seen, or one whose resolution changed since, is
/// taken whole; the menu bar comes off it in `belowMenuBars`.
@Test func usableAreaIgnoresAScreenOfAnotherSize() {
    let bounds = Frame(x: -1049, y: -2160, width: 3840, height: 2160)
    #expect(usableArea(bounds: bounds, screenFrame: nil, screenVisible: nil) == bounds)
    let old = Frame(x: 0, y: 0, width: 2560, height: 1440)
    let oldVisible = Frame(x: 0, y: 0, width: 2560, height: 1415)
    #expect(usableArea(bounds: bounds, screenFrame: old, screenVisible: oldVisible) == bounds)
}
