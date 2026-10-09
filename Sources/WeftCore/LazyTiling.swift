// WeftCore/LazyTiling.swift — which desktops a sweep lays out, and when a
// desktop just shown needs another look (docs/NATIVE.md, "Cold start" and
// "Moving windows").
//
// Accessibility lists only the showing desktop's windows (S0), but an element
// captured while a window was showing keeps taking frame writes after its
// desktop is hidden (S11). So a hidden desktop is laid out as soon as its
// layout changes — a window arrives, one closes, the gaps change — provided
// weft holds an element for every window on it; when the desktop is next
// shown there is nothing left to do but paint. A desktop with a window weft
// has never held an element for waits until it is shown: no warm-up sweep.

/// The desktops a sweep writes frames to: every showing one, and every hidden
/// one whose layout differs from what was last written there and whose
/// windows are all bound. Sorted, so the order does not depend on dictionary
/// order.
///
/// - Parameters:
///   - showing: the desktops on screen now.
///   - computed: each tiling desktop's frames as its layout stands now.
///     Float desktops are absent: weft never places floats.
///   - lastWritten: the frames last written to each desktop.
///   - bound: whether weft holds an AX element for a window.
public func desktopsToLayOut(
    showing: Set<SpaceID>,
    computed: [SpaceID: [WindowID: Frame]],
    lastWritten: [SpaceID: [WindowID: Frame]],
    bound: (WindowID) -> Bool
) -> [SpaceID] {
    var out = showing
    for (sid, frames) in computed where !showing.contains(sid) {
        guard !frames.isEmpty, frames != lastWritten[sid], frames.keys.allSatisfy(bound) else { continue }
        out.insert(sid)
    }
    return out.sorted()
}

/// Whether a desktop just shown should be looked at again: some window laid
/// out on it has no AX element yet, because the app's window list was still
/// empty on the first pass. Bounded by the caller to a few tries per desktop
/// change, so an app that never answers costs a second, not a timer.
public func needsAnotherLook(showingWindows: [WindowID], bound: (WindowID) -> Bool, triesLeft: Int) -> Bool {
    triesLeft > 0 && showingWindows.contains { !bound($0) }
}
