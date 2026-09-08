import CoreServices
import Foundation

// MARK: - Hot reload (M6)

/// Watches the config directory via FSEvents and calls onChange (trailing
/// debounce) when weft.toml changes. Own runloop thread with a keep-alive
/// source (same pattern as the observer/input loops — a sourceless runloop
/// exits instead of parking).
public final class ConfigWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var keepAlive: CFRunLoopSource?
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private let ready = DispatchSemaphore(value: 0)
    private let directory: String
    private let onChange: () -> Void
    /// Retained for the stream's lifetime — the FSEvents refcon points here.
    private var streamBox: StreamBox?

    public init(directory: String, onChange: @escaping () -> Void) {
        self.directory = directory
        self.onChange = onChange
        let box = WatchBox(watcher: self)
        let thread = Thread {
            let rl = CFRunLoopGetCurrent()
            var ctx = CFRunLoopSourceContext(
                version: 0, info: nil, retain: nil, release: nil,
                copyDescription: nil, equal: nil, hash: nil,
                schedule: nil, cancel: nil, perform: nil
            )
            let src = CFRunLoopSourceCreate(nil, 0, &ctx)
            CFRunLoopAddSource(rl, src, CFRunLoopMode.defaultMode!)
            box.watcher.lock.withLock {
                box.watcher.runLoop = rl
                box.watcher.keepAlive = src
            }
            box.watcher.ready.signal()
            CFRunLoopRun()
        }
        thread.name = "weft.config"
        thread.qualityOfService = .utility
        thread.start()
        ready.wait()
    }

    public func start() {
        guard lock.withLock({ runLoop }) != nil else { return }
        let box = StreamBox(watcher: self)
        lock.withLock { streamBox = box }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<StreamBox>.fromOpaque(info).takeUnretainedValue().fired()
            },
            &context,
            [directory] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            UInt32(kFSEventStreamCreateFlagFileEvents)
        )
        guard let stream else { return }
        lock.withLock { self.stream = stream }
        // Schedule + start on the watch thread (the stream's runloop).
        // OpaquePointer isn't Sendable — box it (owned by self.stream).
        let ref = StreamRef(stream)
        perform {
            FSEventStreamScheduleWithRunLoop(ref.value, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode!.rawValue)
            FSEventStreamStart(ref.value)
        }
    }

    public func stop() {
        let (rl, stream): (CFRunLoop?, FSEventStreamRef?) = lock.withLock { (runLoop, self.stream) }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        lock.withLock {
            self.stream = nil
            self.streamBox = nil
        }
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

    fileprivate func perform(_ block: @escaping @Sendable () -> Void) {
        let rl = lock.withLock { runLoop }
        guard let rl, let mode = CFRunLoopMode.defaultMode else { return }
        CFRunLoopPerformBlock(rl, mode.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    fileprivate func fired() {
        // Trailing debounce: editors write temp+rename bursts; reload once.
        lock.withLock { pending?.cancel() }
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        lock.withLock { pending = work }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

private final class WatchBox: @unchecked Sendable {
    let watcher: ConfigWatcher
    init(watcher: ConfigWatcher) { self.watcher = watcher }
}

/// @unchecked Sendable owner for the FSEventStream across the schedule hop
/// (lifetime is owned by ConfigWatcher.stream; this is just a carrier).
private final class StreamRef: @unchecked Sendable {
    let value: FSEventStreamRef
    init(_ value: FSEventStreamRef) { self.value = value }
}

private final class StreamBox: @unchecked Sendable {
    weak var watcher: ConfigWatcher?
    init(watcher: ConfigWatcher) { self.watcher = watcher }
    func fired() { watcher?.fired() }
}
