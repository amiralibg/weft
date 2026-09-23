// WeftIPC/Status.swift — the shapes `query spaces` and `query bar-state` put
// on the socket.
//
// In a library rather than inside weftd for the same reason WeftBarConfig is:
// an executable target cannot have tests, and this is code other programs
// parse. weft-bar decodes it on every menu refresh and weftctl's doctor reads
// it, so a field that changes name or meaning breaks them silently — JSON
// decoding does not complain about a number that is the wrong number.

import WeftCore

/// One native desktop, as the wire describes it.
///
/// **`id` is the DESKTOP's space id and never a workspace's.** weft-bar
/// decodes it as a `UInt64` and hands it straight back to `space focus`, so a
/// workspace id here would deserialise perfectly and name a different desktop,
/// with nothing anywhere to notice. `WorkspaceID` is deliberately not Codable
/// so that putting one here is a build error, and `of(desktop:in:…)` below is
/// the only thing that fills this in.
public struct SpaceStatus: Codable, Sendable, Equatable {
    public var id: SpaceID
    public var label: String
    public var layout: String
    public var windows: [WindowID]
    public var current: Bool
    public var display: String

    public init(
        id: SpaceID,
        label: String,
        layout: String,
        windows: [WindowID],
        current: Bool,
        display: String
    ) {
        self.id = id
        self.label = label
        self.layout = layout
        self.windows = windows
        self.current = current
        self.display = display
    }
}

extension SpaceStatus {
    /// The wire's view of one desktop: whatever workspace is showing on it.
    ///
    /// A desktop weft has not swept yet has no workspace and so no layout, and
    /// reports the kind it *would* get — the `[[space]] layout` declaration for
    /// its label, else the general default. `fallbackWindows` is what the
    /// WindowServer says is there, used when weft has no membership of its own
    /// to report.
    public static func of(
        desktop sid: SpaceID,
        in sp: SpaceState,
        display: String,
        current: Bool,
        declaredLayout: (String) -> LayoutKind?,
        defaultLayout: LayoutKind,
        fallbackWindows: [WindowID] = []
    ) -> SpaceStatus {
        let ws = sp.workspace(on: sid)
        let label = ws?.label ?? "\(sid)"
        let layout = ws?.layout.kind
            ?? ws?.overrideKind
            ?? declaredLayout(label)
            ?? defaultLayout
        return SpaceStatus(
            id: sid,
            label: label,
            layout: layout.rawValue,
            windows: ws?.members.sorted() ?? fallbackWindows,
            current: current,
            display: display
        )
    }
}

/// One window, as the menu bar needs it. `spaces` lists the desktops weft has
/// it filed under, so it is space ids here too.
public struct BarWindowStatus: Codable, Sendable, Equatable {
    public var id: WindowID
    public var app: String
    public var title: String
    public var pid: Int32
    public var spaces: [SpaceID]

    public init(id: WindowID, app: String, title: String, pid: Int32, spaces: [SpaceID]) {
        self.id = id
        self.app = app
        self.title = title
        self.pid = pid
        self.spaces = spaces
    }
}

/// `query bar-state`: everything the menu bar redraws from, in one answer.
public struct BarStateStatus: Codable, Sendable, Equatable {
    public var spaces: [SpaceStatus]
    public var windows: [BarWindowStatus]

    public init(spaces: [SpaceStatus], windows: [BarWindowStatus]) {
        self.spaces = spaces
        self.windows = windows
    }
}

/// `query windows`: a WindowInfo plus weft's verdict on it. `floating` is nil
/// for a window in a layout, and otherwise names why it is not — "manual"
/// (the user floated it), "popup" (not a tileable window), "quirk" (refused
/// its frame twice), "rule" (a `manage = false` rule matched).
///
/// `spaces` is desktop ids, like everything else out here.
public struct WindowStatus: Codable, Sendable, Equatable {
    public var id: WindowID
    public var app: String
    public var title: String
    public var pid: Int32
    public var spaces: [SpaceID]
    public var frame: Frame
    public var bound: Bool
    public var floating: String?

    public init(
        id: WindowID,
        app: String,
        title: String,
        pid: Int32,
        spaces: [SpaceID],
        frame: Frame,
        bound: Bool,
        floating: String? = nil
    ) {
        self.id = id
        self.app = app
        self.title = title
        self.pid = pid
        self.spaces = spaces
        self.frame = frame
        self.bound = bound
        self.floating = floating
    }
}

/// `query workspaces`: which model the running daemon is actually in.
///
/// The file is not the answer. weftd rebuilds its workspace set when
/// `workspaces` or `workspace-anchor` changes, but a reload that has not
/// landed yet — or a daemon that has not been restarted — leaves the two
/// disagreeing, and both the Settings window and `doctor` have to be able to
/// say which one the user is looking at.
///
/// `anchor` is the desktop actually hosting the workspaces, which is not
/// necessarily `requestedAnchor`: `adoptDesktops` clamps an anchor that names
/// no desktop, because a sweep has to produce a usable state whatever the file
/// says. The two fields differing is the only evidence that happened.
public struct WorkspacesStatus: Codable, Sendable, Equatable {
    /// `native` or `virtual` — the mode the daemon is running, not the file's.
    public var mode: String
    /// Mission Control ordinal of the desktop hosting virtual workspaces.
    /// Meaningless under `native`, where every desktop hosts its own.
    public var anchor: Int
    /// What `workspace-anchor` asked for. Differs from `anchor` when it named
    /// a desktop that does not exist.
    public var requestedAnchor: Int
    /// Live native desktops, i.e. what Mission Control shows.
    public var desktops: Int
    /// Live workspaces. Equals `desktops` under `native`.
    public var workspaces: Int

    public init(
        mode: String,
        anchor: Int,
        requestedAnchor: Int,
        desktops: Int,
        workspaces: Int
    ) {
        self.mode = mode
        self.anchor = anchor
        self.requestedAnchor = requestedAnchor
        self.desktops = desktops
        self.workspaces = workspaces
    }

    /// Whether the anchor the daemon used is not the one that was asked for.
    public var anchorClamped: Bool { mode == "virtual" && anchor != requestedAnchor }
}
