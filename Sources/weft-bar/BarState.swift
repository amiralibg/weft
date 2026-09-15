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
    /// Every permission weft needs is in place. Drives whether the menu
    /// carries a Permissions row at all: once setup is done it is not a thing
    /// anyone needs quick access to. Defaults false — when the daemon cannot
    /// be asked, the row is the thing most likely to help.
    @Published private(set) var permissionsReady = false

    /// Called after every successful refresh, so the status item can redraw
    /// without observing.
    var onChange: (() -> Void)?

    private var refreshing = false
    private var refreshAgain = false
    private var checkPermissionsAgain = false
    private var pollTimer: Timer?
    private var stream: StreamToken?

    var currentSpace: BarSpace? { spaces.first(where: \.current) }

    func start() {
        refresh(checkPermissions: true)
        connectStream()
        // A slow backstop, not the primary source. The stream carries every
        // real state change; this covers the window where it is reconnecting,
        // a daemon that is not running yet, and permission switches (which do
        // not produce daemon events).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(checkPermissions: true) }
        }
    }

    /// Pull the snapshot off the main thread, then publish it in one turn of
    /// the run loop so views observe a coherent state.
    func refresh(checkPermissions: Bool = false) {
        guard !refreshing else {
            // Coalesce: if something changed while a refresh was in flight,
            // run exactly one more once it lands rather than queueing one
            // per event.
            refreshAgain = true
            checkPermissionsAgain = checkPermissionsAgain || checkPermissions
            return
        }
        refreshing = true
        Task.detached(priority: .userInitiated) {
            let next = Self.takeSnapshot(checkPermissions: checkPermissions)
            await MainActor.run {
                self.spaces = next.spaces
                self.windows = next.windows
                self.daemonUp = next.reachable
                if let needsRestart = next.needsRestart {
                    self.needsRestart = needsRestart
                }
                if let permissionsReady = next.permissionsReady {
                    self.permissionsReady = permissionsReady
                }
                self.refreshing = false
                self.onChange?()
                if self.refreshAgain {
                    self.refreshAgain = false
                    let checkPermissions = self.checkPermissionsAgain
                    self.checkPermissionsAgain = false
                    self.refresh(checkPermissions: checkPermissions)
                }
            }
        }
    }

    /// Tear down any running subscription and start a fresh one.
    func connectStream() {
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
            var retryDelayMs = 50
            while !token.isCancelled {
                let ok = BarIPC.subscribeToState {
                    guard !token.isCancelled else { return }
                    notify()
                }
                // Reconnect promptly on restart: start fast (50ms) so a restarting
                // daemon is caught the moment it rebinds its socket, then back off
                // gracefully if it stays down.
                if ok {
                    retryDelayMs = 50
                    try? await Task.sleep(nanoseconds: 500_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(retryDelayMs) * 1_000_000)
                    retryDelayMs = min(retryDelayMs * 2, 1000)
                }
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
        var needsRestart: Bool?
        var permissionsReady: Bool?
    }

    private struct BarStateResponse: Decodable {
        var spaces: [BarSpace]
        var windows: [BarWindow]
    }

    private nonisolated static func takeSnapshot(checkPermissions: Bool) -> Snapshot {
        let state: BarStateResponse?
        if let json = BarIPC.send("query bar-state"),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(BarStateResponse.self, from: data)
        {
            state = decoded
        } else {
            // A replaced WeftBar can briefly run against the previous weftd
            // while EngineInstaller catches it up. Keep that update path
            // working; only the old daemon pays for the old diagnostic queries.
            state = takeLegacyState()
        }
        guard let state else { return Snapshot() }

        var snapshot = Snapshot(
            spaces: state.spaces,
            windows: state.windows,
            reachable: true
        )
        if checkPermissions,
           let pJSON = BarIPC.send("query permissions"),
           let pData = pJSON.data(using: .utf8),
           let perms = try? JSONDecoder().decode(DaemonPermissions.self, from: pData)
        {
            snapshot.needsRestart = perms.needsRestart ?? false
            snapshot.permissionsReady = perms.ready
        }
        return snapshot
    }

    private nonisolated static func takeLegacyState() -> BarStateResponse? {
        guard let sJSON = BarIPC.send("query spaces"),
              let sData = sJSON.data(using: .utf8),
              let spaces = try? JSONDecoder().decode([BarSpace].self, from: sData)
        else { return nil }
        let windows: [BarWindow]
        if let wJSON = BarIPC.send("query windows"),
           let wData = wJSON.data(using: .utf8),
           let list = try? JSONDecoder().decode([BarWindow].self, from: wData)
        {
            windows = list
        } else {
            windows = []
        }
        return BarStateResponse(spaces: spaces, windows: windows)
    }
}
