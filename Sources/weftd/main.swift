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
    private let layoutSaveQueue = DispatchQueue(label: "weft.layout-save", qos: .utility)
    /// `WEFT_TRACE=1` puts every bus event in the log. Off by default: it is
    /// a write syscall per event, and the events are the noisiest thing weft
    /// does.
    static let traceEvents = ProcessInfo.processInfo.environment["WEFT_TRACE"] == "1"
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
    /// Where stack members peek out behind the front one, on the visible
    /// spaces. Published to the tap as bare rects; kept here with the member
    /// each belongs to, so a claimed click can be resolved. Under
    /// `dividerLock`, alongside the divider zones it is refreshed with.
    private var stackPeekZones: [StackPeek] = []
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
            // Both consumers below are opt-in, and the summary costs a
            // core-queue hop on every flushed event. Skip it when neither
            // would read it.
            let integrations = self.currentConfig().integrations
            let bordersWantColour = integrations.borders.enabled
                && (!integrations.borders.activeColor.isEmpty || !integrations.borders.modeColor.isEmpty)
            guard integrations.sketchybar.enabled || bordersWantColour else { return }
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
        startSpaceWatch()
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
                self?.requestInputAccess(reason: "tap denied at startup")
            }
            self?.startTapWatch()
        }
    }

    /// Keeps the event tap alive for the life of the daemon.
    ///
    /// A tap that failed at startup — Accessibility not granted yet, or TCC
    /// still settling after a login or an OS update — was only ever retried
    /// when something queried permissions, which in practice meant only while
    /// WeftBar was running and polling. Otherwise keybinds stayed dead until
    /// weftd was restarted. A live tap can also be switched off or invalidated
    /// without the callback ever hearing about it, and the same check turns it
    /// back on or rebuilds it. Every 5 s with a wide leeway: two cheap calls,
    /// nothing on core.
    private func startTapWatch() {
        tapWatchQueue.async { [weak self] in
            guard let self, self.tapWatch == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.tapWatchQueue)
            timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(2))
            timer.setEventHandler { [weak self] in _ = self?.input.ensureTap() }
            timer.resume()
            self.tapWatch = timer
        }
    }

    private let tapWatchQueue = DispatchQueue(label: "weft.tap-watch", qos: .utility)
    /// Touched only on `tapWatchQueue`.
    private var tapWatch: DispatchSourceTimer?

    /// Ask TCC for Input Monitoring — and, more to the point, get weftd *listed*.
    ///
    /// This is not about showing a dialog. It is what makes macOS add a weftd
    /// row to the Input Monitoring list; without it the list has no such row
    /// and the only way in is the `+` picker, which cannot browse to
    /// `~/.local/bin` because a dotted directory is hidden. Being told to
    /// "find weftd" in a folder Finder refuses to show is the whole of that
    /// complaint.
    ///
    /// It does raise a system modal, though, and at startup that modal landed
    /// on top of the Setup window whose entire job is to walk the user through
    /// this permission — a second, unexplained dialog from a process with no
    /// window of its own. So when WeftBar is running it is left to Setup,
    /// which calls `request-input-access` over the socket at the step where
    /// the user is already reading about Input Monitoring.
    private func requestInputAccess(reason: String) {
        // Only ever for Setup. weftd used to ask by itself when no Setup
        // window was open, which put a system dialog up out of nowhere; now
        // every permission prompt comes from a Setup step the user clicked.
        if reason == "Setup asked" {
            _ = CGRequestListenEventAccess()
            fputs("weftd: requested Input Monitoring (\(reason)) — weftd should now be listed "
                + "in System Settings › Privacy & Security › Input Monitoring; switch it on\n",
                stderr)
            return
        }
        fputs("weftd: Input Monitoring not granted; leaving the request to the Setup "
            + "window rather than stacking a second dialog on top of it\n", stderr)
    }

    /// Is WeftBar — and therefore possibly its Setup window — running?
    private static func setupIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.weft.bar").isEmpty
    }

    /// Everything that must happen once, after the socket is listening.
    ///
    /// Callers that arrive during the first sweep are not turned away: the
    /// socket accepts them, and `handle` runs their command on `incoming`
    /// behind the sweep, so the worst case is a command that answers late
    /// rather than one that fails.
    func start() {
        // Said once, at the top of the log, because it explains everything
        // after it: with Stage Manager on, macOS moves windows weft has just
        // placed, and each of those moves reads like a weft bug.
        if SystemChecks.stageManagerEnabled() {
            fputs(
                "weftd: WARNING Stage Manager is on — macOS will move windows weft places. "
                    + "Turn it off: \(SystemChecks.stageManagerSetting)\n",
                stderr
            )
        }
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
    /// window's old rectangle.
    private func focusAndWarp(window: WindowID, pid: Int32, target: Frame? = nil) {
        noteFocusedWindow(window)
        applier.focusWindow(window, pid: pid)
        warpMouseToWindow(window, target: target)
        bus.emit(DaemonEvent(kind: .windowFocused, window: window))
    }

    private func findWindow(at point: CGPoint) -> (wid: WindowID, frame: Frame, isFloating: Bool)? {
        let px = Double(point.x)
        let py = Double(point.y)
        // Off-core (this runs on `incoming`), so take the set through core
        // rather than reading the live one under the frame reads below.
        for wid in core.sync(execute: { self.manualFloat }) {
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
              let layout = sp.layout(on: sid)
        else { return nil }
        let screen = usableScreen(for: sid)
        let config = currentConfig().general.asTilingConfig()
        switch layout {
        case .tiling(let t):
            let frames = WeftCore.layout(t, in: screen, config: config)
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
                // A stack strip first: a click on a member peeking out
                // behind the front one means "that one", and it is the one
                // bare click here that *should* take focus.
                let (zones, peeks) = dividerLock.withLock { (dividerZones, stackPeekZones) }
                let px = Double(location.x), py = Double(location.y)
                if let peek = peeks.first(where: { $0.rect.contains(x: px, y: py) }) {
                    raiseStackMember(peek.member)
                    return
                }
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
            if let pid = pid(of: hit.wid) {
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
                        switch sp.layout(on: sid) {
                        case .tiling(let t):
                            sp.setLayout(.tiling(t.swapping(drag.windowID, target.wid)), on: sid)
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
        let frames: [WindowID: Frame]? = core.sync {
            guard let sid = self.spaces.currentSpace,
                  case .tiling(let tree)? = self.spaces.layout(on: sid)
            else { return nil }
            let screen = self.usableScreen(for: sid)
            let config = self.currentConfig().general.asTilingConfig()
            let current = WeftCore.layout(tree, in: screen, config: config)
            let next = tree.resizing(
                divider: d.a, d.b, axis: d.axis,
                deltaPoints: delta, frames: current
            )
            guard next != tree else { return nil }
            self.spaces.setLayout(.tiling(next), on: sid)
            return WeftCore.layout(next, in: screen, config: config)
        }
        guard let frames else { return }
        applyFramesCoalesced(frames)
    }

    /// A click on a stack's peeking strip: bring that member to the front.
    ///
    /// The same state change `stack next` makes, aimed at one member rather
    /// than the next one along. No cursor warp: the pointer is already on the
    /// strip the user clicked, and yanking it to the window's centre would
    /// be the opposite of what they just did.
    private func raiseStackMember(_ wid: WindowID) {
        let sp = readSpaces()
        guard let sid = sp.visibleSpaces.first(where: {
            sp.layout(on: $0)?.windows.contains(wid) == true
        }), let pid = pid(of: wid) else { return }
        updateSpaces { s in
            if case .tiling(let t)? = s.layout(on: sid), t.windows.contains(wid) {
                s.setLayout(.tiling(t.focusing(wid)), on: sid)
            }
        }
        applySpaceLayout(sid)
        noteFocusedWindow(wid)
        applier.focusWindow(wid, pid: pid)
        bus.emit(DaemonEvent(kind: .windowFocused, window: wid))
        bus.emit(stateChangedEvent())
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
        if bordersBridge.drawsBorders { bordersBridge.renderer.move(frames) }
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
            dividerLock.withLock {
                dividerZones = []
                stackPeekZones = []
            }
            input.updateDividerZones([])
            input.updateStackZones([])
            return
        }
        let config = cfg.asTilingConfig()
        var all: [Divider] = []
        var peeks: [StackPeek] = []
        // From the same numbers the apply just used. A border process learns
        // a window moved after the fact and reads the geometry back, which is
        // why its borders trail the window.
        var borderFrames: [WindowID: Frame] = [:]
        // One core hop for the whole refresh, not one per space: this runs at
        // the end of every apply, and the core queue is what keybinds wait on.
        let sp = readSpaces()
        // Which desktops are showing, asked of the WindowServer rather than of
        // weft's cache of it. The two disagree for as long as it takes weft to
        // notice a switch it did not perform — a trackpad swipe, Mission
        // Control, an app activating elsewhere — and `space focus` already
        // refuses to trust the cache for exactly that reason. Grab zones and
        // borders describe what is *on screen*, and the border pieces are
        // sticky so they render on whatever desktop is showing: believing the
        // cache here paints the previous desktop's layout over the new one.
        // One call, ~40 µs, no window list.
        let showing = WorldReader.currentSpaces()
        for (uuid, sid) in showing {
            guard let layout = sp.layout(on: sid) else { continue }
            let screen = usableScreen(onDisplay: sp.displayBySpace[sid] ?? uuid)
            let frames: [WindowID: Frame]
            var grabbable = true
            switch layout {
            case .tiling(let tree):
                // A fullscreen window covers its neighbours, so there is no
                // border to grab and every pair overlaps anyway.
                grabbable = tree.fullscreen == nil
                frames = WeftCore.layout(tree, in: screen, config: config)
                peeks += stackPeeks(in: tree, frames: frames)
                if wantBorders {
                    // Stack members behind the front one have a slot and a
                    // peek strip, but no border of their own.
                    let hidden = hiddenStackMembers(in: tree)
                    for (wid, frame) in frames where !hidden.contains(wid) { borderFrames[wid] = frame }
                }
            case .float(let fl):
                grabbable = false
                // A float space has no computed geometry — the windows are
                // wherever the user put them, so read it.
                frames = liveFrames(of: fl.windows)
                if wantBorders { borderFrames.merge(frames) { current, _ in current } }
            }
            if grabbable && cfg.mouseBorderResize {
                all += dividers(in: frames, innerGap: cfg.innerGap)
            }
        }
        let clickablePeeks = cfg.mouseBorderResize ? peeks : []
        dividerLock.withLock {
            dividerZones = all
            stackPeekZones = clickablePeeks
        }
        input.updateDividerZones(cfg.mouseBorderResize ? all.map(\.rect) : [])
        input.updateStackZones(clickablePeeks.map(\.rect))
        if wantBorders {
            // Drop the windows that are in a layout but not on screen.
            //
            // Closing a window does not always destroy it — Ghostty and most
            // Electron apps order it out and keep it — and minimising does not
            // either. Neither produces a destroy notification, so the layout
            // goes on holding the window and, before this, went on drawing a
            // border around the place it used to be. `evictOrderedOut` finds
            // them, but only on the next focus change, and closing a window
            // with the mouse need not move focus at all.
            let onScreen = WorldReader.onScreenWindowIDs()
            borderFrames = borderFrames.filter { onScreen.contains($0.key) }
            // Only windows in a layout, which is what keeps popovers,
            // Spotlight and every other transient panel border-free with no
            // heuristic at all. The active border goes where macOS says focus
            // is: a float no layout owns gets none, rather than the last tile
            // keeping a highlight it no longer has.
            //
            // Passed through as the system reports it, *not* pre-resolved to
            // nil for a window with no border. `noteFocusedWindow` pushes the
            // raw value straight to the renderer on every focus change, so
            // filtering it only here meant the two writers disagreed and
            // whichever ran last won — with `show-inactive = false` that flips
            // between "no highlight" and "no borders at all". The renderer
            // holds the one rule: a focused window with no border makes no
            // border active.
            let focus = systemFocusLock.withLock { systemFocusLocked }
                ?? sp.currentSpace.flatMap { sp.layout(on: $0)?.focus }
            // Membership and targets — what the renderer is asked for. Its own
            // trace line prints what it actually drew, read from the
            // WindowServer. Comparing the two is how you tell a window weft
            // should not be bordering from a window that has not moved yet.
            if Trace.logging {
                let list = borderFrames.sorted { $0.key < $1.key }.map {
                    String(
                        format: "%u@%.0f,%.0f %.0fx%.0f", $0.key,
                        $0.value.x, $0.value.y, $0.value.width, $0.value.height)
                }
                fputs(
                    "weftd: borders focus=\(focus.map(String.init) ?? "none") "
                        + "frames=[\(list.joined(separator: "  "))]\n",
                    stderr
                )
            }
            bordersBridge.renderer.update(frames: borderFrames, focused: focus)
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
        guard let sid = currentSID(), let l = readSpaces().layout(on: sid) else { return nil }
        switch l {
        case .tiling: return .bsp
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
            let layout = sid.flatMap { sp.layout(on: $0) }
            let focus = layout?.focus
            return Snap(
                sid: sid,
                label: sid.flatMap { sp.workspace(on: $0)?.label },
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
        // The fallback is silent, and silence is the problem: a space whose
        // display does not resolve gets laid out into the *first* display's
        // rect, so its windows stay where they are and its borders are drawn
        // around a slot on another screen — a ring around nothing. Whether that
        // ever actually happens is exactly what a border bug report needs to
        // answer, so it says so instead of guessing later.
        let (raw, fellBackTo): (Frame, String?) = screensLock.withLock {
            if let uuid, let f = screensByUUID[uuid] { return (f, nil) }
            let first = displayOrder.first
            let frame = first.flatMap { screensByUUID[$0] } ?? Frame(x: 0, y: 0, width: 1, height: 1)
            return (frame, first ?? "none")
        }
        if let fellBackTo, Trace.logging {
            fputs(
                "weftd: no screen for display \(uuid ?? "nil") — laying out against \(fellBackTo) "
                    + "instead. Frames computed against the wrong display look exactly like a "
                    + "border around nothing.\n",
                stderr
            )
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
        systemFocusLock.withLock { systemFocusLocked = wid }
        // A recolour, or the one border moving over: no layout pass needed.
        if bordersBridge.drawsBorders { bordersBridge.renderer.setFocus(wid) }
        // Where the window physically is, for the ones membership cannot
        // answer for. A float, a rule's `manage = false`, a quirked window and
        // a panel are in no layout at all, so the loop below never matched
        // them and `focusedDisplay` stayed on the display the user had left —
        // and with it `currentSpace`, which is the space every following
        // command, every border pass and every new window resolves against.
        // Clicking a floating window on the second monitor and then pressing a
        // space keybind acted on the first monitor's desktop.
        let onDisplay = WorldReader.frame(of: wid).flatMap { f in
            displayUUID(containing: CGPoint(x: f.x + f.width / 2, y: f.y + f.height / 2))
        }
        updateSpaces { sp in
            for sid in sp.visibleSpaces where sp.layout(on: sid)?.windows.contains(wid) == true {
                sp.focusedDisplay = sp.displayBySpace[sid]
                return
            }
            if let onDisplay, sp.currentByDisplay[onDisplay] != nil {
                sp.focusedDisplay = onDisplay
            }
        }
    }

    /// The window macOS says has focus, whether or not weft manages it.
    ///
    /// A float or a window a rule unmanaged is in no layout, so nothing in
    /// `SpaceState` records that it is the one the user is typing into.
    /// Written from the observer thread, read from the apply path.
    private var systemFocusLocked: WindowID?
    private let systemFocusLock = NSLock()

    /// Whether focus is on a window no layout owns — a float over the tiles.
    private func focusIsUnmanaged() -> Bool {
        guard let focus = systemFocusLock.withLock({ systemFocusLocked }) else { return false }
        return !readSpaces().workspaces.values.contains { $0.layout.windows.contains(focus) }
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

    /// React to the space having changed, whoever changed it.
    ///
    /// Records what it acted on so the watcher below does not do it again for
    /// the same switch.
    private func handleSpaceChange() {
        let now = SpaceControl.currentSpaceByDisplay()
        actedSpacesLock.withLock { actedSpacesLocked = now }
        bus.emit(DaemonEvent(kind: .spaceChanged))
        // Borders are sticky, so the old desktop's would hang over the new
        // one until the sweep below replaces them.
        if bordersBridge.drawsBorders { bordersBridge.renderer.clear() }
        syncFromSnapshot()
    }

    /// Notice a space change macOS did not tell us about.
    ///
    /// `NSWorkspace.activeSpaceDidChangeNotification` is the fast path and
    /// stays the fast path, but it is not reliable enough to be the only one.
    /// It is a GUI-level notification arriving in a launchd daemon, it does
    /// not say which display moved, and on a trackpad swipe it can arrive
    /// while the WindowServer is still animating — so the sweep it triggers
    /// reads the space the user is leaving and files every window under it.
    /// What that looks like from the outside is a window manager that only
    /// understands the space changes it performed itself: swipe, and weft is
    /// on the wrong desktop until a keybind switch puts it right.
    ///
    /// So: ask — at the moments a change is likely, not three times a second
    /// forever. `currentSpaceByDisplay` is cheap (~40 µs, no window list), but
    /// a 3 Hz timer is still a WindowServer round trip and a CPU wake-up every
    /// 333 ms for the life of the daemon on a machine that is otherwise idle,
    /// which is the wrong trade for something that should cost nothing when
    /// nothing moves.
    ///
    /// The early notification is covered by looking again a beat after every
    /// one (`scheduleSpaceRechecks`). A switch with no notification at all
    /// almost always moves keyboard focus, and every focus event checks. What
    /// is left — a switch that neither notifies nor moves focus — is caught by
    /// a slow backstop with a wide leeway, so the kernel can fold its wake-up
    /// into one it was making anyway.
    private func startSpaceWatch() {
        // Seed it, or the first check reads a difference against an empty
        // dictionary and spends a full sweep re-discovering the desktop the
        // startup sweep just finished with.
        let start = SpaceControl.currentSpaceByDisplay()
        actedSpacesLock.withLock { actedSpacesLocked = start }
        let timer = DispatchSource.makeTimerSource(queue: syncQueue)
        timer.schedule(deadline: .now() + 3, repeating: 3, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.checkSpaceChanged() }
        timer.resume()
        spaceWatch = timer
    }

    /// Sweep only if the WindowServer is showing a different space from the
    /// one weft last acted on. On `syncQueue`, like everything that sweeps.
    private func checkSpaceChanged() {
        // A carry changes desktop once per step, and each change would sweep,
        // clear the borders and re-apply layouts — on top of the window still
        // being held. The desktop weft ends on is reconciled once the carry
        // returns, so there is nothing to do until then.
        guard !DragMove.isCarrying else { return }
        let now = SpaceControl.currentSpaceByDisplay()
        let acted = actedSpacesLock.withLock { actedSpacesLocked }
        guard !now.isEmpty, now != acted else { return }
        handleSpaceChange()
    }

    /// Look again after a space notification, for the swipe whose
    /// notification arrived while the WindowServer was still animating.
    private func scheduleSpaceRechecks() {
        for delay in [0.35, 1.0] {
            syncQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.checkSpaceChanged()
            }
        }
    }

    /// Fill in titles the window list would not give us.
    ///
    /// `kCGWindowName` comes back empty for every other process without Screen
    /// Recording, so title rules quietly never matched for anyone who had not
    /// granted it — and it is the permission people most reasonably decline to
    /// a window manager, since "record my screen" is not what they think they
    /// are agreeing to.
    ///
    /// AX has the same string for the asking and needs a permission weft
    /// cannot work without anyway. Paid for only where it buys something: no
    /// title rules in the config, nothing to do; a title already read, nothing
    /// to do. What is left is one round trip per untitled window on a config
    /// that actually matches on titles.
    private func fillMissingTitles(_ world: World, rules: [Rule]) -> World {
        guard rules.contains(where: { $0.title != nil }) else { return world }
        var world = world
        for i in world.windows.indices where world.windows[i].title.isEmpty {
            if let title = applier.title(of: world.windows[i].id) {
                world.windows[i].title = title
            }
        }
        return world
    }

    /// Whether weftd has ever put up macOS's own prompt for a permission.
    ///
    /// A marker file, not a flag in memory: the prompt is what creates the TCC
    /// row, the row outlives the process, and weftd restarts constantly. In
    /// memory it would prompt again on every restart, which is the behaviour
    /// this is here to stop.
    private func askMarker(_ service: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/weft/.asked-\(service)")
    }

    private func hasAsked(_ service: String) -> Bool {
        FileManager.default.fileExists(atPath: askMarker(service).path)
    }

    private func markAsked(_ service: String) {
        let url = askMarker(service)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
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

    /// What a desktop with no workspace on it would be laid out as: the kind
    /// the user last chose, else the `[[space]]` declaration, else the general
    /// default. Every caller reaches this through `layout(on:) ?? …`, so it is
    /// only ever asked about a desktop that has nothing — it used to open by
    /// returning the existing layout, which since workspaces became the thing
    /// that holds one is a branch no caller can take.
    private func resolvedInitialLayout(for sid: SpaceID, in sp: SpaceState) -> SpaceLayout {
        let cfg = currentConfig()
        let ws = sp.workspace(on: sid)
        let kind = ws?.overrideKind
            ?? cfg.spaces.first(where: { $0.label == (ws?.label ?? "") })?.layout
            ?? cfg.general.defaultLayout
        switch kind {
        case .float: return .float(FloatState())
        case .bsp: return .tiling(Tree())
        }
    }

    /// Current space's layout (dual-context). Absent (unvisited) reads as an
    /// empty layout matching space/default config — sync fills it in.
    private func currentLayout() -> SpaceLayout {
        let sp = readSpaces()
        guard let sid = sp.currentSpace else { return .tiling(Tree()) }
        return sp.layout(on: sid) ?? resolvedInitialLayout(for: sid, in: sp)
    }

    private func storeLayout(_ layout: SpaceLayout) {
        updateSpaces { sp in
            if let sid = sp.currentSpace {
                sp.setLayout(layout, on: sid)
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
        var world = WorldReader.snapshot()
        let tRead = Date()
        Trace.record("sweep.world", ms: tRead.timeIntervalSince(t0) * 1000)
        refreshScreens()
        let cfg = currentConfig()
        world = fillMissingTitles(world, rules: cfg.rules)
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
        let screenLocked = SystemChecks.screenLocked()
        let worldPids = Set(world.windows.map { $0.pid })
        // Bundle ids come from NSRunningApplication; resolve them before
        // taking the core queue so a slow lookup is not everyone's problem.
        var bundles: [Int32: String?] = [:]
        for pid in worldPids { bundles[pid] = bundleID(for: pid) }
        // Classify windows we have not seen before. One AX read each, here in
        // phase 1 where AX is allowed, never on the core queue (§13.2).
        let now = Date()
        // Windows judged "not a real window" a few seconds ago and never asked
        // again. See `negativeVerdict`: the first answer is taken while the
        // app may still be starting, and used to be the only one there was.
        let (unclassified, visibleSids, sinceSnapshot, recheck, wasNegative) = core.sync {
            let due = Set(
                self.negativeVerdict
                    .filter {
                        !self.recheckedNegatives.contains($0.key)
                            && now.timeIntervalSince($0.value) >= Self.negativeRecheckDelay
                    }
                    .map { $0.key }
            )
            return (
                world.windows.filter { self.standardWindow[$0.id] == nil || due.contains($0.id) },
                Set(self.spaces.visibleSpaces),
                self.unbindableSince,
                due,
                Set(self.negativeVerdict.keys)
            )
        }
        var freshlyClassified: [WindowID: Bool] = [:]
        var freshUnbindable: [WindowID: Date] = [:]
        // One fan-out for the whole sweep. Asking window by window meant a
        // cold start walked every app in series before anything was tiled.
        let tClassify0 = Date()
        let verdicts = applier.classifyBatch(unclassified.map { (wid: $0.id, pid: $0.pid) })
        let tClassify = Date()
        if !unclassified.isEmpty {
            Trace.record(
                "sweep.classify", ms: tClassify.timeIntervalSince(tClassify0) * 1000,
                detail: "\(unclassified.count) window(s)"
            )
        }
        for w in unclassified {
            if let verdict = verdicts[w.id] {
                switch verdict {
                case .success:
                    freshlyClassified[w.id] = true
                case .failure(let why):
                    freshlyClassified[w.id] = false
                    if !wasNegative.contains(w.id) {
                        fputs("weftd: floating \(w.app) (\(w.id)) — \(Self.reason(why))\n", stderr)
                    }
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
                if !wasNegative.contains(w.id) {
                    fputs("weftd: ignoring \(w.app) (\(w.id)) — on screen but AX cannot see it\n", stderr)
                }
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
            // Which workspaces already existed, taken before `adoptDesktops`
            // creates any. A workspace absent here is one weft has not visited
            // this launch, and further down that is what earns it a seeded
            // layout kind.
            let priorKeys = Set(sp.workspaces.keys)
            if sp.workspaces.isEmpty {
                // Fresh launch: seed names from weft.toml [[space]] decls so a
                // first config just works; falls back to labels.json, then numerics.
                // Delete labels.json to re-adopt the config's names wholesale.
                let declared = cfg.spaces.map { $0.label }
                sp.adoptDesktops(
                    allSids, names: declared.isEmpty ? Daemon.loadLabels() : declared
                )
                // After, not before: an override belongs to a workspace, and
                // `adoptDesktops` is what builds both the workspaces and the
                // order the saved list is counted in.
                sp.assignOverrides(kinds: Daemon.loadLayoutOverrides())
            } else {
                // Desktops added/removed at runtime: keep every existing label,
                // but re-derive the ordinal list so `space focus 3` still means
                // the third desktop on screen. `names: nil` is what says "keep
                // what is already named"; a desktop that is new gets its number.
                //
                // This used to be open-coded here and left more behind than it
                // took: labels were dropped for a vanished desktop and its
                // layout was not — that fell to `syncMembership`'s live filter,
                // which had no idea the desktop was gone and only knew it was
                // not in the list. Now one function owns creation and removal,
                // and removes the workspace, what is showing on the desktop and
                // the layout override together.
                sp.adoptDesktops(allSids, names: nil)
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
            if let old = oldCurrent, let nw = newCurrent, old != nw,
               let previous = sp.active[old] {
                // Only a desktop that still exists can become "recent". It used
                // to be recorded as a raw space id whether or not the desktop
                // survived the sweep, so unplugging a display left `space focus
                // recent` pointing at a dead one and answering "space N is not
                // on any display" until something else moved.
                sp.recentWorkspace = previous
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
            self.negativeVerdict = self.negativeVerdict.filter { worldWids.contains($0.key) }
            self.recheckedNegatives = self.recheckedNegatives.intersection(worldWids)
            // One re-ask per window, and only for a verdict that went against
            // it. Asked and answered the same way twice is the app telling us
            // the truth; asked once while it was still launching is not.
            self.recheckedNegatives.formUnion(recheck)
            for (wid, standard) in freshlyClassified {
                if standard {
                    self.negativeVerdict.removeValue(forKey: wid)
                    self.recheckedNegatives.remove(wid)
                } else if self.negativeVerdict[wid] == nil {
                    self.negativeVerdict[wid] = now
                }
            }
            self.unbindableSince = self.unbindableSince.filter {
                worldWids.contains($0.key) && self.standardWindow[$0.key] == nil
            }
            for (wid, first) in freshUnbindable where self.standardWindow[wid] == nil {
                self.unbindableSince[wid] = first
            }
            self.spaceMoveAttempts = self.spaceMoveAttempts.intersection(worldWids)
            self.spaceMoveDeferredLogged = self.spaceMoveDeferredLogged.intersection(worldWids)
            var windowDesktops: [WindowID: [SpaceID]] = [:]
            var unmanagedNow: Set<WindowID> = []
            let showing = Set(sp.currentByDisplay.values)
            for w in world.windows {
                self.pids[w.id] = w.pid
                self.appNames[w.id] = w.app
                self.windowTitles[w.id] = w.title
                // Floated by hand, and it stays floated.
                //
                // `manualFloat` was folded into `unmanagedNow` *after* this
                // loop, which set the "do not manage it" flag and left the
                // window in `windowDesktops` all the same — so the sweep put
                // it straight back into its space's tree and the next apply
                // tiled it. `float toggle` therefore held only until the next
                // sweep: leave the desktop and come back, or open any window
                // anywhere, and the float was a tile again. Every other
                // reason to leave a window alone — a rule, a quirk, a panel —
                // already skips the membership line below, and this is the
                // one that did not.
                if self.manualFloat.contains(w.id) {
                    unmanagedNow.insert(w.id)
                    continue
                }
                // Closed but kept: on a showing desktop, not on screen. Not
                // a tile (`isTileable`), and not unmanaged either — if the
                // app shows it again, the next sweep gives it a slot.
                if !screenLocked, !w.isTileable(visibleSpaces: showing) { continue }
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
                    // The space half of a rule is independent of the tiling
                    // half, and is read first: `manage = false` says "do not
                    // lay this window out", not "leave it wherever it opened".
                    // A float with `space = "main"` used to be dropped here
                    // before the move was ever considered, so the rule did
                    // half of what it said and said nothing about the rest.
                    //
                    // Only windows AX has positively classified as standard
                    // are moved. A cross-space move is the one thing in a
                    // sweep that does not correct itself next time round: get
                    // it wrong and the window is on another desktop, and an
                    // app whose sheet or popover was carried off alone stops
                    // routing clicks and scrolls to the parent it left behind.
                    // `nil` here is "AX has not answered yet" — the 1.1s
                    // reclassify sweep is already scheduled, and leaving the
                    // window out of `spaceMoveAttempts` lets that sweep do the
                    // move once the answer is in. Tiling can afford to guess
                    // (§S0); this cannot.
                    switch spaceMoveDecision(
                        outcome: outcome,
                        isStandardWindow: self.standardWindow[w.id],
                        alreadyAttempted: self.spaceMoveAttempts.contains(w.id)
                    ) {
                    case .move(let target):
                        self.spaceMoveAttempts.insert(w.id)
                        // Resolve against the in-progress labels (just seeded
                        // above), not the still-unwritten global — otherwise
                        // first-sync moves always miss with "unknown space".
                        if let sid = sp.resolveWorkspace(target).flatMap({ sp.desktop(of: $0) }) {
                            pendingMoves.append(RuleMove(wid: w.id, app: w.app, sid: sid, label: target))
                        } else {
                            fputs("weftd: rule wants '\(w.app)' (\(w.id)) on unknown space '\(target)'\n", stderr)
                        }
                    case .wait:
                        // The change that stopped app sheets and popovers
                        // being carried to other desktops. Logged once per
                        // window so a report can show it firing — and show
                        // whether the window it held back was a real one.
                        if self.spaceMoveDeferredLogged.insert(w.id).inserted {
                            fputs(
                                "weftd: holding '\(w.app)' (\(w.id)) — rule wants space "
                                    + "'\(outcome.space ?? "?")', waiting for AX to say what it is\n",
                                stderr
                            )
                        }
                    case .skip:
                        // Closes the story on a window that was held: AX has
                        // answered, and the answer was "a panel, not a
                        // window". Left where it is, deliberately.
                        if self.standardWindow[w.id] == false,
                           self.spaceMoveDeferredLogged.remove(w.id) != nil {
                            fputs(
                                "weftd: '\(w.app)' (\(w.id)) is a panel, not a window — "
                                    + "left on this desktop\n",
                                stderr
                            )
                        }
                    }
                    if !outcome.manage {
                        unmanagedNow.insert(w.id)
                        continue
                    }
                }
                if self.strikes[w.id, default: 0] >= 2 {
                    unmanagedNow.insert(w.id)
                    continue
                }
                windowDesktops[w.id] = w.spaces
            }
            for wid in unmanagedNow.subtracting(self.unmanaged).sorted() {
                fputs("weftd: floating \(wid) (rule/quirk — excluded from layouts)\n", stderr)
            }
            self.manualFloat = self.manualFloat.intersection(worldWids)
            self.floatFrames = self.floatFrames.filter { worldWids.contains($0.key) }
            unmanagedNow.formUnion(self.manualFloat)
            self.unmanaged = unmanagedNow
            // The seam. Up to here everything came from SLS: `windowDesktops`
            // is the WindowServer's answer to "which desktop is this window
            // on", verbatim. `reconcileWorkspaces` turns that into "which
            // workspace", which is weft's own answer and the only part of
            // membership macOS does not own.
            let live = sp.liveWorkspaces(desktops: liveSids)
            let membership = reconcileWorkspaces(
                windowDesktops: windowDesktops,
                membership: sp.workspaces.mapValues { $0.layout.windows },
                desktopOf: sp.workspaces.mapValues { $0.desktop },
                activeOn: sp.active
            )
            var screens: [WorkspaceID: Frame] = [:]
            for id in live {
                screens[id] = sp.desktop(of: id).flatMap { usableBySpace[$0] }
            }
            let (synced, _) = syncMembership(
                sp, membership: membership, live: live,
                screens: screens, config: cfg.general.asTilingConfig()
            )
            sp = synced
            // Workspaces seen for the first time this launch take the layout
            // the user last chose for them, else the `[[space]]` declaration,
            // else the general default. One that already had a layout keeps it:
            // this branch is seeding, not enforcement.
            for id in live.subtracting(priorKeys) {
                guard let ws = sp.workspaces[id] else { continue }
                let kind = ws.overrideKind
                    ?? cfg.spaces.first(where: { $0.label == ws.label })?.layout
                    ?? cfg.general.defaultLayout
                self.convertLayout(&sp, workspace: id, to: kind)
            }
            // Every live desktop must have a workspace showing on it, and the
            // failure if one does not is silent from end to end: a window that
            // arrives there is dropped by `reconcileWorkspaces` because there
            // is nowhere to put it, `evictOrderedOut` finds nothing held and
            // returns early so closed windows never give their slots back, and
            // `refreshDividerZones` skips the desktop so its grab zones and
            // borders simply stop being drawn. Nothing throws and nothing is
            // logged. `adoptDesktops` is the only thing that creates or removes
            // a workspace and it maintains this by construction, so reaching
            // here means that function has a hole in it — say so.
            for sid in liveSids where sp.active[sid] == nil {
                fputs("weftd: desktop \(sid) has no workspace — windows there will not be tiled\n", stderr)
            }
            self.spaces = sp
            let currentSids = Set(sp.currentByDisplay.values)
            let visible = world.windows.filter { !Set($0.spaces).isDisjoint(with: currentSids) }
            let total = sp.workspaces.values.reduce(0) { $0 + $1.layout.windows.count }
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
        // A window judged "not a real window" gets one more sweep to disagree,
        // once the app has had a few seconds to finish starting. Nothing else
        // guarantees one: an app that opens a window on an otherwise idle
        // desktop produces no further events, so the second answer would never
        // be asked for and the first would stand for the window's whole life.
        let recheckDue: TimeInterval? = core.sync {
            self.negativeVerdict
                .filter { !self.recheckedNegatives.contains($0.key) }
                .map { Self.negativeRecheckDelay - now.timeIntervalSince($0.value) }
                .min()
        }
        if let delay = recheckDue {
            pendingRecheck?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.syncFromSnapshot() }
            pendingRecheck = work
            syncQueue.asyncAfter(deadline: .now() + max(delay, 0.05), execute: work)
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
        let tBind = Date()
        Trace.record("sweep.bind", ms: tBind.timeIntervalSince(tBind0) * 1000)
        Trace.record("sweep.total", ms: tBind.timeIntervalSince(t0) * 1000)
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
            for (id, ws) in sp.workspaces {
                switch ws.layout {
                case .tiling(let t) where t.windows.contains(wid):
                    sp.setLayout(.tiling(t.removing(wid)), of: id)
                case .float(let f) where f.windows.contains(wid):
                    sp.setLayout(.float(f.removing(wid)), of: id)
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
        // The WindowServer recycles window ids, and `watchOnLoop` skips any wid
        // it already holds an element for — so a dead id left in the observer's
        // table means the next window handed that number never gets a move or
        // resize notification for as long as the daemon runs.
        observers.forgetWindow(wid)
    }

    private func watchCurrent() {
        let sp = readSpaces()
        let pids = allPids()
        let currentSids = Set(sp.currentByDisplay.values)
        let wids = currentSids.flatMap { sp.layout(on: $0)?.windows ?? [] }
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
    /// One-shot second opinion on a window judged "not a real window".
    private var pendingRecheck: DispatchWorkItem?
    /// Follow-up sweep after a rule relocates a window, so layout membership
    /// catches up with where the window actually is.
    private var pendingRuleResync: DispatchWorkItem?
    /// The spaces weft has actually reacted to, per display. Compared against
    /// the WindowServer by `spaceWatch`; also written by the notification path
    /// so a switch weft heard about does not get handled twice.
    ///
    /// Written from the observer thread and read from the watcher's timer, so
    /// it carries its own lock rather than belonging to either.
    private var actedSpacesLocked: [String: SpaceID] = [:]
    private let actedSpacesLock = NSLock()
    private var spaceWatch: DispatchSourceTimer?
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
        // weft's own carry looks exactly like a user dragging a window, because
        // it is one. Re-applying the layout 150ms in writes an AX frame to the
        // window being dragged, and an AX move mid-drag ends the drag session:
        // the window is dropped where it stands and the rest of the keypresses
        // change desktop carrying nothing. That is the whole "it just switches
        // spaces and leaves the window behind" report.
        guard !DragMove.isCarrying else { return }
        pendingDragApply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyCurrentSpace()
            self.bus.emit(self.stateChangedEvent())
        }
        pendingDragApply = work
        syncQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - Creation ladder

    /// Windows a creation notification named that have not landed yet, and
    /// when each was announced. Touched only from `syncQueue`, like the other
    /// sweep timers.
    private var awaitedWindows: [WindowID: DispatchTime] = [:]
    private var pendingLadder: DispatchWorkItem?
    /// When the ladder sweeps, in ms after the newest creation.
    ///
    /// This replaces a fixed pair — one sweep at 20 ms and one at 300 ms — for
    /// the case where the notification names the window. A newborn window
    /// usually has no space membership and no AX element at 20 ms, so in
    /// practice it landed on the 300 ms sweep every time: the visible beat
    /// before a new window takes its slot. Sweeping on a doubling schedule and
    /// stopping the moment the window is tiled and bound lands a native app
    /// in one or two rungs; a slow Electron launch walks further up and ends
    /// no worse than before. The last rung is past the old 300 ms on purpose
    /// — it is the heal for a window that took its time.
    private static let creationLadderMs: [Int] = [16, 32, 64, 128, 256, 512]

    private func awaitWindow(_ wid: WindowID) {
        if awaitedWindows[wid] == nil { awaitedWindows[wid] = .now() }
        // Restart from the fastest rung: the newest window deserves the quick
        // sweeps, and anything older still waiting is checked on each of them.
        runLadder(rung: 0, origin: .now())
    }

    private func runLadder(rung: Int, origin: DispatchTime) {
        pendingLadder?.cancel()
        guard rung < Self.creationLadderMs.count else {
            // Out of rungs. Record what never settled so the trace says so,
            // and leave those windows to the ordinary sweeps.
            for (wid, t0) in awaitedWindows {
                Trace.record("create.settle", ms: Self.ms(since: t0), detail: "\(wid) did not settle")
            }
            awaitedWindows.removeAll()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.syncFromSnapshot()
            self.settleAwaited(rung: rung)
            if !self.awaitedWindows.isEmpty {
                self.runLadder(rung: rung + 1, origin: origin)
            }
        }
        pendingLadder = work
        syncQueue.asyncAfter(
            deadline: origin + .milliseconds(Self.creationLadderMs[rung]), execute: work
        )
    }

    /// Drop every awaited window that has landed: in a layout with an AX
    /// element bound (so its frame write is real), or judged unmanaged (a
    /// rule, a dialog, a panel — landed, just not tiled).
    private func settleAwaited(rung: Int) {
        guard !awaitedWindows.isEmpty else { return }
        let sp = readSpaces()
        let unmanaged = core.sync { self.unmanaged }
        for (wid, t0) in awaitedWindows {
            let tiled = applier.isBound(wid)
                && sp.workspaces.values.contains { $0.layout.windows.contains(wid) }
            guard tiled || unmanaged.contains(wid) else { continue }
            awaitedWindows.removeValue(forKey: wid)
            Trace.record(
                "create.settle", ms: Self.ms(since: t0),
                detail: "\(wid) after \(rung + 1) sweep(s)\(tiled ? "" : ", unmanaged")"
            )
        }
    }

    private static func ms(since t0: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000
    }

    /// Give back the slots of windows that were closed without being
    /// destroyed.
    ///
    /// An app that keeps running after its window closes — Ghostty, most
    /// Electron apps — orders the window out and keeps it, so no destroyed
    /// notification arrives and the survivors never grew into the gap until
    /// some later sweep happened by. One on-screen list per focus change,
    /// compared with what the visible layouts hold, catches it the moment
    /// focus moves: the same instant refill a real destroy gets.
    private func evictOrderedOut() {
        guard !SystemChecks.screenLocked() else { return }
        let sp = readSpaces()
        let visible = sp.visibleSpaces
        let held = visible.flatMap { sp.layout(on: $0)?.windows ?? [] }
        guard !held.isEmpty else { return }
        let t = Trace.start("focus.visibility")
        let onScreen = WorldReader.onScreenWindowIDs()
        let gone = held.filter { !onScreen.contains($0) }
        t.end(detail: "\(held.count) window(s)")
        guard !gone.isEmpty else { return }
        for wid in gone { forgetWindow(wid) }
        let focusedSID = readSpaces().currentSpace
        for sid in visible {
            applySpaceLayout(sid, raiseFocus: sid == focusedSID)
        }
        bus.emit(stateChangedEvent())
    }

    /// Keyboard focus landed on `wid` — from an AX notification, or from an
    /// app coming forward.
    ///
    /// Both sources are needed and neither is enough. AX names the window but
    /// stays silent when the app merely activates; activation names the app
    /// but not the window. Everything downstream of "focus moved" is here, so
    /// the two paths cannot drift apart.
    private func focusChanged(to wid: WindowID?) {
        // A desktop switch nobody announced usually shows up as focus
        // landing on a window over there. No window list involved, and it
        // is what lets the space watch run slowly instead of at 3 Hz.
        checkSpaceChanged()
        // Before the rest, and even when focus went to nothing:
        // closing a window moves focus, and for an app that keeps its
        // closed windows this is the only event there is.
        evictOrderedOut()
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
            sp0.layout(on: $0)?.windows.contains(wid) == true
        }) else {
            // A float, a rule's `manage = false`, a quirk, a panel: known
            // to the last sweep and deliberately in no layout. Another
            // sweep would reach the same verdict, and clicking back and
            // forth between a tile and a float cost two full WindowServer
            // sweeps plus a re-apply of every visible space per click.
            if core.sync(execute: { self.unmanaged.contains(wid) }) {
                // Say so anyway. This *is* a focus change — it is just a
                // focus change onto a window no layout owns. Returning in
                // silence left the menu bar, sketchybar and anything else
                // on the bus showing the tile the user focused before,
                // for as long as they worked in the float.
                bus.emit(DaemonEvent(kind: .windowFocused, window: wid))
                bus.emit(stateChangedEvent())
                return
            }
            scheduleSync()
            return
        }
        updateSpaces { sp in
            guard let layout = sp.layout(on: homeSID) else { return }
            let sid = homeSID
            switch layout {
            case .tiling(let t):
                guard t.windows.contains(wid) else { return }
                sp.setLayout(.tiling(t.focusing(wid)), on: sid)
            case .float(let f):
                guard f.windows.contains(wid) else { return }
                sp.setLayout(.float(f.focusing(wid)), on: sid)
            }
        }
        bus.emit(DaemonEvent(kind: .windowFocused, window: wid))
        bus.emit(stateChangedEvent())
    }

    private func handleObserverEvent(_ event: ObserverEvent) {
        switch event {
        case .windowCreated(let pid, let wid):
            bus.emit(DaemonEvent(kind: .windowCreated, window: wid, app: "pid=\(pid)"))
            if let wid {
                awaitWindow(wid)
            } else {
                scheduleSync()
            }
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
            let actual = WorldReader.frame(of: wid)
            // Before the echo check, and regardless of it: an echo is weft's
            // own write *landing*, which is the moment the border most needs
            // to move. The renderer is told that the geometry changed and
            // reads it itself — passing this frame on would be handing it a
            // number that is already one notification out of date.
            if bordersBridge.drawsBorders { bordersBridge.renderer.windowMoved(wid) }
            if let actual, applier.isEcho(wid: wid, frame: actual) {
                return
            }
            scheduleDragSettleApply()
        case .windowFocused(let wid):
            focusChanged(to: wid)
        case .appActivated(let pid):
            // Clicking another app's window is a focus change that AX never
            // reports: the app's own focused window did not change, only
            // which app is in front. Ask the app what it considers focused
            // and run the same path the AX notification takes.
            let front = FocusedWindow.of(pid: pid)
            if Trace.logging {
                let known = systemFocusLock.withLock { systemFocusLocked }
                if front != known {
                    fputs(
                        "weftd: pid \(pid) came forward on \(front.map(String.init) ?? "nothing")"
                            + " — AX had not said so (weft had \(known.map(String.init) ?? "nothing"))\n",
                        stderr
                    )
                }
            }
            focusChanged(to: front)
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
            handleSpaceChange()
            scheduleSpaceRechecks()
        case .displayChanged:
            // Geometry first: a resolution change or an unplug leaves every
            // layout sized to a screen that no longer exists, and the sweep
            // below computes frames from these rects.
            refreshScreens()
            // Scale factors and geometry both changed under every border.
            bordersBridge.renderer.displaysChanged()
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

    /// The window a command means when it says "the focused window".
    ///
    /// Not the layout's focus, which is where every one of these verbs used to
    /// start. `SpaceLayout.focus` can only ever name a window that layout
    /// holds, so the moment the user clicks into a float it goes on naming the
    /// *tile* they were in before — and `float toggle`, `space move-window`
    /// and `move display` then quietly operated on that tile. From the user's
    /// side the float could not be acted on at all: the one verb that would
    /// have tiled it again did something else, to a window somewhere else, and
    /// reported success.
    ///
    /// So the system's focus comes first, and the layout's is the fallback.
    /// `systemFocusLocked` is what the observers recorded and costs nothing;
    /// the AX read behind `FocusedWindow.current` covers an event weft missed
    /// and is only ever reached here, never on the tiling path. Both are
    /// checked against the WindowServer before they are believed, so a window
    /// that has since closed or moved off screen cannot be acted on.
    private func activeWindowID() -> WindowID? {
        let visible = Set(readSpaces().visibleSpaces)
        func showing(_ wid: WindowID) -> Bool {
            !Set(SpaceControl.spacesForWindow(wid)).isDisjoint(with: visible)
        }
        if let sys = systemFocusLock.withLock({ systemFocusLocked }), showing(sys) { return sys }
        if let sys = FocusedWindow.current(), showing(sys) { return sys }
        return currentLayout().focus
    }

    private func handleFloat(_ mode: StickyMode) -> IPCResponse {
        guard let wid = activeWindowID() else {
            return IPCResponse(ok: false, error: "no focused window to float")
        }
        // `manualFloat`, `unmanaged` and `floatFrames` are core-owned state and
        // this runs on `incoming`, so every read and write of them below goes
        // through core. The screen work cannot: `applySpaceLayout`,
        // `applyFrames`, `raiseFronts` and `focusAndWarp` all assert they are
        // off core. Hence the shape — decide and mutate inside one `core.sync`,
        // then do the screen work after it, outside.
        //
        // Floating by hand is not the only way a window ends up outside every
        // layout. weft floats one itself when its AX verdict says "not a real
        // window" or when two frame writes in a row were refused — and both
        // of those are heuristics taken once, often while the app was still
        // starting up. A window floated that way answered `float toggle` by
        // *floating it again*: added to `manualFloat`, centred at 70%, still
        // not tiled, and reporting success. There was no verb that put it
        // back. The question `float toggle` asks is "is this window in a
        // layout right now", not "did the user put it here".
        let isFloating = core.sync {
            self.manualFloat.contains(wid) || self.floatedByVerdict(wid)
        }
        switch mode {
        case .on where isFloating:
            return IPCResponse(ok: true, output: "window \(wid) already floating")
        case .off where !isFloating:
            return IPCResponse(ok: true, output: "window \(wid) already tiled")
        default:
            break
        }
        // The space this window is on, not the space weft thinks the user is
        // on. Floating a window on the second monitor took the *other*
        // display's layout apart instead — the removal was a no-op there, and
        // the window was then centred on a screen it was not on, so it jumped
        // monitors on its way to floating.
        let sp0 = readSpaces()
        let home = sp0.workspaces.values.first { $0.layout.windows.contains(wid) }?.desktop
            ?? SpaceControl.spacesForWindow(wid).first(where: { sp0.active[$0] != nil })
            ?? currentSID()
        if isFloating {
            // Snapshot where the user had it before the layout reclaims it,
            // so floating it again lands back in the same place. The AX read
            // stays off core — only the store goes on it.
            let live = WorldReader.frame(of: wid)
            core.sync {
                if let live { self.floatFrames[wid] = live }
                self.manualFloat.remove(wid)
                self.unmanaged.remove(wid)
                // The user has overruled the heuristic for this window. Say so
                // in the state the next sweep reads, or the sweep re-applies
                // the same verdict and the window floats straight back out —
                // which is `float toggle` doing nothing, slowly.
                self.strikes.removeValue(forKey: wid)
                self.unbindableSince.removeValue(forKey: wid)
                self.negativeVerdict.removeValue(forKey: wid)
                if self.standardWindow[wid] == false { self.standardWindow[wid] = true }
                if let sid = home {
                    self.updateSpaces { sp in
                        switch sp.layout(on: sid) ?? self.resolvedInitialLayout(for: sid, in: sp) {
                        case .tiling(var t):
                            t = t.inserting(wid)
                            sp.setLayout(.tiling(t), on: sid)
                        case .float(var f):
                            f = f.inserting(wid)
                            sp.setLayout(.float(f), on: sid)
                        }
                    }
                }
            }
            if let sid = home { applySpaceLayout(sid) }
            bus.emit(stateChangedEvent())
            return IPCResponse(ok: true, output: "window \(wid) tiled")
        } else {
            let uScreen = usableScreen(for: home)
            // Where the user last left this window floating, if they ever
            // did. Floating a window, moving it, tiling it and floating it
            // again used to snap it back to the centre every time — the
            // second float threw away the whole arrangement the first one
            // was for. Fall back to a centred 70% only the first time.
            let target: Frame = core.sync {
                self.manualFloat.insert(wid)
                self.unmanaged.insert(wid)
                if let sid = home {
                    self.updateSpaces { sp in
                        switch sp.layout(on: sid) ?? self.resolvedInitialLayout(for: sid, in: sp) {
                        case .tiling(var t):
                            t = t.removing(wid)
                            sp.setLayout(.tiling(t), on: sid)
                        case .float(var f):
                            f = f.removing(wid)
                            sp.setLayout(.float(f), on: sid)
                        }
                    }
                }
                return self.floatFrames[wid].flatMap { remembered -> Frame? in
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
            }
            if let sid = home { applySpaceLayout(sid) }
            applyFrames([wid: target])
            raiseFronts([wid])
            if let pid = pid(of: wid) {
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
        var home: SpaceID? = sp.workspaces.values.first { $0.layout.windows.contains(wid) }?.desktop
        if home == nil {
            home = WorldReader.snapshot().windows
                .first { $0.id == wid }?.spaces.first
        }
        guard let sid = home else {
            return IPCResponse(ok: false, error: "no such window \(wid)")
        }
        if !sp.currentByDisplay.values.contains(sid) {
            let label = sp.workspace(on: sid)?.label ?? "\(sid)"
            let switched = handleSpace(.focus(label))
            guard switched.ok else { return switched }
        }
        guard let pid = pid(of: wid) else {
            return IPCResponse(ok: false, error: "window \(wid) has no process")
        }
        updateSpaces { s in
            guard let layout = s.layout(on: sid) else { return }
            switch layout {
            case .tiling(let t) where t.windows.contains(wid):
                s.setLayout(.tiling(t.focusing(wid)), on: sid)
            case .float(let f) where f.windows.contains(wid):
                s.setLayout(.float(f.focusing(wid)), on: sid)
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
        case "trace reset":
            // `weftctl bench` calls this first, so its numbers describe the
            // run and not the last hour of desktop use.
            Trace.reset()
            return IPCResponse(ok: true, output: "trace reset")
        case "request-accessibility":
            // Setup's Accessibility step, and the only place weftd asks for
            // it. Asking with the prompt is what puts weftd in the list — an
            // unbundled binary gets there no other way — so it has to happen
            // at least once, right after the user clicked the step that says
            // so, never at startup.
            //
            // But only once. macOS's dialog and the Settings pane say the same
            // thing, and opening both put a modal on top of the switch it was
            // telling the user to find. After the first ask the row exists for
            // good, so every later visit checks without prompting and the pane
            // is all the user sees. The reply says which happened; WeftBar
            // opens the pane only when no dialog is on screen.
            let firstAsk = !hasAsked("accessibility")
            if firstAsk { markAsked("accessibility") }
            let trusted = AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": firstAsk] as CFDictionary
            )
            if trusted { return IPCResponse(ok: true, output: "granted") }
            return IPCResponse(ok: true, output: firstAsk ? "prompted" : "requested")
        case "request-screen-recording":
            // The same shape as Accessibility, for the same reason.
            // `CGRequestScreenCaptureAccess` is what puts weftd in the list —
            // it does work for an unbundled binary, the row just does not
            // exist until something asks — and it also raises macOS's dialog.
            // Calling it on every visit put that dialog on top of the pane
            // every time, saying what the pane was already showing.
            //
            // Asked once, which is all the registration needs. After that the
            // preflight answers without a dialog and the pane is all the user
            // sees. The reply tells WeftBar which happened.
            if hasAsked("screen-recording") {
                return IPCResponse(
                    ok: true, output: CGPreflightScreenCaptureAccess() ? "granted" : "requested"
                )
            }
            markAsked("screen-recording")
            if CGPreflightScreenCaptureAccess() {
                return IPCResponse(ok: true, output: "granted")
            }
            _ = CGRequestScreenCaptureAccess()
            return IPCResponse(ok: true, output: "prompted")
        case "request-input-access":
            // Ask TCC to list weftd under Input Monitoring, on demand.
            //
            // weftd used to do this by itself the moment its event tap failed,
            // which is during startup — so the system's own modal landed on
            // top of the Setup window that exists to walk the user through
            // exactly this permission, from a process they cannot see. Two
            // dialogs asking for one thing, one of them unexplained. Setup now
            // asks for it when the user is looking at the Input Monitoring
            // step, and weftd only falls back to asking on its own when no
            // Setup window is running to do it (see `requestInputAccess`).
            requestInputAccess(reason: "Setup asked")
            return IPCResponse(ok: true, output: "requested Input Monitoring")
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
        let tDispatch = Trace.start("cmd.dispatch")
        defer { tDispatch.end(detail: String(describing: command).prefix(40).description) }
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
        if case .exec(let shell) = command {
            // The state the command runs against is the state it was bound to
            // react to, so a bind can be `exec notify-send "$WEFT_SPACE_LABEL"`
            // with nothing to query. Same variables the sketchybar bridge
            // publishes, from the same place.
            guard Exec.run(shell, env: currentStateSummary().environment) else {
                return IPCResponse(
                    ok: false,
                    error: "exec refused: \(Exec.maxConcurrent) commands are already running")
            }
            return IPCResponse(ok: true, output: "exec \(shell)")
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
        applyFrames(frames)
        raiseFronts(outcome.raises)
        if let focus = outcome.focus, let pid = pid(of: focus) {
            focusAndWarp(window: focus, pid: pid, target: frames[focus])
        }
        // The borders moved with the windows. A stale grab zone is a click
        // swallowed where there is nothing to drag.
        if !frames.isEmpty { refreshDividerZones() }
        bus.emit(stateChangedEvent())
        return IPCResponse(ok: true, output: "\(describe()) dispatched=\(frames.count)")
    }

    /// What reducing one command produced, before anything is written.
    private struct ReduceOutcome {
        var frames: [WindowID: Frame] = [:]
        var focus: WindowID?
        var raises: [WindowID] = []
    }

    /// Reduce one command against the current space and commit the new layout
    /// state. Writes nothing to the screen — the caller decides whether the
    /// frames go out immediately (a keybind) or through the drag coalescer.
    private func reduceOnCore(_ command: Command) -> ReduceOutcome {
        dispatchPrecondition(condition: .notOnQueue(core))
        let mutations: [Mutation] = core.sync {
            let sid = self.spaces.currentSpace
            let tile = self.currentConfig().general.asTilingConfig()
            let uScreen = self.usableScreen(for: sid)
            switch sid.flatMap({ self.spaces.layout(on: $0) }) ?? .tiling(Tree()) {
            case .tiling(let tree):
                let cur = State(tree: tree, screen: uScreen, config: tile)
                let (n, m) = Reducer.reduce(cur, command)
                if let sid { self.spaces.setLayout(.tiling(n.tree), on: sid) }
                return m
            case .float(let fl):
                // Live SLS frames, not `remembered`: the user has been moving
                // these windows by hand, so remembered geometry is stale by
                // definition and directional focus would score against it.
                let live = self.liveFrames(of: fl.windows)
                let (n, m) = Reducer.reduceFloat(fl, command: command, frames: live)
                if let sid { self.spaces.setLayout(.float(n), on: sid) }
                return m
            }
        }
        var out = ReduceOutcome()
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
    }

    // MARK: - Spaces (M4)

    private func handleSpace(_ sub: SpaceCommand) -> IPCResponse {
        // Topology only: no space verb needs the window list, and a full
        // sweep here sat directly on the `space focus` critical path.
        let displays = WorldReader.displaysOnly()
        let sp = readSpaces()
        switch sub {
        case .focus(let target):
            guard let id = sp.resolveWorkspace(target), let sid = sp.desktop(of: id) else {
                let known = sp.workspaces.values.map { $0.label }.sorted().joined(separator: ", ")
                return IPCResponse(ok: false, error: "unknown space '\(target)' (labels: \(known))")
            }
            let label = sp.label(of: id) ?? "\(sid)"
            // From `displays`, read from the WindowServer a line above, not
            // from `sp` — weft's cached idea of where the user is.
            //
            // The two disagree whenever a desktop changed without weft doing
            // it and the notification has not landed yet: a trackpad swipe,
            // Mission Control, an app activating on another desktop. Asking
            // the cache meant `space focus` answered "already on 3" while the
            // user was looking at 5, and returned ok — so nothing switched,
            // nothing re-tiled, and nothing was logged either. A keybind that
            // does nothing at all and reports success is the worst of the
            // three outcomes available here.
            //
            // The display this desktop belongs to. Everything below has to
            // know it, because on a two-display Mac "focus this space" is two
            // different operations depending on whether the space is already
            // showing — and both of them have to leave `focusedDisplay`
            // pointing at it, or the next command resolves "the current
            // space" against the monitor the user just left.
            let home = displays.first(where: { $0.spaces.contains(sid) })?.uuid
                ?? sp.displayBySpace[sid]
            let previous = currentSID()
            // Showing somewhere. Whether that is somewhere the user is
            // looking *from* is the next question.
            if displays.contains(where: { $0.currentSpace == sid }) {
                if !sp.currentByDisplay.values.contains(sid) {
                    // The cache was the stale one. Correct it, so the next
                    // command does not start from the same wrong answer.
                    syncQueue.async { [weak self] in self?.syncFromSnapshot() }
                }
                // Showing on the display the user is already on: genuinely
                // nothing to do. Re-tiling or re-activating here yanked focus
                // around on a repeated keypress.
                guard let home, home != sp.focusedDisplay else {
                    return IPCResponse(ok: true, output: "already on \(label)")
                }
                // Showing on the *other* display, which is not the same thing
                // and used to be treated as if it were. `alt-1` with main
                // already up on the second monitor answered "already on main"
                // and moved nothing: keyboard focus stayed where it was, so
                // the desktop the user had just named was not the one their
                // next keybind acted on. Nothing needs switching — the space
                // is on screen — but focus does have to go there.
                updateSpaces { s in
                    if let previous, previous != sid, let was = s.active[previous] {
                        s.recentWorkspace = was
                    }
                }
                let took = takeFocus(display: home, showing: sid)
                bus.emit(stateChangedEvent())
                return IPCResponse(
                    ok: true,
                    output: took == nil
                        ? "\(label) is showing on the other display — pointer moved there"
                        : "focused \(label) on the other display"
                )
            }
            if SpaceControl.focusSpace(sid) {
                // Verified switch (SpaceControl re-reads the WindowServer).
                updateSpaces { s in
                    for d in displays where d.spaces.contains(sid) {
                        s.currentByDisplay[d.uuid] = sid
                    }
                    if let previous, previous != sid, let was = s.active[previous] {
                        s.recentWorkspace = was
                    }
                    // Keyboard focus follows the desktop the user named, even
                    // when that desktop lives on the other monitor. Without
                    // this `currentSpace` still resolved through the old
                    // display, so the space weft tiled, bordered and focused
                    // after the switch was the one on the display nobody had
                    // asked about — and `applySpaceLayout` below only
                    // corrected it by accident, when the destination happened
                    // to have a window it could activate.
                    if let home { s.focusedDisplay = home }
                }
                // Instant either way (weft-sa or the Dock swipe), and verified
                // landed — safe to tile + focus now.
                applySpaceLayout(sid, stealFocus: true)
                bus.emit(stateChangedEvent())
                return IPCResponse(ok: true, output: "switched to \(label)")
            }
            guard let number = sp.ordinal(of: sid) else {
                return IPCResponse(ok: false, error: "space \(sid) is not on any display")
            }
            guard (1...9).contains(number) else {
                return IPCResponse(
                    ok: false,
                    error: "space '\(label)' is desktop #\(number); the keystroke fallback only covers 1-9. "
                        + "weft's Dock swipe reaches every desktop on macOS 26.6 or later."
                )
            }
            // Say it before posting the key rather than after. ⌃N is a
            // *shortcut*, and "Switch to Desktop N" is off on a stock macOS —
            // so with no scripting addition this is the ordinary case, not an
            // edge one, and posting a keystroke into the void and then
            // reporting a timeout describes the symptom rather than the cause.
            let shortcuts = SpaceControl.missionControlSwitchShortcuts()
            guard shortcuts.contains(number) else {
                return IPCResponse(
                    ok: false,
                    error: "cannot switch to '\(label)': "
                        + (DockSwipe.isSupported
                            ? "the Dock swipe did not land, and "
                            : "this macOS release does not take weft's Dock swipe (26.6 or later does), and ")
                        + "'Switch to Desktop \(number)' is off, so weft has nothing else to switch with. "
                        + (AXIsProcessTrusted()
                            ? "Turn it on in System Settings → Keyboard → Keyboard Shortcuts → Mission Control."
                            : "Grant weftd Accessibility: both ways of switching post events, which needs it.")
                )
            }
            updateSpaces { s in
                if let previous, previous != sid, let was = s.active[previous] {
                    s.recentWorkspace = was
                }
                if let home { s.focusedDisplay = home }
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
                    + "Shortcuts → Mission Control → 'Switch to Desktop \(number)'."
            )
        case .moveWindow(let target, let widOpt, let follow):
            guard let id = sp.resolveWorkspace(target), let sid = sp.desktop(of: id) else {
                return IPCResponse(ok: false, error: "unknown space '\(target)'")
            }
            guard let wid = widOpt ?? activeWindowID() else {
                return IPCResponse(ok: false, error: "nothing focused")
            }
            return moveWindow(
                wid, toSpace: sid, label: sp.label(of: id) ?? "\(sid)", follow: follow)
        case .label(let name):
            guard !name.isEmpty else {
                return IPCResponse(ok: false, error: "usage: space label <name>")
            }
            guard let sid = currentSID() else {
                return IPCResponse(ok: false, error: "no current space")
            }
            updateSpaces { sp in
                if let id = sp.active[sid] { sp.workspaces[id]?.label = name }
            }
            saveLabels()
            return IPCResponse(ok: true, output: "space \(sid) labelled '\(name)'")
        case .layout(let kind):
            let targetKind: LayoutKind
            // Set when the request named something weft no longer does, so
            // the reply can say what it did instead of pretending.
            var note: String?
            if kind == "toggle" {
                let curKind = currentLayout().kind
                targetKind = (curKind == .float) ? .bsp : .float
            } else if kind == "scroll" {
                // A keybind or a habit from before the scroll layout was
                // removed. bsp is what the space would have been anyway.
                targetKind = .bsp
                note = "the scroll layout was removed — using bsp"
                fputs("weftd: space layout scroll requested; \(note!)\n", stderr)
            } else if let lkind = LayoutKind(rawValue: kind) {
                targetKind = lkind
            } else {
                return IPCResponse(ok: false, error: "usage: space layout <bsp|float|toggle>")
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
                guard let id = sp.active[sid] else { return }
                convertLayout(&sp, workspace: id, to: targetKind)
                // Remember that this was asked for, not derived. Without the
                // record the next config reload, the next time the workspace
                // empties, and the next restart all quietly undo it.
                sp.workspaces[id]?.overrideKind = targetKind
            }
            saveLayoutOverrides()
            if let sid = currentSID() {
                applySpaceLayout(sid)
            }
            bus.emit(stateChangedEvent())
            return IPCResponse(ok: true, output: note.map { "\($0)\n\(describe())" } ?? describe())
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
    private func moveWindow(
        _ wid: WindowID, toSpace sid: SpaceID, label: String, follow: Bool = false
    ) -> IPCResponse {
        // Layout membership is not the same question as "is it here". An
        // unmanaged window sits on the current space in no layout at all, and
        // testing the layout sent it down the background-window path and
        // refused the move on a desktop the window was already on. Ask the
        // WindowServer where the window is; only fall back to the layout when
        // it has nothing to say.
        // A window on another desktop used to be refused outright: nothing
        // could move it without a scripting addition. The drag route can — it
        // goes to the window's desktop, carries it, and comes back — so the
        // refusal now applies only when that route is unavailable too.
        if !currentLayout().windows.contains(wid), !DragMove.isSupported {
            let onCurrent = currentSID().map { SpaceControl.spacesForWindow(wid).contains($0) } ?? false
            if !onCurrent {
                return IPCResponse(
                    ok: false,
                    error: "wid \(wid) is not on the current space, and weft has no way to move a "
                        + "background window: bind 'Move left/right a space' in System Settings → "
                        + "Keyboard → Keyboard Shortcuts → Mission Control")
            }
        }
        let startedOn = currentSID()
        // A desktop on the *other* monitor is not something the carry can
        // reach, and it is the only route weft has to a background desktop —
        // so `move display east` failed outright on every two-display Mac,
        // with "target N and window space M are not on one display".
        //
        // It does not need the carry. With separate Spaces per display the
        // WindowServer decides a window's display from where the window is:
        // put its frame inside the other monitor and it joins that monitor's
        // showing desktop. One AX write, no desktop switch, no keystroke —
        // better than the carry rather than a fallback for it. It only works
        // for a desktop that is showing, which is exactly what `move display`
        // always names.
        if !SpaceControl.spacesForWindow(wid).contains(sid),
           let home = readSpaces().displayBySpace[sid],
           WorldReader.currentSpaces()[home] == sid,
           displayOf(window: wid) != home,
           moveAcrossDisplays(wid, to: sid, on: home)
        {
            return finishMove(wid, toSpace: sid, label: label, follow: follow, startedOn: startedOn)
        }
        guard SpaceControl.moveWindowToSpace(wid, sid, follow: follow) else {
            // The actual reason, not a list of the things it might have been.
            // weft moves a window by holding it and pressing the bound "move a
            // space" shortcut, and there are several ways that does not
            // happen; naming all of them and asking the user to re-run under
            // WEFT_TRACE is asking them to reproduce the bug to learn what it
            // was. DragMove records which one it hit.
            let why = DragMove.failureReason
                ?? "weft moves a window by holding it and pressing your 'move a space' "
                    + "shortcut, and it did not take. Check System Settings → Keyboard → "
                    + "Keyboard Shortcuts → Mission Control → Move left/right a space."
            return IPCResponse(ok: false, error: "the move did not land: \(why)")
        }
        return finishMove(wid, toSpace: sid, label: label, follow: follow, startedOn: startedOn)
    }

    /// Which display a window is physically on, by its centre.
    private func displayOf(window wid: WindowID) -> String? {
        guard let f = WorldReader.frame(of: wid) else { return nil }
        return displayUUID(containing: CGPoint(x: f.x + f.width / 2, y: f.y + f.height / 2))
    }

    /// Put `wid` on the desktop showing on display `uuid`, by moving it there.
    ///
    /// Verified like every other mutation in this area: the WindowServer
    /// reporting `sid` afterwards, never the fact that a frame was written.
    /// The window keeps its size — `finishMove` re-tiles it into the target
    /// display's rect a moment later, and arriving at the right size matters
    /// less than arriving at all.
    private func moveAcrossDisplays(_ wid: WindowID, to sid: SpaceID, on uuid: String) -> Bool {
        guard let live = WorldReader.frame(of: wid), let pid = pid(of: wid) else { return false }
        let screen = usableScreen(onDisplay: uuid)
        let width = min(live.width, screen.width)
        let height = min(live.height, screen.height)
        let target = Frame(
            x: screen.x + (screen.width - width) / 2,
            y: screen.y + (screen.height - height) / 2,
            width: width,
            height: height
        )
        applier.apply(frames: [wid: target], pids: [wid: pid], force: true)
        let deadline = Date().addingTimeInterval(0.5)
        repeat {
            if SpaceControl.spacesForWindow(wid).contains(sid) { return true }
            usleep(5_000)
        } while Date() < deadline
        return false
    }

    /// Reconcile the model after a move that has already landed: drop the
    /// window from every other space's layout, insert it into the target's,
    /// and re-apply whatever is on screen.
    private func finishMove(
        _ wid: WindowID, toSpace sid: SpaceID, label: String, follow: Bool, startedOn: SpaceID?
    ) -> IPCResponse {
        // Record the desktop the carry left us on before anything reads it.
        // `applySpaceLayout` below asks `visibleSpaces` which space to raise
        // into, and every later command resolves `recent` against this — so a
        // follow that updated nothing would tile the destination as a
        // background space and leave `⌥Tab` pointing at the desktop the user
        // is standing on.
        if follow {
            let live = WorldReader.currentSpaces()
            updateSpaces { s in
                for (uuid, current) in live { s.currentByDisplay[uuid] = current }
                if let startedOn, startedOn != sid, let was = s.active[startedOn] {
                    s.recentWorkspace = was
                }
                s.focusedDisplay = s.displayBySpace[sid] ?? s.focusedDisplay
            }
            actedSpacesLock.withLock { actedSpacesLocked = live }
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
            let destination = sp.active[sid]
            for (id, ws) in sp.workspaces where id != destination {
                switch ws.layout {
                case .tiling(let t) where t.windows.contains(wid):
                    sp.setLayout(.tiling(t.removing(wid)), of: id)
                case .float(let f) where f.windows.contains(wid):
                    sp.setLayout(.float(f.removing(wid)), of: id)
                default:
                    break
                }
            }
            switch sp.layout(on: sid) ?? self.resolvedInitialLayout(for: sid, in: sp) {
            case .tiling(var t):
                // Split against the TARGET display's rect: a window landing
                // on a 3840-wide monitor should split it side by side even
                // though it came from a 1710-wide one.
                if !t.windows.contains(wid) { t = t.inserting(wid, in: targetScreen, config: tile) }
                // Arriving with the window means arriving *on* it. Without
                // this the destination raises whichever tile it last focused,
                // so the window the user just sent lands behind one they were
                // not thinking about.
                if follow { t = t.focusing(wid) }
                sp.setLayout(.tiling(t), on: sid)
            case .float(var f):
                if !f.windows.contains(wid) { f = f.inserting(wid) }
                if follow { f = f.focusing(wid) }
                sp.setLayout(.float(f), on: sid)
            }
        }
        if let cur = currentSID(), cur != sid {
            applySpaceLayout(cur)
        }
        if readSpaces().visibleSpaces.contains(sid) {
            applier.bind(windows: pid(of: wid).map { [(wid: wid, pid: $0)] } ?? [])
            // Following means the destination is the space the user is looking
            // at, so it gets the raise and the window gets focus. Not
            // following, it is a background space and raising there would hand
            // its display the active menu bar (§14.6).
            applySpaceLayout(sid, stealFocus: follow, raiseFocus: follow)
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
        return IPCResponse(
            ok: true, output: "moved \(wid) to \(label)\(follow ? " and followed" : "")")
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
                guard let self, let pid = self.pid(of: wid) else { return }
                self.focusAndWarp(window: wid, pid: pid)
            }
            return IPCResponse(ok: true, output: "focusing \(bundleID) (instant space switch + raise)")
        } else if let (_, number) = Daemon.spaceNumber(sid, in: world), (1...9).contains(number) {
            SpaceControl.focusSpaceNumber(number)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, let pid = self.pid(of: wid) else { return }
                self.focusAndWarp(window: wid, pid: pid)
            }
            return IPCResponse(ok: true, output: "focusing \(bundleID) (space switch + raise)")
        } else {
            return IPCResponse(ok: false, error: "cannot switch to the desktop holding \(bundleID)")
        }
    }

    private func handleSticky(_ widOpt: WindowID?, _ mode: StickyMode) -> IPCResponse {
        guard let wid = widOpt ?? activeWindowID() else {
            return IPCResponse(ok: false, error: "nothing focused")
        }
        let on: Bool
        switch mode {
        case .on: on = true
        case .off: on = false
        case .toggle: on = SpaceControl.spacesForWindow(wid).count <= 1
        }
        guard SpaceControl.setSticky(wid, on) else {
            return IPCResponse(
                ok: false,
                error: "sticky is unavailable: the WindowServer accepts the sticky tag from an "
                    + "ordinary connection and drops it. Nothing changed.")
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
        let label = sp.workspace(on: sid)?.label ?? "\(sid)"
        if let focus = takeFocus(display: uuid, showing: sid) {
            bus.emit(stateChangedEvent())
            return IPCResponse(ok: true, output: "focused \(focus) on \(label)")
        }
        bus.emit(stateChangedEvent())
        return IPCResponse(ok: true, output: "\(label) is empty — pointer moved there")
    }

    /// Move keyboard focus onto `uuid`, whose current space is already `sid`.
    ///
    /// Not a space switch: with separate Spaces per display both displays are
    /// showing something, so this is focusing a window that is on screen
    /// already. Returns the window that took focus, or nil when nothing there
    /// could — in which case weft still moves its own notion of the current
    /// display, because that is what the caller asked for and what makes the
    /// next command and the next window land on the right monitor, and puts
    /// the pointer there so the next click agrees.
    private func takeFocus(display uuid: String, showing sid: SpaceID) -> WindowID? {
        if let focus = readSpaces().layout(on: sid)?.focus, let pid = pid(of: focus) {
            // Activating the window is the display switch; noteFocusedWindow
            // inside focusAndWarp records the display it lives on.
            focusAndWarp(window: focus, pid: pid)
            return focus
        }
        updateSpaces { $0.focusedDisplay = uuid }
        let screen = usableScreen(onDisplay: uuid)
        CGWarpMouseCursorPosition(CGPoint(
            x: screen.x + screen.width / 2, y: screen.y + screen.height / 2
        ))
        return nil
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
        // The same resolution `space move-window` uses: a float, or a window
        // a rule unmanaged, is in no layout and can never be the layout's
        // focus — so "send this window to the other monitor" acted on some
        // tile behind it, for exactly the windows most likely to need sending.
        guard let wid = activeWindowID() else {
            return IPCResponse(ok: false, error: "nothing focused")
        }
        if displayOf(window: wid) == uuid {
            return IPCResponse(ok: true, output: "window \(wid) is already on that display")
        }
        let moved = moveWindow(
            wid, toSpace: sid, label: sp.workspace(on: sid)?.label ?? "\(sid)")
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
    /// wid → when weft last judged it "not a real window", for the ones that
    /// have not been asked a second time yet.
    ///
    /// The verdict is one AX read, and for a window that has just opened it is
    /// taken at the worst possible moment. An app still starting up reports
    /// its window as fixed-size, or too small to have title-bar buttons, or is
    /// not AX-enumerable at all — and "cached for the window's lifetime" then
    /// means permanently. An app opened for the first time since weft was
    /// installed came up floating and stayed floating, through every sweep,
    /// with `retile` the only way back and nothing to suggest it.
    ///
    /// One re-ask a few seconds later is enough: by then the app has finished
    /// starting, and the second answer is the one worth keeping. It costs
    /// nothing in steady state, because a window nothing was wrong with never
    /// enters this map.
    private var negativeVerdict: [WindowID: Date] = [:]
    /// Windows whose negative verdict has already had its second chance.
    private var recheckedNegatives: Set<WindowID> = []
    private static let negativeRecheckDelay: TimeInterval = 4.0

    /// Whether this window is outside every layout because weft judged it so,
    /// rather than because the user or a rule said to leave it alone.
    ///
    /// Core-queue state; callers are already on core.
    private func floatedByVerdict(_ wid: WindowID) -> Bool {
        standardWindow[wid] == false || strikes[wid, default: 0] >= 2
    }

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
    /// Windows already logged as waiting on a classification. The wait is
    /// re-evaluated on every sweep, so without this the log would carry one
    /// line per window per sweep and be useless for exactly the slow, rare
    /// problem it is there to catch.
    private var spaceMoveDeferredLogged: Set<WindowID> = []
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
        let previous: ValidatedConfig = configLock.withLock {
            let old = _config
            _config = next
            return old
        }
        // Loaded, but not everything in it did anything. Said on every load
        // rather than once: the file is the thing being edited, and a warning
        // that only appears at startup is one nobody connects to the key.
        for w in next.warnings {
            fputs("weft: config warning line \(w.line): \(w.message)\n", stderr)
        }
        input.updateKeymap(next.keymap)
        applier.setEnhancedUIExempt(Set(next.general.enhancedUIExempt))
        input.updateMouseModifier(next.general.mouseModifier)
        input.setBorderDragEnabled(next.general.mouseBorderResize)
        refreshDividerZones()
        WorldReader.manageMenubarApps = next.general.manageMenubarApps
        bordersBridge.applyConfig(next.integrations.borders, currentLayout: currentSpaceLayoutKind(), currentMode: input.currentMode)
        sketchybarBridge.updateConfig(next.integrations.sketchybar)
        applyDeclaredLayouts()
        // Gaps, stack offset and screen reserve shape every frame, and a
        // reload that changes any of them re-tiles now, from the values just
        // loaded. Settings used to ask for a re-tile itself, straight after
        // writing the file; that sweep usually beat this reload and drew the
        // old values, so every change showed up one step behind.
        let reshaped = previous.general.asTilingConfig() != next.general.asTilingConfig()
            || previous.general.reserve != next.general.reserve
        if !initial, reshaped {
            syncQueue.async { [weak self] in self?.syncFromSnapshot() }
        }
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
            guard let id = sp.id(forLabel: decl.label),
                  let ws = sp.workspaces[id]
            else { continue }  // unknown label yet (space not visited) — applied on first sync
            // Editing `layout =` in weft.toml is an instruction and wins; a
            // reload that did not touch this space's declaration is not, and
            // must not undo a `space layout` the user ran since. Reloads fire
            // on every save of the file, so without this every unrelated edit
            // — a keybind, a rule, a gap — snapped every space back.
            let declarationChanged = previous[decl.label] != decl.layout
            if !declarationChanged, ws.overrideKind != nil { continue }
            if declarationChanged, ws.overrideKind != nil {
                updateSpaces { $0.workspaces[id]?.overrideKind = nil }
                clearedOverride = true
            }
            if ws.layout.kind == decl.layout { continue }
            updateSpaces { sp in
                convertLayout(&sp, workspace: id, to: decl.layout)
            }
            changed = true
        }
        if clearedOverride { saveLayoutOverrides() }
        if changed {
            syncFromSnapshot()
        }
    }

    /// The `[[space]] layout` values the last config load saw, per label. Only
    /// a *change* between loads counts as the user re-deciding in the file.
    private var lastDeclaredLayouts: [String: LayoutKind] = [:]

    /// Convert one workspace's layout preserving membership. INTO float
    /// captures live SLS frames as the remembered arrangement.
    private func convertLayout(
        _ sp: inout SpaceState, workspace id: WorkspaceID, to kind: LayoutKind
    ) {
        let cur = sp.workspaces[id]?.layout ?? .tiling(Tree())
        guard cur.kind != kind else { return }
        switch (kind, cur) {
        case (.bsp, .tiling), (.float, .float):
            break  // already that kind (guarded above; listed for exhaustiveness)
        case (.bsp, .float(let f)):
            sp.setLayout(.tiling(treeFromOrder(f.order, focus: f.focus)), of: id)
        case (.float, .tiling(let t)):
            // The screen comes from `sp`, never from `readSpaces()`. Callers
            // run this inside `updateSpaces`, which holds `spaces` for
            // writing; reading it again from in here is an exclusivity
            // violation, and Swift aborts the daemon on the spot. That is the
            // SIGABRT in `usableScreen(for:)` under `applyDeclaredLayouts`,
            // and `space layout float` walked into the same one.
            let screen = usableScreen(onDisplay: sp.display(of: id))
            sp.setLayout(.float(floatFromWindows(
                t.windows, actuals: conversionFrames(of: t.windows, screen: screen), focus: t.focus
            )), of: id)
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
    /// Converting a space to float remembers every window's live frame as its
    /// floating position. A window that is off every screen — dragged there,
    /// or stranded by an unplugged monitor — would be "restored" to nowhere,
    /// so anything off-display gets a cascaded rect on this space's screen.
    private func conversionFrames(of wids: [WindowID], screen: Frame) -> [WindowID: Frame] {
        let live = liveFrames(of: wids)
        let displays = SpaceControl.displayLayout().map(\.frame)
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
        let names = sp.persistedNames()
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
        let kinds = sp.persistedOverrides()
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

    private func handleQuery(_ text: String) -> IPCResponse {
        let parts = text.split(separator: " ").map(String.init)
        // `--no-ax` skips the Accessibility round trip per running app that
        // fills in `bound`. WeftBar fetches the window list on every change
        // and never reads `bound`, so every app on the machine was being woken
        // to answer an AX query on every focus change, for nothing.
        let noAX = parts.count == 3 && parts[2] == "--no-ax"
        guard parts.count == 2 || noAX else {
            return IPCResponse(ok: false, error: "usage: query <displays|spaces|windows|world|state|tree|trace|capability|permissions> [--no-ax]")
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
        case "bar-state":
            // WeftBar only needs the daemon's already-authoritative model.
            // Sending it through `query spaces` + `query windows` made every
            // menu refresh perform two complete WindowServer sweeps, including
            // the diagnostic query's AX round trip to every app. The bar polls
            // as a reconnect backstop and also refreshes after events, so that
            // ostensibly harmless UI work could keep WindowServer and several
            // apps busy while the desktop itself was idle.
            let sp = readSpaces()
            let cfg = currentConfig()
            let metadata: (
                pids: [WindowID: Int32],
                apps: [WindowID: String],
                titles: [WindowID: String]
            ) = isOnCore()
                ? (pids, appNames, windowTitles)
                : core.sync { (self.pids, self.appNames, self.windowTitles) }
            var windowSpaces: [WindowID: [SpaceID]] = [:]
            let spaces = sp.order.compactMap { sid -> SpaceStatus? in
                guard let display = sp.displayBySpace[sid] else { return nil }
                let label = sp.workspace(on: sid)?.label ?? "\(sid)"
                let layout = sp.layout(on: sid)?.kind
                    ?? sp.workspace(on: sid)?.overrideKind
                    ?? cfg.spaces.first(where: { $0.label == label })?.layout
                    ?? cfg.general.defaultLayout
                let windows = sp.layout(on: sid)?.windows.sorted() ?? []
                for wid in windows { windowSpaces[wid, default: []].append(sid) }
                return SpaceStatus(
                    id: sid,
                    label: label,
                    layout: layout.rawValue,
                    windows: windows,
                    current: sp.currentByDisplay[display] == sid,
                    display: display
                )
            }
            let windows = windowSpaces.keys.sorted().compactMap { wid -> BarWindowStatus? in
                guard let pid = metadata.pids[wid] else { return nil }
                return BarWindowStatus(
                    id: wid,
                    app: metadata.apps[wid] ?? "?",
                    title: metadata.titles[wid] ?? "",
                    pid: pid,
                    spaces: windowSpaces[wid] ?? []
                )
            }
            return emit(BarStateStatus(spaces: spaces, windows: windows))
        case "trace":
            return emit(Trace.stats())
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
                    }
                ))
            case .float(let fl):
                return emit(StateView(
                    focus: fl.focus,
                    windows: fl.windows.sorted(),
                    screen: screen,
                    frames: fl.remembered.sorted(by: { $0.key < $1.key }).map {
                        FrameEntry(id: $0.key, frame: $0.value)
                    }
                ))
            }
        case "tree":
            switch currentLayout() {
            case .tiling(let tree):
                return emit(TreeView.of(tree.root))
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
            let world = WorldReader.snapshot(includeAXBinding: !noAX)
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
                let label = sp.workspace(on: s.id)?.label ?? "\(s.id)"
                let layout = sp.layout(on: s.id)?.kind
                    ?? sp.workspace(on: s.id)?.overrideKind
                    ?? cfg.spaces.first(where: { $0.label == label })?.layout
                    ?? cfg.general.defaultLayout
                return SpaceStatus(
                    id: s.id,
                    label: label,
                    layout: layout.rawValue,
                    windows: sp.layout(on: s.id)?.windows.sorted() ?? s.windows,
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
                // A window with no AX element is not refusing anything — it is
                // not reachable *yet*. A newborn window spends its first few
                // sweeps like that, and the creation ladder sweeps it several
                // times in that window, so counting these would auto-float a
                // perfectly ordinary new window before it ever had a chance.
                // One that stays unreachable is judged by the unbindable
                // timer in the sweep instead, which is the check built for it.
                if case .noAXElement? = result.failureReasons[wid] { continue }
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
    /// float focus, which is always raised so it stays visible.
    private func raiseFronts(_ wids: [WindowID]) {
        dispatchPrecondition(condition: .notOnQueue(core))
        guard !wids.isEmpty else { return }
        let applier = self.applier
        let pids = allPids()
        let current = currentLayout()
        let targets: [(WindowID, Int32)] = wids.compactMap { wid in
            guard let pid = pids[wid] else { return nil }
            switch current {
            case .tiling(let tree):
                // A window the tree has never heard of is a float, or one a
                // rule unmanaged, sitting over the tiles. It is the one window
                // on a tiled desktop that raising is *for*: tiles do not
                // overlap each other, so they hide nothing and need no raise,
                // while a float focused from a keybind or the switcher came
                // forward in every sense except the visible one — focused,
                // taking key input, and still behind the tile it overlaps.
                if !tree.windows.contains(wid) { return (wid, pid) }
                guard let root = tree.root,
                      stackChain(root: root, containing: wid) != nil
                else { return nil }
                return (wid, pid)
            case .float:
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

    /// Apply one space's layout. Tiling writes frames + raises; float never
    /// positions — it only fronts the focused window.
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
    ///
    /// `force` skips the apply-path diff, for a caller that has been moving
    /// windows with `SLSMoveWindow` and needs each app told where it ended up.
    private func applySpaceLayout(
        _ sid: SpaceID, stealFocus: Bool = false, raiseFocus: Bool = true, force: Bool = false
    ) {
        // The real funnel for frame writes, and therefore where the carry
        // guard belongs.
        //
        // `applyCurrentSpace` carried it and was described as the funnel, but
        // it is not the only way in: the trailing pass a *previous*
        // `space move-window` schedules calls this directly, 250 ms after the
        // move. Land that during the next carry and it writes an AX frame to
        // the window being held, which ends the drag — the window is dropped
        // where it stands and the remaining keypresses change desktop carrying
        // nothing. That is why moving a window somewhere and then moving it
        // straight back failed: the first move scheduled the write that broke
        // the second.
        guard !DragMove.isCarrying else { return }
        let screen = self.usableScreen(for: sid)
        let config = currentConfig().general.asTilingConfig()
        guard let spaceLayout = readSpaces().layout(on: sid) else { return }
        switch spaceLayout {
        case .tiling(let tree):
            let frames = Trace.time("layout", detail: "\(tree.windows.count) window(s)") {
                layout(tree, in: screen, config: config)
            }
            applyFrames(frames, force: force)
            // Do not raise the tree's focus over a float the user is actually
            // in. `tree.focus` is the last *tile* that had focus, and it
            // survives focus moving to a window no layout owns — so every
            // background sweep pushed that tile back in front of the float,
            // which is why a floating window would not stay on top however
            // many times it was clicked. An explicit focus verb still raises:
            // that is the user asking for this tile, not a sweep guessing.
            if let focus = tree.focus, raiseFocus, stealFocus || !focusIsUnmanaged() {
                raiseFronts([focus])
                if stealFocus, let pid = pid(of: focus) {
                    focusAndWarp(window: focus, pid: pid)
                }
            }
        case .float(let fl):
            // Never position floats: everything here is the user's own
            // arrangement. Front the focused one so focus changes stay
            // visible, and leave the rest alone.
            if let focus = fl.focus, let pid = pid(of: focus), raiseFocus {
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
        // The funnel every re-apply reaches. Guarded here as well as at the two
        // callers above, because any path that writes a frame while a window is
        // held drops it — and a path that has not been traced yet is exactly
        // the one that would.
        guard !DragMove.isCarrying else { return }
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
        // `allowDrag` is the whole difference between a rule and a command.
        // The only route that actually moves a window on macOS 27 holds it and
        // presses the desktop shortcut, so honouring a rule means the screen
        // changes desktop twice — unprompted, because an app opened. That is
        // opt-in; without it the rule reports honestly and leaves the window be.
        let mayTakeOverTheScreen = currentConfig().general.followSpaceRules
        if SpaceControl.moveWindowToSpace(wid, sid, allowDrag: mayTakeOverTheScreen) {
            fputs("weftd: rule moved \(app) (\(wid)) to \(label)\n", stderr)
            return true
        }
        fputs(
            "weftd: rule cannot place \(app) (\(wid)) on \(label)"
                + (mayTakeOverTheScreen
                    ? "\n"
                    : " — set follow-space-rules = true under [general] to let weft"
                        + " hold the window and switch desktops to do it\n"),
            stderr
        )
        return false
    }

    /// Put back any managed window that has ended up off every display.
    ///
    /// This used to be scroll's cleanup — the strip hid columns by moving them
    /// to `minX - 5000`, and a crash between hiding one and showing it again
    /// stranded a window its own app believed was on screen. The strip is
    /// gone, and so is the only thing weft did that could strand a window on
    /// purpose. What is left is the case that was always possible: a window
    /// dragged off the side, or left behind by a display that was unplugged
    /// while it was there. Same symptom, same fix — and now it is a recovery
    /// verb rather than a garbage collector, which is why it is in `usage()`.
    private func rescue() -> String {
        let displays = SpaceControl.displayLayout().map { $0.frame }
        guard !displays.isEmpty else { return "rescue: no display" }
        var healed = 0
        var stranded: [WindowID] = []
        let frames = currentVisibleFrames()
        let pids = allPids()
        for wid in pids.keys.sorted() {
            guard let f = WorldReader.frame(of: wid) else { continue }
            // Off *every* display, not merely partly off one: a window the
            // user has deliberately nudged past an edge is not debris.
            guard !displays.contains(where: { $0.intersects(f) }) else { continue }
            guard let target = frames[wid], let pid = pids[wid] else {
                stranded.append(wid)
                continue
            }
            if applier.restore(wid, pid: pid, to: target) {
                healed += 1
            } else {
                stranded.append(wid)
            }
        }
        return "rescue: healed=\(healed) stranded=\(stranded)"
    }

    /// Computed frames for the current space; float shows the remembered
    /// user frames. Uses usableScreen (menu bar/Dock/reserve excluded) — the
    /// raw `screen` rect here previously disagreed with applySpaceLayout by
    /// the reserve height, so rescue/query placed windows under the bar.
    private func currentVisibleFrames() -> [WindowID: Frame] {
        let screen = self.usableScreen(for: currentSID())
        let config = currentConfig().general.asTilingConfig()
        switch currentLayout() {
        case .tiling(let tree):
            return layout(tree, in: screen, config: config)
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
}

private struct BarStateStatus: Codable, Sendable {
    var spaces: [SpaceStatus]
    var windows: [BarWindowStatus]
}

private struct BarWindowStatus: Codable, Sendable {
    var id: WindowID
    var app: String
    var title: String
    var pid: Int32
    var spaces: [SpaceID]
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

// First line of every run, so a log someone sends back names the build that
// produced it. A bug report against "weft" is unactionable when the fix for it
// shipped two releases ago.
fputs("weftd: \(WeftVersion.full) starting (pid \(ProcessInfo.processInfo.processIdentifier))\n", stderr)

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
