import Foundation
import WeftCore

/// M2: internal event bus. Events commit on the core queue, then fan out here
/// on a low-priority queue — no consumer can ever slow the reducer (§10.1).
///
/// Coalescing: one "focus a window on another space" produces several events;
/// we buffer for 16ms (one frame) and emit one batch per tick, deduplicated.
final class EventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [DaemonEvent] = []
    private var scheduled = false
    private let queue = DispatchQueue(label: "weft.bus", qos: .utility)

    /// Called off-core for every flushed event (hub broadcast + stderr trace).
    var sink: ((DaemonEvent) -> Void)? {
        get { lock.withLock { _sink } }
        set { lock.withLock { _sink = newValue } }
    }

    private var _sink: ((DaemonEvent) -> Void)?

    func emit(_ event: DaemonEvent) {
        lock.withLock {
            pending.append(event)
            guard !scheduled else { return }
            scheduled = true
            queue.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
                self?.flush()
            }
        }
    }

    private func flush() {
        let events: [DaemonEvent] = lock.withLock {
            let batch = pending
            pending = []
            scheduled = false
            return batch
        }
        var seen = Set<DaemonEventHash>()
        for event in events {
            let key = DaemonEventHash(event)
            guard seen.insert(key).inserted else { continue }  // dedupe within tick
            lock.withLock { _sink }?(event)
        }
    }
}

// DaemonEvent isn't Hashable (arrays are, but synthesized conformance wasn't
// declared) — thin wrapper for tick dedupe without touching the wire type.
private struct DaemonEventHash: Hashable {
    let kind: DaemonEvent.Kind
    let window: WindowID?
    let space: SpaceID?
    let app: String?
    let focus: WindowID?
    let windows: [WindowID]?
    let mode: String?
    let layout: String?
    let title: String?
    let stackIndex: Int?
    let stackCount: Int?
    let scrollCol: Int?
    let scrollCols: Int?

    init(_ e: DaemonEvent) {
        kind = e.kind
        window = e.window
        space = e.space
        app = e.app
        focus = e.focus
        windows = e.windows
        mode = e.mode
        layout = e.layout
        title = e.title
        stackIndex = e.stackIndex
        stackCount = e.stackCount
        scrollCol = e.scrollCol
        scrollCols = e.scrollCols
    }
}
