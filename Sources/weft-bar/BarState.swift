import AppKit
import Foundation

/// What the menu bar draws, kept up to date without the main thread ever
/// waiting on a socket.
///
/// The menu used to be built by making two blocking IPC calls inside
/// `menuNeedsUpdate`, and the title by making a third on a two-second timer,
/// all on the main thread. That is three chances a second for the whole app —
/// including the Settings window, which lives in this same process — to freeze
/// for as long as the daemon takes to answer, which is exactly as long as it
/// takes to sweep the WindowServer. Clicking anything in Settings while that
/// timer was running was the lag.
///
/// So: one background subscription to the daemon's event stream, refreshes
/// driven by what actually changed, and a plain cached snapshot for the UI to
/// read synchronously.
@MainActor
final class BarState: ObservableObject {
    @Published private(set) var spaces: [BarSpace] = []
    @Published private(set) var windows: [BarWindow] = []
    /// Nil until the first answer arrives; false once the daemon has been
    /// asked and did not reply.
    @Published private(set) var daemonUp: Bool?
    /// Set when weftd is running but needs restarting to pick up a
    /// permission granted while it was already up.
    @Published private(set) var needsRestart = false

    /// Called after every successful refresh, so the status item can redraw
    /// without observing.
    var onChange: (() -> Void)?

    private var refreshing = false
    private var refreshAgain = false
    private var pollTimer: Timer?
    private var stream: StreamToken?

    var currentSpace: BarSpace? { spaces.first(where: \.current) }

    func start() {
        refresh()
        connectStream()
        // A slow backstop, not the primary source. The stream carries every
        // real change; this only covers the window where it is reconnecting,
        // and a daemon that is not running yet.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        stream?.cancel()
        stream = nil
    }

    /// Coalesced. A burst of events — an app launching fires several within a
    /// few milliseconds — collapses into one refresh, and one more after it if
    /// anything arrived while that was in flight.
    func refresh() {
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        Task.detached(priority: .utility) {
            let snapshot = Snapshot.read()
            await MainActor.run { self.apply(snapshot) }
        }
    }

    private func apply(_ s: Snapshot) {
        refreshing = false
        if s.reachable {
            spaces = s.spaces
            windows = s.windows
        }
        daemonUp = s.reachable
        needsRestart = s.needsRestart
        onChange?()
        if refreshAgain {
            refreshAgain = false
            refresh()
        }
    }

    /// One long-lived connection, reconnecting with a delay when it drops.
    /// The daemon pushes a `stateChanged` line on every layout, focus and
    /// space change, which is precisely when the menu bar is stale.
    private func connectStream() {
        stream?.cancel()
        let token = StreamToken()
        stream = token
        // Built here, on the main actor, and handed to the background task as
        // the only thing it knows about this object. The task itself never
        // touches `self`, so there is nothing to race over.
        let notify: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        Task.detached(priority: .utility) {
            while !token.isCancelled {
                let ok = BarIPC.subscribe { _ in
                    guard !token.isCancelled else { return }
                    notify()
                }
                // Reconnect, unhurried: a daemon that is down stays down for
                // seconds at a time, and a tight retry loop against a missing
                // socket is a busy wait that shows up in Activity Monitor.
                try? await Task.sleep(nanoseconds: ok ? 500_000_000 : 2_000_000_000)
            }
        }
    }

    /// Lets the main actor call off a background reconnect loop it does not
    /// otherwise share any state with.
    private final class StreamToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    /// Everything the menu needs, read off the main thread in one go.
    private struct Snapshot: Sendable {
        var spaces: [BarSpace] = []
        var windows: [BarWindow] = []
        var reachable = false
        var needsRestart = false

        static func read() -> Snapshot {
            var out = Snapshot()
            guard let sJSON = BarIPC.send("query spaces"),
                  let sData = sJSON.data(using: .utf8),
                  let spaces = try? JSONDecoder().decode([BarSpace].self, from: sData)
            else { return out }
            out.reachable = true
            out.spaces = spaces
            if let wJSON = BarIPC.send("query windows"),
               let wData = wJSON.data(using: .utf8),
               let windows = try? JSONDecoder().decode([BarWindow].self, from: wData)
            {
                out.windows = windows
            }
            struct Perms: Decodable { var needsRestart: Bool? }
            if let pJSON = BarIPC.send("query permissions"),
               let pData = pJSON.data(using: .utf8),
               let perms = try? JSONDecoder().decode(Perms.self, from: pData)
            {
                out.needsRestart = perms.needsRestart ?? false
            }
            return out
        }
    }
}
