// WeftCore/NativeRoutes.swift — the private routes weft drives native desktops
// with, what each one's self-test found on this macOS build, and the verdicts
// that decide whether one call through them did what it was asked.
//
// The bridged move and switch return nothing that can be believed (S8, S10,
// S11), so every call is judged here, from what the WindowServer reads back
// afterwards — and these judgements are pure, so they are tested without a
// WindowServer (docs/NATIVE.md, "Testing Decisions").

/// One private route (docs/NATIVE.md, "Self-tests and degradation").
public enum NativeRoute: String, CaseIterable, Codable, Sendable {
    /// SkyLight's two bridged perform functions, found by walking its symbol
    /// table, and the operation classes weft builds.
    case symbols = "symbol-walk"
    /// Moving any window to any desktop.
    case move = "bridged-move"
    /// Show + Hide + SetCurrent: switching a display's desktop in one step.
    case switchDesktop = "bridged-switch"
    /// A synthetic Dock swipe, one desktop per step: the switch fallback.
    case dockSwipe = "dock-swipe"

    /// What weft cannot do when this route fails, for `weftctl doctor`.
    public var lostWithout: String {
        switch self {
        case .symbols: "every bridged route: moving windows between desktops, and the instant switch"
        case .move: "space move-window, rules that place windows on a desktop, and weftctl spread"
        case .switchDesktop: "the instant switch; desktops switch by Dock swipe, one step at a time"
        case .dockSwipe: "switching from weft when the instant switch is off; use ⌃←/⌃→"
        }
    }
}

/// What one route's self-test found.
public struct RouteStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Tested on this macOS build and did what it should.
        case passed
        /// Tested and did not: weft does not use it.
        case failed
        /// Not tested yet, or could not be (one desktop, nothing to switch to).
        case untested
        /// Turned off on purpose (`WEFT_PUBLIC_ONLY`), or because a route it
        /// depends on failed.
        case off
    }

    public var state: State
    public var detail: String

    public init(_ state: State, _ detail: String) {
        self.state = state
        self.detail = detail
    }

    public var usable: Bool { state == .passed }
}

/// Every route's status on one macOS build.
public struct NativeRoutes: Codable, Sendable, Equatable {
    /// `kern.osversion`, e.g. "26A434": a result holds for this build only.
    public var macOSBuild: String
    public var routes: [String: RouteStatus]

    public init(macOSBuild: String, routes: [NativeRoute: RouteStatus] = [:]) {
        self.macOSBuild = macOSBuild
        self.routes = Dictionary(uniqueKeysWithValues: routes.map { ($0.key.rawValue, $0.value) })
    }

    public subscript(route: NativeRoute) -> RouteStatus {
        get { routes[route.rawValue] ?? RouteStatus(.untested, "not run") }
        set { routes[route.rawValue] = newValue }
    }

    /// How weft switches desktops given these results, best first.
    public var switchMethod: SwitchMethod {
        if self[.symbols].usable, self[.switchDesktop].usable { return .bridged }
        if self[.dockSwipe].usable { return .dockSwipe }
        return .none
    }

    public var canMove: Bool { self[.symbols].usable && self[.move].usable }
}

public enum SwitchMethod: String, Codable, Sendable {
    case bridged
    case dockSwipe = "dock-swipe"
    /// weft cannot switch desktops on this macOS.
    case none
}

// MARK: - Verdicts

/// Where the windows of one bridged move ended up.
public struct MoveVerdict: Sendable, Equatable {
    public var arrived: [WindowID]
    public var missing: [WindowID]

    public var complete: Bool { missing.isEmpty }

    public init(arrived: [WindowID], missing: [WindowID]) {
        self.arrived = arrived
        self.missing = missing
    }

    /// A window arrived when it reads back on exactly the target desktop.
    /// On the target and another one is not arrived: that is an all-desktops
    /// window, which weft never moves, or a move half done.
    public static func judge(_ windows: [WindowID], target: SpaceID, readBack: [WindowID: [SpaceID]]) -> MoveVerdict {
        var out = MoveVerdict(arrived: [], missing: [])
        for w in windows {
            if readBack[w] == [target] { out.arrived.append(w) } else { out.missing.append(w) }
        }
        return out
    }
}

/// Whether one switch of one display did what it was asked.
///
/// The display reading back the target is not enough: setting the current
/// desktop alone reads back perfectly and leaves the old desktop on the glass
/// (S11). So the windows are checked too — but only windows weft manages. A
/// desktop also holds windows that are never on screen, such as a menu-bar
/// app's ordered-out popover or the borders overlay (S12), and counting those
/// would fail a good switch.
public enum SwitchVerdict: Sendable, Equatable {
    case landed
    /// The display reads back another desktop.
    case notCurrent(showing: SpaceID)
    /// Managed windows of the target are not on screen.
    case targetNotShown([WindowID])
    /// Managed windows of the old desktop are still on screen.
    case oldStillShown([WindowID])

    public var landed: Bool { self == .landed }

    /// - Parameters:
    ///   - expectShown: managed windows on the target alone.
    ///   - expectHidden: managed windows on the old desktop alone (a window
    ///     on both is on every desktop and shows either way).
    ///   - onScreen: the public on-screen window list, after the switch.
    public static func judge(
        target: SpaceID, currentAfter: SpaceID,
        expectShown: [WindowID], expectHidden: [WindowID], onScreen: Set<WindowID>
    ) -> SwitchVerdict {
        guard currentAfter == target else { return .notCurrent(showing: currentAfter) }
        let notShown = expectShown.filter { !onScreen.contains($0) }
        if !notShown.isEmpty { return .targetNotShown(notShown) }
        let stillShown = expectHidden.filter { onScreen.contains($0) }
        if !stillShown.isEmpty { return .oldStillShown(stillShown) }
        return .landed
    }

    public var detail: String {
        switch self {
        case .landed: "landed"
        case .notCurrent(let s): "the display still shows desktop \(s)"
        case .targetNotShown(let w): "\(w.count) window(s) of the target not on screen"
        case .oldStillShown(let w): "\(w.count) window(s) of the old desktop still on screen"
        }
    }
}
