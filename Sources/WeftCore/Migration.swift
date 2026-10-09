// WeftCore/Migration.swift — 0.9.21's virtual workspaces, spread onto macOS
// desktops (docs/NATIVE.md, "Migration from 0.9.21").
//
// 0.9.21 kept every workspace on one desktop per display and wrote which
// windows were in which, by number, to `membership.json`. 0.9.22 makes each
// workspace a desktop, so old workspace k's windows go to desktop k by the
// global numbering. A workspace with no desktop yet keeps its windows where
// they are, and `weftctl spread` finishes the job once desktops are added.

/// What a spread does.
public struct SpreadPlan: Sendable, Equatable {
    public struct Batch: Sendable, Equatable {
        public var desktop: SpaceID
        public var windows: [WindowID]

        public init(desktop: SpaceID, windows: [WindowID]) {
            self.desktop = desktop
            self.windows = windows
        }
    }

    /// One bridged move per desktop, in desktop-number order.
    public var batches: [Batch]
    /// Old workspace numbers (1-based) that still hold a window but have no
    /// desktop with their number: their windows stay put.
    public var waiting: [Int]

    public init(batches: [Batch] = [], waiting: [Int] = []) {
        self.batches = batches
        self.waiting = waiting
    }

    /// Every old workspace with a window left has its desktop:
    /// `membership.json` has done its job.
    public var complete: Bool { waiting.isEmpty }
}

/// Spread old workspaces onto desktops by number.
///
/// - Parameters:
///   - old: 0.9.21's workspaces by number, each its window ids.
///   - desktops: the desktops that exist now, by global number.
///   - windowDesktops: every window that exists now and the spaces macOS
///     reports it on.
///
/// A window moves only when it exists, is on exactly one ordinary desktop
/// (not every desktop, not a fullscreen space) and is not already on its
/// target. An old workspace whose windows have all closed asks for nothing.
public func planSpread(
    old: [[WindowID]], desktops: [SpaceID], windowDesktops: [WindowID: [SpaceID]]
) -> SpreadPlan {
    let ordinary = Set(desktops)
    var plan = SpreadPlan()
    var claimed = Set<WindowID>()
    for (k, wids) in old.enumerated() {
        let movable = wids.filter { w in
            guard let on = windowDesktops[w], on.count == 1, ordinary.contains(on[0]) else { return false }
            return claimed.insert(w).inserted
        }
        guard !movable.isEmpty else { continue }
        guard k < desktops.count else {
            plan.waiting.append(k + 1)
            continue
        }
        let target = desktops[k]
        let moving = movable.filter { windowDesktops[$0] != [target] }
        if !moving.isEmpty { plan.batches.append(.init(desktop: target, windows: moving)) }
    }
    return plan
}
