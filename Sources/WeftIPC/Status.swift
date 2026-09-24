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
    /// Every workspace, in the order `space focus N` counts, as the socket
    /// reports it to `query spaces` and `query bar-state`.
    ///
    /// `id` is the managed desktop the workspace lives on — what weft-bar and
    /// weftctl have always decoded, as `UInt64` — so several workspaces on one
    /// desktop share it; they are told apart by `label`. `current` means
    /// showing on its display right now. A workspace holding nothing reports
    /// the kind it *would* get: its override, else its `[[space]] layout`,
    /// else the default — an empty tree's kind is `bsp`, which told Settings
    /// `bsp` for a workspace the file declares `float`.
    public static func workspaces(
        in sp: SpaceState,
        declaredLayout: (String) -> LayoutKind?,
        defaultLayout: LayoutKind
    ) -> [SpaceStatus] {
        sp.wsOrder.compactMap { wsid -> SpaceStatus? in
            guard let ws = sp.workspaces[wsid], let display = sp.displayBySpace[ws.desktop] else {
                return nil
            }
            let label = ws.label.isEmpty ? "\(wsid.raw)" : ws.label
            let layout = ws.layout.windows.isEmpty
                ? (ws.overrideKind ?? declaredLayout(label) ?? defaultLayout)
                : ws.layout.kind
            return SpaceStatus(
                id: ws.desktop,
                label: label,
                layout: layout.rawValue,
                windows: ws.members.sorted(),
                current: sp.showingDisplay(of: wsid) != nil,
                display: display
            )
        }
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

/// `query workspaces`: how weft's workspaces sit on this Mac's displays, from
/// the daemon's point of view. Settings draws its display picture from this
/// and `weftctl doctor` reports it.
public struct WorkspacesStatus: Codable, Sendable, Equatable {
    public struct Display: Codable, Sendable, Equatable {
        public var uuid: String
        /// 1-based, west to east — what `focus display N` counts.
        public var index: Int
        /// Which of this display's macOS desktops weft manages, 1-based in
        /// Mission Control order. Nil when it could not be placed.
        public var managedDesktop: Int?
        /// How many macOS desktops this display has. More than one is fine;
        /// weft pauses on the others.
        public var desktops: Int
        /// Showing another desktop or a fullscreen app right now.
        public var paused: Bool
        /// Label of the workspace this display shows (or would, once back).
        public var showing: String?

        public init(
            uuid: String, index: Int, managedDesktop: Int?, desktops: Int,
            paused: Bool, showing: String?
        ) {
            self.uuid = uuid
            self.index = index
            self.managedDesktop = managedDesktop
            self.desktops = desktops
            self.paused = paused
            self.showing = showing
        }
    }

    /// How many workspaces exist.
    public var workspaces: Int
    public var displays: [Display]

    public init(workspaces: Int, displays: [Display]) {
        self.workspaces = workspaces
        self.displays = displays
    }

    /// Displays with desktops weft pauses on.
    public var displaysWithExtraDesktops: [Display] { displays.filter { $0.desktops > 1 } }
}
