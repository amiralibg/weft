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
    /// The user brought an application forward.
    ///
    /// Not the same event as `windowFocused`, and not covered by it. An app's
    /// `AXFocusedWindow` does not change when the app is merely activated —
    /// the window it names was already its focused one — so clicking on
    /// another app's window produces no AX focus notification at all. That is
    /// every click that switches app, and with two displays it is most clicks
    /// on the other monitor: weft went on believing focus was where it left
    /// it, resolved "the current space" against the display the user had
    /// left, and pushed focus back there on the next sweep.
    case appActivated(pid: Int32)
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
        /// A keybind or gesture asked for something and weft could not do
        /// it. `title` is the command, `message` why.
        case commandFailed
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
    /// `stateChanged`: the workspace showing on the focused display.
    ///
    /// Part of the snapshot so that switching between two empty workspaces is
    /// a change. With only the focused window and the window list in it, the
    /// two snapshots were identical, the bus dropped the second as a repeat,
    /// and WeftBar stayed on the first — every switch past one empty
    /// workspace looked like it had done nothing.
    public var workspace: String?
    /// `stateChanged`: the workspace showing on each display, in display
    /// order, so a change on the other display is a change too.
    public var showing: [String]?
    /// `commandFailed`: why, in words meant for the user.
    public var message: String?

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
        workspace: String? = nil,
        showing: [String]? = nil,
        message: String? = nil
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
        self.workspace = workspace
        self.showing = showing
        self.message = message
    }
}
