import CoreGraphics
import Foundation

public enum MouseButton: Sendable, Equatable {
    case left
    case right
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
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        box.lock.withLock {
            if let tap = box.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        return Unmanaged.passUnretained(event)
    }
    if type == .leftMouseDown || type == .rightMouseDown {
        let reqMod = box.lock.withLock { box.mouseModifier }
        if reqMod.rawValue != 0 && event.flags.contains(reqMod) {
            box.lock.withLock { box.isDragging = true }
            let btn: MouseButton = (type == .leftMouseDown) ? .left : .right
            let loc = event.location
            box.lock.withLock { box.onMouseGesture }?(.down(button: btn, location: loc))
            return nil
        }
        return Unmanaged.passUnretained(event)
    } else if type == .leftMouseDragged || type == .rightMouseDragged {
        let dragging = box.lock.withLock { box.isDragging }
        if dragging {
            let btn: MouseButton = (type == .leftMouseDragged) ? .left : .right
            let loc = event.location
            box.lock.withLock { box.onMouseGesture }?(.drag(button: btn, location: loc))
            return nil
        }
        return Unmanaged.passUnretained(event)
    } else if type == .leftMouseUp || type == .rightMouseUp {
        let wasDragging = box.lock.withLock {
            let d = box.isDragging
            box.isDragging = false
            return d
        }
        if wasDragging {
            let btn: MouseButton = (type == .leftMouseUp) ? .left : .right
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
