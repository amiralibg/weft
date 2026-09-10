// weftd — M2: core serial queue + observers + event bus + socket loop.
//
// Flow (§3):
//   observers ──→ core.async ──→ reduce/resync ──→ applyQueue → AXApplier
//   socket bg queue → Command parse → core.sync reduce → applyQueue → reply
// AX never runs on the core queue; the bus fans out on .utility.

import AppKit
import CoreGraphics
import Foundation
import WeftConfig
import WeftCore
import WeftInput
import WeftIPC
import WeftPlatform

final class Daemon: @unchecked Sendable {
    /// Owns `spaces` and the per-window metadata below. Held for the duration
    /// of dictionary mutations and nothing else: **no AX, no SLS sweep, no
    /// frame apply may run here** (§3, "the one rule that makes this fast").
    /// Every keybind takes `core.sync`, so anything slow on this queue is
    /// latency the user feels on every keypress.
    private let core = DispatchQueue(label: "weft.core")
    private let coreKey = DispatchSpecificKey<UInt8>()
    private let applyQueue = DispatchQueue(label: "weft.apply", qos: .userInitiated)
    /// Serial, so parked-set writes land in the order they were taken.
    private let parkedSaveQueue = DispatchQueue(label: "weft.parked-save", qos: .utility)
    private let layoutSaveQueue = DispatchQueue(label: "weft.layout-save", qos: .utility)
    /// `WEFT_TRACE=1` puts every bus event in the log. Off by default: it is
    /// a write syscall per event, and the events are the noisiest thing weft
    /// does.
    static let traceEvents = ProcessInfo.processInfo.environment["WEFT_TRACE"] == "1"
    private let parkedLock = NSLock()
    /// Serializes keybind commands. The tap callback must never block (§6),
    /// and handleCommand blocks (core.sync + apply wait) — so input lands
    /// here and runs off the tap thread, in press order.
    private let incoming = DispatchQueue(label: "weft.incoming")
    /// Observer events and world resyncs. Serial, off-core: reading the
    /// WindowServer, binding AX elements and applying frames all happen here,
    /// touching `core` only for the microseconds of the state swap.
    private let syncQueue = DispatchQueue(label: "weft.sync", qos: .userInitiated)
    private let applier = AXApplier()
    private let hub = SubscriberHub()
    private let bus = EventBus()
    private let observers = ObserverSet()
    private let input = InputManager()
    /// Per-space tiling + labels (M4). Single-space `State` values are built
    /// on demand from the current space's tree for the pure reducer.
    private var spaces = SpaceState()
    private var pids: [WindowID: Int32] = [:]
    private var appNames: [WindowID: String] = [:]
    private var windowTitles: [WindowID: String] = [:]
    private let bordersBridge = BordersBridge()
    private let sketchybarBridge = SketchybarBridge()
    /// Usable rect per display uuid (top-left origin, menu bar + Dock already
    /// excluded), and the display uuids west→east. Refreshed on every sweep
    /// and on display reconfiguration. Written from the sync queue and read
    /// from the core queue and the command path, hence the lock — this used
    /// to be one `Frame` for the whole machine.
    private var screensByUUID: [String: Frame] = [:]
    private var displayOrder: [String] = []
    private let screensLock = NSLock()
    private var manualFloat: Set<WindowID> = []
    /// Where each hand-floated window was when it was last put back into the
    /// layout. Floating it again restores that geometry instead of re-centring
    /// it, so `float toggle` is a toggle rather than a reset. Pruned with the
    /// rest of the per-window tables on every sweep.
    private var floatFrames: [WindowID: Frame] = [:]

    private struct DragState {
        var windowID: WindowID
        var button: MouseButton
        var startPoint: CGPoint
        var lastPoint: CGPoint
        var startFrame: Frame
        var isFloating: Bool
        /// The border being dragged, when this is a bare border drag.
        var divider: Divider?
        /// Motion seen since the last resize step was emitted.
        ///
        /// A tiled resize is quantised — it only fires past a threshold — and
        /// the threshold used to be applied to a single drag event's delta and
        /// the remainder thrown away. A normal mouse reports one to five
        /// points per event, so nothing ever cleared the bar: resizing a tiled
        /// window by dragging did nothing at all unless you flicked the mouse.
        /// Carrying the remainder makes a slow drag resize smoothly and a fast
        /// one behave as it always did.
        var pendingX: Double = 0
        var pendingY: Double = 0
        /// Whether this gesture has actually written a frame. A press that
        /// moved nothing has nothing to flush and nothing to announce.
        var movedGeometry = false
    }
    private var currentDrag: DragState?
    /// Points of accumulated drag before a tiled resize step is emitted.
    ///
    /// Two, not eight. Eight was chosen to keep the command rate down when
    /// every step meant a string round trip and an unthrottled frame write;
    /// the drag path now skips the parser and coalesces its writes, so the
    /// only thing the threshold still costs is visible stepping. At 2pt a
    /// drag tracks the cursor.
    private static let resizeStep: Double = 2
    /// Borders between tiled windows on the visible spaces, for hit-testing a
    /// bare mouse-down. Written on the sync/apply paths, read on the incoming
    /// queue; the tap gets its own copy of just the rectangles.
    private var dividerZones: [Divider] = []
    private let dividerLock = NSLock()

    /// Whether Accessibility was already granted when this process started.
    ///
    /// A grant that arrives afterwards flips `AXIsProcessTrusted()` to true,
    /// and every AX call still fails: the app connections this process opened
    /// while untrusted stay untrusted for its lifetime. So weft comes up
    /// looking healthy — green permissions, no errors — and cannot move a
    /// window until it is restarted, which nothing told the user to do. This
    /// is the flag that lets the Setup window put a button in front of them
    /// instead.
    private let launchedTrusted = AXIsProcessTrusted()

    init?() {
        core.setSpecific(key: coreKey, value: 1)
        let layout = SpaceControl.displayLayout()
        guard !layout.isEmpty else {
            fputs("weftd: no display found\n", stderr)
            return nil
        }
        self.screensByUUID = Dictionary(uniqueKeysWithValues: layout.map { ($0.uuid, $0.visible) })
        self.displayOrder = layout.map { $0.uuid }
        self.parkedWindows = Daemon.loadParked()
        if !parkedWindows.isEmpty {
            fputs("weftd: restored \(parkedWindows.count) tracked-parked windows\n", stderr)
        }
        loadConfigFile(initial: true)
        bus.sink = { [hub, weak self] event in
            // Encode only if somebody is listening. `hub` is the `weftctl
            // subscribe` fan-out, and the trace is off unless asked for:
            // writing a JSON line to the log file for every focus change and
            // every window move is a synchronous file write on a path that
            // fires dozens of times a second, and the file it grows is one
            // nobody reads until something is already wrong.
            if hub.hasSubscribers || Daemon.traceEvents,
               let data = try? JSONEncoder().encode(event),
               let line = String(data: data, encoding: .utf8)
            {
                hub.broadcast(line)
                if Daemon.traceEvents { fputs("event \(line)\n", stderr) }
            }
            guard let self else { return }
            let state = self.currentStateSummary()
            self.sketchybarBridge.trigger(event: event.kind.rawValue, state: state)
            if let lk = state.layout {
                self.bordersBridge.updateColor(layout: lk, mode: state.mode, config: self.currentConfig().integrations.borders)
            }
        }
        // The first sweep is NOT run here.
        //
        // It reads the whole WindowServer and does two rounds of AX work, and
        // until it returned nothing else in `main` had run — so the socket did
        // not exist yet. Everything that talks to weftd (`weftctl`, and the
        // menu-bar app's reconnect loop) got connection-refused for the whole
        // of it and reported the engine as down, which is most of what a
        // restart *feels* like. `main` starts the listener and then calls
        // `start()`.
        observers.onEvent = { [weak self] event in
            guard let self else { return }
            // Off-core (was core.async): handling an event reads the whole
            // WindowServer and can apply frames, which must never block the
            // queue every keybind synchronises on.
            syncQueue.async { [weak self] in self?.handleObserverEvent(event) }
        }
        observers.start()
        watchCurrent()
        startConfigWatcher()
        // Input last, and off the init path: tap creation can stall for
        // seconds in TCC when permission is missing, and daemon startup
        // (socket, observers, initial tile) must never wait on it.
        // Keybinds simply start working a few seconds later when granted.
        input.onCommand = { [weak self] command in self?.postCommand(command) }
        input.onModeChange = { [weak self] mode in
            self?.bus.emit(DaemonEvent(kind: .modeChanged, mode: mode))
            fputs("weftd: mode \(mode)\n", stderr)
        }
        input.updateMouseModifier(currentConfig().general.mouseModifier)
        input.setBorderDragEnabled(currentConfig().general.mouseBorderResize)
        WorldReader.manageMenubarApps = currentConfig().general.manageMenubarApps
        input.onMouseGesture = { [weak self] gesture in
            self?.handleMouseGesture(gesture)
        }
        // The tap can come up long after launch, when the user grants Input
        // Monitoring with weftd already running. It starts from `.default`
        // with whatever keymap `init` handed it, so re-apply the config that
        // is current by then — a reload may have replaced it in the meantime.
        input.onTapInstalledLate = { [weak self] in
            guard let self else { return }
            let cfg = self.currentConfig()
            self.input.updateKeymap(cfg.keymap)
            self.input.updateMouseModifier(cfg.general.mouseModifier)
            self.input.setBorderDragEnabled(cfg.general.mouseBorderResize)
            self.syncQueue.async { [weak self] in self?.refreshDividerZones() }
            fputs("weftd: input tap installed late — keybinds are live\n", stderr)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t0 = Date()
            let ok = self?.input.start() ?? false
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            fputs(
                "weftd: input tap \(ok ? "installed (mode default)" : "denied — grant Input Monitoring; socket still live") [\(ms)ms]\n",
                stderr
            )
            if !ok {
                // Ask the system, from weftd itself. This is not about showing
                // a dialog — it is what makes macOS ADD weftd to the Input
                // Monitoring list. Without it the list has no weftd row, and
                // the only way in is the `+` picker, which cannot browse to
                // `~/.local/bin` because a dotted directory is hidden. Being
                // told to "find weftd" in a folder Finder refuses to show is
                // the whole of that complaint.
                _ = CGRequestListenEventAccess()
                fputs("weftd: requested Input Monitoring — weftd should now be listed in "
                    + "System Settings › Privacy & Security › Input Monitoring; switch it on\n", stderr)
            }
        }
    }

    /// Everything that must happen once, after the socket is listening.
    ///
    /// Callers that arrive during the first sweep are not turned away: the
    /// socket accepts them, and `handle` runs their command on `incoming`
    /// behind the sweep, so the worst case is a command that answers late
    /// rather than one that fails.
    func start() {
        // On the sync queue, not the caller's: `main` calls this and then
        // enters `CFRunLoopRun`, and the main run loop is where NSWorkspace
        // delivers app-launch, app-quit and space-change notifications. Doing
        // the sweep on the main thread means none of those arrive until it
        // finishes. The queue is serial, so anything the observers post in the
        // meantime is handled after the first sweep, in order.
        syncQueue.async { [weak self] in self?.syncFromSnapshot(initial: true) }
    }

    private func warpMouseToWindow(_ wid: WindowID, target: Frame? = nil) {
        guard currentConfig().general.mouseFollowsFocus else { return }
        guard let frame = target ?? WorldReader.frame(of: wid) else { return }
        if let currentPos = CGEvent(source: nil)?.location,
           frame.contains(x: Double(currentPos.x), y: Double(currentPos.y))
        {
            return
        }
        let center = CGPoint(x: frame.x + frame.width / 2.0, y: frame.y + frame.height / 2.0)
        CGWarpMouseCursorPosition(center)
    }

    /// `target` is where the window is *going*, when the caller knows.
    ///
    /// The warp used to read the window's live frame, which races the frame
    /// write it was triggered by: on any retile the cursor landed on the
    /// window's old rectangle, and during a scroll pan it would chase a window
    /// that is still crossing the screen — or land off it entirely, on a
    /// column that has not arrived yet.
    private func focusAndWarp(window: WindowID, pid: Int32, target: Frame? = nil) {
        noteFocusedWindow(window)
        applier.focusWindow(window, pid: pid)
        warpMouseToWindow(window, target: target)
        bus.emit(DaemonEvent(kind: .windowFocused, window: window))
    }

    private func findWindow(at point: CGPoint) -> (wid: WindowID, frame: Frame, isFloating: Bool)? {
        let px = Double(point.x)
        let py = Double(point.y)
        for wid in manualFloat {
            if let f = WorldReader.frame(of: wid), f.contains(x: px, y: py) {
                return (wid, f, true)
            }
        }
        // The pointer decides which display, and that display's current
        // space owns the layout under it — not whichever space has keyboard
        // focus, which may be on the other monitor entirely.
        let sp = readSpaces()
        let onDisplay = displayUUID(containing: point)
        guard let sid = onDisplay.flatMap({ sp.currentByDisplay[$0] }) ?? sp.currentSpace,
              let layout = sp.layouts[sid]
        else { return nil }
        let screen = usableScreen(for: sid)
        let config = currentConfig().general.asTilingConfig()
        switch layout {
        case .tiling(let t):
            let frames = WeftCore.layout(t, in: screen, config: config)
            for (w, f) in frames where f.contains(x: px, y: py) {
                return (w, f, false)
            }
        case .scroll(let s):
            let (frames, _) = scrollLayout(s, screen: screen, config: config)
            for (w, f) in frames where f.contains(x: px, y: py) {
                return (w, f, false)
            }
        case .float(let fl):
            for w in fl.windows.reversed() {
                if let f = WorldReader.frame(of: w), f.contains(x: px, y: py) {
                    return (w, f, true)
                }
            }
        }
        return nil
    }

    private func handleMouseGesture(_ gesture: MouseGesture) {
        incoming.async { [weak self] in
            guard let self else { return }
            self.processMouseGesture(gesture)
        }
    }

    private func processMouseGesture(_ gesture: MouseGesture) {
        switch gesture {
        case .down(let button, let location):
            if button == .border {
                // The tap already decided this press is on a border; find
                // which one, and start dragging it. Focus is deliberately NOT
                // taken: grabbing a border is not selecting a window, and
                // pulling focus across the screen on every drag would be
                // exactly the "windows moving by themselves" complaint.
                let zones = dividerLock.withLock { dividerZones }
                guard let d = divider(
                    at: Double(location.x), y: Double(location.y), in: zones
                ) else { return }
                currentDrag = DragState(
                    windowID: d.a, button: button,
                    startPoint: location, lastPoint: location,
                    startFrame: .zero, isFloating: false, divider: d
                )
                return
            }
            guard let hit = findWindow(at: location) else { return }
            noteFocusedWindow(hit.wid)
            if let pid = pids[hit.wid] {
                applier.focusWindow(hit.wid, pid: pid)
            }
            raiseFronts([hit.wid])
            currentDrag = DragState(
                windowID: hit.wid,
                button: button,
                startPoint: location,
                lastPoint: location,
                startFrame: hit.frame,
                isFloating: hit.isFloating
            )
        case .drag(let button, let location):
            guard var drag = currentDrag else { return }
            let dx = Double(location.x - drag.lastPoint.x)
            let dy = Double(location.y - drag.lastPoint.y)
            drag.lastPoint = location
            if let d = drag.divider {
                // Border drag: no threshold and no quantisation. The border
                // is under the cursor, so anything other than "it moves with
                // the cursor" reads as broken.
                let delta = d.axis == .horizontal ? dx : dy
                guard abs(delta) > 0.01 else { currentDrag = drag; return }
                drag.movedGeometry = true
                currentDrag = drag
                dragDivider(d, by: delta)
                return
            }
            // Floating drags are measured from where the gesture *started*,
            // against the frame the window had then.
            //
            // They used to read the window's live frame and add this event's
            // delta to it. With the writes coalesced that read is a lagging
            // source — it returns the frame from two events ago — so the
            // deltas it was adding to were stale and the window fell steadily
            // behind the cursor, keeping whatever it had lost. Total offset
            // from the start point cannot drift, and it is self-correcting if
            // a write is dropped.
            let totalX = Double(location.x - drag.startPoint.x)
            let totalY = Double(location.y - drag.startPoint.y)
            if button == .left {
                if drag.isFloating {
                    let f = drag.startFrame
                    drag.movedGeometry = true
                    applyFramesCoalesced([drag.windowID: Frame(
                        x: f.x + totalX, y: f.y + totalY, width: f.width, height: f.height
                    )])
                }
            } else if button == .right {
                if drag.isFloating {
                    let f = drag.startFrame
                    drag.movedGeometry = true
                    applyFramesCoalesced([drag.windowID: Frame(
                        x: f.x, y: f.y,
                        width: max(f.width + totalX, 100),
                        height: max(f.height + totalY, 100)
                    )])
                } else {
                    drag.pendingX += dx
                    drag.pendingY += dy
                    if abs(drag.pendingX) >= Self.resizeStep {
                        let amount = drag.pendingX
                        drag.movedGeometry = true
                        dragResize(amount > 0 ? .right : .left, by: abs(amount))
                        drag.pendingX = 0
                    }
                    if abs(drag.pendingY) >= Self.resizeStep {
                        let amount = drag.pendingY
                        drag.movedGeometry = true
                        dragResize(amount > 0 ? .down : .up, by: abs(amount))
                        drag.pendingY = 0
                    }
                }
            }
            currentDrag = drag
        case .up(let button, let location):
            guard let drag = currentDrag else { return }
            currentDrag = nil
            // Every gesture that moved geometry fed the coalescer and
            // suppressed the per-event bus traffic, so the tail of it is
            // settled here. A press that never moved anything — a plain click
            // on a floating window — settles nothing and emits nothing.
            if drag.movedGeometry {
                // Flush whatever the coalescer was holding back, then let the
                // borders and the bar catch up with the final geometry.
                flushPendingApply()
                // The borders moved with the windows, so the grab zones the
                // tap is hit-testing against describe the layout as it was
                // before the drag. Leaving them stale is a click swallowed
                // where there is nothing left to drag — and after a resize
                // that is exactly where the user's cursor already is.
                refreshDividerZones()
                bus.emit(stateChangedEvent())
                return
            }
            if button == .left && !drag.isFloating {
                if let target = findWindow(at: location), target.wid != drag.windowID {
                    updateSpaces { sp in
                        guard let sid = self.currentSID() else { return }
                        switch sp.layouts[sid] {
                        case .tiling(let t):
                            sp.layouts[sid] = .tiling(t.swapping(drag.windowID, target.wid))
                        case .scroll(let s):
                            sp.layouts[sid] = .scroll(s.swapping(drag.windowID, target.wid))
                        case .float, nil:
                            break
                        }
                    }
                    applyCurrentSpace()
                    bus.emit(stateChangedEvent())
                }
            }
        }
    }

    // MARK: - Border dragging

    /// Move one border by `delta` points along its axis and repaint.
    ///
    /// Runs on the incoming queue, once per mouse event. Everything expensive
    /// is either pure (the ratio edit) or coalesced (the frame writes), so a
    /// 120 Hz drag costs 120 tree edits and however many frame writes the two
    /// apps involved can actually absorb.
    private func dragDivider(_ d: Divider, by delta: Double) {
        let result: (frames: [WindowID: Frame], parked: Set<WindowID>, scope: Set<WindowID>)? = core.sync {
            guard let sid = self.spaces.currentSpace,
                  let layout = self.spaces.layouts[sid]
            else { return nil }
            let screen = self.usableScreen(for: sid)
            let config = self.currentConfig().general.asTilingConfig()
            switch layout {
            case .tiling(let tree):
                let current = WeftCore.layout(tree, in: screen, config: config)
                let next = tree.resizing(
                    divider: d.a, d.b, axis: d.axis,
                    deltaPoints: delta, frames: current
                )
                guard next != tree else { return nil }
                self.spaces.layouts[sid] = .tiling(next)
                return (WeftCore.layout(next, in: screen, config: config), [], [])
            case .scroll(let sc):
                // Aim the edit at the column the cursor is actually holding.
                //
                // This used to focus `d.a` first and resize "the focused
                // column", which had two costs: grabbing a border silently
                // moved focus — the exact thing the mouse-down path goes out
                // of its way not to do — and the follow-up `ensureVisible`
                // re-panned the strip mid-drag, so the border slid out from
                // under the cursor as soon as the column outgrew the screen.
                guard let (col, row) = sc.position(of: d.a) else { return nil }
                let usable = scrollUsable(screen: screen, config: config)
                let next: ScrollState
                switch d.axis {
                case .horizontal:
                    next = sc.adjustingWidth(delta / max(usable.w, 1), column: col)
                case .vertical:
                    next = sc.adjustingHeight(delta / max(usable.h, 1), column: col, row: row)
                }
                guard next != sc else { return nil }
                self.spaces.layouts[sid] = .scroll(next)
                let (frames, parked) = scrollLayout(next, screen: screen, config: config)
                return (frames, parked, Set(next.windows))
            case .float:
                return nil
            }
        }
        guard let result else { return }
        applyFramesCoalesced(result.frames)
        // Widening a column pushes the ones right of it off the edge. Without
        // this they kept their last on-screen frame and piled up under the
        // rightmost visible column for the rest of the drag.
        if !result.scope.isEmpty {
            reconcileParked(parkedNow: result.parked, frames: result.frames, scope: result.scope)
        }
    }

    /// Latest-wins frame writes, for drags.
    ///
    /// AX frame writes are cross-process and take single-digit milliseconds
    /// per window; a mouse reports every 8 ms. Queueing one apply per event
    /// builds a backlog the drag never catches up with — the window keeps
    /// resizing for a second after the button comes up, which is what a
    /// "slow" resize actually is. So: at most one apply in flight, and the
    /// newest target replaces any that were waiting. Intermediate frames of a
    /// drag are worth nothing once a newer one exists.
    private let applyCoalesceLock = NSLock()
    private var lastDragFrames: [WindowID: Frame]?

    private func applyFramesCoalesced(_ frames: [WindowID: Frame]) {
        applyCoalesceLock.withLock { lastDragFrames = frames }
        // Positions go out on every event — a WindowServer transaction, no
        // app IPC — and the applier holds its own latest-wins queue for the
        // AX size writes, which are the only part an app can be slow at.
        applier.applyDragFrames(frames: frames, pids: allPids())
        // From the same numbers, in the same breath. An external border
        // process only learns about this move by being notified after the
        // fact and reading the geometry back, which is why its borders trail
        // the window during a drag.
        if bordersBridge.drawsBorders {
            let parked = readParked()
            let live = frames.filter { !parked.contains($0.key) }
            bordersBridge.renderer.update(frames: live, scope: Set(frames.keys))
        }
    }

    /// Run the full frame-set protocol over the drag's final geometry.
    ///
    /// The gesture itself deliberately skips the read-back-and-correct pass,
    /// so this is where an app that quietly refused a size, or landed a few
    /// points off, is put right — once, when the button comes up.
    private func flushPendingApply() {
        let last: [WindowID: Frame]? = applyCoalesceLock.withLock {
            let n = lastDragFrames
            lastDragFrames = nil
            return n
        }
        // A strip whose columns were resized may now be shorter than the
        // screen, or scrolled past its own end. Neither is something the drag
        // path corrects — it deliberately leaves the viewport alone so the
        // border does not slide out from under the cursor — so the correction
        // belongs here, once, when the button comes up, and it supersedes the
        // coalescer's last frame set rather than following it.
        if let sid = currentSID(), case .scroll = readSpaces().layouts[sid] {
            applySpaceLayout(sid, force: true)
            return
        }
        // Forced: the drag moved every window with `SLSMoveWindow`, so the
        // WindowServer already agrees with the target and the usual diff would
        // skip the AX write — leaving each app believing the position it had
        // before the gesture, for the life of the window (S2).
        if let last { applyFrames(last, force: true) }
    }

    /// Republish everything that describes the layout as it is *now*: the
    /// borders the mouse can grab, and the borders the user can see.
    ///
    /// Called from the apply path, so the zones can never describe a layout
    /// that is no longer on screen — a stale zone means a click swallowed
    /// where there is nothing to drag, which is worse than no zones at all.
    /// The window borders come from the same pass because they answer the
    /// same question and computing every visible space's frames twice, on
    /// every apply, is the kind of thing that turns into lag.
    private func refreshDividerZones() {
        let cfg = currentConfig().general
        let wantBorders = bordersBridge.drawsBorders
        guard cfg.mouseBorderResize || wantBorders else {
            dividerLock.withLock { dividerZones = [] }
            input.updateDividerZones([])
            return
        }
        let config = cfg.asTilingConfig()
        var all: [Divider] = []
        var borderFrames: [WindowID: Frame] = [:]
        // One core hop for the whole refresh, not one per space: this runs at
        // the end of every apply, and the core queue is what keybinds wait on.
        let sp = readSpaces()
        let parked = readParked()
        for sid in Set(sp.currentByDisplay.values) {
            guard let layout = sp.layouts[sid] else { continue }
            let screen = usableScreen(onDisplay: sp.displayBySpace[sid])
            let frames: [WindowID: Frame]
            var grabbable = true
            switch layout {
            case .tiling(let tree):
                // A fullscreen window covers its neighbours, so there is no
                // border to grab and every pair overlaps anyway.
                grabbable = tree.fullscreen == nil
                frames = WeftCore.layout(tree, in: screen, config: config)
            case .scroll(let sc):
                grabbable = sc.fullscreen == nil
                frames = scrollLayout(sc, screen: screen, config: config).frames
            case .float(let fl):
                grabbable = false
                // A float space has no computed geometry — the windows are
                // wherever the user put them, so read it.
                frames = liveFrames(of: fl.windows)
            }
            if wantBorders {
                for (wid, frame) in frames where !parked.contains(wid) {
                    borderFrames[wid] = frame
                }
            }
            if grabbable && cfg.mouseBorderResize {
                all += dividers(in: frames, innerGap: cfg.innerGap)
            }
        }
        dividerLock.withLock { dividerZones = all }
        input.updateDividerZones(cfg.mouseBorderResize ? all.map(\.rect) : [])
        // Only windows in a layout, which is what makes menu-bar popovers,
        // Spotlight and every other transient panel border-free without a
        // single heuristic: they were never in a layout to begin with.
        if wantBorders {
            bordersBridge.renderer.update(
                frames: borderFrames, focused: sp.currentSpace.flatMap { sp.layouts[$0]?.focus }
            )
        }
    }

    /// Keybind entry point. Returns immediately (tap-thread safe); the command
    /// runs serialized on `incoming`, sharing handleCommand with the socket.
    func postCommand(_ command: String) {
        incoming.async { [weak self] in
            guard let self else { return }
            let response = self.handleCommand(command)
            if !response.ok {
                fputs("weftd: input command failed: \(response.error ?? command)\n", stderr)
            }
        }
    }

    private func currentSpaceLayoutKind() -> LayoutKind? {
        guard let sid = currentSID(), let l = readSpaces().layouts[sid] else { return nil }
        switch l {
        case .tiling: return .bsp
        case .scroll: return .scroll
        case .float: return .float
        }
    }

    /// Snapshot for the bus/bridges. Runs on every flushed event, so it takes
    /// the core queue exactly once — it used to hop four times per event
    /// (readSpaces + currentSID + currentSpaceLayoutKind + currentLayout×2),
    /// and that contention lands directly on keybind latency.
    private func currentStateSummary() -> StateSummary {
        struct Snap {
            var sid: SpaceID?
            var label: String?
            var kind: LayoutKind?
            var count: Int
            var focus: WindowID?
            var app: String?
            var title: String?
            var pid: Int32?
        }
        let snap: Snap = core.sync {
            let sp = self.spaces
            let sid = sp.currentSpace
            let layout = sid.flatMap { sp.layouts[$0] }
            let focus = layout?.focus
            return Snap(
                sid: sid,
                label: sid.flatMap { sp.labels[$0] },
                kind: layout?.kind,
                count: layout?.windows.count ?? 0,
                focus: focus,
                app: focus.flatMap { self.appNames[$0] },
                title: focus.flatMap { self.windowTitles[$0] },
                pid: focus.flatMap { self.pids[$0] }
            )
        }
        let ctx: WindowContext? = snap.focus.map { wid in
            WindowContext(
                wid: wid,
                app: snap.app,
                bundleID: snap.pid.flatMap { bundleID(for: $0) },
                title: snap.title
            )
        }
        return StateSummary(
            spaceID: snap.sid,
            spaceLabel: snap.label,
            layout: snap.kind,
            windowCount: snap.count,
            focused: ctx,
            mode: input.currentMode
        )
    }

    // MARK: - Screens (one usable rect per display)

    /// Usable rect for the display that owns `sid`, in AX/SLS coordinates
    /// (top-left origin), with the config reserve taken off each edge.
    ///
    /// Every layout computation is keyed by space, because a space belongs to
    /// exactly one display: the previous single rect, derived from
    /// `NSScreen.main`, tiled every space on a second monitor into the first
    /// monitor's frame — off-screen entirely when the second display sits
    /// above or west of the primary.
    ///
    /// An unknown space (unvisited, or a display that vanished mid-command)
    /// falls back to the westmost display rather than failing: a window
    /// somewhere beats a window nowhere.
    private func usableScreen(for sid: SpaceID?) -> Frame {
        usableScreen(onDisplay: sid.flatMap { readSpaces().displayBySpace[$0] })
    }

    private func usableScreen(onDisplay uuid: String?) -> Frame {
        // `reserve` applies to every display, matching `external_bar all:…`
        // — a bar height taken off only the main display is `external_bar
        // main`, which is a config question, not a geometry one.
        let res = currentConfig().general.reserve
        let raw: Frame = screensLock.withLock {
            if let uuid, let f = screensByUUID[uuid] { return f }
            return displayOrder.first.flatMap { screensByUUID[$0] }
                ?? Frame(x: 0, y: 0, width: 1, height: 1)
        }
        return Frame(
            x: raw.x + res.left,
            y: raw.y + res.top,
            width: max(raw.width - res.left - res.right, 1),
            height: max(raw.height - res.top - res.bottom, 1)
        )
    }

    /// Re-read display geometry. Cheap (CG + NSScreen, no WindowServer sweep,
    /// no AX), so every sweep does it — a resolution change, a Dock move or a
    /// monitor being unplugged otherwise leaves layouts sized to a screen that
    /// no longer exists.
    private func refreshScreens() {
        let layout = SpaceControl.displayLayout()
        guard !layout.isEmpty else { return }
        screensLock.withLock {
            screensByUUID = Dictionary(uniqueKeysWithValues: layout.map { ($0.uuid, $0.visible) })
            displayOrder = layout.map { $0.uuid }
        }
    }

    /// Record that `wid` now has focus, and with it which display the user is
    /// on: the display owning the visible space that holds the window.
    ///
    /// This replaces asking SLS for the active menu bar display, which turns
    /// out to be the wrong question. `SLSCopyActiveMenuBarDisplayIdentifier`
    /// is right at startup but only updates on real user interaction — after
    /// weft activates a window itself it keeps reporting the display it last
    /// saw a click on, so `focus display` set it and every following command
    /// read the stale value back. Membership is exact, costs no IPC, and is
    /// information the daemon already has.
    private func noteFocusedWindow(_ wid: WindowID) {
        updateSpaces { sp in
            for sid in sp.visibleSpaces where sp.layouts[sid]?.windows.contains(wid) == true {
                sp.focusedDisplay = sp.displayBySpace[sid]
                return
            }
        }
        // Two repaints, no geometry, no WindowServer sweep. This is the whole
        // cost of following focus when the renderer is in-process.
        bordersBridge.renderer.setFocus(wid)
    }

    /// Display uuids west→east. The order `focus display west|east` counts in.
    private func displaysWestToEast() -> [String] {
        screensLock.withLock { displayOrder }
    }

    /// The display a screen point falls on — used to route mouse gestures to
    /// the right display's current space.
    private func displayUUID(containing point: CGPoint) -> String? {
        screensLock.withLock {
            displayOrder.first {
                screensByUUID[$0]?.contains(x: Double(point.x), y: Double(point.y)) ?? false
            }
        }
    }

    // MARK: - Core access
    //
    // Observers hop to core via async; socket/input handlers run off-core and
    // hop in via sync. Helpers below do the right thing from either context —
    // never sync onto the queue you're already on (libdispatch traps that).

    /// wid → pid, from whichever queue the caller is on.
    private func pid(of wid: WindowID) -> Int32? {
        isOnCore() ? pids[wid] : core.sync { pids[wid] }
    }

    private func allPids() -> [WindowID: Int32] {
        isOnCore() ? pids : core.sync { pids }
    }

    private func isOnCore() -> Bool {
        DispatchQueue.getSpecific(key: coreKey) != nil
    }

    private func readSpaces() -> SpaceState {
        isOnCore() ? spaces : core.sync { spaces }
    }

    private func updateSpaces(_ f: (inout SpaceState) -> Void) {
        if isOnCore() { f(&spaces) } else { core.sync { f(&self.spaces) } }
    }

    /// The space every command means by "the current space": the current
    /// space of the display holding the active menu bar. Anchoring at the
    /// first display instead — which this used to do — sent every keybind to
    /// the built-in screen while the user was working on the external one.
    private func currentSID() -> SpaceID? {
        readSpaces().currentSpace
    }

    private func resolvedInitialLayout(for sid: SpaceID, in sp: SpaceState) -> SpaceLayout {
        if let existing = sp.layouts[sid] { return existing }
        let cfg = currentConfig()
        let kind = sp.overrides[sid]
            ?? cfg.spaces.first(where: { $0.label == (sp.labels[sid] ?? "") })?.layout
            ?? cfg.general.defaultLayout
        switch kind {
        case .scroll: return .scroll(ScrollState())
        case .float: return .float(FloatState())
        case .bsp: return .tiling(Tree())
        }
    }

    /// Current space's layout (dual-context). Absent (unvisited) reads as an
    /// empty layout matching space/default config — sync fills it in.
    private func currentLayout() -> SpaceLayout {
        let sp = readSpaces()
        guard let sid = sp.currentSpace else { return .tiling(Tree()) }
        return sp.layouts[sid] ?? resolvedInitialLayout(for: sid, in: sp)
    }

    private func storeLayout(_ layout: SpaceLayout) {
        updateSpaces { sp in
            if let sid = sp.currentSpace {
                sp.layouts[sid] = layout
            }
        }
    }

    // MARK: - Membership

    /// Rebuild per-space membership from a fresh WindowServer snapshot:
    /// insert new windows (id order) into each space's tree, drop gone ones,
    /// bind AX + apply layouts for CURRENT spaces only (S0: other spaces'
    /// windows aren't AX-enumerable — their layouts compute now and apply on
    /// space_changed). Safe to call from any thread.
    func syncFromSnapshot(initial: Bool = false) {
        // ── Phase 1 (off-core): read the world. No lock, no queue held. ──
        dispatchPrecondition(condition: .notOnQueue(core))
        let t0 = Date()
        let world = WorldReader.snapshot()
        let tRead = Date()
        refreshScreens()
        let cfg = currentConfig()
        // sid → display, and the display keyboard focus is on. Both are read
        // here, off-core, because `activeDisplayUUID` is a WindowServer round
        // trip and the core queue is what every keybind waits on.
        var displayBySpace: [SpaceID: String] = [:]
        for space in world.spaces { displayBySpace[space.id] = space.displayUUID }
        let focusedDisplay = SpaceControl.activeDisplayUUID(
            known: Set(world.displays.map { $0.uuid })
        )
        // Mission Control order: display-major, then SLS order within each
        // display — exactly how the user counts desktops, and how yabai
        // numbers them. `world.spaces` is already built in that order and
        // fullscreen spaces are filtered out by WorldReader (§11 risk 6).
        let liveSids = Set(world.spaces.map { $0.id })
        let allSids = world.displays.flatMap { $0.spaces.filter(liveSids.contains) }
        let worldWids = Set(world.windows.map { $0.id })
        let worldPids = Set(world.windows.map { $0.pid })
        // Bundle ids come from NSRunningApplication; resolve them before
        // taking the core queue so a slow lookup is not everyone's problem.
        var bundles: [Int32: String?] = [:]
        for pid in worldPids { bundles[pid] = bundleID(for: pid) }
        // Classify windows we have not seen before. One AX read each, here in
        // phase 1 where AX is allowed, never on the core queue (§13.2).
        let (unclassified, visibleSids, sinceSnapshot) = core.sync {

            (
                world.windows.filter { self.standardWindow[$0.id] == nil },
                Set(self.spaces.visibleSpaces),
                self.unbindableSince
            )
        }
        var freshlyClassified: [WindowID: Bool] = [:]
        var freshUnbindable: [WindowID: Date] = [:]
        let now = Date()
        // One fan-out for the whole sweep. Asking window by window meant a
        // cold start walked every app in series before anything was tiled.
        let tClassify0 = Date()
        let verdicts = applier.classifyBatch(unclassified.map { (wid: $0.id, pid: $0.pid) })
        let tClassify = Date()
        for w in unclassified {
            if let verdict = verdicts[w.id] {
                switch verdict {
                case .success:
                    freshlyClassified[w.id] = true
                case .failure(let why):
                    freshlyClassified[w.id] = false
                    fputs("weftd: floating \(w.app) (\(w.id)) — \(Self.reason(why))\n", stderr)
                }
                continue
            }
            // No AX element at all. On a space that is NOT visible this means
            // nothing — S0, the window is simply not enumerable yet. On a
            // visible space it is the signature of something that is not a
            // window: Stats' 280x674 panel passes every CGWindowList filter
            // weft had (layer 0, both dimensions over 100px) and got tiled
            // next to the user's terminal.
            guard !Set(w.spaces).isDisjoint(with: visibleSids) else { continue }
            let first = sinceSnapshot[w.id] ?? now
            freshUnbindable[w.id] = first
            if now.timeIntervalSince(first) >= 1.0 {
                freshlyClassified[w.id] = false
                fputs("weftd: ignoring \(w.app) (\(w.id)) — on screen but AX cannot see it\n", stderr)
            }
        }
        // One usable rect per space, not one for the machine: the split axis
        // a new window picks depends on the shape of the slot it lands in,
        // and that shape is the shape of *its own* display.
        var usableBySpace: [SpaceID: Frame] = [:]
        for (sid, uuid) in displayBySpace {
            usableBySpace[sid] = usableScreen(onDisplay: uuid)
        }

        // ── Phase 2 (on core, microseconds): swap the authoritative state. ──
        // Rule-driven space moves are *collected* here and performed in phase
        // 3: each one is a socket round trip plus a settle sleep, which has no
        // business running on the queue every keybind synchronises on.
        struct RuleMove { let wid: WindowID; let app: String; let sid: SpaceID; let label: String }
        var pendingMoves: [RuleMove] = []
        let (currentSids, visible, total) = core.sync { () -> (Set<SpaceID>, [WindowInfo], Int) in
            var sp = self.spaces
            if sp.labels.isEmpty {
                // Fresh launch: seed names from weft.toml [[space]] decls so a
                // first config just works; falls back to labels.json, then numerics.
                // Delete labels.json to re-adopt the config's names wholesale.
                let declared = cfg.spaces.map { $0.label }
                sp.assignLabels(sids: allSids, names: declared.isEmpty ? Daemon.loadLabels() : declared)
                sp.assignOverrides(sids: allSids, kinds: Daemon.loadLayoutOverrides())
            } else {
                // Desktops added/removed at runtime: keep every existing label,
                // but re-derive the ordinal list so `space focus 3` still means
                // the third desktop on screen.
                sp.order = allSids
                for (i, sid) in allSids.enumerated() where sp.labels[sid] == nil {
                    sp.labels[sid] = "\(i + 1)"
                }
                for sid in sp.labels.keys where !liveSids.contains(sid) {
                    sp.labels.removeValue(forKey: sid)
                }
            }
            let oldCurrent = sp.currentSpace
            sp.displays = world.displays.map { $0.uuid }
            sp.currentByDisplay = Dictionary(
                uniqueKeysWithValues: world.displays.map { ($0.uuid, $0.currentSpace) }
            )
            sp.displayBySpace = displayBySpace
            // Seed only. The menu-bar display is right at startup but stale
            // afterwards (see noteFocusedWindow), so it must not overwrite a
            // display that focus tracking has since established — and it must
            // still rescue us when the tracked display is unplugged.
            if sp.focusedDisplay == nil || sp.currentByDisplay[sp.focusedDisplay!] == nil {
                sp.focusedDisplay = focusedDisplay
            }
            let newCurrent = sp.currentSpace
            if let old = oldCurrent, let nw = newCurrent, old != nw {
                sp.recentSpace = old
            }
            // Invert window→spaces into per-space membership (all spaces, not
            // just current — unvisited spaces compute layouts blind). Rules +
            // quirks filter unmanaged windows out of every layout (M6).
            self.strikes = self.strikes.filter { worldWids.contains($0.key) }
            self.appNames = self.appNames.filter { worldWids.contains($0.key) }
            self.windowTitles = self.windowTitles.filter { worldWids.contains($0.key) }
            self.bundleLock.withLock {
                self.bundleCache = self.bundleCache.filter { worldPids.contains($0.key) }
            }
            self.pids = self.pids.filter { worldWids.contains($0.key) }
            self.standardWindow = self.standardWindow.filter { worldWids.contains($0.key) }
            for (wid, standard) in freshlyClassified { self.standardWindow[wid] = standard }
            self.unbindableSince = self.unbindableSince.filter {
                worldWids.contains($0.key) && self.standardWindow[$0.key] == nil
            }
            for (wid, first) in freshUnbindable where self.standardWindow[wid] == nil {
                self.unbindableSince[wid] = first
            }
            self.spaceMoveAttempts = self.spaceMoveAttempts.intersection(worldWids)
            var bySpace: [SpaceID: [WindowID]] = [:]
            var unmanagedNow: Set<WindowID> = []
            for w in world.windows {
                self.pids[w.id] = w.pid
                self.appNames[w.id] = w.app
                self.windowTitles[w.id] = w.title
                // Not a standard window (a menu-bar extra's panel, a
                // system popover): never tile it, never let it take a slot.
                // Unclassified windows fall through and are managed — a cold
                // AX read on an unvisited space says nothing (S0), and
                // guessing "no" there would unmanage the whole space.
                if self.standardWindow[w.id] == false {
                    unmanagedNow.insert(w.id)
                    continue
                }
                let bundle = bundles[w.pid] ?? nil
                if let b = bundle, Daemon.autoFloatBundles.contains(b) {
                    unmanagedNow.insert(w.id)
                    continue
                }
                if let outcome = matchRules(cfg.rules, app: w.app, bundleID: bundle, title: w.title) {
                    if !outcome.manage {
                        unmanagedNow.insert(w.id)
                        continue
                    }
                    // Resolve against the in-progress labels (just seeded
                    // above), not the still-unwritten global — otherwise
                    // first-sync moves always miss with "unknown space".
                    if let target = outcome.space, !self.spaceMoveAttempts.contains(w.id) {
                        self.spaceMoveAttempts.insert(w.id)
                        if let sid = sp.resolveSpace(target) {
                            pendingMoves.append(RuleMove(wid: w.id, app: w.app, sid: sid, label: target))
                        } else {
                            fputs("weftd: rule wants '\(w.app)' (\(w.id)) on unknown space '\(target)'\n", stderr)
                        }
                    }
                }
                if self.strikes[w.id, default: 0] >= 2 {
                    unmanagedNow.insert(w.id)
                    continue
                }
                for sid in w.spaces { bySpace[sid, default: []].append(w.id) }
            }
            for wid in unmanagedNow.subtracting(self.unmanaged).sorted() {
                fputs("weftd: floating \(wid) (rule/quirk — excluded from layouts)\n", stderr)
            }
            self.manualFloat = self.manualFloat.intersection(worldWids)
            self.floatFrames = self.floatFrames.filter { worldWids.contains($0.key) }
            unmanagedNow.formUnion(self.manualFloat)
            self.unmanaged = unmanagedNow
            let priorKeys = Set(sp.layouts.keys)
            let (synced, _) = syncMembership(
                sp, spaces: bySpace, live: liveSids,
                screens: usableBySpace, config: cfg.general.asTilingConfig()
            )
            sp = synced
            // Spaces seen for the first time this launch take the layout the
            // user last chose for them, else the `[[space]]` declaration, else
            // the general default. A space that already had a layout keeps it:
            // this branch is seeding, not enforcement.
            for sid in liveSids where !priorKeys.contains(sid) {
                let label = sp.labels[sid] ?? ""
                let kind = sp.overrides[sid]
                    ?? cfg.spaces.first(where: { $0.label == label })?.layout
                    ?? cfg.general.defaultLayout
                self.convertLayout(&sp, sid: sid, to: kind)
                // A space seeded straight into scroll never passed through a
                // conversion, so this is the only place its declared centre
                // mode can be stamped on.
                self.applyScrollSettings(&sp, sid: sid)
            }
            self.spaces = sp
            let currentSids = Set(sp.currentByDisplay.values)
            let visible = world.windows.filter { !Set($0.spaces).isDisjoint(with: currentSids) }
            let total = sp.layouts.values.reduce(0) { $0 + $1.windows.count }
            return (currentSids, visible, total)
        }

        // ── Phase 3 (off-core): privileged calls, AX binding, frame writes. ──
        // A window waiting out the "on screen but AX cannot see it" timer needs
        // a sweep after the timer expires to actually be judged. Nothing else
        // guarantees one — a popover that opens while the desktop is otherwise
        // idle produces no further events — so the verdict would never land and
        // it would stay tiled. One shot, cancellable, no steady-state polling.
        if !freshUnbindable.isEmpty {
            pendingClassify?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.syncFromSnapshot() }
            pendingClassify = work
            syncQueue.asyncAfter(deadline: .now() + 1.1, execute: work)
        }
        // Rule moves happen here, in phase 3 — *after* phase 2 has already
        // filed each window under the space SLS reported for it. So a window a
        // rule relocates is, from this moment, laid out by the wrong space's
        // tree, and moving a window between spaces produces no event that would
        // bring us back. The membership stayed wrong for the life of the
        // window: two terminals filed under different spaces both computed the
        // east half of their own layout and landed on exactly the same pixels,
        // one invisible underneath the other.
        //
        // Re-sync once the moves have settled. `spaceMoveAttempts` already caps
        // each window at one move for its lifetime, so the extra pass cannot
        // move anything again and cannot feed itself.
        var moved = false
        for m in pendingMoves {
            moved = attemptRuleMoveToSid(wid: m.wid, app: m.app, sid: m.sid, label: m.label) || moved
        }
        if moved {
            pendingRuleResync?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.syncFromSnapshot() }
            pendingRuleResync = work
            syncQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        let tBind0 = Date()
        applier.bind(windows: visible.map { (wid: $0.id, pid: $0.pid) })
        applier.forget(keeping: worldWids)
        // Same reason as `forgetWindow`, for the windows that died without a
        // destroyed notification we ever saw — and for whatever `parked.json`
        // restored at launch that no longer exists.
        forgetParked(readParked().subtracting(worldWids))
        let tBind = Date()
        // Only the display the user is actually on may raise anything.
        //
        // Raising calls `NSRunningApplication.activate()`, and with two
        // displays this loop raised the focused window of *each* visible
        // space — so the two monitors took it in turns to activate their own
        // window, every activation posted a focused-window notification, and
        // every one of those scheduled another sweep. The daemon sat there
        // flipping focus between two windows on two displays forever, with
        // nobody touching the machine. It is in the log as an unbroken
        // alternation of `windowFocused` between the same two window ids.
        let focusedSID = readSpaces().currentSpace
        for sid in currentSids.sorted() {
            applySpaceLayout(sid, raiseFocus: sid == focusedSID)
        }
        watchCurrent()
        bus.emit(stateChangedEvent())
        if initial {
            let geometry = displaysWestToEast().enumerated().map { i, uuid -> String in
                let f = usableScreen(onDisplay: uuid)
                let mark = uuid == focusedDisplay ? "*" : ""
                return "\(i + 1)\(mark) \(Int(f.width))x\(Int(f.height))@\(Int(f.x)),\(Int(f.y))"
            }.joined(separator: " ")
            func ms(_ a: Date, _ b: Date) -> Int { Int(b.timeIntervalSince(a) * 1000) }
            fputs("weftd: displays \(geometry) spaces \(currentSids.count) current, \(allSids.count) total, windows \(total)\n", stderr)
            // Where a restart actually goes. Reading the WindowServer is
            // cheap; the two AX phases are not, and both are the kind of cost
            // that grows with how many apps are open — so a number here is
            // the difference between "weft is slow to start" and a fix.
            fputs(
                "weftd: first sweep \(ms(t0, Date()))ms "
                    + "(world \(ms(t0, tRead))ms, classify \(unclassified.count) "
                    + "\(ms(tClassify0, tClassify))ms, bind \(ms(tBind0, tBind))ms)\n",
                stderr
            )
        }
    }

    private func writeSpaces(_ next: SpaceState) {
        updateSpaces { $0 = next }
    }

    /// Drop a dead window from every layout and every side table, right now.
    /// Waiting for the next sweep left the survivors holding the dead
    /// window's half of the split for as long as the sweep took.
    private func forgetWindow(_ wid: WindowID) {
        updateSpaces { sp in
            for (sid, layout) in sp.layouts {
                switch layout {
                case .tiling(let t) where t.windows.contains(wid):
                    sp.layouts[sid] = .tiling(t.removing(wid))
                case .scroll(let s) where s.windows.contains(wid):
                    sp.layouts[sid] = .scroll(s.removing(wid))
                case .float(let f) where f.windows.contains(wid):
                    sp.layouts[sid] = .float(f.removing(wid))
                default:
                    break
                }
            }
        }
        core.sync {
            self.pids.removeValue(forKey: wid)
            self.appNames.removeValue(forKey: wid)
            self.windowTitles.removeValue(forKey: wid)
            self.strikes.removeValue(forKey: wid)
            self.standardWindow.removeValue(forKey: wid)
            self.unbindableSince.removeValue(forKey: wid)
            self.manualFloat.remove(wid)
            self.floatFrames.removeValue(forKey: wid)
            self.unmanaged.remove(wid)
        }
        // A dead window is not a parked window. Leaving it in the tracked set
        // put a stale id in `parked.json` forever, and the WindowServer
        // recycles ids: the next window handed this number was believed
        // already parked, so the one call that would have moved it off screen
        // — `reconcileParked`'s diff — never fired for it.
        forgetParked([wid])
        observers.forgetWindow(wid)
    }

    /// Drop window ids from the tracked-parked set and persist.
    private func forgetParked(_ wids: Set<WindowID>) {
        let changed: Bool = parkedLock.withLock {
            let next = parkedWindows.subtracting(wids)
            guard next != parkedWindows else { return false }
            parkedWindows = next
            return true
        }
        if changed { saveParked() }
    }

    private func watchCurrent() {
        let sp = readSpaces()
        let pids = self.pids
        let currentSids = Set(sp.currentByDisplay.values)
        let wids = sp.layouts
            .filter { currentSids.contains($0.key) }
            .flatMap { $0.value.windows }
        observers.watch(
            pids: Array(Set(pids.values)),
            windows: wids.compactMap { wid in pids[wid].map { (wid, $0) } }
        )
    }

    // MARK: - Observer events (always on core)

    /// Trailing-edge delayed resync: newborn windows may report no spaces
    /// and no AX element in the first sync after creation — one quiet
    /// follow-up heals both without polling in steady state. 0.3s is the
    /// measured compromise: the tile visibly lands fast, and SLS/AX have
    /// settled by then.
    private var pendingResync: DispatchWorkItem?
    /// Leading debounce for world resyncs. One app launch fires
    /// windowCreated + appLaunched + focusChanged within a few milliseconds,
    /// and each of those used to run a full WindowServer sweep *plus* schedule
    /// a second one — six sweeps for one new window. Both timers live on
    /// `syncQueue` and are only touched from it, so no lock is needed.
    private var pendingFastSync: DispatchWorkItem?
    /// Coalesced trailing apply for user drags. Direct `applyCurrentSpace()`
    /// on every Moved/Resized fought the user's hand (retile mid-drag) and,
    /// combined with unconditional focusAndWarp, looked like windows "moving
    /// by themselves". Now drags settle first, then we tile once.
    private var pendingDragApply: DispatchWorkItem?
    /// One-shot re-check for windows still inside the unbindable grace period.
    private var pendingClassify: DispatchWorkItem?
    /// Follow-up sweep after a rule relocates a window, so layout membership
    /// catches up with where the window actually is.
    private var pendingRuleResync: DispatchWorkItem?
    /// Trailing re-apply after `space move-window`, for the size write an app
    /// drops while it is still changing spaces.
    private var pendingMoveSettle: DispatchWorkItem?

    /// Request a world resync. `fast` collapses the current burst into a single
    /// sweep ~20 ms out; the 0.3 s trailing sweep always follows, because a
    /// newborn window reports no spaces and no AX element until SLS settles.
    private func scheduleSync(fast: Bool = true) {
        if fast {
            pendingFastSync?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.syncFromSnapshot() }
            pendingFastSync = work
            syncQueue.asyncAfter(deadline: .now() + 0.02, execute: work)
        }
        pendingResync?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncFromSnapshot() }
        pendingResync = work
        syncQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func scheduleDragSettleApply() {
        pendingDragApply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyCurrentSpace()
            self.bus.emit(self.stateChangedEvent())
        }
        pendingDragApply = work
        syncQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func handleObserverEvent(_ event: ObserverEvent) {
        switch event {
        case .windowCreated(let pid):
            bus.emit(DaemonEvent(kind: .windowCreated, app: "pid=\(pid)"))
            scheduleSync()
        case .windowDestroyed(let wid):
            bus.emit(DaemonEvent(kind: .windowDestroyed, window: wid))
            // Drop the window from every layout immediately so the survivors
            // expand on this frame instead of waiting for the sweep — the
            // "close doesn't expand" lag. The sweep then reconciles: destroy
            // notifications race the WindowServer list, so the dead wid can
            // still appear in CGWindowList for a moment.
            forgetWindow(wid)
            applyCurrentSpace()
            bus.emit(stateChangedEvent())
            scheduleSync()
        case .windowMoved(let wid), .windowResized(let wid):
            // Our own writes echo back as moved/resized notifications (classic
            // tiling-WM feedback loop, §11 risk 7). Drop them; a genuine user
            // drag settles first and THEN retiles once (trailing edge), so we
            // never fight the hand mid-drag.
            if let actual = WorldReader.frame(of: wid),
               applier.isEcho(wid: wid, frame: actual)
            {
                return
            }
            scheduleDragSettleApply()
        case .windowFocused(let wid):
            guard let wid else { return }
            // Focus may have crossed to the other display; resolve that
            // before asking whether the window is in "the current" layout.
            noteFocusedWindow(wid)
            // Unknown window: a close whose destroyed notification we missed,
            // a creation the sweep hasn't seen, or simply an unmanaged/float
            // window. This used to run a full WindowServer sweep inline —
            // on the queue every keybind blocks on — which is where the focus
            // lag came from. Ask for a coalesced sweep and return now.
            //
            // "Unknown" means unknown to *any* space on screen, not to the
            // current one. Asking only the current space meant that with two
            // displays attached, every click on the other monitor was a
            // window weft had never heard of and cost a full WindowServer
            // sweep — on a two-display desktop that is most focus changes.
            let sp0 = readSpaces()
            guard let homeSID = sp0.visibleSpaces.first(where: {
                sp0.layouts[$0]?.windows.contains(wid) == true
            }) else {
                scheduleSync()
                return
            }
            updateSpaces { sp in
                guard let layout = sp.layouts[homeSID] else { return }
                let sid = homeSID
                switch layout {
                case .tiling(let t):
                    guard t.windows.contains(wid) else { return }
                    sp.layouts[sid] = .tiling(t.focusing(wid))
                case .scroll(let s):
                    guard s.windows.contains(wid) else { return }
                    sp.layouts[sid] = .scroll(s.focusing(wid))
                case .float(let f):
                    guard f.windows.contains(wid) else { return }
                    sp.layouts[sid] = .float(f.focusing(wid))
                }
            }
            bus.emit(DaemonEvent(kind: .windowFocused, window: wid))
            bus.emit(stateChangedEvent())
        case .appLaunched(let pid, let bundleID):
            bus.emit(DaemonEvent(kind: .appLaunched, app: "\(bundleID) pid=\(pid)"))
            scheduleSync()
        case .appTerminated(let pid, let bundleID):
            bus.emit(DaemonEvent(kind: .appTerminated, app: "\(bundleID) pid=\(pid)"))
            applier.forgetApp(pid: pid)
            observers.forgetApp(pid: pid)
            WorldReader.forgetOwner(pid: pid)
            scheduleSync()  // same dead-wid-lingers race as windowDestroyed
        case .spaceChanged:
            // Closes the S0 cold-start gap: windows on a newly visited space
            // become AX-bindable here (apply-on-space_changed, §5.0). Runs
            // inline: the user is looking at the new space right now, so this
            // is the one event that must not wait out a debounce.
            bordersBridge.renderer.clearOnSpaceChange()
            // A pan is motion the user is watching. They are not watching this
            // space any more, so it arrives now rather than being abandoned
            // half-way across a screen nobody is looking at.
            panAnimator.finish()
            bus.emit(DaemonEvent(kind: .spaceChanged))
            syncFromSnapshot()
        case .displayChanged:
            // Geometry first: a resolution change or an unplug leaves every
            // layout sized to a screen that no longer exists, and the sweep
            // below computes frames from these rects.
            refreshScreens()
            // Every stored strip render describes a screen that may no longer
            // exist, and a pan in flight is interpolating towards a viewport
            // computed from it.
            panAnimator.finish()
            forgetScrollRender()
            // Scale factors and geometry both changed; every overlay's
            // backing store is sized for a display that may not be there.
            bordersBridge.renderer.clearOnSpaceChange()
            bus.emit(DaemonEvent(kind: .displayChanged))
            syncFromSnapshot()
        }
    }

    // MARK: - Socket handling

    func handle(line: String, conn: IPCConnection) {
        let text: String
        if let data = line.data(using: .utf8),
           let req = try? JSONDecoder().decode(IPCRequest.self, from: data)
        {
            text = req.command
        } else {
            text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Streaming verb: hold the connection open, push bus events.
        if text == "subscribe" || text.hasPrefix("subscribe ") {
            guard subscribeFilters(text) != nil else {
                send(conn, IPCResponse(ok: false, error: "usage: subscribe [--all | kinds...]"))
                conn.close()
                return
            }
            conn.detach()
            hub.add(conn)
            fputs("weftd: subscriber added (\(hub.count))\n", stderr)
            bus.emit(stateChangedEvent())  // instant proof the stream is live
            return
        }

        send(conn, handleCommand(text))
    }

    private func send(_ conn: IPCConnection, _ response: IPCResponse) {
        if let data = try? JSONEncoder().encode(response),
           let str = String(data: data, encoding: .utf8)
        {
            conn.send(str)
        } else {
            conn.send(#"{"ok":false,"error":"encode failed"}"#)
        }
    }

    /// Validates `subscribe` filter args. M2 streams everything (filters land
    /// with the sketchybar bridge in M6.5); unknown kinds are rejected early.
    private func subscribeFilters(_ text: String) -> [String]? {
        let parts = text.split(separator: " ").map(String.init)
        guard parts.first == "subscribe" else { return nil }
        let known: Set<String> = [
            "--all", "windowCreated", "windowDestroyed", "windowFocused",
            "spaceChanged", "appLaunched", "appTerminated", "displayChanged",
            "stateChanged", "modeChanged",
        ]
        let filters = Array(parts.dropFirst())
        if filters.isEmpty || filters == ["--all"] { return [] }
        guard filters.allSatisfy({ known.contains($0) }) else { return nil }
        return filters
    }

    private func activeWindowID() -> WindowID? {
        if let f = currentLayout().focus { return f }
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let pid = frontApp.processIdentifier
            let world = WorldReader.snapshot()
            if let w = world.windows.first(where: { $0.pid == pid && self.manualFloat.contains($0.id) }) {
                return w.id
            }
        }
        return nil
    }

    private func handleFloat(_ mode: StickyMode) -> IPCResponse {
        guard let wid = activeWindowID() else {
            return IPCResponse(ok: false, error: "no focused window to float")
        }
        let isManual = manualFloat.contains(wid)
        switch mode {
        case .on where isManual:
            return IPCResponse(ok: true, output: "window \(wid) already floating")
        case .off where !isManual:
            return IPCResponse(ok: true, output: "window \(wid) already tiled")
        default:
            break
        }
        if isManual {
            // Snapshot where the user had it before the layout reclaims it,
            // so floating it again lands back in the same place.
            if let live = WorldReader.frame(of: wid) { floatFrames[wid] = live }
            manualFloat.remove(wid)
            unmanaged.remove(wid)
            if let sid = currentSID() {
                updateSpaces { sp in
                    switch sp.layouts[sid] ?? self.resolvedInitialLayout(for: sid, in: sp) {
                    case .tiling(var t):
                        t = t.inserting(wid)
                        sp.layouts[sid] = .tiling(t)
                    case .scroll(var s):
                        s = s.inserting(wid)
                        sp.layouts[sid] = .scroll(s)
                    case .float(var f):
                        f = f.inserting(wid)
                        sp.layouts[sid] = .float(f)
                    }
                }
                applySpaceLayout(sid)
            }
            bus.emit(stateChangedEvent())
            return IPCResponse(ok: true, output: "window \(wid) tiled")
        } else {
            manualFloat.insert(wid)
            unmanaged.insert(wid)
            if let sid = currentSID() {
                updateSpaces { sp in
                    switch sp.layouts[sid] ?? self.resolvedInitialLayout(for: sid, in: sp) {
                    case .tiling(var t):
                        t = t.removing(wid)
                        sp.layouts[sid] = .tiling(t)
                    case .scroll(var s):
                        s = s.removing(wid)
                        sp.layouts[sid] = .scroll(s)
                    case .float(var f):
                        f = f.removing(wid)
                        sp.layouts[sid] = .float(f)
                    }
                }
                applySpaceLayout(sid)
            }
            // Where the user last left this window floating, if they ever
            // did. Floating a window, moving it, tiling it and floating it
            // again used to snap it back to the centre every time — the
            // second float threw away the whole arrangement the first one
            // was for. Fall back to a centred 70% only the first time.
            let uScreen = usableScreen(for: currentSID())
            let target = floatFrames[wid].flatMap { remembered -> Frame? in
                // Ignore geometry from a screen this window is no longer on.
                let cx = remembered.x + remembered.width / 2
                let cy = remembered.y + remembered.height / 2
                return uScreen.contains(x: cx, y: cy) ? remembered : nil
            } ?? Frame(
                x: uScreen.x + uScreen.width * 0.15,
                y: uScreen.y + uScreen.height * 0.15,
                width: uScreen.width * 0.70,
                height: uScreen.height * 0.70
            )
            applyFrames([wid: target])
            raiseFronts([wid])
            if let pid = pids[wid] {
                focusAndWarp(window: wid, pid: pid)
            }
            bus.emit(stateChangedEvent())
            return IPCResponse(ok: true, output: "window \(wid) floating")
        }
    }

    /// Focus one window by id, from anywhere.
    ///
    /// The reducer's `setFocus` only ever looked inside the *current* space's
    /// layout and did nothing otherwise, which is most of what the window
    /// switcher lists: picking a window on another desktop silently did
    /// nothing at all. Switch to its space first, then focus it — and handle
    /// floats and unmanaged windows, which are in no layout to be found in.
    private func handleFocusWindow(_ wid: WindowID) -> IPCResponse {
        let sp = readSpaces()
        // Which space holds it: layouts first (cheap), then the WindowServer
        // for windows weft does not manage.
        var home: SpaceID? = sp.layouts.first { $0.value.windows.contains(wid) }?.key
        if home == nil {
            home = WorldReader.snapshot().windows
                .first { $0.id == wid }?.spaces.first
        }
        guard let sid = home else {
            return IPCResponse(ok: false, error: "no such window \(wid)")
        }
        if !sp.currentByDisplay.values.contains(sid) {
            let label = sp.labels[sid] ?? "\(sid)"
            let switched = handleSpace(.focus(label))
            guard switched.ok else { return switched }
        }
        guard let pid = pid(of: wid) else {
            return IPCResponse(ok: false, error: "window \(wid) has no process")
        }
        updateSpaces { s in
            guard let layout = s.layouts[sid] else { return }
            switch layout {
            case .tiling(let t) where t.windows.contains(wid):
                s.layouts[sid] = .tiling(t.focusing(wid))
            case .scroll(let sc) where sc.windows.contains(wid):
                s.layouts[sid] = .scroll(sc.focusing(wid))
            case .float(let f) where f.windows.contains(wid):
                s.layouts[sid] = .float(f.focusing(wid))
            default:
                break
            }
        }
        applySpaceLayout(sid)
        raiseFronts([wid])
        focusAndWarp(window: wid, pid: pid)
        bus.emit(stateChangedEvent())
        return IPCResponse(ok: true, output: "focused \(wid)")
    }

    private func handleCommand(_ text: String) -> IPCResponse {
        // Socket and keybind handlers always run off-core (bg threads and the
        // incoming queue); the core.sync below would trap on-core. Fail fast
        // if that invariant ever breaks instead of deadlocking.
        dispatchPrecondition(condition: .notOnQueue(core))
        switch text {
        case "sync":
            syncFromSnapshot()
            return IPCResponse(ok: true, output: describe())
        case "retile":
            // Explicit user request: forgive quirked windows and let them back
            // into the layout. Without this, `retile` was powerless against
            // exactly the situation the user reaches for it in.
            forgiveQuirks()
            syncFromSnapshot()
            if let sid = currentSID() {
                applySpaceLayout(sid)
            }
            bus.emit(stateChangedEvent())
            return IPCResponse(ok: true, output: describe())
        case "rescue":
            // Crash debris sweep (§11 risk 3): unpark stranded windows.
            let report = rescue()
            fputs("weftd: \(report)\n", stderr)
            return IPCResponse(ok: true, output: report)
        default:
            break
        }

        if text.hasPrefix("query") {
            return handleQuery(text)
        }

        let command: Command
        do {
            command = try Command.parse(text)
        } catch {
            return IPCResponse(ok: false, error: "parse: \(error)")
        }
        if case .query = command {
            return handleQuery(text)
        }
        return dispatch(command)
    }

    /// Everything past parsing. Split out so the mouse paths — which know
    /// exactly what they mean — can call it without building a string and
    /// parsing it back. A drag emits one of these per mouse event, and
    /// `resize right 3.0` → tokenize → parse → enum was pure overhead on the
    /// one path where it happened a hundred times a second.
    private func dispatch(_ command: Command) -> IPCResponse {
        dispatchPrecondition(condition: .notOnQueue(core))
        if case .space(let sub) = command {
            return handleSpace(sub)
        }
        if case .sticky(let widOpt, let mode) = command {
            return handleSticky(widOpt, mode)
        }
        if case .focusDisplay(let target) = command {
            return handleFocusDisplay(target)
        }
        if case .moveWindowToDisplay(let target, let follow) = command {
            return handleMoveWindowToDisplay(target, follow: follow)
        }
        if case .moveSpaceToDisplay(let target) = command {
            return handleMoveSpaceToDisplay(target)
        }
        if case .appToggle(let bundleID) = command {
            return handleAppToggle(bundleID)
        }
        if case .float(let mode) = command {
            return handleFloat(mode)
        }
        if case .setFocus(let wid) = command {
            return handleFocusWindow(wid)
        }

        let outcome = reduceOnCore(command)
        let frames = outcome.frames
        // Fire and forget: the keybind is done as soon as the writes are
        // queued. Z-order and focus follow on the same per-pid queues, so
        // they still land after the frames for each window.
        var animating = false
        if let strip = outcome.scroll, !frames.isEmpty {
            switch renderScroll(
                sid: strip.sid, state: strip.state, screen: strip.screen,
                config: strip.config, settled: frames, parkedNow: outcome.parkedNow
            ) {
            case .animating:
                animating = true
            case .settle(let force):
                applyFrames(frames, force: force)
                outcome.reconcileParked(on: self, frames: frames)
            }
        } else {
            applyFrames(frames)
            outcome.reconcileParked(on: self, frames: frames)
        }
        raiseFronts(outcome.raises)
        if let focus = outcome.focus, let pid = pid(of: focus) {
            focusAndWarp(window: focus, pid: pid, target: frames[focus])
        }
        // The borders moved with the windows. A stale grab zone is a click
        // swallowed where there is nothing to drag. A pan rebuilds them when
        // it lands instead — the zones have to describe where the windows
        // stop, not where they are passing through.
        if !frames.isEmpty && !animating { refreshDividerZones() }
        bus.emit(stateChangedEvent())
        return IPCResponse(ok: true, output: "\(describe()) dispatched=\(frames.count)")
    }

    /// What reducing one command produced, before anything is written.
    ///
    /// `parkedNow`/`scope` are non-empty only for scroll spaces: every command
    /// that changes the strip changes which columns are on screen, and
    /// reconciling that used to happen exclusively in `applySpaceLayout`.
    /// Nothing on the command path called it, so a resize or a column focus
    /// left newly-hidden columns unparked — sitting on screen at their last
    /// frame, underneath the columns still visible — and newly-revealed
    /// columns still at -5000.
    private struct ReduceOutcome {
        var frames: [WindowID: Frame] = [:]
        var focus: WindowID?
        var raises: [WindowID] = []
        /// The strip this command left behind, for the pan animator. Nil for
        /// every other layout kind, and for a command that changed nothing.
        var scroll: (sid: SpaceID, state: ScrollState, screen: Frame, config: TilingConfig)?
        var parkedNow: Set<WindowID> = []
        var scope: Set<WindowID> = []

        func reconcileParked(on daemon: Daemon, frames: [WindowID: Frame]) {
            guard !scope.isEmpty else { return }
            daemon.reconcileParked(parkedNow: parkedNow, frames: frames, scope: scope)
        }
    }

    /// Reduce one command against the current space and commit the new layout
    /// state. Writes nothing to the screen — the caller decides whether the
    /// frames go out immediately (a keybind) or through the drag coalescer.
    private func reduceOnCore(_ command: Command) -> ReduceOutcome {
        dispatchPrecondition(condition: .notOnQueue(core))
        var strip: (sid: SpaceID, state: ScrollState, screen: Frame, config: TilingConfig)?
        let (mutations, parkedNow, scope):
            ([Mutation], Set<WindowID>, Set<WindowID>) = core.sync {
            let sid = self.spaces.currentSpace
            let tile = self.currentConfig().general.asTilingConfig()
            let uScreen = self.usableScreen(for: sid)
            switch sid.flatMap({ self.spaces.layouts[$0] }) ?? .tiling(Tree()) {
            case .tiling(let tree):
                let cur = State(tree: tree, screen: uScreen, config: tile)
                let (n, m) = Reducer.reduce(cur, command)
                if let sid { self.spaces.layouts[sid] = .tiling(n.tree) }
                return (m, [], [])
            case .scroll(let sc):
                let (n, m) = Reducer.reduceScroll(
                    sc, screen: uScreen, config: tile, command: command,
                    presets: sid.map { self.scrollPresets(for: $0, in: self.spaces) }
                        ?? ScrollState.presets
                )
                if let sid { self.spaces.layouts[sid] = .scroll(n) }
                guard n != sc else { return (m, [], []) }
                if let sid { strip = (sid, n, uScreen, tile) }
                let (_, parked) = scrollLayout(n, screen: uScreen, config: tile)
                return (m, parked, Set(n.windows))
            case .float(let fl):
                // Live SLS frames, not `remembered`: the user has been moving
                // these windows by hand, so remembered geometry is stale by
                // definition and directional focus would score against it.
                let live = self.liveFrames(of: fl.windows)
                let (n, m) = Reducer.reduceFloat(fl, command: command, frames: live)
                if let sid { self.spaces.layouts[sid] = .float(n) }
                return (m, [], [])
            }
        }
        var out = ReduceOutcome(parkedNow: parkedNow, scope: scope)
        out.scroll = strip
        for m in mutations {
            switch m {
            case .setFrame(let id, let f): out.frames[id] = f
            case .focusWindow(let id): out.focus = id
            case .raise(let id): out.raises.append(id)
            }
        }
        return out
    }

    /// One step of a modifier-drag resize on a tiled window.
    ///
    /// The same reduction a `resize` keybind performs, minus everything that
    /// only makes sense once: the frames go through the drag coalescer rather
    /// than straight out, and the state-changed event and the divider-zone
    /// rebuild wait for the button to come up. Running the full command path
    /// per mouse event meant a core round trip, an uncoalesced AX write, a
    /// zone rebuild and a bus event — which forks sketchybar — a hundred
    /// times a second, and the drag fell behind the cursor and stayed behind.
    private func dragResize(_ dir: ResizeDirection, by amount: Double) {
        let outcome = reduceOnCore(.resize(dir, amount))
        guard !outcome.frames.isEmpty else { return }
        applyFramesCoalesced(outcome.frames)
        outcome.reconcileParked(on: self, frames: outcome.frames)
    }

    // MARK: - Spaces (M4)

    private func handleSpace(_ sub: SpaceCommand) -> IPCResponse {
        // Topology only: no space verb needs the window list, and a full
        // sweep here sat directly on the `space focus` critical path.
        let displays = WorldReader.displaysOnly()
        let sp = readSpaces()
        switch sub {
        case .focus(let target):
            guard let sid = sp.resolveSpace(target) else {
                return IPCResponse(ok: false, error: "unknown space '\(target)' (labels: \(sp.labels.values.sorted().joined(separator: ", ")))")
            }
            let label = sp.labels[sid] ?? "\(sid)"
            if sp.currentByDisplay.values.contains(sid) {
                // Already there. Do not re-tile or re-activate: doing so on a
                // repeated keypress yanked focus around for no reason.
                return IPCResponse(ok: true, output: "already on \(label)")
            }
            let previous = currentSID()
            if SpaceControl.focusSpace(sid) {
                // Verified switch (SpaceControl re-reads the WindowServer).
                updateSpaces { s in
                    for d in displays where d.spaces.contains(sid) {
                        s.currentByDisplay[d.uuid] = sid
                    }
                    if let previous, previous != sid { s.recentSpace = previous }
                }
                // SA switch is instant (no 250ms animation) — safe to tile + focus now.
                applySpaceLayout(sid, stealFocus: true)
                bus.emit(stateChangedEvent())
                return IPCResponse(ok: true, output: "switching to \(label) (instant via scripting addition)")
            }
            guard let number = sp.ordinal(of: sid) else {
                return IPCResponse(ok: false, error: "space \(sid) is not on any display")
            }
            guard (1...9).contains(number) else {
                return IPCResponse(
                    ok: false,
                    error: "space '\(label)' is desktop #\(number); the keystroke fallback only covers 1-9. "
                        + "Load the scripting addition (sudo yabai --load-sa, or weft's own) for instant switching to any desktop."
                )
            }
            updateSpaces { s in
                if let previous, previous != sid { s.recentSpace = previous }
            }
            SpaceControl.focusSpaceNumber(number)
            // Confirm rather than claim: the Mission Control shortcut may be
            // disabled in System Settings, which is undetectable up front.
            if SpaceControl.waitForCurrentSpace(sid, timeout: 0.6) {
                return IPCResponse(ok: true, output: "switched to \(label) (ctrl+\(number))")
            }
            return IPCResponse(
                ok: false,
                error: "ctrl+\(number) did not switch to '\(label)'. Enable System Settings → Keyboard → "
                    + "Shortcuts → Mission Control → 'Switch to Desktop \(number)', or load the scripting addition."
            )
        case .moveWindow(let target, let widOpt):
            guard let sid = sp.resolveSpace(target) else {
                return IPCResponse(ok: false, error: "unknown space '\(target)'")
            }
            let wid: WindowID
            if let w = widOpt {
                wid = w
            } else {
                guard let f = currentLayout().focus else {
                    return IPCResponse(ok: false, error: "nothing focused")
                }
                wid = f
            }
            return moveWindow(wid, toSpace: sid, label: sp.labels[sid] ?? "\(sid)")
        case .label(let name):
            guard !name.isEmpty else {
                return IPCResponse(ok: false, error: "usage: space label <name>")
            }
            guard let sid = currentSID() else {
                return IPCResponse(ok: false, error: "no current space")
            }
            updateSpaces { $0.labels[sid] = name }
            saveLabels()
            return IPCResponse(ok: true, output: "space \(sid) labelled '\(name)'")
        case .layout(let kind):
            let targetKind: LayoutKind
            if kind == "toggle" {
                let curKind = currentLayout().kind
                targetKind = (curKind == .float) ? .bsp : .float
            } else if let lkind = LayoutKind(rawValue: kind),
                      ["bsp", "scroll", "float"].contains(kind)
            {
                targetKind = lkind
            } else {
                return IPCResponse(ok: false, error: "usage: space layout <bsp|scroll|float|toggle>")
            }
            guard let sid = currentSID() else {
                return IPCResponse(ok: false, error: "no current space")
            }
            // Picking a layout is the user saying "arrange this space". A
            // window sitting outside every layout because it once timed out
            // makes that a lie — it stays exactly where it was while the
            // others rearrange around it. Forgive first, then convert.
            forgiveQuirks()
            syncFromSnapshot()
            updateSpaces { sp in
                convertLayout(&sp, sid: sid, to: targetKind)
                // Remember that this was asked for, not derived. Without the
                // record the next config reload, the next time the space
                // empties, and the next restart all quietly undo it.
                sp.overrides[sid] = targetKind
            }
            saveLayoutOverrides()
            if let sid = currentSID() {
                applySpaceLayout(sid)
            }
            bus.emit(stateChangedEvent())
            return IPCResponse(ok: true, output: describe())
        }
    }

    /// Move `wid` to space `sid` without following it, then reconcile the
    /// model: drop it from every other space's layout, insert it into the
    /// target's. Shared by `space move-window` and `move display`, which
    /// differ only in how they name the destination.
    ///
    /// The target space's layout is applied too — on multi-display it is
    /// very often visible on the other monitor right now, so leaving it for
    /// the next sweep showed the window at its old size for a beat.
    private func moveWindow(_ wid: WindowID, toSpace sid: SpaceID, label: String) -> IPCResponse {
        if !currentLayout().windows.contains(wid) && !ScriptingAddition.isAvailable() {
            return IPCResponse(ok: false, error: "wid \(wid) is not on the current space (needs weft-sa to move background windows)")
        }
        guard SpaceControl.moveWindowToSpace(wid, sid) else {
            return IPCResponse(ok: false, error: "WindowServer ignored the move (needs weft-sa) — nothing changed")
        }
        // Re-read display geometry before sizing anything against it. macOS
        // puts the menu bar on whichever display has focus, so the other
        // display's `visibleFrame` is a full-height rect until focus lands
        // there — and a window sent to a space on that display was laid out
        // into a rect 22 points taller than the one it would actually get.
        refreshScreens()
        let targetScreen = usableScreen(for: sid)
        let tile = currentConfig().general.asTilingConfig()
        updateSpaces { sp in
            for key in sp.layouts.keys where key != sid {
                switch sp.layouts[key] {
                case .tiling(let t) where t.windows.contains(wid):
                    sp.layouts[key] = .tiling(t.removing(wid))
                case .scroll(let s) where s.windows.contains(wid):
                    sp.layouts[key] = .scroll(s.removing(wid))
                case .float(let f) where f.windows.contains(wid):
                    sp.layouts[key] = .float(f.removing(wid))
                default:
                    break
                }
            }
            switch sp.layouts[sid] ?? self.resolvedInitialLayout(for: sid, in: sp) {
            case .tiling(var t):
                // Split against the TARGET display's rect: a window landing
                // on a 3840-wide monitor should split it side by side even
                // though it came from a 1710-wide one.
                if !t.windows.contains(wid) { t = t.inserting(wid, in: targetScreen, config: tile) }
                sp.layouts[sid] = .tiling(t)
            case .scroll(var s):
                if !s.windows.contains(wid) { s = s.inserting(wid) }
                sp.layouts[sid] = .scroll(s)
            case .float(var f):
                if !f.windows.contains(wid) { f = f.inserting(wid) }
                sp.layouts[sid] = .float(f)
            }
        }
        if let cur = currentSID() {
            applySpaceLayout(cur)
        }
        if readSpaces().visibleSpaces.contains(sid) {
            applier.bind(windows: pid(of: wid).map { [(wid: wid, pid: $0)] } ?? [])
            applySpaceLayout(sid, raiseFocus: false)
        }
        // And once more when the app has finished changing spaces.
        //
        // The frame written above is correct and does not always land: the
        // app is mid-transition, and a size write during it is the one an app
        // is most likely to drop. Position usually sticks and size does not,
        // so the window arrives in the right corner at its old size — most
        // visibly when the destination is on another display, where the old
        // size is wrong by a whole monitor. Nothing else would have corrected
        // it: moving a window between spaces produces no event, so no sweep
        // follows, and it stayed wrong until something else happened to
        // retile. One trailing pass, cancelled by the next move.
        // Scheduled from the sync queue, which is the only queue that touches
        // the pending-work items — this runs on `incoming`.
        syncQueue.async { [weak self] in
            guard let self else { return }
            self.pendingMoveSettle?.cancel()
            let settle = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.refreshScreens()
                if self.readSpaces().visibleSpaces.contains(sid) {
                    self.applySpaceLayout(sid, raiseFocus: false)
                }
                if let cur = self.currentSID() { self.applySpaceLayout(cur) }
                self.bus.emit(self.stateChangedEvent())
            }
            self.pendingMoveSettle = settle
            self.syncQueue.asyncAfter(deadline: .now() + 0.25, execute: settle)
        }
        bus.emit(stateChangedEvent())
        return IPCResponse(ok: true, output: "moved \(wid) to \(label)")
    }

    private func handleAppToggle(_ bundleID: String) -> IPCResponse {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return IPCResponse(ok: false, error: "no application with bundle id \(bundleID)")
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return IPCResponse(ok: true, output: "launching \(bundleID)")
        }
        guard let app = running.first else {
            return IPCResponse(ok: false, error: "no application with bundle id \(bundleID)")
        }
        if app.isActive {
            app.hide()
            return IPCResponse(ok: true, output: "hid \(bundleID)")
        }
        // Focus: its window's space first (instant or keystroke), then raise the window.
        let pid = app.processIdentifier
        let world = WorldReader.snapshot()
        guard let win = world.windows.first(where: { $0.pid == pid }),
              let sid = win.spaces.first
        else {
            return IPCResponse(ok: false, error: "cannot locate a window/space for \(bundleID)")
        }
        let wid = win.id
        if SpaceControl.focusSpace(sid) {
            // Instant switch: tile raise-only now, focus after settle.
            applySpaceLayout(sid)
            bus.emit(stateChangedEvent())
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, let pid = self.pids[wid] else { return }
                self.focusAndWarp(window: wid, pid: pid)
            }
            return IPCResponse(ok: true, output: "focusing \(bundleID) (instant space switch + raise)")
        } else if let (_, number) = Daemon.spaceNumber(sid, in: world), (1...9).contains(number) {
            SpaceControl.focusSpaceNumber(number)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, let pid = self.pids[wid] else { return }
                self.focusAndWarp(window: wid, pid: pid)
            }
            return IPCResponse(ok: true, output: "focusing \(bundleID) (space switch + raise)")
        } else {
            return IPCResponse(ok: false, error: "cannot switch to space for \(bundleID) (needs weft-sa)")
        }
    }

    private func handleSticky(_ widOpt: WindowID?, _ mode: StickyMode) -> IPCResponse {
        let wid: WindowID
        if let w = widOpt {
            wid = w
        } else {
            guard let f = currentLayout().focus else {
                return IPCResponse(ok: false, error: "nothing focused")
            }
            wid = f
        }
        let on: Bool
        switch mode {
        case .on: on = true
        case .off: on = false
        case .toggle: on = SpaceControl.spacesForWindow(wid).count <= 1
        }
        guard SpaceControl.setSticky(wid, on) else {
            return IPCResponse(ok: false, error: "WindowServer ignored sticky (needs weft-sa) — nothing changed")
        }
        syncFromSnapshot()  // reconciles membership on every space
        return IPCResponse(ok: true, output: "sticky \(on ? "on" : "off") for \(wid)")
    }

    /// Resolve a display target against the display keyboard focus is on.
    ///
    /// `next`/`prev` do not wrap: yabai stops at the last display, and that
    /// failure is what makes `{ … next … } || { … first … }` in a keybind
    /// fall through to the first display instead of quietly doing nothing.
    private enum DisplayResolution {
        case display(String)
        case failed(String)
    }

    private func resolveDisplay(_ target: DisplayTarget) -> DisplayResolution {
        let order = displaysWestToEast()
        guard !order.isEmpty else { return .failed("no displays") }
        let sp = readSpaces()
        let anchor = sp.focusedDisplay.flatMap { order.firstIndex(of: $0) } ?? 0
        let idx: Int
        switch target {
        case .first: idx = 0
        case .last: idx = order.count - 1
        case .index(let n): idx = n - 1
        case .prev: idx = anchor - 1
        case .next: idx = anchor + 1
        case .cycle: idx = (anchor + 1) % order.count
        case .north, .south:
            guard let found = nearestDisplay(from: anchor, in: order, towards: target) else {
                return .failed("no display \(describe(target)) of display \(anchor + 1)")
            }
            return .display(found)
        case .west, .east:
            // Geometry first, arrangement order as the fallback. A monitor
            // stacked *above* the built-in — which is this machine — is
            // neither west nor east of it, and a keybind bound to `west`
            // should still reach the only other screen there is.
            if let found = nearestDisplay(from: anchor, in: order, towards: target) {
                return .display(found)
            }
            idx = target == .west ? anchor - 1 : anchor + 1
        }
        guard order.indices.contains(idx) else {
            if order.count == 1 { return .failed("only one display") }
            return .failed("no display \(describe(target)) of display \(anchor + 1)")
        }
        return .display(order[idx])
    }

    /// Nearest display whose centre lies in `target`'s direction from the
    /// anchor's centre. Nil when nothing is that way.
    private func nearestDisplay(
        from anchor: Int, in order: [String], towards target: DisplayTarget
    ) -> String? {
        let rects = screensLock.withLock { screensByUUID }
        guard order.indices.contains(anchor), let from = rects[order[anchor]] else { return nil }
        func centre(_ f: Frame) -> (x: Double, y: Double) {
            (f.x + f.width / 2, f.y + f.height / 2)
        }
        let origin = centre(from)
        var best: (uuid: String, distance: Double)?
        for (i, uuid) in order.enumerated() where i != anchor {
            guard let f = rects[uuid] else { continue }
            let c = centre(f)
            let dx = c.x - origin.x
            let dy = c.y - origin.y
            let ahead: Bool
            switch target {
            case .west: ahead = dx < 0 && abs(dx) >= abs(dy)
            case .east: ahead = dx > 0 && abs(dx) >= abs(dy)
            case .north: ahead = dy < 0 && abs(dy) > abs(dx)
            case .south: ahead = dy > 0 && abs(dy) > abs(dx)
            default: ahead = false
            }
            guard ahead else { continue }
            let d = dx * dx + dy * dy
            if best == nil || d < best!.distance { best = (uuid, d) }
        }
        return best?.uuid
    }

    private func describe(_ target: DisplayTarget) -> String {
        switch target {
        case .next: return "next"
        case .prev: return "prev"
        case .west: return "west"
        case .east: return "east"
        case .north: return "north"
        case .south: return "south"
        case .first: return "first"
        case .last: return "last"
        case .cycle: return "cycle"
        case .index(let n): return "#\(n)"
        }
    }

    /// Move keyboard focus to another display.
    ///
    /// With separate Spaces per display both displays already show a current
    /// space, so this is not a space switch at all — it is focusing a window
    /// that is *already on screen*. Switching spaces here (which is what the
    /// old anchor-at-display-1 version did) took ~250 ms and could flip the
    /// wrong monitor's desktop.
    private func handleFocusDisplay(_ target: DisplayTarget) -> IPCResponse {
        let uuid: String
        switch resolveDisplay(target) {
        case .display(let u): uuid = u
        case .failed(let e): return IPCResponse(ok: false, error: e)
        }
        let sp = readSpaces()
        guard let sid = sp.currentByDisplay[uuid] else {
            return IPCResponse(ok: false, error: "display \(describe(target)) has no current space")
        }
        if sp.focusedDisplay == uuid {
            return IPCResponse(ok: true, output: "already on display \(describe(target))")
        }
        let label = sp.labels[sid] ?? "\(sid)"
        if let focus = sp.layouts[sid]?.focus, let pid = pid(of: focus) {
            // Activating the window is the display switch; noteFocusedWindow
            // inside focusAndWarp records the display it lives on.
            focusAndWarp(window: focus, pid: pid)
            bus.emit(stateChangedEvent())
            return IPCResponse(ok: true, output: "focused \(focus) on \(label)")
        }
        // Nothing there can take keyboard focus. weft still moves its own
        // notion of the current display — that is what the user asked for,
        // and it is what makes the next `move display` or new window land
        // here — and puts the pointer there so the next click agrees.
        updateSpaces { $0.focusedDisplay = uuid }
        let screen = usableScreen(onDisplay: uuid)
        CGWarpMouseCursorPosition(CGPoint(
            x: screen.x + screen.width / 2, y: screen.y + screen.height / 2
        ))
        bus.emit(stateChangedEvent())
        return IPCResponse(ok: true, output: "\(label) is empty — pointer moved there")
    }

    /// Send the focused window to another display's current space.
    /// The window does NOT follow focus (yabai's `window --display`); the
    /// user's keybind pairs it with `focus display` when they want both.
    private func handleMoveWindowToDisplay(
        _ target: DisplayTarget, follow: Bool
    ) -> IPCResponse {
        let uuid: String
        switch resolveDisplay(target) {
        case .display(let u): uuid = u
        case .failed(let e): return IPCResponse(ok: false, error: e)
        }
        let sp = readSpaces()
        guard let sid = sp.currentByDisplay[uuid] else {
            return IPCResponse(ok: false, error: "display \(describe(target)) has no current space")
        }
        guard let wid = currentLayout().focus else {
            return IPCResponse(ok: false, error: "nothing focused")
        }
        if sp.displayBySpace[currentSID() ?? 0] == uuid {
            return IPCResponse(ok: true, output: "window \(wid) is already on that display")
        }
        let moved = moveWindow(wid, toSpace: sid, label: sp.labels[sid] ?? "\(sid)")
        guard moved.ok, follow else { return moved }
        // Follow the window rather than the display's previous focus: the
        // window we just sent is the one the user is thinking about.
        updateSpaces { $0.focusedDisplay = uuid }
        if let pid = pid(of: wid) { focusAndWarp(window: wid, pid: pid) }
        bus.emit(stateChangedEvent())
        return IPCResponse(ok: true, output: (moved.output ?? "") + " and followed")
    }

    /// Send the whole current space to another display (yabai's
    /// `space --display`).
    ///
    /// This cannot work on macOS 26 and says so. The unprivileged sequence
    /// needs `SLSSpaceSetCompatID` *and* `SLSSetDisplaySpaceCompatID`; the
    /// second no longer exists in SkyLight (checked against the shipping
    /// binary, see SkyLightShim.h), so there is nothing to call and nothing
    /// the scripting addition adds. Reporting that beats a silent no-op.
    private func handleMoveSpaceToDisplay(_ target: DisplayTarget) -> IPCResponse {
        let uuid: String
        switch resolveDisplay(target) {
        case .display(let u): uuid = u
        case .failed(let e): return IPCResponse(ok: false, error: e)
        }
        guard let sid = currentSID() else {
            return IPCResponse(ok: false, error: "no current space")
        }
        if SpaceControl.moveSpaceToDisplay(sid, uuid) {
            syncFromSnapshot()
            return IPCResponse(ok: true, output: "space \(sid) is on display \(describe(target))")
        }
        return IPCResponse(
            ok: false,
            error: "moving a whole space between displays is not possible on this macOS: "
                + "SkyLight no longer exports SLSSetDisplaySpaceCompatID. "
                + "Use `move display \(describe(target))` to send the window instead."
        )
    }

    /// 1-based Mission Control number of a space on its display (SLS order).
    /// Assumption: SLS space order matches the number order — the user
    /// confirms on first `space focus` (wrong landing = report it).
    static func spaceNumber(_ sid: SpaceID, in world: World) -> (String, Int)? {
        for d in world.displays {
            if let i = d.spaces.firstIndex(of: sid) { return (d.uuid, i + 1) }
        }
        return nil
    }

    // MARK: - Config (M6)

    private let configLock = NSLock()
    private var _config = ValidatedConfig.default
    private var watcher: ConfigWatcher?
    /// Windows the rules float (manage=false), quirks, or refuser strikes.
    /// Excluded from every layout — model-invisible until they leave.
    private var unmanaged: Set<WindowID> = []
    /// Consecutive frame-set failures per window; ≥2 → auto-float (quirk).
    private var strikes: [WindowID: Int] = [:]
    /// wid → "is a real window", from its AX subrole. Answered once per
    /// window off the core queue and cached for its lifetime; a window we
    /// could not classify yet is simply absent and asked about again next
    /// sweep. Layer-0 and bigger-than-100px is not enough on its own — a
    /// menu-bar extra's panel passes both.
    private var standardWindow: [WindowID: Bool] = [:]

    /// The log line for a classification refusal, in the user's terms rather
    /// than the AX attribute's.
    private static func reason(_ why: AXApplier.NotTileable) -> String {
        switch why {
        case .subrole: return "it is a dialog or panel, not a window"
        case .fixedSize: return "the app will not let it be resized"
        case .panelChrome: return "it is a small window with no title-bar buttons (a popup)"
        }
    }
    /// wid → when AX first failed to produce an element for it while its space
    /// was visible. A real window binds immediately (measured: Ghostty binds on
    /// the first sweep, and even windows on *other* spaces bind), so staying
    /// unbindable for a full second while on screen is what a menu-bar extra's
    /// panel looks like. Time, not sweep count: sweeps fire 20 ms apart in a
    /// burst and an app relaunching must not be condemned by that.
    private var unbindableSince: [WindowID: Date] = [:]
    /// Space-rule move attempts (tried once per window lifetime; SA-gated).
    private var spaceMoveAttempts: Set<WindowID> = []
    /// pid → bundle id (immutable per pid; NSRunningApplication is cheap).
    private var bundleCache: [Int32: String] = [:]
    private let bundleLock = NSLock()

    /// Bundle ids that never take sizes (Simulator, System Settings).
    /// User rules in weft.toml cover the rest; refuser strikes cover unknowns.
    private static let autoFloatBundles: Set<String> = [
        "com.apple.iphonesimulator",
        "com.apple.systemsettings",
        "com.weft.bar",
    ]

    private func currentConfig() -> ValidatedConfig {
        configLock.withLock { _config }
    }

    /// Hash of the config text last loaded, so an FSEvents burst over an
    /// unchanged file costs one read and nothing else. Guarded by `configLock`.
    private var lastConfigDigest: Int?

    static func configFile() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/weft/weft.toml")
    }

    /// Load (or reload) weft.toml. Missing file = defaults. Parse errors keep
    /// the running config and report line numbers. On success the keymap
    /// swaps live and declared space layouts apply.
    func loadConfigFile(initial: Bool = false) {
        let url = Daemon.configFile()
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            if initial {
                fputs("weft: no ~/.config/weft/weft.toml — defaults (M6: write one to declare spaces/rules/keys)\n", stderr)
            }
            return
        }
        // FSEvents fires on the directory, and it fires more than once for a
        // single save: an editor writes a temp file and renames it, and the
        // Settings window touches labels.json in the same directory. Both
        // arrived here as a full reload — which re-applies the keymap,
        // restarts the mouse zones and re-derives every declared layout — for
        // a file whose bytes had not changed. Two "config loaded" lines per
        // save is the visible half of it.
        let digest = text.hashValue
        let unchanged: Bool = configLock.withLock {
            defer { lastConfigDigest = digest }
            return !initial && lastConfigDigest == digest
        }
        if unchanged { return }
        let next: ValidatedConfig
        do {
            next = try loadConfig(text)
        } catch let e as ConfigError {
            fputs("weft: config error line \(e.line): \(e.message) — keeping running config\n", stderr)
            return
        } catch {
            fputs("weft: config error: \(error) — keeping running config\n", stderr)
            return
        }
        configLock.withLock { _config = next }
        input.updateKeymap(next.keymap)
        input.updateMouseModifier(next.general.mouseModifier)
        input.setBorderDragEnabled(next.general.mouseBorderResize)
        refreshDividerZones()
        WorldReader.manageMenubarApps = next.general.manageMenubarApps
        bordersBridge.applyConfig(next.integrations.borders, currentLayout: currentSpaceLayoutKind(), currentMode: input.currentMode)
        sketchybarBridge.updateConfig(next.integrations.sketchybar)
        applyDeclaredLayouts()
        fputs("weft: config loaded (\(next.spaces.count) spaces, \(next.rules.count) rules, \(next.keymap.modes.count) modes)\n", stderr)
    }

    /// Convert spaces whose declared layout differs (config is source of
    /// truth — overrides manual `space layout` until the next reload).
    private func applyDeclaredLayouts() {
        let cfg = currentConfig()
        let previous = lastDeclaredLayouts
        lastDeclaredLayouts = Dictionary(
            cfg.spaces.map { ($0.label, $0.layout) }, uniquingKeysWith: { _, b in b }
        )
        guard !cfg.spaces.isEmpty else { return }
        let sp = readSpaces()
        // label → sid for known spaces.
        var changed = false
        var clearedOverride = false
        for decl in cfg.spaces {
            guard let sid = sp.id(forLabel: decl.label),
                  let cur = sp.layouts[sid]
            else { continue }  // unknown label yet (space not visited) — applied on first sync
            // Editing `layout =` in weft.toml is an instruction and wins; a
            // reload that did not touch this space's declaration is not, and
            // must not undo a `space layout` the user ran since. Reloads fire
            // on every save of the file, so without this every unrelated edit
            // — a keybind, a rule, a gap — snapped every space back.
            let declarationChanged = previous[decl.label] != decl.layout
            if !declarationChanged, sp.overrides[sid] != nil { continue }
            if declarationChanged, sp.overrides[sid] != nil {
                updateSpaces { $0.overrides.removeValue(forKey: sid) }
                clearedOverride = true
            }
            if cur.kind == decl.layout { continue }
            updateSpaces { sp in
                convertLayout(&sp, sid: sid, to: decl.layout)
            }
            changed = true
        }
        if clearedOverride { saveLayoutOverrides() }
        // Editing `center-focused-column` is not a layout-kind change, so
        // nothing above would have noticed it. Re-stamp every scroll space.
        var recentred = false
        updateSpaces { sp in
            // Snapshot the keys: the body writes back into the dictionary it
            // would otherwise be iterating.
            for sid in Array(sp.layouts.keys) {
                let was = sp.layouts[sid]
                applyScrollSettings(&sp, sid: sid)
                if sp.layouts[sid] != was { recentred = true }
            }
        }
        if changed || recentred {
            syncFromSnapshot()
        }
    }

    /// The `[[space]] layout` values the last config load saw, per label. Only
    /// a *change* between loads counts as the user re-deciding in the file.
    private var lastDeclaredLayouts: [String: LayoutKind] = [:]

    // MARK: - Per-space scroll settings

    /// The `[[space]] scroll = { … }` block for a space, found by its label.
    ///
    /// Both keys in that block were parsed, type-checked and range-checked by
    /// `WeftConfig` and then read by nobody: `center-focused-column` never
    /// left the file and `preset-column-widths` never left it either. A
    /// config key that validates and does nothing is worse than one that does
    /// not exist, because the user has no way to tell.
    private func scrollDecl(for sid: SpaceID, in sp: SpaceState) -> SpaceScrollDecl? {
        guard let label = sp.labels[sid], !label.isEmpty else { return nil }
        return currentConfig().spaces.first(where: { $0.label == label })?.scroll
    }

    /// The column-width ring for a space: its own, or the default one.
    private func scrollPresets(for sid: SpaceID, in sp: SpaceState) -> [Double] {
        scrollDecl(for: sid, in: sp)?.presetColumnWidths ?? ScrollState.presets
    }

    /// Stamp the declared centre mode onto a space's strip.
    ///
    /// `centerMode` is state rather than a lookup because the layout maths
    /// reads it on every frame, so it has to be put there — at conversion, at
    /// first sight of a space, and on every config reload, which is where a
    /// user who has just edited the file expects to see it take effect.
    private func applyScrollSettings(_ sp: inout SpaceState, sid: SpaceID) {
        guard case .scroll(var sc) = sp.layouts[sid] else { return }
        let want = scrollDecl(for: sid, in: sp)?.centerFocusedColumn
            .flatMap { CenterMode(configValue: $0) } ?? .onOverflow
        guard sc.centerMode != want else { return }
        sc.centerMode = want
        sp.layouts[sid] = .scroll(sc)
    }

    /// Convert one space's layout preserving membership. INTO float captures
    /// live SLS frames as the remembered arrangement.
    private func convertLayout(_ sp: inout SpaceState, sid: SpaceID, to kind: LayoutKind) {
        let cur = sp.layouts[sid] ?? .tiling(Tree())
        guard cur.kind != kind else { return }
        switch (kind, cur) {
        case (.scroll, .tiling(let t)):
            sp.layouts[sid] = .scroll(scrollFromTree(t))
            applyScrollSettings(&sp, sid: sid)
        case (.scroll, .float(let f)):
            sp.layouts[sid] = .scroll(scrollFromFloat(f))
            applyScrollSettings(&sp, sid: sid)
        case (.scroll, .scroll), (.bsp, .tiling), (.float, .float):
            break  // already that kind (guarded above; listed for exhaustiveness)
        case (.bsp, .scroll(let s)):
            sp.layouts[sid] = .tiling(treeFromScroll(s))
        case (.bsp, .float(let f)):
            sp.layouts[sid] = .tiling(treeFromOrder(f.order, focus: f.focus))
        case (.float, .tiling(let t)):
            sp.layouts[sid] = .float(floatFromWindows(
                t.windows, actuals: conversionFrames(of: t.windows, sid: sid), focus: t.focus
            ))
        case (.float, .scroll(let s)):
            sp.layouts[sid] = .float(floatFromWindows(
                s.windows, actuals: conversionFrames(of: s.windows, sid: sid),
                focus: s.focusedWindow
            ))
        }
    }

    /// Live SLS frames for conversion targets (cheap, no app IPC).
    private func liveFrames(of wids: [WindowID]) -> [WindowID: Frame] {
        var out: [WindowID: Frame] = [:]
        for wid in wids {
            if let f = WorldReader.frame(of: wid) { out[wid] = f }
        }
        return out
    }

    /// The same, with a substitute for any window that is not on a display.
    ///
    /// Converting a scroll space to float read every window's live frame and
    /// remembered it as that window's floating position — including the
    /// scrolled-away columns, which are SLS-parked at `minX - 5000`. Their
    /// remembered position was therefore off every screen there is, so the
    /// conversion "restored" them to nowhere. Anything off-display gets a
    /// cascaded rect on this space's screen instead.
    private func conversionFrames(of wids: [WindowID], sid: SpaceID) -> [WindowID: Frame] {
        let live = liveFrames(of: wids)
        let displays = SpaceControl.displayLayout().map(\.frame)
        let screen = usableScreen(for: sid)
        var out: [WindowID: Frame] = [:]
        var cascade = 0.0
        for wid in wids {
            if let f = live[wid], displays.contains(where: { $0.intersects(f) }) {
                out[wid] = f
                continue
            }
            out[wid] = Frame(
                x: screen.x + screen.width * 0.1 + cascade,
                y: screen.y + screen.height * 0.1 + cascade,
                width: screen.width * 0.6,
                height: screen.height * 0.6
            )
            cascade += 28
        }
        return out
    }

    private func startConfigWatcher() {
        let dir = Daemon.configFile().deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: dir) else { return }
        let watcher = ConfigWatcher(directory: dir) { [weak self] in
            self?.loadConfigFile()
        }
        self.watcher = watcher
        watcher.start()
    }

    // MARK: - Label persistence (by ordinal; sids die on reboot, §5.3)

    static func labelsFile() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/weft/labels.json")
    }

    static func loadLabels() -> [String] {
        guard let data = try? Data(contentsOf: labelsFile()),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return names
    }

    private func saveLabels() {
        let sp = readSpaces()
        let names = sp.persistedNames(sids: Array(sp.labels.keys))
        let url = Daemon.labelsFile()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(names) {
            try? data.write(to: url)
        }
    }

    // MARK: - Layout persistence (by ordinal; sids die on reboot, §5.3)
    //
    // Only *chosen* layouts are written here — the ones `space layout` set.
    // A layout that came from `[[space]] layout` or `default-layout` is
    // already persisted, in weft.toml, and copying it into a second file
    // would make editing weft.toml stop working.

    static func layoutsFile() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/weft/layouts.json")
    }

    static func loadLayoutOverrides() -> [String] {
        guard let data = try? Data(contentsOf: layoutsFile()),
              let kinds = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return kinds
    }

    private func saveLayoutOverrides() {
        let sp = readSpaces()
        let kinds = sp.persistedOverrides(sids: sp.order)
        layoutSaveQueue.async {
            let url = Daemon.layoutsFile()
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if let data = try? JSONEncoder().encode(kinds) {
                try? data.write(to: url)
            }
        }
    }

    // MARK: - Parked-set persistence (§11 risk 3)

    static func parkedFile() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/weft/parked.json")
    }

    static func loadParked() -> Set<WindowID> {
        guard let data = try? Data(contentsOf: parkedFile()),
              let ids = try? JSONDecoder().decode([WindowID].self, from: data)
        else { return [] }
        return Set(ids)
    }

    /// Persist the parked set off the caller's thread.
    ///
    /// This is crash-recovery bookkeeping, not something anything waits on,
    /// and it is now reached from the drag path — a column crossing the edge
    /// of the screen mid-resize parks, which called this. A synchronous
    /// `write(to:)` there put a file system round trip in the middle of a
    /// gesture that has 8 ms to answer the cursor.
    private func saveParked() {
        let snapshot = readParked().sorted()
        parkedSaveQueue.async {
            let url = Daemon.parkedFile()
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url)
            }
        }
    }

    private func handleQuery(_ text: String) -> IPCResponse {
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count == 2 else {
            return IPCResponse(ok: false, error: "usage: query <displays|spaces|windows|world|state|tree|capability|permissions>")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func emit<T: Encodable>(_ v: T) -> IPCResponse {
            guard let data = try? encoder.encode(v),
                  let str = String(data: data, encoding: .utf8)
            else { return IPCResponse(ok: false, error: "encode failed") }
            return IPCResponse(ok: true, output: str)
        }
        switch parts[1] {
        case "state":
            let screen = self.usableScreen(for: currentSID())
            let config = currentConfig().general.asTilingConfig()
            switch currentLayout() {
            case .tiling(let tree):
                let frames = layout(tree, in: screen, config: config)
                return emit(StateView(
                    focus: tree.focus,
                    windows: tree.windows.sorted(),
                    screen: screen,
                    frames: frames.sorted(by: { $0.key < $1.key }).map {
                        FrameEntry(id: $0.key, frame: $0.value)
                    },
                    parked: []
                ))
            case .scroll(let sc):
                let (frames, parked) = scrollLayout(sc, screen: screen, config: config)
                return emit(StateView(
                    focus: sc.focusedWindow,
                    windows: sc.windows.sorted(),
                    screen: screen,
                    frames: frames.sorted(by: { $0.key < $1.key }).map {
                        FrameEntry(id: $0.key, frame: $0.value)
                    },
                    parked: parked.sorted()
                ))
            case .float(let fl):
                return emit(StateView(
                    focus: fl.focus,
                    windows: fl.windows.sorted(),
                    screen: screen,
                    frames: fl.remembered.sorted(by: { $0.key < $1.key }).map {
                        FrameEntry(id: $0.key, frame: $0.value)
                    },
                    parked: []
                ))
            }
        case "tree":
            switch currentLayout() {
            case .tiling(let tree):
                return emit(TreeView.of(tree.root))
            case .scroll(let sc):
                return emit(ScrollView.of(sc))
            case .float(let fl):
                return emit(FloatView(order: fl.order, focus: fl.focus))
            }
        case "capability":
            return emit(PlatformCapability.current)
        case "permissions":
            // The daemon's OWN grants. TCC is per binary, so weftctl and
            // WeftBar asking on their own behalf answer a different question
            // than the one that matters — and both used to, which is how a
            // fully green Setup window sat next to a weftd that could not move
            // a single window.
            //
            // Two separate answers for one pane, deliberately. `ensureTap`,
            // not `tapInstalled`: a query is the one moment we know someone
            // is watching for the answer to change, and the tap only ever
            // changes when something retries it — that is what makes flipping
            // a switch take effect while the Setup window is open. But a live
            // tap does NOT mean the Input Monitoring switch is on: macOS lets
            // an Accessibility-trusted process create an event tap, so
            // reporting the tap AS Input Monitoring told users they had
            // granted something they never touched. The switch gets its own
            // field, read from TCC.
            return emit(DaemonPermissions(
                binary: Bundle.main.executablePath
                    ?? ProcessInfo.processInfo.arguments.first ?? "weftd",
                accessibility: Permissions.accessibility(),
                inputMonitoring: Permissions.inputMonitoringPreflight(),
                keybindsLive: input.ensureTap(),
                screenRecording: Permissions.screenRecording(),
                stableIdentity: Permissions.hasStableSigningIdentity(),
                needsRestart: !launchedTrusted && Permissions.accessibility()
            ))
        case "displays":
            // Geometry included: "which rect is weft tiling this space into"
            // is the first question a multi-display problem asks, and the raw
            // SLS topology cannot answer it.
            let sp = readSpaces()
            let current = WorldReader.currentSpaces()
            return emit(displaysWestToEast().enumerated().map { i, uuid in
                DisplayStatus(
                    index: i + 1,
                    uuid: uuid,
                    frame: screensLock.withLock { screensByUUID[uuid] } ?? .zero,
                    usable: usableScreen(onDisplay: uuid),
                    spaces: sp.order.filter { sp.displayBySpace[$0] == uuid },
                    currentSpace: current[uuid],
                    focused: sp.focusedDisplay == uuid
                )
            })
        case "windows", "world":
            // Diagnostic path: pays the per-app AX round trip so `bound`
            // reflects the S0 cold-start gap. Never used by the hot paths.
            let world = WorldReader.snapshot(includeAXBinding: true)
            guard parts[1] == "windows" else { return emit(world) }
            // Why each window is or is not tiled, alongside the window. A
            // window weft has quietly decided not to manage is the single
            // hardest thing to debug from outside, and `query windows` was
            // the obvious place to look and the one place that did not say.
            let reasons = core.sync { () -> [WindowID: String] in
                var out: [WindowID: String] = [:]
                for w in world.windows {
                    if self.manualFloat.contains(w.id) { out[w.id] = "manual" }
                    else if self.standardWindow[w.id] == false { out[w.id] = "popup" }
                    else if (self.strikes[w.id] ?? 0) >= 2 { out[w.id] = "quirk" }
                    else if self.unmanaged.contains(w.id) { out[w.id] = "rule" }
                }
                return out
            }
            return emit(world.windows.map {
                WindowStatus(
                    id: $0.id, app: $0.app, title: $0.title, pid: $0.pid,
                    spaces: $0.spaces, frame: $0.frame, bound: $0.bound,
                    floating: reasons[$0.id]
                )
            })
        case "spaces":
            // Enriched with labels + our per-space model (daemon only; the
            // local fallback serves raw WindowServer membership). Empty
            // spaces show the DECLARED layout (nothing materialized yet).
            let world = WorldReader.snapshot()
            let sp = readSpaces()
            let cfg = currentConfig()
            return emit(world.spaces.map { s in
                let label = sp.labels[s.id] ?? "\(s.id)"
                let layout = sp.layouts[s.id]?.kind
                    ?? sp.overrides[s.id]
                    ?? cfg.spaces.first(where: { $0.label == label })?.layout
                    ?? cfg.general.defaultLayout
                return SpaceStatus(
                    id: s.id,
                    label: label,
                    layout: layout.rawValue,
                    windows: sp.layouts[s.id]?.windows.sorted() ?? s.windows,
                    current: s.isCurrent,
                    display: s.displayUUID
                )
            })
        default:
            return IPCResponse(ok: false, error: "unknown query \(parts[1])")
        }
    }

    // MARK: - Apply (off-core, ordered)

    /// Dispatch frame writes without waiting for them.
    ///
    /// Frame writes are cross-process AX IPC that can take a second on a
    /// browser or Electron window. Blocking the caller on them made every
    /// keybind pay the slowest app's relayout — a measured 1.2 s
    /// `zoom-fullscreen`. Correctness does not need the wait: writes for one
    /// app go to that app's serial queue, so any raise or later write for the
    /// same window is still ordered behind this one.
    ///
    /// Failure accounting (refuser strikes → auto-float) happens in the
    /// completion, off the caller's thread.
    private func applyFrames(_ frames: [WindowID: Frame], force: Bool = false) {
        dispatchPrecondition(condition: .notOnQueue(core))
        guard !frames.isEmpty else { return }
        applier.apply(frames: frames, pids: allPids(), force: force) { [weak self] result in
            self?.noteApplyFailures(result)
        }
    }

    /// Drop every strike-based exclusion. Windows the *rules* float
    /// (manage=false) and windows the user floated by hand are untouched —
    /// those are decisions, not verdicts.
    private func forgiveQuirks() {
        core.sync {
            let ignored = self.standardWindow.filter { !$0.value }.count
            guard !self.strikes.isEmpty || ignored > 0 else { return }
            fputs("weftd: forgiving \(self.strikes.count) quirked and \(ignored) unrecognised window(s)\n", stderr)
            self.strikes.removeAll()
            // Re-ask about windows judged "not a real window". The judgement is
            // a heuristic over AX visibility; an app that was slow once should
            // not be shut out for the life of the daemon with no way back.
            self.standardWindow = self.standardWindow.filter { $0.value }
            self.unbindableSince.removeAll()
        }
    }

    /// Refuser strikes: two *consecutive* failures → auto-float (quirk).
    ///
    /// Consecutive, not cumulative. Counting failures forever and never
    /// forgiving them made one bad moment permanent: a window that timed out
    /// twice — an app mid-relaunch, or every window at once while
    /// Accessibility was missing — was excluded from the layout for the life
    /// of the daemon. And because excluded windows are never sent frames, they
    /// could never succeed, so nothing could ever clear the count. `space
    /// layout` and `retile` could not rescue them either; only killing weftd
    /// could. A window that takes a frame now is working now.
    private func noteApplyFailures(_ result: AXApplier.ApplyResult) {
        if !result.appliedIDs.isEmpty {
            core.sync {
                for wid in result.appliedIDs { self.strikes.removeValue(forKey: wid) }
            }
        }
        guard !result.failedIDs.isEmpty else { return }
        // With the actual fault, not a guess. "frame-set failed for [238,
        // 1603] (app ignored/timeout)" named a cause it had never checked,
        // and it was the wrong one — every failure looked identical whether
        // the app was fighting back or the WindowServer had refused the move.
        let detail = result.failedIDs.map { wid -> String in
            let why = result.failureReasons[wid].map(String.init(describing:)) ?? "unknown"
            return "\(wid): \(why)"
        }.joined(separator: "; ")
        fputs("weftd: frame-set failed — \(detail)\n", stderr)
        // Without Accessibility EVERY write fails, so strike accounting would
        // auto-float the entire desktop within two sweeps and keep it floated
        // after the grant arrives. A blanket denial is not evidence about any
        // particular app. Seen live on a fresh install, where the grant is on
        // the build path and not yet on the installed binary.
        guard AXIsProcessTrusted() else {
            fputs("weftd: ignoring failures — Accessibility not granted for this binary\n", stderr)
            return
        }
        core.sync {
            for wid in result.failedIDs {
                let n = (self.strikes[wid] ?? 0) + 1
                self.strikes[wid] = n
                if n == 2 {
                    fputs("weftd: auto-floating \(wid) (frame-set refused twice — quirk)\n", stderr)
                }
            }
        }
    }

    /// Front stack members after frame writes, in order. M3: AX raise
    /// (SLSOrderWindow needs a privileged connection — rc=1000 from here —
    /// so the µs fast path waits for weft-sa in M4). An AX raise is z-order
    /// only (no resize), ~0.12ms p50, and focus follows the member anyway.
    /// Windows with no stack chain hide nothing and are skipped — except
    /// scroll/float focus, which is always raised so it stays visible.
    private func raiseFronts(_ wids: [WindowID]) {
        dispatchPrecondition(condition: .notOnQueue(core))
        guard !wids.isEmpty else { return }
        let applier = self.applier
        let pids = self.pids
        let current = currentLayout()
        let targets: [(WindowID, Int32)] = wids.compactMap { wid in
            guard let pid = pids[wid] else { return nil }
            switch current {
            case .tiling(let tree):
                guard let root = tree.root,
                      stackChain(root: root, containing: wid) != nil
                else { return nil }
                return (wid, pid)
            case .scroll, .float:
                // No stacking here — the focused window just needs fronting.
                return (wid, pid)
            }
        }
        guard !targets.isEmpty else { return }
        // Async: ordering against pending frame writes is already guaranteed
        // by the per-pid serial queues, and waiting here meant a focus change
        // sat behind the slowest app's relayout.
        for (wid, pid) in targets {
            applier.raise(wid, pid: pid)
        }
    }

    private func stateChangedEvent() -> DaemonEvent {
        let layout = currentLayout()
        return DaemonEvent(kind: .stateChanged, focus: layout.focus, windows: layout.windows.sorted())
    }

    private func describe() -> String {
        let layout = currentLayout()
        return "\(layout.kind.rawValue) focus=\(layout.focus.map(String.init) ?? "none") windows=\(layout.windows.sorted())"
    }

    // MARK: - Scroll pans (viewport animation)

    private let panAnimator = PanAnimator()
    private let panLock = NSLock()

    /// What a scroll space looked like the last time it was drawn.
    ///
    /// The viewport a pan starts from, and the geometry that says whether the
    /// change since then *is* a pan. Frames here are the uncrossed strip —
    /// parked columns included — because a column sliding in from off screen
    /// has to be interpolated from somewhere real.
    private struct ScrollRender {
        var vx: Double
        var frames: [WindowID: Frame]
    }
    private var lastScrollRender: [SpaceID: ScrollRender] = [:]

    /// What the caller still has to do after `renderScroll`.
    private enum ScrollDraw {
        /// The animator took the frames; its landing writes them.
        case animating
        /// Write the settled frames now. `force` when a pan was interrupted
        /// to get here: windows are sitting at interpolated positions that
        /// the apps never heard about, so the AX write has to happen even
        /// where the WindowServer already agrees with the target.
        case settle(force: Bool)
    }

    /// Draw a scroll space's frames, as motion when the change is a pure pan.
    ///
    /// "Pure pan" means the only thing that changed since the last draw is the
    /// viewport — every window the same size in the same row at the same
    /// height, just further along. A width cycle, a resize, a column inserted
    /// mid-strip and a display change all fail that test and are drawn the way
    /// they always were, in one write. Interpolating those would need an AX
    /// size write per window per frame, which is the cost §1 rules out.
    private func renderScroll(
        sid: SpaceID,
        state: ScrollState,
        screen: Frame,
        config: TilingConfig,
        settled: [WindowID: Frame],
        parkedNow: Set<WindowID>
    ) -> ScrollDraw {
        let usableW = scrollUsable(screen: screen, config: config).w
        let toVX = state.effectiveViewportX(usableW: usableW)
        let toAll = scrollStripFrames(state, screen: screen, config: config, viewportX: toVX)
        // Read-and-replace under one lock: two renders of the same strip can
        // land from different queues (a keybind on `incoming`, a sweep on
        // `syncQueue`), and splitting this in two let the second one read the
        // first one's target as though it were where the windows are.
        let previous: ScrollRender? = panLock.withLock {
            let was = lastScrollRender[sid]
            lastScrollRender[sid] = ScrollRender(vx: toVX, frames: toAll)
            return was
        }

        let ms = currentConfig().general.scrollAnimationMs
        guard ms > 0, state.fullscreen == nil, !toAll.isEmpty, let previous else {
            return .settle(force: panAnimator.cancel(sid: sid))
        }
        // Would the last draw's geometry, re-derived from the strip as it is
        // now, land exactly where it actually did? If not, something other
        // than the viewport moved and this is not a pan.
        let atLast = scrollStripFrames(
            state, screen: screen, config: config, viewportX: previous.vx
        )
        let pure = atLast.allSatisfy { wid, f in
            guard let p = previous.frames[wid] else { return false }
            return abs(p.x - f.x) < 1 && abs(p.y - f.y) < 1
                && abs(p.width - f.width) < 1 && abs(p.height - f.height) < 1
        }
        guard pure else { return .settle(force: panAnimator.cancel(sid: sid)) }
        // A pan already heading here keeps going. Sweeps re-derive the same
        // layout for all sorts of reasons — a focus notification, a space
        // event, a rule re-check — and restarting the pan on each of them
        // would reset the clock and leave the strip creeping.
        let running = panAnimator.state(of: sid)
        if let running, abs(running.target - toVX) < 1 { return .animating }
        // Otherwise a pan in flight continues from where it has reached, so a
        // held-down key reads as one scroll rather than a series of restarts.
        let fromVX = running?.current ?? previous.vx
        guard abs(toVX - fromVX) > 1 else {
            return .settle(force: panAnimator.cancel(sid: sid))
        }
        let scope = Set(state.windows)
        // Only the columns that cross this display at some point in the pan
        // take part in it. The rest stay SLS-parked beyond the display union
        // where they already are: their true strip positions are hundreds or
        // thousands of points off the edge, and on a multi-display desktop
        // "off the edge" is *the next monitor* — which is the whole reason
        // parking targets `union.minX - 5000` rather than `-width`.
        //
        // Motion is monotonic, so the exact test is whether the interval each
        // window sweeps overlaps the screen at all.
        let participants = scrollPanParticipants(
            state, screen: screen, config: config, from: fromVX, to: toVX
        )
        guard !participants.isEmpty else {
            return .settle(force: panAnimator.cancel(sid: sid))
        }
        let parkX = (SpaceControl.displayLayout().map { $0.frame.x }.min() ?? screen.x) - 5000
        panAnimator.run(
            sid: sid,
            from: fromVX,
            to: toVX,
            duration: Double(ms) / 1000.0,
            onFrame: { [weak self] vx in
                guard let self else { return }
                let all = scrollStripFrames(
                    state, screen: screen, config: config, viewportX: vx
                )
                var moves: [WindowID: Frame] = [:]
                var onScreen: [WindowID: Frame] = [:]
                for wid in participants {
                    guard let f = all[wid] else { continue }
                    if f.x < screen.x + screen.width, f.x + f.width > screen.x {
                        // Genuinely part-way off the edge, which is exactly
                        // what `SLSMoveWindow` can do and AX cannot: the
                        // WindowServer clips it, so a column arrives by
                        // sliding in rather than appearing once it fits.
                        moves[wid] = f
                        onScreen[wid] = f
                    } else {
                        // Not on this display yet (or any more) — hold it off
                        // past every display rather than at its true strip
                        // position, which could be a neighbouring monitor.
                        moves[wid] = Frame(x: parkX, y: f.y, width: f.width, height: f.height)
                    }
                }
                self.applier.movePositions(moves)
                guard self.bordersBridge.drawsBorders else { return }
                // A border drawn around a column that is still off screen is
                // a rectangle floating in the void.
                self.bordersBridge.renderer.update(frames: onScreen, scope: participants)
            },
            onEnd: { [weak self] end in
                guard let self else { return }
                switch end {
                case .cancelled:
                    return  // the daemon is writing the settled frames itself
                case .superseded(by: let other) where other == sid:
                    return  // the newer pan on this strip owns these windows
                case .landed, .superseded:
                    break
                }
                // The forced apply is the point of the whole arrangement: the
                // pan moved every window behind its app's back, and this is
                // where each app is told where it now is. A pan cut short by
                // another display's strip settles here too — leaving those
                // windows frozen part-way across the screen is the one outcome
                // that has to be impossible.
                self.applyFrames(settled, force: true)
                self.reconcileParked(parkedNow: parkedNow, frames: settled, scope: scope)
                self.refreshDividerZones()
            }
        )
        return .animating
    }

    /// Forget a space's last draw, so the next one cannot be mistaken for a
    /// continuation of it. Layout conversions and display changes both make
    /// the stored geometry describe a strip that no longer exists.
    private func forgetScrollRender(_ sid: SpaceID? = nil) {
        panLock.withLock {
            if let sid { lastScrollRender.removeValue(forKey: sid) } else { lastScrollRender = [:] }
        }
    }

    // MARK: - Scroll apply + parking (M5)

    /// Parked windows (SLS-parked off-screen). Persisted across launches so
    /// a crash between park and unpark can't strand a window: the first sync
    /// unparks anything visible again (§11 risk 3, full restore lands in M7).
    private var parkedWindows: Set<WindowID> = []

    /// Apply one space's layout (all kinds). Tiling writes frames + raises;
    /// scroll ensures the viewport, applies visible frames, reconciles the
    /// parked set; float never positions — it only fronts the focused window.
    ///
    /// `stealFocus=false` (default, all background/sync paths): raise-only,
    /// no app activation, no mouse warp, no windowFocused emit. Activation is
    /// what yanked Spaces around on every sync — `NSApp.activate` pulls the
    /// target app's space forward. Only explicit user focus verbs pass true.
    ///
    /// `raiseFocus=false` drops even the raise. Needed for a space that is
    /// visible on *another display*: raising a window there hands that
    /// display the active menu bar, which turned `move display` — a move that
    /// is not supposed to follow — into a display switch.
    /// `force` skips the apply-path diff, for a caller that has been moving
    /// windows with `SLSMoveWindow` and needs each app told where it ended up.
    private func applySpaceLayout(
        _ sid: SpaceID, stealFocus: Bool = false, raiseFocus: Bool = true, force: Bool = false
    ) {
        let screen = self.usableScreen(for: sid)
        let config = currentConfig().general.asTilingConfig()
        guard let spaceLayout = readSpaces().layouts[sid] else { return }
        switch spaceLayout {
        case .tiling(let tree):
            forgetScrollRender(sid)
            let frames = layout(tree, in: screen, config: config)
            applyFrames(frames, force: force)
            // A space that was scroll a moment ago can still have columns
            // SLS-parked at -5000. bsp gives every window a frame, so nothing
            // here is meant to be hidden: bring them all back, or they stay
            // invisible until the space is switched to scroll again.
            reconcileParked(parkedNow: [], frames: frames, scope: Set(tree.windows))
            if let focus = tree.focus, raiseFocus {
                raiseFronts([focus])
                if stealFocus, let pid = pids[focus] {
                    focusAndWarp(window: focus, pid: pid)
                }
            }
        case .scroll(var sc):
            sc.ensureVisible(sc.focusCol, screen: screen, config: config)
            updateSpaces { sp in
                if case .scroll(let cur) = sp.layouts[sid], cur.viewportX != sc.viewportX {
                    sp.layouts[sid] = .scroll(sc)
                }
            }
            let (frames, parkedNow) = scrollLayout(sc, screen: screen, config: config)
            switch renderScroll(
                sid: sid, state: sc, screen: screen, config: config,
                settled: frames, parkedNow: parkedNow
            ) {
            case .animating:
                break  // the pan writes the frames when it lands
            case .settle(let interrupted):
                applyFrames(frames, force: force || interrupted)
                reconcileParked(parkedNow: parkedNow, frames: frames, scope: Set(sc.windows))
            }
            if let focus = sc.focusedWindow, raiseFocus {
                raiseFronts([focus])
                if stealFocus, let pid = pids[focus] {
                    focusAndWarp(window: focus, pid: pid, target: frames[focus])
                }
            }
        case .float(let fl):
            forgetScrollRender(sid)
            // Never position floats — but do put back anything this space
            // parked while it was a scroll strip, to its remembered frame.
            reconcileParked(parkedNow: [], frames: fl.remembered, scope: Set(fl.windows))
            // Front the focused one so focus changes stay visible; everything
            // else is the user's arrangement.
            if let focus = fl.focus, let pid = pids[focus], raiseFocus {
                if stealFocus {
                    focusAndWarp(window: focus, pid: pid)
                } else {
                    applier.raise(focus, pid: pid)
                }
            }
        }
        refreshDividerZones()
    }

    private func applyCurrentSpace() {
        if let sid = currentSID() {
            applySpaceLayout(sid)
        }
    }

    /// Bundle id for a pid, cached (immutable per pid; empty = none).
    /// Reached from the core queue, the sync queue and the bus queue, so the
    /// cache carries its own lock rather than relying on the caller's.
    private func bundleID(for pid: Int32) -> String? {
        if let cached = bundleLock.withLock({ bundleCache[pid] }) {
            return cached.isEmpty ? nil : cached
        }
        let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        bundleLock.withLock { bundleCache[pid] = b }
        return b.isEmpty ? nil : b
    }

    /// Space-placement rule, attempted once per window lifetime. Pre-SA this
    /// always reports the honest error; post-SA it just starts working.
    /// Returns whether the window actually moved.
    @discardableResult
    private func attemptRuleMoveToSid(
        wid: WindowID, app: String, sid: SpaceID, label: String
    ) -> Bool {
        if SpaceControl.moveWindowToSpace(wid, sid) {
            fputs("weftd: rule moved \(app) (\(wid)) to \(label)\n", stderr)
            return true
        }
        fputs("weftd: rule cannot place \(app) (\(wid)) on \(label) (needs weft-sa)\n", stderr)
        return false
    }

    /// Diff the computed parked set against the tracked one: SLS-park newly
    /// hidden columns, nudge-unpark newly visible ones. Unpark failures stay
    /// tracked (retried next sync); park failures stay untracked (retried as
    /// newly-hidden next sync). All SLS-local except the AX nudge.
    ///
    /// `scope` is the windows this layout is entitled to speak for — the
    /// space being applied. `parkedWindows` is global, so without it applying
    /// a bsp space would have unparked every scrolled-away column on every
    /// *other* scroll space, dumping them on top of the space in front.
    private func reconcileParked(
        parkedNow: Set<WindowID>, frames: [WindowID: Frame], scope: Set<WindowID>
    ) {
        let before = readParked()
        let applier = self.applier
        let unionMinX = SpaceControl.displayLayout().map { $0.frame.x }.min() ?? 0
        let parkX = unionMinX - 5000
        // The tracked set is a claim about the screen, and it can be wrong in
        // both directions: a park the WindowServer dropped, a window whose id
        // was recycled onto a new window that was never parked at all. Both
        // leave a window recorded as parked while it sits in the layout's way,
        // and a window recorded as parked is one this diff will never park.
        // So the entries that matter — the ones this layout wants hidden —
        // are checked against the WindowServer rather than believed. One SLS
        // bounds read each, no app IPC, only for columns that are off screen
        // anyway.
        let stale = before.intersection(parkedNow).filter {
            !applier.isParked($0, leftOf: unionMinX)
        }
        let toPark = parkedNow.subtracting(before).union(stale)
        let toUnpark = before.intersection(scope).subtracting(parkedNow)
        guard !toPark.isEmpty || !toUnpark.isEmpty else { return }
        let pids = self.pids
        // Async, not sync.
        //
        // `unpark` is the nudge protocol: an SLS move plus two AX writes taken
        // *synchronously* on the target app's queue. Blocking the caller on
        // that meant every column that scrolled into view charged its app's
        // round trip to whatever asked — a keybind on the command queue, or a
        // mouse event mid-drag. `applyQueue` is serial, so the ordering these
        // need is still exact; nothing waits on the result.
        applyQueue.async {
            var next = self.readParked()
            for wid in toPark.sorted() {
                if applier.park(wid, toX: parkX) {
                    next.insert(wid)
                }
            }
            for wid in toUnpark.sorted() {
                guard let frame = frames[wid] else {
                    next.remove(wid)  // no target (window gone?) — rescue reports it
                    continue
                }
                guard let pid = pids[wid] else { continue }  // stays tracked, retried
                if applier.unpark(wid, pid: pid, to: frame) {
                    next.remove(wid)
                }
            }
            self.writeParked(next)
            self.saveParked()
        }
    }

    /// `parkedWindows` is mutated on `applyQueue` and read from the command
    /// and mouse queues (`rescue`, and the reconcile's own entry check), so it
    /// carries a lock rather than relying on the caller's queue.
    private func readParked() -> Set<WindowID> {
        parkedLock.withLock { parkedWindows }
    }

    private func writeParked(_ next: Set<WindowID>) {
        parkedLock.withLock { parkedWindows = next }
    }

    /// Sweep for stranded windows: SLS bounds far off every display that are
    /// neither tracked-parked nor covered by a current layout. Crash debris
    /// (§11 risk 3) gets nudge-unparked to its computed frame when known.
    private func rescue() -> String {
        let minX = SpaceControl.displayLayout().map { $0.frame.x }.min() ?? 0
        var tracked = 0
        var healed = 0
        var unknown: [WindowID] = []
        let frames = currentVisibleFrames()
        let tracked0 = readParked()
        for wid in pids.keys.sorted() {
            guard let f = WorldReader.frame(of: wid), f.x + f.width < minX - 1000 else { continue }
            if tracked0.contains(wid) {
                tracked += 1
            } else if let target = frames[wid], let pid = pids[wid] {
                if applier.unpark(wid, pid: pid, to: target) {
                    healed += 1
                } else {
                    unknown.append(wid)
                }
            } else {
                unknown.append(wid)
            }
        }
        return "rescue: tracked-parked=\(tracked) healed=\(healed) stranded=\(unknown)"
    }

    /// Computed frames for the current space (tiling + visible scroll;
    /// float shows remembered user frames; parked excluded everywhere).
    /// Uses usableScreen (menu bar/Dock/reserve excluded) — the raw `screen`
    /// rect here previously disagreed with applySpaceLayout by the reserve
    /// height, so rescue/query placed windows under the bar.
    private func currentVisibleFrames() -> [WindowID: Frame] {
        let screen = self.usableScreen(for: currentSID())
        let config = currentConfig().general.asTilingConfig()
        switch currentLayout() {
        case .tiling(let tree):
            return layout(tree, in: screen, config: config)
        case .scroll(let sc):
            let (frames, _) = scrollLayout(sc, screen: screen, config: config)
            return frames
        case .float(let fl):
            return fl.remembered
        }
    }
}

private struct FrameEntry: Codable, Sendable {
    var id: WindowID
    var frame: Frame
}

private struct StateView: Codable, Sendable {
    var focus: WindowID?
    var windows: [WindowID]
    var screen: Frame
    var frames: [FrameEntry]
    var parked: [WindowID]
}

private struct DaemonPermissions: Codable, Sendable {
    /// The path the user must add in System Settings — not weftctl's, not
    /// WeftBar's. Shown verbatim so it can be pasted or revealed in Finder.
    var binary: String
    var accessibility: Bool
    /// The Input Monitoring switch itself, as TCC has it. Says nothing about
    /// whether keybinds work — see `keybindsLive` for that.
    var inputMonitoring: Bool
    /// The live event tap: what keybinds and mouse gestures actually run on.
    /// It can be up with `inputMonitoring` off (Accessibility covers it), and
    /// down with it on (a tap that failed and has not been retried), so the
    /// two are reported apart and never collapsed into one checkmark.
    var keybindsLive: Bool
    var screenRecording: Bool
    /// Whether a rebuild will keep these grants — see
    /// `Permissions.hasStableSigningIdentity()`. False means any switch that
    /// reads as on in System Settings may be granting nothing.
    var stableIdentity: Bool
    /// Accessibility was granted *after* this process started, so its AX
    /// connections are stale and nothing will work until it is restarted.
    /// The one thing weft cannot fix for itself, and the one thing it can
    /// reliably ask for.
    var needsRestart: Bool
    /// Functional readiness, not a count of switches. Screen Recording is in
    /// here because without it `kCGWindowName` is redacted for every window
    /// weftd does not own — titles come back empty and every title-matching
    /// rule silently stops matching.
    var allGranted: Bool {
        accessibility && keybindsLive && screenRecording && !needsRestart
    }
}

/// `query windows`: a WindowInfo plus weft's verdict on it. `floating` is nil
/// for a window in a layout, and otherwise names why it is not — "manual"
/// (the user floated it), "popup" (not a tileable window), "quirk" (refused
/// its frame twice), "rule" (a `manage = false` rule matched).
private struct WindowStatus: Codable, Sendable {
    var id: WindowID
    var app: String
    var title: String
    var pid: Int32
    var spaces: [SpaceID]
    var frame: Frame
    var bound: Bool
    var floating: String?
}

private struct DisplayStatus: Codable, Sendable {
    var index: Int
    var uuid: String
    /// Menu bar and Dock already excluded.
    var frame: Frame
    /// `frame` minus the config reserve — what layouts actually tile into.
    var usable: Frame
    var spaces: [SpaceID]
    var currentSpace: SpaceID?
    var focused: Bool
}

private struct SpaceStatus: Codable, Sendable {
    var id: SpaceID
    var label: String
    var layout: String
    var windows: [WindowID]
    var current: Bool
    var display: String
}

private struct FloatView: Codable, Sendable {
    var order: [WindowID]
    var focus: WindowID?
}

/// Locked box for crossing the apply completion (which is @Sendable) back
/// onto the handler thread.
private final class ApplyResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = AXApplier.ApplyResult(applied: 0, skipped: 0, errors: 0)

    var value: AXApplier.ApplyResult {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// MARK: - main

ignoreSIGPIPE()
setlinebuf(stderr)  // launchd/log captures must see lines instantly, not on exit

// Check Accessibility without triggering a macOS modal prompt
if !Permissions.accessibility() {
    fputs("weftd: accessibility permission missing\n", stderr)
}

guard let daemon = Daemon() else { exit(1) }
let path = IPCPaths.socketPath()
fputs("weftd: listening on \(path)\n", stderr)
let server = IPCServer(path: path) { line, conn in
    daemon.handle(line: line, conn: conn)
}

// The socket loop is a blocking accept(); it goes on a background thread so
// the MAIN THREAD CAN RUN A RUN LOOP.
//
// This is load-bearing, not tidiness. NSWorkspace notifications
// (didLaunchApplication, didTerminateApplication, activeSpaceDidChange) and
// CGDisplayRegisterReconfigurationCallback are all delivered through the main
// run loop. With `server.run()` on the main thread none of them ever fired,
// so the daemon never learned that:
//   - an app launched  → its windows were never discovered or tiled
//   - the active space changed by any means other than weft's own `space
//     focus` → every subsequent command operated on the wrong space
//   - a display was added, removed or resized
// AX observers were unaffected (they own a run loop on their own thread),
// which is why *some* events still arrived and made the gap hard to see.
DispatchQueue.global(qos: .userInitiated).async {
    server.run()
}
// First sweep after the listener is up, so a `weftctl` or a menu-bar app that
// reconnects the instant launchd restarts the service finds a socket rather
// than a refused connection.
daemon.start()
CFRunLoopRun()
