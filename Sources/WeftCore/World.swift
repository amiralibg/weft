// WeftCore — pure world model. No I/O, no AppKit, no SkyLight, no AX.
//
// Everything here is a value type, Sendable + Codable, unit-testable with no
// display attached. The platform layer builds a World; the layout engine (M2+)
// will consume it as `(World, Config) -> [WindowID: Frame]`.

public typealias WindowID = UInt32
public typealias SpaceID = UInt64

/// Display-agnostic rectangle. Doubles so JSON output is stable across archs.
public struct Frame: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = Frame(x: 0, y: 0, width: 0, height: 0)

    public func contains(x: Double, y: Double) -> Bool {
        x >= self.x && x < self.x + self.width && y >= self.y && y < self.y + self.height
    }
}

public struct Display: Codable, Sendable, Equatable {
    /// Stable across disconnect/reconnect (CGDisplayCreateUUIDFromDisplayID).
    public var uuid: String
    public var spaces: [SpaceID]
    public var currentSpace: SpaceID

    public init(uuid: String, spaces: [SpaceID], currentSpace: SpaceID) {
        self.uuid = uuid
        self.spaces = spaces
        self.currentSpace = currentSpace
    }
}

public struct Space: Codable, Sendable, Equatable {
    public var id: SpaceID
    /// From SLSSpaceGetType. 4 = native fullscreen → skip entirely (§11 risk 6).
    public var type: Int32
    public var displayUUID: String
    public var isCurrent: Bool
    /// Window ids reported by SLSCopyManagedDisplaySpaces for this space.
    public var windows: [WindowID]

    public init(id: SpaceID, type: Int32, displayUUID: String, isCurrent: Bool, windows: [WindowID]) {
        self.id = id
        self.type = type
        self.displayUUID = displayUUID
        self.isCurrent = isCurrent
        self.windows = windows
    }

    public var isFullscreen: Bool { type == 4 }
}

public struct WindowInfo: Codable, Sendable, Equatable {
    public var id: WindowID
    public var app: String
    public var title: String
    public var pid: Int32
    public var spaces: [SpaceID]
    public var frame: Frame
    /// S0 cold-start gap: WindowServer knows the window but no AX element has
    /// been captured yet (space never visited since launch). Layout can be
    /// *computed* but not *applied* until first space_changed.
    public var bound: Bool

    public init(
        id: WindowID, app: String, title: String, pid: Int32,
        spaces: [SpaceID], frame: Frame, bound: Bool
    ) {
        self.id = id
        self.app = app
        self.title = title
        self.pid = pid
        self.spaces = spaces
        self.frame = frame
        self.bound = bound
    }
}

public struct World: Codable, Sendable, Equatable {
    public var displays: [Display]
    public var spaces: [Space]
    public var windows: [WindowInfo]

    public init(displays: [Display], spaces: [Space], windows: [WindowInfo]) {
        self.displays = displays
        self.spaces = spaces
        self.windows = windows
    }
}
