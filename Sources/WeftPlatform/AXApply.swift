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
    /// pid → process name, for trace output only.
    private var appNameCache: [Int32: String] = [:]
    /// pid → bundle id, for the enhanced-UI exemption only.
    private var bundleIDCache: [Int32: String] = [:]
    /// Bundle ids whose `AXEnhancedUserInterface` is left alone (config).
    private var enhancedUIExempt: Set<String> = []
    /// The newest write claimed for each window, and the frame it targets.
    ///
    /// A close fires an apply straight away and then two sweeps behind it,
    /// each of which recomputes the same frames. While the first write is
    /// still queued behind a slow app, the WindowServer does not yet show the
    /// new size, so the entry diff cannot tell the sweeps' writes are
    /// redundant — and every one of them was another full relayout of a
    /// Chromium window. An identical target already in flight is dropped at
    /// entry; a different one supersedes it, and the stale write is skipped
    /// when its turn comes rather than performed and immediately undone.
    private var inFlight: [WindowID: (gen: UInt64, frame: Frame)] = [:]
    private var writeGenCounter: UInt64 = 0
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
    /// Latest-wins backpressure for the AX size writes of a drag.
    private let resizeLock = NSLock()
    private var pendingResizes: [(wid: WindowID, frame: Frame, pid: Int32)]?
    private var resizeInFlight = false
    private let dragQueue = DispatchQueue(label: "weft.ax.drag", qos: .userInteractive)

    public init() {
        self.cid = SLSMainConnectionID()
    }

    // MARK: - Binding

    /// Capture AX elements for the given windows. Must be called while the
    /// windows are on the active space (S0) — typically right after discovery
    /// or on window-created events. Rebinds are cheap and idempotent.
    public func bind(windows: [(wid: WindowID, pid: Int32)]) {
        // Only apps with something still unbound.
        //
        // This runs at the end of every world sweep, and sweeps fire on every
        // window creation, focus change and space switch. Enumerating AX
        // windows is a cross-process round trip per app with a 0.15s timeout
        // each, taken synchronously on the queue that also applies frames —
        // so re-binding fifteen already-bound apps was, on every event, the
        // single most expensive thing weft did, for nothing. A window's AX
        // element does not change under us; the only ones worth asking about
        // are the ones we have never resolved.
        let unbound: [(wid: WindowID, pid: Int32)] = lock.withLock {
            windows.filter { windowElements[$0.wid] == nil }
        }
        let pids = Set(unbound.map { $0.pid })
        guard !pids.isEmpty else { return }
        lock.withLock {
            for pid in pids where queues[pid] == nil {
                queues[pid] = DispatchQueue(label: "weft.ax.\(pid)")
            }
        }
        // Fan out, do not walk. Each app's enumeration is a cross-process
        // round trip with a 0.15 s ceiling, and this used to take them one
        // after another on the caller's thread: fifteen apps that each spend
        // 40 ms is 600 ms of nothing happening, and on a cold start — where
        // every app is unbound at once — it is the largest single component
        // of "weft takes ages to come up". Apps are independent, the queues
        // are already per-pid, so the only reason it was serial was the
        // `.sync`. Wait for the whole set, not for each one in turn.
        let group = DispatchGroup()
        for pid in pids {
            let appEl = appElement(for: pid)
            // Enumerate windows on a per-pid queue so a wedged app can't
            // stall binding for everyone else.
            queue(for: pid).async(group: group) {
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
        // Bounded, so a single wedged app cannot hold up a sweep for longer
        // than one app's timeout: the ones that answered are bound, and the
        // one that did not is asked again on the next sweep (this is
        // idempotent, and `unbound` above means the cost is only ever paid
        // for windows still missing an element).
        _ = group.wait(timeout: .now() + 0.4)
        // Windows whose pid wasn't enumerable keep their old binding, if any.
    }

    /// Why a window is not tileable. `nil` from `classify` means "cannot
    /// tell"; a value here means "asked, and the answer is no".
    public enum NotTileable: String, Error, Sendable {
        /// AX subrole is a dialog, a sheet, a popover, a system panel —
        /// anything that is not `AXStandardWindow`.
        case subrole
        /// The app refuses to resize this window. A fixed-size window cannot
        /// take a tile: it keeps its own size, sits in the middle of a slot
        /// the layout reserved for it, and pushes every real window aside for
        /// nothing. Mattermost's in-call widget is exactly this.
        case fixedSize
        /// No title-bar buttons at all — no close, no minimise, no
        /// full-screen: a panel wearing a standard subrole. Only trusted for
        /// small windows, where a false positive costs little and a false
        /// negative is very visible.
        case panelChrome
    }

    /// Is this a real, tileable window?
    ///
    /// The CGWindowList filter (layer 0, both dimensions over 100px) is not
    /// enough on its own, and neither is the subrole alone:
    ///
    /// - A menu-bar extra's panel — Stats, iStat, a Now Playing popover — is
    ///   a layer-0 window bigger than 100x100, so weft tiled it and pushed
    ///   the user's real windows aside. Its subrole is `AXSystemDialog`,
    ///   `AXUnknown` or similar, so the subrole test catches it.
    /// - An Electron popup — Mattermost's floating call widget, a Slack huddle
    ///   window — reports `AXStandardWindow` and is caught by nothing. It is
    ///   fixed-size, though, and a window that will not resize cannot be
    ///   tiled: given a slot it keeps its own 470x180, ignores the frame, and
    ///   the layout has silently given a quarter of the screen to a badge.
    ///
    /// So: standard subrole AND resizable AND (for small windows) real window
    /// chrome. Anything else floats.
    ///
    /// nil means "cannot tell" — the app is not AX-enumerable right now (the
    /// window may be on another space, S0). Callers must treat nil as "not
    /// yet classified" and ask again, never as "not tileable": answering no
    /// on a cold read would silently unmanage every window on an unvisited
    /// space.
    ///
    /// One batch of AX reads on the app's own queue, and the caller is
    /// expected to cache the answer for the window's lifetime. Never call
    /// this from the core queue.
    public func classify(wid: WindowID, pid: Int32) -> Result<Void, NotTileable>? {
        var element: AXUIElement? = lock.withLock { windowElements[wid] }
        if element == nil {
            bind(windows: [(wid: wid, pid: pid)])
            element = lock.withLock { windowElements[wid] }
        }
        guard let el = element else { return nil }
        return queue(for: pid).sync { self.classifyOnQueue(el: el, wid: wid) }
    }

    /// The AX reads behind `classify`. Caller must already be on `wid`'s app
    /// queue.
    private func classifyOnQueue(el: AXUIElement, wid: WindowID) -> Result<Void, NotTileable>? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                el, kAXSubroleAttribute as CFString, &value
            ) == .success, let subrole = value as? String else { return nil }
            guard subrole == (kAXStandardWindowSubrole as String) else {
                return .failure(.subrole)
            }
            // A window the app will not let us resize cannot hold a tile.
            var sizeSettable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(
                el, kAXSizeAttribute as CFString, &sizeSettable
            ) == .success else { return nil }
            guard sizeSettable.boolValue else { return .failure(.fixedSize) }
            // Chrome check, small windows only. A real document window has a
            // minimise button, a full-screen button, or both; a floating
            // widget that has talked its way past the two tests above has
            // neither. Restricted by size because a legitimately chromeless
            // window (a game, a kiosk view) is always large, and floating one
            // of those would be much worse than tiling a badge.
            var bounds = CGRect.zero
            if SLSGetWindowBounds(self.cid, wid, &bounds) == 0,
               bounds.width < 480 || bounds.height < 320
            {
                var button: CFTypeRef?
                let chrome = [
                    kAXMinimizeButtonAttribute,
                    kAXFullScreenButtonAttribute,
                    kAXCloseButtonAttribute,
                ].contains {
                    AXUIElementCopyAttributeValue(el, $0 as CFString, &button) == .success
                }
                // All three absent, or it is a real window. One title-bar
                // button is enough to prove there is a title bar.
                if !chrome { return .failure(.panelChrome) }
            }
            return .success(())
    }

    /// `classify` for a whole sweep at once, one pass per app instead of one
    /// per window.
    ///
    /// Cold start asks this about every window on the desktop, and the
    /// single-window version answers them strictly in turn: each answer is a
    /// handful of AX round trips, so thirty windows across a dozen apps spent
    /// most of a second in a loop before a single tile was written. Grouping
    /// by pid keeps the per-app serialisation that protects a wedged app's
    /// neighbours, and runs the apps against each other.
    ///
    /// Same contract as `classify`: a missing key means "cannot tell yet".
    public func classifyBatch(
        _ windows: [(wid: WindowID, pid: Int32)]
    ) -> [WindowID: Result<Void, NotTileable>] {
        guard !windows.isEmpty else { return [:] }
        bind(windows: windows)
        let grouped = Dictionary(grouping: windows, by: { $0.pid })
        let sink = VerdictSink()
        let group = DispatchGroup()
        for (pid, items) in grouped {
            queue(for: pid).async(group: group) {
                for item in items {
                    guard let el = self.lock.withLock({ self.windowElements[item.wid] })
                        ?? self.resolveElement(for: item.wid, pid: pid)
                    else { continue }
                    if let verdict = self.classifyOnQueue(el: el, wid: item.wid) {
                        sink.put(item.wid, verdict)
                    }
                }
            }
        }
        // One app's whole ceiling, not one per window. Anything still
        // unanswered stays unclassified and is asked again next sweep, which
        // is exactly what a nil from `classify` already meant.
        _ = group.wait(timeout: .now() + 0.5)
        return sink.all()
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
            appNameCache.removeValue(forKey: pid)
            bundleIDCache.removeValue(forKey: pid)
        }
    }

    // MARK: - Apply

    /// Why one window refused its frame.
    ///
    /// The log line used to guess — every failure was reported as "app
    /// ignored/timeout", which is one of four quite different faults and was
    /// the wrong one often enough to send a diagnosis down the wrong path.
    /// The frame-set protocol knows exactly which step it failed at; it just
    /// was not saying.
    public enum FailureReason: Sendable, CustomStringConvertible {
        /// `SLSMoveWindow` refused. The window is another app's and the
        /// WindowServer connection was not allowed to move it.
        case windowServerRefused(Int32)
        /// No AX element for the window, and the SLS-only path did not land.
        case noAXElement
        /// The bounds read back after the move failed outright.
        case boundsUnreadable
        /// The move was accepted, the window is not where it was put — an app
        /// enforcing its own geometry, or one that ignored the message.
        case positionRejected(want: CGPoint, got: CGPoint)

        public var description: String {
            switch self {
            case .windowServerRefused(let status):
                return "WindowServer refused the move (SLSMoveWindow \(status))"
            case .noAXElement:
                return "no AX element and the WindowServer move did not land"
            case .boundsUnreadable:
                return "could not read the window's bounds back"
            case .positionRejected(let want, let got):
                return String(
                    format: "app kept its own position (wanted %.0f,%.0f — got %.0f,%.0f)",
                    want.x, want.y, got.x, got.y
                )
            }
        }
    }

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
        /// Why each entry in `failedIDs` failed, from the last attempt.
        public var failureReasons: [WindowID: FailureReason]

        public init(
            applied: Int, skipped: Int, errors: Int,
            failedIDs: [WindowID] = [], appliedIDs: [WindowID] = [],
            failureReasons: [WindowID: FailureReason] = [:]
        ) {
            self.applied = applied
            self.skipped = skipped
            self.errors = errors
            self.failedIDs = failedIDs
            self.appliedIDs = appliedIDs
            self.failureReasons = failureReasons
        }
    }

    /// Apply target frames. Calls completion off the core queue when every
    /// per-pid queue has drained. Reads geometry only via SLS, never AX.
    /// `force` skips the "already there" diff.
    ///
    /// Needed by anything that has been moving windows with `SLSMoveWindow`
    /// — a border drag. Those leave every window physically at
    /// its target and the app still believing the position it had before the
    /// gesture started (S2), so the diff sees nothing to do, the AX write
    /// that would resync the app never happens, and the desync the SLS fast
    /// path is only supposed to hold for the length of a gesture becomes
    /// permanent: popovers, sheets and drag origins anchor to a stale origin
    /// for the life of the window.
    public func apply(
        frames: [WindowID: Frame],
        pids: [WindowID: Int32],
        force: Bool = false,
        completion: (@Sendable (ApplyResult) -> Void)? = nil
    ) {
        // Diff against actual physical frame on entry so we do not skip
        // out-of-sync windows. Position must match tightly; size gets slop
        // for cell-snapping terminals (else every sync rewrites a settled
        // 5px-snapped window — churn that looked like "moving by itself").
        // Read geometry first, take the lock second. These are SLS calls —
        // cheap, but there is one per window, and doing them inside the lock
        // meant a drag's diff pass blocked every per-pid queue that wanted to
        // record a result at the same time.
        let tTotal = Trace.start("apply.total")
        let tDiff = Trace.start("apply.diff")
        var settled: [WindowID: Frame] = [:]
        var todo: [(wid: WindowID, frame: Frame, pid: Int32)] = []
        for (wid, frame) in frames {
            guard let pid = pids[wid] else { continue }
            if !force,
               let actual = WorldReader.frame(of: wid),
               abs(actual.x - frame.x) < 1.0, abs(actual.y - frame.y) < 1.0,
               abs(actual.width - frame.width) <= sizeSlop,
               abs(actual.height - frame.height) <= sizeSlop
            {
                settled[wid] = actual
                continue
            }
            todo.append((wid, frame, pid))
        }
        tDiff.end()
        if !settled.isEmpty {
            lock.withLock { for (wid, f) in settled { lastApplied[wid] = f } }
        }
        // Claim each write; drop the ones whose identical target is already
        // on its way (see `inFlight`).
        let requested = todo.count
        var claimed: [WindowID: UInt64] = [:]
        lock.withLock {
            todo = todo.filter { item in
                if let pending = inFlight[item.wid],
                   framesEqual(pending.frame, item.frame, tolerance: 0.5)
                {
                    return false
                }
                writeGenCounter += 1
                inFlight[item.wid] = (writeGenCounter, item.frame)
                claimed[item.wid] = writeGenCounter
                return true
            }
        }
        let gens = claimed
        let alreadyQueued = requested - todo.count
        let written = todo.count
        let detail = alreadyQueued > 0
            ? "\(written) window(s), \(alreadyQueued) already in flight"
            : "\(written) window(s)"
        guard !todo.isEmpty else {
            tTotal.end(detail: alreadyQueued > 0 ? "\(alreadyQueued) already in flight" : "all settled")
            completion?(ApplyResult(applied: 0, skipped: frames.count, errors: 0))
            return
        }
        Trace.time("apply.commit") { commitPositions(todo) }
        let grouped = Dictionary(grouping: todo, by: { $0.pid })
        let group = DispatchGroup()
        let counter = Counter()
        for (pid, items) in grouped {
            group.enter()
            queue(for: pid).async {
                self.withEnhancedUIOff(pid: pid) {
                    for item in items {
                        let gen = gens[item.wid]
                        // Superseded while it waited: a newer apply claimed
                        // this window, and its write is behind this one on
                        // the same serial queue. Performing this one would be
                        // a relayout the app throws away a moment later.
                        guard self.lock.withLock({ self.inFlight[item.wid]?.gen == gen }) else {
                            continue
                        }
                        // One immediate retry: transient timeouts (Gecko
                        // relayout, JetBrains) are the common failure, not
                        // dead apps — the 0.15s messaging timeout bounds both.
                        var reason = self.setFrameOnQueue(item.frame, wid: item.wid, pid: pid)
                        if reason != nil {
                            reason = self.setFrameOnQueue(item.frame, wid: item.wid, pid: pid)
                        }
                        counter.add(reason: reason, wid: item.wid)
                        self.lock.withLock {
                            if self.inFlight[item.wid]?.gen == gen {
                                self.inFlight.removeValue(forKey: item.wid)
                            }
                        }
                    }
                }
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .utility)) {
            let (a, e, failed, ok, reasons) = counter.snapshot()
            tTotal.end(detail: detail)
            completion?(ApplyResult(
                applied: a,
                skipped: frames.count - written,
                errors: e,
                failedIDs: failed.sorted(),
                appliedIDs: ok.sorted(),
                failureReasons: reasons
            ))
        }
    }

    /// Position-only apply, for the frames of an interactive drag.
    ///
    /// The full frame-set protocol is the right thing for a settled layout and
    /// the wrong thing for a gesture. Per window it costs an SLS move, an AX
    /// position write, an AX size write, an SLS read-back and — about half the
    /// time — a correction write, all of it serialised behind the app. A mouse
    /// reports every 8 ms; two or three apps' worth of that does not fit, so
    /// the drag falls behind the cursor and keeps going after the button
    /// comes up.
    ///
    /// During a drag almost nothing actually changes size. Moving a bsp
    /// divider *translates* the windows on the far side of it — the same
    /// size, a different origin. So: every target position goes out in one
    /// WindowServer transaction (atomic, no app IPC, and all the windows land
    /// on the same compositor frame instead of arriving one by one), and only
    /// the windows whose size genuinely changed pay for an AX write. No
    /// read-back, no correction: the settle pass at the end of the drag runs
    /// the full protocol and fixes anything that drifted.
    public func applyDragFrames(frames: [WindowID: Frame], pids: [WindowID: Int32]) {
        guard !frames.isEmpty else { return }
        var resizes: [(wid: WindowID, frame: Frame, pid: Int32)] = []
        let transaction = SLSTransactionCreate(cid)
        var moved = false
        for (wid, frame) in frames {
            var pre = CGRect.zero
            let readable = SLSGetWindowBounds(cid, wid, &pre) == 0
            let needsMove = !readable
                || abs(pre.minX - frame.x) > 0.5 || abs(pre.minY - frame.y) > 0.5
            let needsResize = !readable
                || abs(pre.width - frame.width) > 0.5 || abs(pre.height - frame.height) > 0.5
            if needsMove, let transaction {
                SLSTransactionMoveWindowWithGroup(
                    transaction, wid, CGPoint(x: frame.x, y: frame.y)
                )
                moved = true
            }
            if needsResize, let pid = pids[wid] {
                resizes.append((wid, frame, pid))
            }
        }
        // `SLSTransactionCreate` is annotated CF_RETURNS_RETAINED in the shim,
        // so ARC releases it — which matters here, where one leak is one leak
        // per mouse event.
        if let transaction, moved { SLSTransactionCommit(transaction, 0) }
        // Record the expectation for every window we touched, so the observer
        // does not read our own drag back as the user moving windows.
        lock.withLock {
            for (wid, frame) in frames {
                epochCounter += 1
                epoch[wid] = epochCounter
                expectedFrame[wid] = frame
                expectedAt[wid] = Date()
                lastApplied[wid] = frame
            }
        }
        // Resizes are the expensive half and get their own backpressure: the
        // positions above go out on every single mouse event, because they
        // cost nothing, while at most one batch of AX size writes is ever in
        // flight and the newest batch replaces any that were waiting. Holding
        // the *positions* back behind a slow app — which a single coalescer
        // over the whole frame set does — is what made a drag lag behind the
        // cursor even when only one window was actually changing size.
        guard !resizes.isEmpty else { return }
        let start: Bool = resizeLock.withLock {
            pendingResizes = resizes
            guard !resizeInFlight else { return false }
            resizeInFlight = true
            return true
        }
        if start { drainResizes() }
    }

    private func drainResizes() {
        let batch: [(wid: WindowID, frame: Frame, pid: Int32)]? = resizeLock.withLock {
            let next = pendingResizes
            pendingResizes = nil
            if next == nil { resizeInFlight = false }
            return next
        }
        guard let batch else { return }
        let group = DispatchGroup()
        for (pid, items) in Dictionary(grouping: batch, by: { $0.pid }) {
            queue(for: pid).async(group: group) {
                self.withEnhancedUIOff(pid: pid) {
                    for item in items {
                        guard let el = self.resolveElement(for: item.wid, pid: pid) else { continue }
                        var size = CGSize(width: item.frame.width, height: item.frame.height)
                        if let v = AXValueCreate(.cgSize, &size) {
                            AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
                        }
                        // An app that grows from its top-left corner ends up
                        // in the right place already; one that does not needs
                        // the origin restating, and that is WindowServer-local.
                        var origin = CGPoint(x: item.frame.x, y: item.frame.y)
                        SLSMoveWindow(self.cid, item.wid, &origin)
                    }
                }
            }
        }
        group.notify(queue: dragQueue) { [weak self] in self?.drainResizes() }
    }

    /// Put every window at its target position in one WindowServer commit.
    ///
    /// Called before the per-app AX writes of a normal apply so a retile
    /// reads as one movement rather than a ripple: without it each window
    /// moves on whatever frame its app's queue got to, and a four-window
    /// space visibly rearranges in stages.
    private func commitPositions(_ items: [(wid: WindowID, frame: Frame, pid: Int32)]) {
        guard items.count > 1, let transaction = SLSTransactionCreate(cid) else { return }
        for item in items {
            SLSTransactionMoveWindowWithGroup(
                transaction, item.wid, CGPoint(x: item.frame.x, y: item.frame.y)
            )
        }
        SLSTransactionCommit(transaction, 0)
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
            // Resolve, do not merely look up. The cache is populated as a side
            // effect of writing a frame, so a window that has never been laid
            // out — a brand new one, or one whose frame-set failed — had no
            // entry, and focusing it did nothing whatsoever: no raise, no
            // attribute write, silently.
            let el: AXUIElement? = self.resolveElement(for: wid, pid: pid)
            if let el {
                Self.makeFocused(el)
                AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            }
            // Activate AFTER the attribute writes, not alongside them.
            //
            // These used to go out on two independent queues, so `activate()`
            // routinely won the race — and activating an app makes macOS
            // restore that app's *own* idea of its key window, undoing the
            // AXMain write that had just named a different one. Focusing the
            // second of two windows in the same app therefore left the app
            // focused on the first, which is what anything tracking real focus
            // (JankyBorders, sketchybar) then drew.
            self.activateQueue.async {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
        }
    }

    /// Tell the *app* which of its windows is now the focused one.
    ///
    /// `AXRaise` changes z-order and `activate()` brings the app forward, but
    /// neither tells the application anything: its `AXFocusedWindow` stays
    /// whatever it was. Focusing the second of two Ghostty windows therefore
    /// raised the right window and then activated the app onto the *old* one —
    /// weft's own focus and the system's disagreed, `mouse-follows-focus`
    /// warped to a window that was not focused, and anything tracking the real
    /// focused window (JankyBorders, sketchybar) drew its highlight around the
    /// previous window and stayed there. It looked like a borders bug. It was
    /// two missing attribute writes.
    ///
    /// `AXMain` is the one that moves the app's notion of its front window;
    /// `AXFocused` moves keyboard focus. Both, in that order, before the raise.
    private static func makeFocused(_ el: AXUIElement) {
        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
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
            let el: AXUIElement? = self.resolveElement(for: wid, pid: pid)
            if let el {
                Self.makeFocused(el)
                AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            }
            self.activateQueue.async {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
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

    // MARK: - Rescue

    /// Bring a window that is off every display back to a real frame.
    ///
    /// The nudge protocol (S4). An SLS move puts the window back where the
    /// WindowServer is concerned, but the app still believes the position it
    /// had before it went missing — so writing that same position through AX
    /// is a no-op, and the window stays where it is. Writing a *different*
    /// position first, then the real target, is what makes the app move.
    ///
    /// Synchronous on the app's queue, because the only caller is `rescue`
    /// and it reports what it managed to fix.
    @discardableResult
    public func restore(_ wid: WindowID, pid: Int32, to frame: Frame) -> Bool {
        var p = CGPoint(x: frame.x, y: frame.y)
        guard SLSMoveWindow(cid, wid, &p) == 0 else { return false }
        // Resolve, do not merely look up — the same trap `focusWindow`
        // documents. The cache is filled as a side effect of writing a frame,
        // and a window that has been off screen is by definition one nothing
        // has written a frame for lately, so a cache miss here failed the
        // rescue outright and left the window exactly where it was.
        guard resolveElement(for: wid, pid: pid) != nil else { return false }
        var ok = false
        queue(for: pid).sync {
            let nudge = Frame(x: frame.x + 5, y: frame.y + 5, width: frame.width, height: frame.height)
            _ = self.setFrameOnQueue(nudge, wid: wid, pid: pid)
            ok = self.setFrameOnQueue(frame, wid: wid, pid: pid) == nil
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
        let appEl = appElement(for: pid)
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

    /// Process name for a pid, cached. Only ever used as trace `detail`, so
    /// a miss is cosmetic — but the lookup is a `NSRunningApplication`
    /// round trip and this runs on the write path, so it happens once per app.
    private func appName(for pid: Int32) -> String {
        if let cached = lock.withLock({ appNameCache[pid] }) { return cached }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        lock.withLock { appNameCache[pid] = name }
        return name
    }

    /// Whether weft holds an AX element for this window — i.e. whether a
    /// frame write to it can be more than a WindowServer-only move.
    public func isBound(_ wid: WindowID) -> Bool {
        lock.withLock { windowElements[wid] != nil }
    }

    /// The app's AX element, created once per pid with the 0.15 s ceiling
    /// every cross-process call here relies on.
    private func appElement(for pid: Int32) -> AXUIElement {
        lock.withLock {
            if let el = appElements[pid] { return el }
            let el = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(el, 0.15)
            appElements[pid] = el
            return el
        }
    }

    /// Config: bundle ids whose `AXEnhancedUserInterface` is left alone.
    public func setEnhancedUIExempt(_ ids: Set<String>) {
        lock.withLock { enhancedUIExempt = ids }
    }

    private func isEnhancedUIExempt(pid: Int32) -> Bool {
        let (exempt, cached) = lock.withLock { (enhancedUIExempt, bundleIDCache[pid]) }
        guard !exempt.isEmpty else { return false }
        if let cached { return exempt.contains(cached) }
        let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        lock.withLock { bundleIDCache[pid] = id }
        return exempt.contains(id)
    }

    /// Run a batch of frame writes with the app's `AXEnhancedUserInterface`
    /// switched off, and put it back afterwards.
    ///
    /// Chromium and Electron turn that attribute on the moment an
    /// accessibility client enumerates their windows — which weft does at
    /// bind — and with it on, a size write goes through the app's animated
    /// relayout path. That is the single largest term in `ax.size` for those
    /// apps, and it is why yabai does the same. The attribute is per app, so
    /// the toggle wraps a whole per-pid batch: one read, and two writes only
    /// when it was actually on.
    ///
    /// It is always restored — an assistive tool that relies on it gets it
    /// back as soon as the batch lands — and `enhanced-ui-exempt` skips the
    /// toggle entirely for an app that cannot tolerate even that.
    private func withEnhancedUIOff(pid: Int32, _ body: () -> Void) {
        guard !isEnhancedUIExempt(pid: pid) else { return body() }
        let appEl = appElement(for: pid)
        let attr = "AXEnhancedUserInterface" as CFString
        var value: CFTypeRef?
        let wasOn = AXUIElementCopyAttributeValue(appEl, attr, &value) == .success
            && (value as? NSNumber)?.boolValue == true
        guard wasOn else { return body() }
        AXUIElementSetAttributeValue(appEl, attr, kCFBooleanFalse)
        defer { AXUIElementSetAttributeValue(appEl, attr, kCFBooleanTrue) }
        body()
    }

    // MARK: - Frame-set protocol (runs on a per-pid queue)

    /// nil on success, otherwise why it failed.
    @discardableResult
    private func setFrameOnQueue(_ frame: Frame, wid: WindowID, pid: Int32) -> FailureReason? {
        var target = CGPoint(x: frame.x, y: frame.y)
        // 1. Instant compositor positioning via SkyLight
        let slsStatus = SLSMoveWindow(cid, wid, &target)
        let slsOK = (slsStatus == 0)

        // 2. Resolve AX element for size + positioning notifications
        guard let el = resolveElement(for: wid, pid: pid) else {
            // SLS-only placement: success iff WindowServer accepted it AND
            // a follow-up read shows the window actually there (position
            // verdict; size drift is app constraint, not refusal).
            if !slsOK { return .noAXElement }
            var rect = CGRect.zero
            guard SLSGetWindowBounds(cid, wid, &rect) == 0 else { return .boundsUnreadable }
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
            return posOK ? nil : .positionRejected(want: target, got: rect.origin)
        }

        // Is the size already right? An AX size write is the expensive half of
        // this — it forces the app through a full relayout, and a browser or
        // an Electron window can spend tens of milliseconds there. Moving a
        // bsp divider only translates the windows on the far side of it, so
        // most windows in a drag are the same size they already were and were
        // being asked to relayout for nothing.
        //
        // The tolerance is tight on purpose. `sizeSlop` is 8pt — the room a
        // cell-snapping terminal is allowed — and reusing it here would have
        // swallowed the 2pt steps a slow drag is made of, so a resize would
        // simply not happen until the cursor moved far enough in one event.
        var pre = CGRect.zero
        let preReadable = SLSGetWindowBounds(cid, wid, &pre) == 0
        let sizeAlreadyRight = preReadable
            && abs(pre.width - frame.width) <= 0.5
            && abs(pre.height - frame.height) <= 0.5
        // Direction decides the order (`axWriteOrder`): a shrinking window
        // resized after it moves overhangs the screen edge in between, and
        // the app pulls it back — which is the correction write below, and on
        // a Chromium window a second full relayout.
        let order: AXWriteOrder = (preReadable && !sizeAlreadyRight)
            ? axWriteOrder(
                from: Frame(x: pre.minX, y: pre.minY, width: pre.width, height: pre.height),
                to: frame
            )
            : .positionThenSize

        let who = appName(for: pid)
        func writePosition() {
            var p = target
            guard let v = AXValueCreate(.cgPoint, &p) else { return }
            Trace.time("ax.position", detail: who) {
                AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
            }
        }
        func writeSize() {
            guard !sizeAlreadyRight else { return }
            var s = CGSize(width: frame.width, height: frame.height)
            guard let v = AXValueCreate(.cgSize, &s) else { return }
            Trace.time("ax.size", detail: who) {
                AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
            }
        }
        switch order {
        case .positionThenSize:
            writePosition()
            writeSize()
        case .sizeThenPosition:
            writeSize()
            writePosition()
        }
        let tVerify = Trace.start("ax.verify")
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
                    Trace.time("ax.correction", detail: "\(who) \(order)") {
                        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
                    }
                    if SLSGetWindowBounds(cid, wid, &rect) == 0 {
                        posOK = abs(rect.minX - target.x) <= verifyTolerance
                            && abs(rect.minY - target.y) <= verifyTolerance
                    } else { haveRect = false }
                }
            }
        }
        tVerify.end(detail: who)
        let ok = slsOK && haveRect && posOK
        let reason: FailureReason? = ok ? nil
            : !slsOK ? .windowServerRefused(slsStatus)
            : !haveRect ? .boundsUnreadable
            : .positionRejected(want: target, got: rect.origin)
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
        return reason
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
    private var reasons: [WindowID: AXApplier.FailureReason] = [:]

    func add(reason: AXApplier.FailureReason?, wid: WindowID) {
        lock.withLock {
            if let reason {
                errors += 1
                failed.append(wid)
                reasons[wid] = reason
            } else {
                applied += 1
                succeeded.append(wid)
            }
        }
    }

    func snapshot() -> (Int, Int, [WindowID], [WindowID], [WindowID: AXApplier.FailureReason]) {
        lock.withLock { (applied, errors, failed, succeeded, reasons) }
    }
}

/// Locked collector for `classifyBatch`, which writes from every app queue.
private final class VerdictSink: @unchecked Sendable {
    private let lock = NSLock()
    private var verdicts: [WindowID: Result<Void, AXApplier.NotTileable>] = [:]

    func put(_ wid: WindowID, _ verdict: Result<Void, AXApplier.NotTileable>) {
        lock.withLock { verdicts[wid] = verdict }
    }

    func all() -> [WindowID: Result<Void, AXApplier.NotTileable>] {
        lock.withLock { verdicts }
    }
}

/// The window the user is actually looking at, whether or not weft manages it.
///
/// Every command that acts on "the focused window" reads the layout's focus,
/// which only ever names a window in a layout. A window a rule unmanaged is in
/// no layout, so it is never the layout's focus: commands aimed at it either
/// said "nothing focused" or quietly acted on some tiled window elsewhere on
/// the desktop. Asking the system instead costs one AX round trip and is only
/// reached on that fallback, never on the tiling path.
public enum FocusedWindow {
    public static func current() -> WindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, attr as CFString, &value) == .success,
                  let el = value as! AXUIElement?
            else { continue }
            var wid: UInt32 = 0
            if _AXUIElementGetWindow(el, &wid) == .success, wid != 0 {
                return WindowID(wid)
            }
        }
        return nil
    }
}
