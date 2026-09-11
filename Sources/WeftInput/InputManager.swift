import ApplicationServices
import CoreGraphics
import Foundation
import WeftCore

public enum MouseButton: Sendable, Equatable {
    case left
    case right
    /// A plain left-press that landed on the border between two tiled
    /// windows. Not a button — a role: it is the same physical button as
    /// `.left`, claimed by the tap because of where it landed rather than
    /// because a modifier was held. Kept apart so the daemon never confuses a
    /// border drag with a window drag.
    case border
}

public enum MouseGesture: Sendable, Equatable {
    case down(button: MouseButton, location: CGPoint)
    case drag(button: MouseButton, location: CGPoint)
    case up(button: MouseButton, location: CGPoint)
}

// MARK: - Tap thread

//
// The event tap's runloop source must live on a thread with a running
// CFRunLoop, and the tap callback must never block (macOS disables taps that
// exceed their callback deadline). Matching + enqueue only happens here.

private final class TapLoop: @unchecked Sendable {
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
        thread.name = "weft.input"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func perform(_ block: @escaping @Sendable () -> Void) {
        let rl = lock.withLock { runLoop }
        guard let rl, let mode = CFRunLoopMode.defaultMode else { return }
        CFRunLoopPerformBlock(rl, mode.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    func stop() {
        let rl = lock.withLock { runLoop }
        guard let rl, let mode = CFRunLoopMode.defaultMode else { return }
        CFRunLoopPerformBlock(rl, mode.rawValue) { [weak self] in
            guard let self else { return }
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
    let loop: TapLoop
    init(loop: TapLoop) { self.loop = loop }
}

// MARK: - Callback box (refcon)

/// Shared between the C callback (tap thread) and the manager. The callback
/// path takes the lock, copies what it needs, and returns — no waiting.
private final class TapBox: @unchecked Sendable {
    let lock = NSLock()
    var tap: CFMachPort?
    var keymap: Keymap
    var mode: String
    var mouseModifier: CGEventFlags = .maskAlternate
    var isDragging: Bool = false
    /// The button role of the drag in progress, so drag/up events report the
    /// same one the down did.
    var dragButton: MouseButton = .left
    /// Grab zones for the borders between tiled windows, republished by the
    /// daemon on every layout apply.
    ///
    /// Read on the tap thread for every mouse-down, which is why it is a flat
    /// array of rectangles and not a query: the callback must decide whether
    /// to swallow the click before returning, and it may not block. A scan of
    /// a few dozen rects is tens of nanoseconds.
    var dividerZones: [Frame] = []
    /// The strips where a stack's hidden members peek out behind the front
    /// one. A bare click there raises that member. Same rules as the divider
    /// zones: a flat array, scanned on the tap thread, never a query.
    var stackZones: [Frame] = []
    /// Off unless the user has asked for border dragging.
    var borderDragEnabled = false
    var onCommand: ((String) -> Void)?
    var onModeChange: ((String) -> Void)?
    var onMouseGesture: ((MouseGesture) -> Void)?

    init(keymap: Keymap) {
        self.keymap = keymap
        self.mode = keymap.initialMode
    }
}

private func tapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let box = Unmanaged<TapBox>.fromOpaque(refcon).takeUnretainedValue()

    // The footgun every event-tap implementation hits once (§6): re-enable.
    //
    // And drop any drag in progress. A tap that goes down mid-drag never sees
    // the mouse-up that would clear the latch, so it comes back believing a
    // drag is still running and swallows every drag and up that follows —
    // the pointer stops working in whatever the user does next, with nothing
    // on screen to explain it. The gesture is already lost by the time we get
    // here; the only question is whether the latch outlives it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        box.lock.withLock {
            box.isDragging = false
            if let tap = box.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        return Unmanaged.passUnretained(event)
    }
    if type == .leftMouseDown || type == .rightMouseDown {
        let loc = event.location
        let claimed: MouseButton? = box.lock.withLock {
            if box.mouseModifier.rawValue != 0 && event.flags.contains(box.mouseModifier) {
                return (type == .leftMouseDown) ? .left : .right
            }
            // No modifier: the one thing a bare click may be claimed for is
            // the border between two tiled windows. Everything else — every
            // click inside a window, on its title bar, on the desktop — is
            // passed straight through, so the tap is invisible in normal use.
            guard box.borderDragEnabled, type == .leftMouseDown else { return nil }
            let x = Double(loc.x), y = Double(loc.y)
            // Claimed as `.border` either way: the daemon tells a stack strip
            // from a divider by hit-testing its own copy of both.
            let onChrome = box.dividerZones.contains { $0.contains(x: x, y: y) }
                || box.stackZones.contains { $0.contains(x: x, y: y) }
            return onChrome ? .border : nil
        }
        guard let btn = claimed else {
            // An unclaimed press also ends any drag still on the books. Two
            // downs with no up between them means the up went somewhere we
            // never saw it — a space switch, a modal, an app that grabbed the
            // pointer — and the second press is proof the first gesture is
            // over. Without this the latch survives until some unrelated
            // mouse-up happens to clear it.
            box.lock.withLock { box.isDragging = false }
            return Unmanaged.passUnretained(event)
        }
        box.lock.withLock {
            box.isDragging = true
            box.dragButton = btn
        }
        box.lock.withLock { box.onMouseGesture }?(.down(button: btn, location: loc))
        return nil
    } else if type == .leftMouseDragged || type == .rightMouseDragged {
        let btn: MouseButton? = box.lock.withLock { box.isDragging ? box.dragButton : nil }
        if let btn {
            let loc = event.location
            box.lock.withLock { box.onMouseGesture }?(.drag(button: btn, location: loc))
            return nil
        }
        return Unmanaged.passUnretained(event)
    } else if type == .leftMouseUp || type == .rightMouseUp {
        let btn: MouseButton? = box.lock.withLock {
            let b = box.isDragging ? box.dragButton : nil
            box.isDragging = false
            return b
        }
        if let btn {
            let loc = event.location
            box.lock.withLock { box.onMouseGesture }?(.up(button: btn, location: loc))
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)  // incl. flagsChanged: observe, pass
    }

    // Synthetic loopback guard: our own posts carry userData 0x57454654 ("WEFT")
    if event.getIntegerValueField(.eventSourceUserData) == 0x57454654 {
        return Unmanaged.passUnretained(event)
    }

    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    let mods = event.flags.intersection([.maskAlternate, .maskShift, .maskCommand, .maskControl]).rawValue
    let chord = Chord(mods: mods, keycode: keycode)

    let action: KeyAction? = box.lock.withLock {
        box.keymap.modes[box.mode]?[chord]
    }
    guard let action else {
        return Unmanaged.passUnretained(event)
    }
    switch action {
    case .send(let command):
        box.lock.withLock { box.onCommand }?(command)
    case .mode(let name):
        let known: Bool = box.lock.withLock {
            guard box.keymap.modes[name] != nil else { return false }
            box.mode = name
            return true
        }
        if known {
            box.lock.withLock { box.onModeChange }?(name)
        }
    }
    return nil  // matched: swallow
}

// MARK: - InputManager

/// M2 input: head-insert session tap, modal chords, enqueue-only callback.
/// Keypress → command dispatch is sub-millisecond (no fork+exec, vs skhd §6).
public final class InputManager: @unchecked Sendable {
    private let loop = TapLoop()
    private let box: TapBox
    private let lock = NSLock()
    private var source: CFRunLoopSource?
    private var running = false

    public var onCommand: ((String) -> Void)? {
        get { lock.withLock { _onCommand } }
        set { lock.withLock { _onCommand = newValue } }
    }

    private var _onCommand: ((String) -> Void)?

    public var onModeChange: ((String) -> Void)? {
        get { lock.withLock { _onModeChange } }
        set { lock.withLock { _onModeChange = newValue } }
    }

    private var _onModeChange: ((String) -> Void)?

    public var onMouseGesture: ((MouseGesture) -> Void)? {
        get { lock.withLock { _onMouseGesture } }
        set {
            lock.withLock { _onMouseGesture = newValue }
            box.lock.withLock { box.onMouseGesture = newValue }
        }
    }

    private var _onMouseGesture: ((MouseGesture) -> Void)?

    public func updateMouseModifier(_ modifier: String) {
        let flags: CGEventFlags
        switch modifier.lowercased() {
        case "alt", "opt": flags = .maskAlternate
        case "cmd", "command": flags = .maskCommand
        case "ctrl", "control": flags = .maskControl
        case "shift": flags = .maskShift
        case "fn": flags = .maskSecondaryFn
        default: flags = .maskAlternate
        }
        box.lock.withLock { box.mouseModifier = flags }
    }

    /// Republish the border grab zones. Called on every layout apply, so it
    /// stays cheap: one lock, one array swap, no allocation on the tap side.
    public func updateDividerZones(_ zones: [Frame]) {
        box.lock.withLock {
            guard box.dividerZones != zones else { return }
            box.dividerZones = zones
        }
    }

    /// Republish the stack peek strips. Same cost model as the divider zones.
    public func updateStackZones(_ zones: [Frame]) {
        box.lock.withLock {
            guard box.stackZones != zones else { return }
            box.stackZones = zones
        }
    }

    /// Whether a bare click on a border starts a resize — and on a stack's
    /// peeking strip, raises that member. Off means the tap never claims an
    /// unmodified click at all.
    public func setBorderDragEnabled(_ enabled: Bool) {
        box.lock.withLock {
            box.borderDragEnabled = enabled
            if !enabled {
                box.dividerZones = []
                box.stackZones = []
            }
        }
    }

    public var currentMode: String { box.lock.withLock { box.mode } }

    public init(keymap: Keymap = .default) {
        self.box = TapBox(keymap: keymap)
    }

    /// Hot-swap the keymap (config reload). Unknown current mode falls back
    /// to the new initial mode. Thread-safe; takes effect on next keypress.
    public func updateKeymap(_ keymap: Keymap) {
        box.lock.withLock {
            box.keymap = keymap
            if box.keymap.modes[box.mode] == nil {
                box.mode = keymap.initialMode
            }
        }
    }

    /// Whether the event tap is live. This, not `CGPreflightListenEventAccess`,
    /// is what keybinds depend on — a preflight can say yes while tap creation
    /// still fails, and the difference is "no keybinds work at all".
    public var tapInstalled: Bool {
        box.lock.withLock { box.tap != nil }
    }

    /// Called once, the first time a retry turns the tap on. The daemon uses
    /// it to log the transition and re-apply the keymap it holds.
    public var onTapInstalledLate: (() -> Void)? {
        get { lock.withLock { _onTapInstalledLate } }
        set { lock.withLock { _onTapInstalledLate = newValue } }
    }

    private var _onTapInstalledLate: (() -> Void)?
    private let retryLock = NSLock()
    private var lastRetry = Date.distantPast

    /// The tap if it is up; one more attempt to create it if it is not.
    ///
    /// This is what makes a grant land without a restart. `CGEvent.tapCreate`
    /// re-checks TCC on every call, so the attempt that failed at launch
    /// succeeds the moment the user flips the Input Monitoring switch — but
    /// only if something attempts it again. Nothing did, so keybinds stayed
    /// dead and the Setup window kept reporting the permission as missing
    /// until the daemon happened to be restarted.
    ///
    /// Throttled to one attempt a second: a denied `tapCreate` can sit in TCC
    /// for a while, and the Setup window polls at exactly that rate.
    @discardableResult
    public func ensureTap() -> Bool {
        if tapInstalled { return true }
        let go: Bool = retryLock.withLock {
            guard Date().timeIntervalSince(lastRetry) >= 1.0 else { return false }
            lastRetry = Date()
            return true
        }
        guard go else { return false }
        guard start() else { return false }
        lock.withLock { _onTapInstalledLate }?()
        return true
    }

    @discardableResult
    public func start() -> Bool {
        if tapInstalled { return true }
        // Not until Accessibility is granted. An active tap needs it, and
        // asking for the tap without it is what makes macOS put up its own
        // "would like to control this computer" dialog — from a process with
        // no window, at startup, on top of the Setup window whose job is
        // exactly that permission. The check is silent; the retry loop
        // creates the tap the moment the switch is on.
        guard AXIsProcessTrusted() else { return false }
        let done = DispatchSemaphore(value: 0)
        let result = StartResult()
        // Tap creation + source install happen on the tap thread, so the
        // runloop that owns the source is the one that runs it.
        loop.perform { [weak self] in
            guard let self else {
                result.value = false
                done.signal()
                return
            }
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
                | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
                | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
                | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
                | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
                | CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)
                | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
            let refcon = Unmanaged.passUnretained(self.box).toOpaque()
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: tapCallback,
                userInfo: refcon
            ) else {
                result.value = false
                done.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, CFRunLoopMode.defaultMode!)
            self.lock.withLock {
                self.box.lock.withLock { self.box.tap = tap }
                self.source = source
                self.running = true
            }
            // Forward through volatile storage: the tap thread must never
            // block, so callbacks fan out through the manager's closures,
            // which the daemon implements as queue hops.
            self.box.lock.withLock {
                self.box.onCommand = { [weak self] cmd in self?.forwardCommand(cmd) }
                self.box.onModeChange = { [weak self] mode in self?.forwardMode(mode) }
            }
            result.value = true
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        return result.value
    }

    public func stop() {
        loop.perform { [weak self] in
            guard let self else { return }
            if let source = self.source {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, CFRunLoopMode.defaultMode!)
            }
            self.lock.withLock {
                self.box.lock.withLock { self.box.tap = nil }
                self.source = nil
                self.running = false
            }
        }
        loop.stop()
    }

    // MARK: - Private (never blocks the tap thread)

    private func forwardCommand(_ command: String) {
        lock.withLock { _onCommand }?(command)
    }

    private func forwardMode(_ mode: String) {
        lock.withLock { _onModeChange }?(mode)
    }
}

private final class StartResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
