import Foundation
import WeftIPC

public enum BarIPC {
    public static func send(_ command: String) -> String? {
        let path = IPCPaths.socketPath()
        return IPCClient.sendCommand(path: path, command: command)?.output
    }
}
