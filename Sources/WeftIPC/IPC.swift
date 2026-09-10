import Darwin
import Foundation

/// M2 (extended): Unix-domain-socket transport. Two modes share the listener:
///
/// - Request/response: one request line in, one response line out, close.
/// - Subscribe: `{"command":"subscribe ..."}` holds the connection open and
///   the daemon pushes newline-delimited event JSON until EOF (M2 debug trace;
///   the model for the M6.5 sketchybar bridge).
///
/// Socket: `$TMPDIR/weft-$USER.sock` (§1).
public enum IPCPaths {
    public static func socketPath() -> String {
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/"
        let user = ProcessInfo.processInfo.environment["USER"] ?? "unknown"
        return (tmp as NSString).appendingPathComponent("weft-\(user).sock")
    }
}

/// Ignore SIGPIPE process-wide. A subscriber that dies (Ctrl-C, kill) leaves
/// a dead fd in the hub until the next broadcast; without this, that first
/// write to the dead peer terminates the whole daemon. With it, write()
/// returns EPIPE and the hub drops the peer normally.
public func ignoreSIGPIPE() {
    signal(SIGPIPE, SIG_IGN)
}

public struct IPCRequest: Codable, Sendable {
    public var command: String
    public init(command: String) { self.command = command }
}

public struct IPCResponse: Codable, Sendable {
    public var ok: Bool
    public var output: String?
    public var error: String?

    public init(ok: Bool, output: String? = nil, error: String? = nil) {
        self.ok = ok
        self.output = output
        self.error = error
    }
}

private func makeUnixAddress(path: String) -> (sockaddr_un, socklen_t) {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
        raw[bytes.count] = 0
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return (addr, len)
}

/// Buffered line reader over one fd.
///
/// The obvious version — `read(fd, &byte, 1)` in a loop — is a syscall per
/// byte. That is invisible for a command (`focus west` is eleven of them) and
/// ruinous for a reply: `query windows` on a busy desktop is tens of
/// kilobytes, so every menu open and every settings poll was tens of
/// thousands of syscalls, on the main thread, and felt exactly like it.
///
/// One instance per connection, so bytes read past the newline are kept for
/// the next line rather than dropped — that is what makes the subscribe
/// stream work byte-for-byte the same way.
final class LineReader {
    private let fd: Int32
    private var buffer: [UInt8] = []
    private var offset = 0
    private static let chunk = 16 * 1024
    /// Cap per message, matching the old reader.
    private static let limit = 1_048_576

    init(fd: Int32) { self.fd = fd }

    func next() -> String? {
        var line: [UInt8] = []
        while true {
            // Serve from what is already buffered.
            if offset < buffer.count {
                if let nl = buffer[offset...].firstIndex(of: UInt8(ascii: "\n")) {
                    line.append(contentsOf: buffer[offset..<nl])
                    offset = nl + 1
                    compact()
                    return String(bytes: line, encoding: .utf8)
                }
                line.append(contentsOf: buffer[offset...])
                offset = buffer.count
                compact()
                if line.count > Self.limit { return String(bytes: line, encoding: .utf8) }
            }
            var chunk = [UInt8](repeating: 0, count: Self.chunk)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, Self.chunk) }
            if n <= 0 {
                // EOF or error: a trailing unterminated line is still a line.
                return line.isEmpty ? nil : String(bytes: line, encoding: .utf8)
            }
            buffer = Array(chunk[0..<n])
            offset = 0
        }
    }

    private func compact() {
        if offset >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
            offset = 0
        }
    }
}

private func readLine(fd: Int32) -> String? {
    LineReader(fd: fd).next()
}

private func writeAll(fd: Int32, _ string: String) -> Bool {
    let data = Array((string + "\n").utf8)
    var off = 0
    while off < data.count {
        let n = data.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress!.advanced(by: off), data.count - off)
        }
        if n <= 0 { return false }
        off += n
    }
    return true
}

/// One accepted connection. The handler either responds (server closes it) or
/// detaches it into a SubscriberHub for event streaming.
public final class IPCConnection: @unchecked Sendable {
    private let lock = NSLock()
    private let fd: Int32
    private var detached = false
    private var closed = false

    fileprivate init(fd: Int32) { self.fd = fd }

    /// Send one line. False = peer gone (hubs drop the connection).
    @discardableResult
    public func send(_ line: String) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            return writeAll(fd: fd, line)
        }
    }

    /// Hand ownership to the caller (e.g. a SubscriberHub). The server will
    /// not close the fd; the owner must call `close()`.
    public func detach() {
        lock.withLock { detached = true }
    }

    public func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }

    fileprivate var isDetached: Bool { lock.withLock { detached } }
}

/// Fans event lines out to detached subscriber connections. Dead peers are
/// dropped on the next broadcast (no heartbeat in M2).
public final class SubscriberHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [IPCConnection] = []

    public init() {}

    public var count: Int { lock.withLock { subscribers.count } }

    /// Whether encoding an event is worth doing at all.
    public var hasSubscribers: Bool { lock.withLock { !subscribers.isEmpty } }

    public func add(_ conn: IPCConnection) {
        lock.withLock { subscribers.append(conn) }
    }

    public func broadcast(_ line: String) {
        let conns = lock.withLock { subscribers }
        var live: [IPCConnection] = []
        live.reserveCapacity(conns.count)
        for conn in conns {
            if conn.send(line) {
                live.append(conn)
            } else {
                conn.close()
            }
        }
        lock.withLock { subscribers = live }
    }
}

/// Blocking listener. `handler` runs per connection on a background queue.
public final class IPCServer: Sendable {
    private let path: String
    private let handler: @Sendable (String, IPCConnection) -> Void

    public init(path: String, handler: @escaping @Sendable (String, IPCConnection) -> Void) {
        self.path = path
        self.handler = handler
    }

    public func run() {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var (addr, len) = makeUnixAddress(path: path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len)
            }
        }
        guard bound == 0, listen(fd, 32) == 0 else { return }
        while true {
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { continue }
            let handler = self.handler
            DispatchQueue.global(qos: .userInitiated).async {
                let ipcConn = IPCConnection(fd: conn)
                guard let line = readLine(fd: conn) else {
                    ipcConn.close()
                    return
                }
                handler(line, ipcConn)
                // Handlers that want streaming call conn.detach().
                if !ipcConn.isDetached {
                    ipcConn.close()
                }
            }
        }
    }
}

public enum IPCClient {
    /// Send one request line, return the response line. Nil = no daemon.
    public static func roundTrip(path: String, line: String, timeoutSeconds: Int = 5) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var (addr, len) = makeUnixAddress(path: path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, len)
            }
        }
        guard rc == 0 else { return nil }
        // Bound the whole exchange so a dead daemon can't hang weftctl.
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard writeAll(fd: fd, line) else { return nil }
        shutdown(fd, SHUT_WR)
        return readLine(fd: fd)
    }

    public static func sendCommand(path: String, command: String) -> IPCResponse? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(IPCRequest(command: command)),
              let line = String(data: data, encoding: .utf8),
              let reply = roundTrip(path: path, line: line),
              let replyData = reply.data(using: .utf8),
              let response = try? JSONDecoder().decode(IPCResponse.self, from: replyData)
        else { return nil }
        return response
    }

    /// Open a subscription stream. Sends the request, then calls `onLine`
    /// for every pushed line until EOF. Blocking — Ctrl-C to exit.
    public static func subscribe(path: String, command: String, onLine: (String) -> Void) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var (addr, len) = makeUnixAddress(path: path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, len)
            }
        }
        guard rc == 0 else { return false }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(IPCRequest(command: command)),
              let line = String(data: data, encoding: .utf8),
              writeAll(fd: fd, line)
        else { return false }
        // No half-close: the stream stays open in both directions. One reader
        // for the whole stream — a fresh one per line would drop whatever it
        // had already buffered past the newline.
        let reader = LineReader(fd: fd)
        while let event = reader.next() {
            onLine(event)
        }
        return true
    }
}
