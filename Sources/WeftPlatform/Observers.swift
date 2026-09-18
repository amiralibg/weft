import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

// MARK: - C-callback trampoline
//
// AXObserver callbacks carry no context pointer for app-level notifications,
// so a single process-wide sink forwards to the live ObserverSet. M2 runs one
// daemon, so one sink is exact — not a shortcut.

private final class SinkHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: ((ObserverEvent) -> Void)?

    func set(_ new: ((ObserverEvent) -> Void)?) {
        lock.withLock { sink = new }
    }

    func fire(_ event: ObserverEvent) {
        lock.withLock { sink }?(event)
    }
}

private let sinkHolder = SinkHolder()

private func axCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    let name = notification as String
    let created = kAXWindowCreatedNotification as String
    let focusedChanged = kAXFocusedWindowChangedNotification as String
    let destroyed = kAXUIElementDestroyedNotification as String
    let mini = kAXWindowMiniaturizedNotification as String
    let demini = kAXWindowDeminiaturizedNotification as String
    let moved = kAXWindowMovedNotification as String
    let resized = kAXWindowResizedNotification as String

    // Window-level notifications registered with the wid as refcon.
    if let refcon, name != created, name != focusedChanged {
        let wid = WindowID(UInt(bitPattern: refcon))
        let event: ObserverEvent?
        switch name {
        case destroyed: event = .windowDestroyed(wid)
        case mini: event = .windowDestroyed(wid)  // minimized tiles out (M2 policy)
        case demini: event = nil  // daemon re-syncs on deminimize via created path below
        case moved: event = .windowMoved(wid)
        case resized: event = .windowResized(wid)
        default: event = nil
        }
        if demini == name {
            // Deminimize: element is valid again — treat like a creation.
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            sinkHolder.fire(.windowCreated(pid: pid, wid: wid))
            return
        }
        if let event {
            sinkHolder.fire(event)
        }
        return
    }

    // App-level notifications: resolve the wid, tolerating 0 (transient).
    switch name {
    case created:
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        // The element *is* the new window. Naming it costs one local call and
        // lets the daemon wait for this window specifically; 0 happens for a
        // window still being assembled, and falls back to a plain sweep.
        var wid: UInt32 = 0
        let named = _AXUIElementGetWindow(element, &wid) == .success && wid != 0
        sinkHolder.fire(.windowCreated(pid: pid, wid: named ? wid : nil))
    case focusedChanged:
        var wid: UInt32 = 0
        let ok = _AXUIElementGetWindow(element, &wid) == .success && wid != 0
        sinkHolder.fire(.windowFocused(ok ? wid : nil))
    default:
        break
    }
}

private func displayReconfigCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    sinkHolder.fire(.displayChanged)
}

// MARK: - Observer runloop thread
//
// AXObserver sources must live on a thread with a running CFRunLoop. All
// AXObserverCreate/Add/Remove calls happen on this thread via perform().

private final class ObserverLoop: @unchecked Sendable {
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var keepAlive: CFRunLoopSource?
    private let ready = DispatchSemaphore(value: 0)

    init() {
        let box = LoopBox(loop: self)
        let thread = Thread {
            let rl = CFRunLoopGetCurrent()
            // A runloop with no sources or timers exits immediately instead
            // of parking. This never-signalled source keeps it alive.
            var ctx = CFRunLoopSourceContext(
                version: 0, info: nil, retain: nil, release: nil,
                copyDescription: nil, equal: nil, hash: nil,
                schedule: nil, cancel: nil, perform: nil
            )
            let src = CFRunLoopSourceCreate(nil, 0, &ctx)
            CFRunLoopAddSource(rl, src, CFRunLoopMode.defaultMode!)
            box.loop.lock.withLock {
                box.loop.runLoop = rl
                box.loop.keepAlive = src
            }
            box.loop.ready.signal()
            CFRunLoopRun()
        }
        thread.name = "weft.observers"
        thread.qualityOfService = .utility
        thread.start()
        ready.wait()
    }

    func perform(_ block: @escaping @Sendable () -> Void) {
        let rl = lock.withLock { runLoop }
        guard let rl else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode!.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    func stop() {
        let rl = lock.withLock { runLoop }
        guard let rl else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode!.rawValue) { [weak self] in
            guard let self else { return }
            let mode = CFRunLoopMode.defaultMode!
            let src = self.lock.withLock { () -> CFRunLoopSource? in
                let s = self.keepAlive
                self.keepAlive = nil
                return s
            }
            if let src { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, mode) }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(rl)
    }
}

private final class LoopBox: @unchecked Sendable {
    let loop: ObserverLoop
    init(loop: ObserverLoop) { self.loop = loop }
}

// MARK: - ObserverSet

/// M2 event sources. Everything here is read-only observation — no window is
/// ever moved. Callbacks fire on arbitrary threads; the daemon hops to core.
///
/// Without Accessibility permission AXObserverCreate fails per pid and those
/// apps simply produce no AX events (NSWorkspace/display/space events still
/// flow). The daemon then relies on manual `sync` — the M1 behaviour.
public final class ObserverSet: @unchecked Sendable {
    private let loop = ObserverLoop()
    private let lock = NSLock()
    private var appObservers: [Int32: AXObserver] = [:]
    private var appElements: [Int32: AXUIElement] = [:]
    private var windowElements: [WindowID: AXUIElement] = [:]
    private var ncTokens: [NSObjectProtocol] = []
    private var axFailedPids: Set<Int32> = []
    private var started = false

    public var onEvent: ((ObserverEvent) -> Void)? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    private var _onEvent: ((ObserverEvent) -> Void)?

    public init() {}

    // MARK: - Lifecycle

    /// Register non-AX sources. Safe to call from any thread.
    public func start() {
        lock.withLock {
            guard !started else { return }
            started = true
        }
        sinkHolder.set { [weak self] event in self?.forward(event) }
        let center = NSWorkspace.shared.notificationCenter
        let queue: OperationQueue? = nil  // deliver on posting thread; daemon hops to core
        ncTokens = [
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil, queue: queue
            ) { [weak self] note in self?.appNote(note, launched: true) },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil, queue: queue
            ) { [weak self] note in self?.appNote(note, launched: false) },
            center.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil, queue: queue
            ) { [weak self] _ in self?.forward(.spaceChanged) },
            // The click that switches app.
            //
            // AX has no notification for it: `kAXFocusedWindowChanged` fires
            // when an app's own focused window changes, and activating an app
            // does not change which of its windows that is. So every focus
            // change made by clicking on a different app's window arrived
            // here as nothing at all. NSWorkspace does announce it, for every
            // app, whether or not AX is granted for that process.
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: queue
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                else { return }
                self?.forward(.appActivated(pid: app.processIdentifier))
            },
        ]
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, nil)
    }

    /// Watch the given apps + windows. Idempotent: only new pids/wids are
    /// added. AX work runs on the observer thread.
    public func watch(pids: [Int32], windows: [(WindowID, Int32)]) {
        loop.perform { [weak self] in
            self?.watchOnLoop(pids: pids, windows: windows)
        }
    }

    /// Forget a dead window so its slot can be re-registered if the id is
    /// recycled. `windowElements` used to grow for the life of the daemon and
    /// `watchOnLoop` skips any wid already present — so a recycled id silently
    /// never got move/resize notifications again.
    public func forgetWindow(_ wid: WindowID) {
        loop.perform { [weak self] in
            self?.windowElements.removeValue(forKey: wid)
        }
    }

    /// Tear down the observer for a terminated app. Leaving it registered kept
    /// a run-loop source and an AXUIElement alive per dead process.
    public func forgetApp(pid: Int32) {
        loop.perform { [weak self] in
            guard let self else { return }
            if let observer = self.appObservers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(
                    CFRunLoopGetCurrent(),
                    AXObserverGetRunLoopSource(observer),
                    CFRunLoopMode.defaultMode!
                )
            }
            self.appElements.removeValue(forKey: pid)
            self.axFailedPids.remove(pid)
        }
    }

    public func stop() {
        for token in ncTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        ncTokens = []
        CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, nil)
        sinkHolder.set(nil)
        loop.perform { [weak self] in
            guard let self else { return }
            for (_, observer) in self.appObservers {
                CFRunLoopRemoveSource(
                    CFRunLoopGetCurrent(),
                    AXObserverGetRunLoopSource(observer),
                    CFRunLoopMode.defaultMode!
                )
            }
            self.appObservers = [:]
            self.appElements = [:]
            self.windowElements = [:]
        }
        loop.stop()
    }

    // MARK: - Private

    private func forward(_ event: ObserverEvent) {
        lock.withLock { _onEvent }?(event)
    }

    private func appNote(_ note: Notification, launched: Bool) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        let pid = app.processIdentifier
        let bundle = app.bundleIdentifier ?? "unknown"
        forward(launched ? .appLaunched(pid: pid, bundleID: bundle) : .appTerminated(pid: pid, bundleID: bundle))
    }

    private func watchOnLoop(pids: [Int32], windows: [(WindowID, Int32)]) {
        for pid in pids where appObservers[pid] == nil {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 0.15)
            var observer: AXObserver?
            guard AXObserverCreate(pid, axCallback, &observer) == .success,
                  let observer
            else {
                if axFailedPids.insert(pid).inserted {
                    fputs("weftd: AX observe denied for pid \(pid) (grant Accessibility)\n", stderr)
                }
                continue
            }
            CFRunLoopAddSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(observer),
                CFRunLoopMode.defaultMode!
            )
            var addFailed = false
            for note in [
                kAXWindowCreatedNotification,
                kAXFocusedWindowChangedNotification,
            ] as [String] {
                if AXObserverAddNotification(observer, appEl, note as CFString, nil) != .success {
                    addFailed = true
                }
            }
            if addFailed, axFailedPids.insert(pid).inserted {
                fputs("weftd: AX notifications denied for pid \(pid) (grant Accessibility)\n", stderr)
            }
            appObservers[pid] = observer
            appElements[pid] = appEl
        }
        for (wid, pid) in windows where windowElements[wid] == nil {
            guard let observer = appObservers[pid] else { continue }  // no AX for this app
            guard let el = windowElement(pid: pid, wid: wid) else { continue }
            let refcon = UnsafeMutableRawPointer(bitPattern: UInt(wid))
            for note in [
                kAXUIElementDestroyedNotification,
                kAXWindowMiniaturizedNotification,
                kAXWindowDeminiaturizedNotification,
                kAXWindowMovedNotification,
                kAXWindowResizedNotification,
            ] as [String] {
                if AXObserverAddNotification(observer, el, note as CFString, refcon) != .success,
                   axFailedPids.insert(pid).inserted
                {
                    fputs("weftd: AX notifications denied for pid \(pid) (grant Accessibility)\n", stderr)
                }
            }
            windowElements[wid] = el
        }
    }

    /// Find the AX element for a wid by enumerating its app (read-only).
    private func windowElement(pid: Int32, wid: WindowID) -> AXUIElement? {
        guard let appEl = appElements[pid] else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement]
        else { return nil }
        for el in elements {
            var found: UInt32 = 0
            if _AXUIElementGetWindow(el, &found) == .success, found == wid {
                return el
            }
        }
        return nil
    }
}
