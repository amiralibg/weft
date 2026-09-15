import Foundation
import WeftIPC

public enum BarIPC {
    /// One blocking round trip. **Never call this on the main thread.**
    ///
    /// Every socket call here is a connect + write + read against a daemon
    /// that may be mid-sweep, and WeftBar is a UI process: a menu that opens
    /// by blocking on it is a menu that stutters, and a hotkey that fires by
    /// blocking on it is a keypress that stalls the whole app.
    public static func send(_ command: String) -> String? {
        IPCClient.sendCommand(path: IPCPaths.socketPath(), command: command)?.output
    }

    /// Fire and forget, off the caller's thread. For anything whose reply
    /// nobody reads — every keybind, every menu action.
    public static func post(_ command: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = send(command)
        }
    }

    /// Hold the daemon's event stream open, calling `onEvent` for state
    /// snapshots only. Older daemons validate but ignore the server-side
    /// filter, so filter again here to avoid turning each raw event plus its
    /// resulting snapshot into duplicate UI refreshes.
    ///
    /// Blocking; returns when the stream ends. Callers reconnect.
    public static func subscribeToState(onEvent: @escaping () -> Void) -> Bool {
        IPCClient.subscribe(
            path: IPCPaths.socketPath(), command: "subscribe stateChanged"
        ) { line in
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(StreamEvent.self, from: data),
                  event.kind == "stateChanged"
            else { return }
            onEvent()
        }
    }

    private struct StreamEvent: Decodable {
        var kind: String
    }
}
