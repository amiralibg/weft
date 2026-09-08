import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

/// M2: AX apply path. Every rule from DESIGN §5.2 lives here:
///
/// - 0.15s messaging timeout on every app element at creation.
/// - One serial queue per pid: a hung app stalls only its own queue.
/// - Frame-set protocol: setPosition → setSize → verify POSITION with
///   SLSGetWindowBounds (0.03ms, no app IPC) → correction setPosition if off
///   by >1pt. Position is the verdict; size drift inside `sizeSlop` is app
///   constraint (cell-snapping terminals), recorded as-settled, never a
///   failure. S1 showed corrections fire ~53% of the time.
/// - Diff before write; sub-pixel position deltas + size drift dropped.
/// - Echo suppression: every write records the expected frame + epoch so the
///   observers (M2b) can drop our own AXWindowMoved/Resized notifications.
///
/// Never called on the core queue — the daemon fans mutations out here and the
/// per-pid queues do the blocking IPC.
public final class AXApplier: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [Int32: DispatchQueue] = [:]
    private var appElements: [Int32: AXUIElement] = [:]
    private var windowElements: [WindowID: AXUIElement] = [:]
    private var lastApplied: [WindowID: Frame] = [:]
    private var expectedFrame: [WindowID: Frame] = [:]
    private var expectedAt: [WindowID: Date] = [:]
    private var epoch: [WindowID: UInt64] = [:]
    private var epochCounter: UInt64 = 0
    /// How long our own writes suppress observer echoes. After this the
    /// expected frame expires so a later user drag that lands near an old
    /// target is NOT mistaken for our echo (previous code never expired).
    private let echoTTL: TimeInterval = 2.0
    /// Max position deviation that still counts as "frame-set succeeded".
    /// Position is the verdict: SLS read-back is ground truth.
    private let verifyTolerance: Double = 2.0
    /// Size slop for grid-snapping apps (Ghostty/Alacritty/kitty snap to cell
    /// multiples and can legally land a few px off the request). Size drift
    /// inside this is app constraint, NOT refusal — never a failure, never a
    /// strike. Only position failure fails.
    private let sizeSlop: Double = 8.0
    private let cid: SLConnectionID
    /// App activation only. Separate from the per-pid AX queues so a slow
    /// `activate()` never delays that app's frame writes (see `focusWindow`).
    private let activateQueue = DispatchQueue(label: "weft.ax.activate", qos: .userInitiated)

    public init() {
        self.cid = SLSMainConnectionID()
    }

    // MARK: - Binding

    /// Capture AX elements for the given windows. Must be called while the
    /// windows are on the active space (S0) — typically right after discovery
    /// or on window-created events. Rebinds are cheap and idempotent.
    public func bind(windows: [(wid: WindowID, pid: Int32)]) {
        let pids = Set(windows.map { $0.pid })
        lock.withLock {
            for pid in pids where queues[pid] == nil {
                queues[pid] = DispatchQueue(label: "weft.ax.\(pid)")
            }
        }
        for pid in pids {
            let appEl: AXUIElement = lock.withLock {
                if let el = appElements[pid] { return el }
                let el = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(el, 0.15)
                appElements[pid] = el
                return el
            }
            // Enumerate windows on a per-pid queue so a wedged app can't
            // stall binding for everyone else.
            queue(for: pid).sync {
                var found: [(WindowID, AXUIElement)] = []
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    appEl, kAXWindowsAttribute as CFString, &value
                ) == .success, let elements = value as? [AXUIElement] {
                    for el in elements {
                        var wid: UInt32 = 0
                        if _AXUIElementGetWindow(el, &wid) == .success, wid != 0 {
                            found.append((wid, el))
                        }
                    }
                }
                for attr in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
                    var singleVal: CFTypeRef?
                    if AXUIElementCopyAttributeValue(appEl, attr as CFString, &singleVal) == .success,
                       let el = singleVal as! AXUIElement? {
                        var wid: UInt32 = 0
                        if _AXUIElementGetWindow(el, &wid) == .success, wid != 0 {
                            found.append((wid, el))
                        }
                    }
                }
                self.lock.withLock {
                    for (wid, el) in found {
                        self.windowElements[wid] = el
                    }
                }
            }
        }
        // Windows whose pid wasn't enumerable keep their old binding, if any.
        _ = windows
    }

    /// Is this a real, tileable window?
    ///
    /// The CGWindowList filter (layer 0, both dimensions over 100px) is not
    /// enough on its own: a menu-bar extra's panel — Stats, iStat, a Now
    /// Playing popover — is a layer-0 window bigger than 100x100, so weft
    /// tiled it and pushed the user's real windows aside. yabai does not,
    /// because it manages only windows whose AX subrole is
    /// `AXStandardWindow`; a popover's is `AXSystemDialog`, `AXUnknown` or
    /// similar. This is that check.
    ///
    /// nil means "cannot tell" — the app is not AX-enumerable right now (the
    /// window may be on another space, S0). Callers must treat nil as "not
    /// yet classified" and ask again, never as "not standard": answering no
    /// on a cold read would silently unmanage every window on an unvisited
    /// space.
    ///
    /// One AX round trip, and the caller is expected to cache the answer for
    /// the window's lifetime. Never call this from the core queue.
    public func isStandardWindow(wid: WindowID, pid: Int32) -> Bool? {
        var element: AXUIElement? = lock.withLock { windowElements[wid] }
        if element == nil {
            bind(windows: [(wid: wid, pid: pid)])
            element = lock.withLock { windowElements[wid] }
        }
        guard let el = element else { return nil }
        return queue(for: pid).sync { () -> Bool? in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                el, kAXSubroleAttribute as CFString, &value
            ) == .success, let subrole = value as? String else { return nil }
            return subrole == (kAXStandardWindowSubrole as String)
        }
    }

    /// Drop every cached entry for windows that no longer exist. Without this
    /// `windowElements`, `lastApplied`, `expectedFrame` and `epoch` grew for
    /// the life of the daemon, and a recycled window id inherited a dead
    /// element plus a stale "expected" frame that silently suppressed the new
    /// window's move notifications.
    public func forget(keeping live: Set<WindowID>) {
        lock.withLock {
            windowElements = windowElements.filter { live.contains($0.key) }
            lastApplied = lastApplied.filter { live.contains($0.key) }
            expectedFrame = expectedFrame.filter { live.contains($0.key) }
            expectedAt = expectedAt.filter { live.contains($0.key) }
            epoch = epoch.filter { live.contains($0.key) }
        }
    }

    /// Release the per-pid queue and app element for a terminated process.
    public func forgetApp(pid: Int32) {
        lock.withLock {
            queues.removeValue(forKey: pid)
            appElements.removeValue(forKey: pid)
        }
    }

    // MARK: - Apply

    public struct ApplyResult: Sendable {
        public var applied: Int
        public var skipped: Int
        public var errors: Int
        /// Windows whose frame-set failed (even after one retry) — the
        /// screen disagrees with computed layout for these. Callers log them.
        public var failedIDs: [WindowID]
        /// Windows that took the frame. Needed so a caller keeping failure
        /// counts can forgive a window that starts cooperating again — a
        /// count that only ever rises turns one bad moment into a permanent
        /// verdict.
        public var appliedIDs: [WindowID]

        public init(
            applied: Int, skipped: Int, errors: Int,
            failedIDs: [WindowID] = [], appliedIDs: [WindowID] = []
        ) {
            self.applied = applied
            self.skipped = skipped
            self.errors = errors
            self.failedIDs = failedIDs
            self.appliedIDs = appliedIDs
        }
    }

    /// Apply target frames. Calls completion off the core queue when every
    /// per-pid queue has drained. Reads geometry only via SLS, never AX.
    public func apply(
        frames: [WindowID: Frame],
        pids: [WindowID: Int32],
        completion: (@Sendable (ApplyResult) -> Void)? = nil
    ) {
        // Diff against actual physical frame on entry so we do not skip
        // out-of-sync windows. Position must match tightly; size gets slop
        // for cell-snapping terminals (else every sync rewrites a settled
        // 5px-snapped window — churn that looked like "moving by itself").
        let todo: [(wid: WindowID, frame: Frame, pid: Int32)] = lock.withLock {
            frames.compactMap { wid, frame in
                guard let pid = pids[wid] else { return nil }
                if let actual = WorldReader.frame(of: wid),
                   abs(actual.x - frame.x) < 1.0, abs(actual.y - frame.y) < 1.0,
                   abs(actual.width - frame.width) <= self.sizeSlop,
                   abs(actual.height - frame.height) <= self.sizeSlop
                {
                    lastApplied[wid] = actual
                    return nil
                }
                return (wid, frame, pid)
            }
        }
        guard !todo.isEmpty else {
            completion?(ApplyResult(applied: 0, skipped: frames.count, errors: 0))
            return
        }
        let grouped = Dictionary(grouping: todo, by: { $0.pid })
        let group = DispatchGroup()
        let counter = Counter()
        for (pid, items) in grouped {
            group.enter()
            queue(for: pid).async {
                for item in items {
                    // One immediate retry: transient timeouts (Gecko relayout,
                    // JetBrains) are the common failure, not dead apps — the
                    // 0.15s messaging timeout bounds both attempts.
                    var ok = self.setFrameOnQueue(item.frame, wid: item.wid, pid: pid)
                    if !ok {
                        ok = self.setFrameOnQueue(item.frame, wid: item.wid, pid: pid)
                    }
                    counter.add(ok: ok, wid: item.wid)
                }
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .utility)) {
            let (a, e, failed, ok) = counter.snapshot()
            completion?(ApplyResult(
                applied: a,
                skipped: frames.count - todo.count,
                errors: e,
                failedIDs: failed.sorted(),
                appliedIDs: ok.sorted()
            ))
        }
    }

    /// Raise a window (focus) via AX + app activation.
    ///
    /// Activation runs on its own queue, never the app's AX queue.
    /// `NSRunningApplication.activate()` blocks inside
    /// `_yieldToApplication` for as long as the target app takes to come
    /// forward, and parking that on the per-pid AX queue put it at the head of
    /// the line in front of every subsequent frame write for that app —
    /// measured as a 1.2 s `zoom-fullscreen`.
    public func focusWindow(_ wid: WindowID, pid: Int32) {
        queue(for: pid).async {
            let el: AXUIElement? = self.lock.withLock { self.windowElements[wid] }
            if let el {
                AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            }
        }
        activateQueue.async {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    /// AX raise (z-order only, no resize) without blocking the caller.
    ///
    /// Ordering is still exact: frame writes and raises for one window go to
    /// the same per-pid serial queue, so a raise enqueued after an apply runs
    /// after it. The previous version was `q.sync` wrapped in another
    /// `applyQueue.sync`, which made every focus change wait out the slowest
    /// pending frame write.
    public func raise(_ wid: WindowID, pid: Int32) {
        queue(for: pid).async {
            let el: AXUIElement? = self.lock.withLock { self.windowElements[wid] }
            if let el {
                AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            }
        }
        activateQueue.async {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    /// Blocking raise. Only for callers that must observe the new z-order
    /// before returning; the command path uses `raise` instead.
    public func raiseSync(_ wid: WindowID, pid: Int32) {
        queue(for: pid).sync {
            let el: AXUIElement? = self.lock.withLock { self.windowElements[wid] }
            if let el {
                AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            }
        }
        activateQueue.async {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    // MARK: - Scroll parking (M5)

    /// SLS-park a window far off-screen (S4: AX clamps at -(width-40), SLS
    /// doesn't). WindowServer-local, no app IPC, 0.002ms. Keeps the current
    /// Y so unpark geometry stays trivial. Returns SLS status.
    @discardableResult
    public func park(_ wid: WindowID, toX: Double) -> Bool {
        guard let f = WorldReader.frame(of: wid) else { return false }
        var p = CGPoint(x: toX, y: f.y)
        return SLSMoveWindow(cid, wid, &p) == 0
    }

    /// Unpark with the nudge protocol (S4): SLS back on-screen, then AX write
    /// a *different* position (the app still believes the old one — writing
    /// it back would no-op and strand the window), then the real target.
    /// Synchronous on the app's queue; false keeps the window tracked-parked.
    @discardableResult
    public func unpark(_ wid: WindowID, pid: Int32, to frame: Frame) -> Bool {
        var p = CGPoint(x: frame.x, y: frame.y)
        guard SLSMoveWindow(cid, wid, &p) == 0 else { return false }
        let el: AXUIElement? = lock.withLock { windowElements[wid] }
        guard el != nil else { return false }
        var ok = false
        queue(for: pid).sync {
            let nudge = Frame(x: frame.x + 5, y: frame.y + 5, width: frame.width, height: frame.height)
            _ = self.setFrameOnQueue(nudge, wid: wid, pid: pid)
            ok = self.setFrameOnQueue(frame, wid: wid, pid: pid)
        }
        return ok
    }

    // MARK: - Echo suppression (for observers, M2b)

    /// True if this notification frame matches what we just wrote — drop it.
    /// Expires after `echoTTL` so stale targets never suppress real user moves.
    public func isEcho(wid: WindowID, frame: Frame) -> Bool {
        lock.withLock {
            guard let exp = expectedFrame[wid], let at = expectedAt[wid] else { return false }
            guard Date().timeIntervalSince(at) <= echoTTL else {
                expectedFrame.removeValue(forKey: wid)
                expectedAt.removeValue(forKey: wid)
                return false
            }
            return framesEqual(exp, frame, tolerance: 1.0)
        }
    }

    public func currentEpoch(wid: WindowID) -> UInt64? {
        lock.withLock { epoch[wid] }
    }

    private func resolveElement(for wid: WindowID, pid: Int32) -> AXUIElement? {
        if let el = lock.withLock({ windowElements[wid] }) {
            return el
        }
        let appEl: AXUIElement = lock.withLock {
            if let el = appElements[pid] { return el }
            let el = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(el, 0.15)
            appElements[pid] = el
            return el
        }
        // 1. Standard windows attribute
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &value) == .success,
           let elements = value as? [AXUIElement] {
            for el in elements {
                var w: UInt32 = 0
                if _AXUIElementGetWindow(el, &w) == .success, w != 0 {
                    lock.withLock { windowElements[WindowID(w)] = el }
                    if WindowID(w) == wid {
                        return el
                    }
                }
            }
        }
        // 2. Fallbacks for apps (like Ghostty/Electron) that expose windows via MainWindow/FocusedWindow
        for attr in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var singleVal: CFTypeRef?
            if AXUIElementCopyAttributeValue(appEl, attr as CFString, &singleVal) == .success,
               let el = singleVal as! AXUIElement? {
                var w: UInt32 = 0
                if _AXUIElementGetWindow(el, &w) == .success, w != 0 {
                    lock.withLock { windowElements[WindowID(w)] = el }
                    if WindowID(w) == wid {
                        return el
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Frame-set protocol (runs on a per-pid queue)

    @discardableResult
    private func setFrameOnQueue(_ frame: Frame, wid: WindowID, pid: Int32) -> Bool {
        var target = CGPoint(x: frame.x, y: frame.y)
        // 1. Instant compositor positioning via SkyLight
        let slsStatus = SLSMoveWindow(cid, wid, &target)
        let slsOK = (slsStatus == 0)

        // 2. Resolve AX element for size + positioning notifications
        guard let el = resolveElement(for: wid, pid: pid) else {
            // SLS-only placement: success iff WindowServer accepted it AND
            // a follow-up read shows the window actually there (position
            // verdict; size drift is app constraint, not refusal).
            if !slsOK { return false }
            var rect = CGRect.zero
            guard SLSGetWindowBounds(cid, wid, &rect) == 0 else { return false }
            let posOK = abs(rect.minX - target.x) <= verifyTolerance
                && abs(rect.minY - target.y) <= verifyTolerance
            lock.withLock {
                epochCounter += 1
                epoch[wid] = epochCounter
                if posOK {
                    let settled = Frame(x: target.x, y: target.y, width: rect.width, height: rect.height)
                    lastApplied[wid] = settled
                    expectedFrame[wid] = settled
                    expectedAt[wid] = Date()
                }
            }
            return posOK
        }

        let size = CGSize(width: frame.width, height: frame.height)
        var p = target
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
        }
        var s = size
        if let v = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
        }
        // Verify POSITION with SLS (cheap, no app IPC). Correction fires
        // ~half the time depending on grow-vs-shrink direction (S1). Size is
        // read back and recorded as-settled so echoes match and the diff
        // above doesn't rewrite a happily-snapped terminal every sync.
        var rect = CGRect.zero
        var posOK = false
        var haveRect = false
        if SLSGetWindowBounds(cid, wid, &rect) == 0 {
            haveRect = true
            posOK = abs(rect.minX - target.x) <= verifyTolerance
                && abs(rect.minY - target.y) <= verifyTolerance
            if !posOK {
                var p2 = target
                if let v = AXValueCreate(.cgPoint, &p2) {
                    AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
                    if SLSGetWindowBounds(cid, wid, &rect) == 0 {
                        posOK = abs(rect.minX - target.x) <= verifyTolerance
                            && abs(rect.minY - target.y) <= verifyTolerance
                    } else { haveRect = false }
                }
            }
        }
        let ok = slsOK && haveRect && posOK
        // Record echo suppression only on real success; on failure leave any
        // prior expectation alone so observer Moved/Resized events are treated
        // as genuine (and can trigger strikes upstream via failedIDs).
        lock.withLock {
            epochCounter += 1
            epoch[wid] = epochCounter
            if ok {
                let settled = Frame(x: target.x, y: target.y, width: rect.width, height: rect.height)
                lastApplied[wid] = settled
                expectedFrame[wid] = settled
                expectedAt[wid] = Date()
            }
        }
        return ok
    }

    private func queue(for pid: Int32) -> DispatchQueue {
        lock.withLock {
            if let q = queues[pid] { return q }
            let q = DispatchQueue(label: "weft.ax.\(pid)")
            queues[pid] = q
            return q
        }
    }
}

private func framesEqual(_ a: Frame, _ b: Frame, tolerance: Double) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
        && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
}

/// Simple locked counter for fan-out completion.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var applied = 0
    private var errors = 0
    private var failed: [WindowID] = []
    private var succeeded: [WindowID] = []

    func add(ok: Bool, wid: WindowID) {
        lock.withLock {
            if ok {
                applied += 1
                succeeded.append(wid)
            } else {
                errors += 1
                failed.append(wid)
            }
        }
    }

    func snapshot() -> (Int, Int, [WindowID], [WindowID]) {
        lock.withLock { (applied, errors, failed, succeeded) }
    }
}
