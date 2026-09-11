// WeftCore/Events.swift — event vocabulary (§10.1).
//
// Two directions, both pure + Sendable:
//   ObserverEvent  platform → daemon core queue (window/app/space/display changes)
//   DaemonEvent    daemon → bus → `weftctl subscribe` / sketchybar bridge (M6.5)
//
// DaemonEvent is a flat struct (not an enum with payloads) so the JSON wire
// format stays stable for future clients: one `kind`, optional fields.

public enum ObserverEvent: Sendable, Equatable {
    /// `wid` is the new window when the notification could name it. It usually
    /// can, and knowing which window to wait for is what lets the daemon stop
    /// sweeping the moment that window lands rather than on a fixed timer.
    case windowCreated(pid: Int32, wid: WindowID?)
    case windowDestroyed(WindowID)
    case windowMoved(WindowID)
    case windowResized(WindowID)
    case windowFocused(WindowID?)
    case appLaunched(pid: Int32, bundleID: String)
    case appTerminated(pid: Int32, bundleID: String)
    case spaceChanged
    case displayChanged
}

public struct DaemonEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case windowCreated
        case windowDestroyed
        case windowFocused
        case spaceChanged
        case appLaunched
        case appTerminated
        case displayChanged
        case stateChanged
        case modeChanged
        case layoutChanged
        case stackChanged
    }

    public var kind: Kind
    public var window: WindowID?
    public var space: SpaceID?
    public var app: String?
    public var focus: WindowID?
    public var windows: [WindowID]?
    public var mode: String?
    public var layout: String?
    public var title: String?
    public var stackIndex: Int?
    public var stackCount: Int?

    public init(
        kind: Kind,
        window: WindowID? = nil,
        space: SpaceID? = nil,
        app: String? = nil,
        focus: WindowID? = nil,
        windows: [WindowID]? = nil,
        mode: String? = nil,
        layout: String? = nil,
        title: String? = nil,
        stackIndex: Int? = nil,
        stackCount: Int? = nil
    ) {
        self.kind = kind
        self.window = window
        self.space = space
        self.app = app
        self.focus = focus
        self.windows = windows
        self.mode = mode
        self.layout = layout
        self.title = title
        self.stackIndex = stackIndex
        self.stackCount = stackCount
    }
}
