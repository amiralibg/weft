// WeftCore/Events.swift — event vocabulary (§10.1).
//
// Two directions, both pure + Sendable:
//   ObserverEvent  platform → daemon core queue (window/app/space/display changes)
//   DaemonEvent    daemon → bus → `weftctl subscribe` / sketchybar bridge (M6.5)
//
// DaemonEvent is a flat struct (not an enum with payloads) so the JSON wire
// format stays stable for future clients: one `kind`, optional fields.

public enum ObserverEvent: Sendable, Equatable {
    case windowCreated(pid: Int32)
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
        case scrollChanged
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
    public var scrollCol: Int?
    public var scrollCols: Int?

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
        stackCount: Int? = nil,
        scrollCol: Int? = nil,
        scrollCols: Int? = nil
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
        self.scrollCol = scrollCol
        self.scrollCols = scrollCols
    }
}
