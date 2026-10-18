// WeftCore/Fullscreen.swift — native-fullscreen exits, as a pure decision
// (REDESIGN.md, "Fullscreen and macOS's own window features").
//
// The world skips fullscreen and Split View spaces (§11 risk 6), so a window
// that goes fullscreen drops out of every sweep until it leaves. What the
// sweeps see is only a disappearance and an reappearance; the interesting
// decisions live in the angles:
//
// - entering: which workspace was it a member of, and what did its tiling
//   tree look like — the only memory that can put every other window of that
//   workspace back in its exact slot afterwards, not only near it.
// - exiting: into the workspace it came from, at that slot, instead of
//   wherever a `[[rule]] space` would carry it to. Rules place windows when
//   they *open*; a fullscreen exit is the user's own act, and was their
//   workspace again. When that workspace is hidden, the exit brought the
//   user there, so the plan says to show it.

/// Where a window was before it went native fullscreen. Daemon state; this
/// type only carries it between the sweep and the decision.
public struct FullscreenMemo: Sendable, Equatable {
    /// The workspace the window was a member of.
    public var workspace: WorkspaceID
    /// The workspace's whole tiling tree at the moment the window entered
    /// fullscreen, with the window still in it. Nil when the window was not
    /// laid out there — a float workspace, a loose member, or a window weft
    /// had no record of because it opened straight into fullscreen. Restore
    /// then means "the right workspace"; its layout is the next sweep's to
    /// decide as usual.
    public var tree: Tree?

    public init(workspace: WorkspaceID, tree: Tree? = nil) {
        self.workspace = workspace
        self.tree = tree
    }
}

/// What a sweep does for a window whose memo is open, once the world is read.
public enum FullscreenSettle: Sendable, Equatable {
    /// Still on a fullscreen space: nothing yet, the memo keeps.
    case fullscreen
    /// The memo's workspace is gone (its desktop was deleted, its display
    /// unplugged while it was fullscreen): the memo drops and the sweep
    /// treats the window like any first sighting — a rule still owes it its
    /// one move.
    case forget
    /// The window is a member of its old workspace again. The tree, when
    /// carried, didn't change its members while the window was away, so the
    /// remembered subtree replaces the reflowed one and the arrangement
    /// restarts as it was. Nil keeps the slot the sweep just gave it — the
    /// right place with the wrong geometry is still the right place.
    case home(Tree?)
    /// The window exited to some other desktop (auto-arrange, a drag in
    /// Mission Control): one bridged move home. `follow` shows the workspace
    /// when it is hidden, because leaving fullscreen was the user's act.
    case move(follow: Bool)
}

/// The memo to open when `wid` first shows up on a fullscreen space. The
/// state is what the daemon still believed about the world — one sweep stale,
/// which is exactly the rubble before the reflow.
public func fullscreenMemo(_ state: SpaceState, of wid: WindowID) -> FullscreenMemo? {
    guard let id = state.workspace(holding: wid), let ws = state.workspaces[id] else { return nil }
    if case .tiling(let t) = ws.layout, t.windows.contains(wid) {
        return FullscreenMemo(workspace: id, tree: t)
    }
    return FullscreenMemo(workspace: id, tree: nil)
}

/// The settle for a window with an open memo, against `state` as this sweep
/// left it (the membership sync has already run).
public func fullscreenSettle(
    stillFullscreen: Bool,
    memo: FullscreenMemo,
    state: SpaceState,
    of wid: WindowID
) -> FullscreenSettle {
    if stillFullscreen { return .fullscreen }
    guard let ws = state.workspaces[memo.workspace] else { return .forget }
    if !ws.contains(wid) {
        return .move(follow: state.showingDisplay(of: memo.workspace) == nil)
    }
    // Exact restore demands that nothing joined or left while the window was
    // fullscreen: the members must match the remembered tree, window for
    // window. The paused workspace cannot be commanded or dragged on, so the
    // common case — watch a movie, exit — always qualifies.
    if case .tiling(let now) = ws.layout, let snapshot = memo.tree,
       Set(snapshot.windows) == Set(now.windows) {
        return .home(snapshot)
    }
    return .home(nil)
}
