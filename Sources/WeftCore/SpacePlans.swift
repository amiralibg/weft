// WeftCore/SpacePlans.swift — what a desktop command does, decided from a
// snapshot and returned as effects (docs/NATIVE.md, "Testing Decisions").
//
// The daemon carries the effects out — a bridged switch, a bridged move, a
// re-tile, a focus — and verifies each on the Mac. Nothing here touches the
// Mac, so every decision about which desktop shows, where a window ends up and
// what a command answers is tested without one.

/// One thing a command does to the Mac.
public enum SpaceEffect: Sendable, Equatable {
    /// Switch `display` from the space it shows to desktop `to`.
    case switchDisplay(display: String, from: SpaceID, to: SpaceID)
    /// Keyboard focus moves to a display already showing what was asked
    /// for. Nothing switches.
    case focusDisplay(String)
    /// One bridged move of these windows to desktop `to`.
    case move([WindowID], to: SpaceID)
    /// Lay a desktop out again — showing or not (layout before show).
    case retile(SpaceID)
    /// Focus a window, or with nil the desktop itself (an empty desktop must
    /// not leave typing in a window elsewhere).
    case focus(WindowID?)
    /// Nothing to do; the answer says why.
    case nothing(String)
    /// The command cannot be done; the answer says why.
    case refuse(String)
}

extension SpaceState {
    /// The display "here" means: the one keyboard focus is on, else the first.
    public var hereDisplay: String? {
        if let d = focusedDisplay, currentByDisplay[d] != nil { return d }
        return displays.first
    }

    /// `space focus`: show a workspace, and focus `window` there or the window
    /// last used there.
    ///
    /// - Showing on the focused display: nothing (or just the window).
    /// - Showing on another display: focus moves there; nothing switches
    ///   (NATIVE.md, story 5).
    /// - Otherwise its display switches to it, from whatever it shows — a
    ///   fullscreen space included — in one step, at any distance.
    public func planFocus(_ id: WorkspaceID, window: WindowID? = nil) -> [SpaceEffect] {
        guard let ws = workspaces[id], let display = displayBySpace[ws.desktop] else {
            return [.refuse("that desktop no longer exists")]
        }
        let target = window ?? ws.focusTarget
        if let showing = showingDisplay(of: id) {
            if showing == hereDisplay {
                if let window, window != ws.focusTarget { return [.focus(window)] }
                return [.nothing("already on \(ws.label)")]
            }
            return [.focusDisplay(showing), .focus(target)]
        }
        let from = currentByDisplay[display] ?? ws.desktop
        return [.switchDisplay(display: display, from: from, to: ws.desktop), .focus(target)]
    }

    /// `space move-window`, a rule, or `move display`: send `wid`, which
    /// macOS reports on `desktops`, to workspace `id`.
    ///
    /// One bridged move, then both desktops are laid out again — the target
    /// even when it is not showing, so the window is in its tile on arrival.
    /// Following shows the target with the window focused; staying leaves
    /// focus on the desktop the user is on.
    public func planMoveWindow(
        _ wid: WindowID, on desktops: [SpaceID], to id: WorkspaceID, follow: Bool
    ) -> [SpaceEffect] {
        guard let ws = workspaces[id] else { return [.refuse("that desktop no longer exists")] }
        let ours = Set(desktops).filter { active[$0] != nil }
        if ours.count > 1 {
            return [.refuse(
                "window \(wid) is on every desktop (Dock › Options › All Desktops), so weft does not move it"
            )]
        }
        if desktops == [ws.desktop] {
            return follow ? planFocus(id, window: wid) : [.nothing("already on \(ws.label)")]
        }
        let source = ours.first
        var out: [SpaceEffect] = [.move([wid], to: ws.desktop)]
        if let source { out.append(.retile(source)) }
        out.append(.retile(ws.desktop))
        if follow {
            out += planFocus(id, window: wid)
        } else if let source, let left = workspace(on: source), showingDisplay(of: left.id) != nil {
            let rest = left.members.filter { $0 != wid }
            let next = [left.lastFocused, left.layout.focus].compactMap { $0 }.first { rest.contains($0) } ?? rest.first
            out.append(.focus(next))
        }
        return out
    }

    /// What `space focus` / `move-window` answers for a target that names no
    /// desktop (NATIVE.md, "Desktop count"): weft cannot create desktops, so it
    /// says how to add one.
    public func refusal(for target: String) -> String {
        switch target {
        case "next": return "no desktop after this one on this display"
        case "prev": return "no desktop before this one on this display"
        case "recent": return "no recent desktop yet"
        default: break
        }
        if let n = missingDesktop(target) {
            let named = Int(target) == nil ? " ('\(target)')" : ""
            return "desktop \(n)\(named) does not exist; add desktops in Mission Control (weft cannot create them)"
        }
        let known = wsOrder.compactMap { workspaces[$0]?.label }.joined(separator: ", ")
        return "unknown desktop '\(target)' (desktops: \(known))"
    }
}
