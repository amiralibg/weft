import Darwin
import Foundation
import WeftCore

/// Client for the Scripting Addition daemon running inside Dock.app.
/// Supports both `weft-sa` and `yabai-sa` sockets seamlessly.
public enum ScriptingAddition {
    // Known SA opcodes (matching Dock payload)
    private static let opcodeHandshake: UInt8 = 1
    private static let opcodeSpaceFocus: UInt8 = 2
    private static let opcodeSpaceCreate: UInt8 = 3
    private static let opcodeSpaceDestroy: UInt8 = 4
    private static let opcodeSpaceMove: UInt8 = 5
    private static let opcodeWindowMove: UInt8 = 6
    private static let opcodeWindowOpacity: UInt8 = 7
    private static let opcodeWindowLayer: UInt8 = 9
    private static let opcodeWindowSticky: UInt8 = 10
    private static let opcodeWindowShadow: UInt8 = 11
    private static let opcodeWindowFocus: UInt8 = 12
    private static let opcodeWindowOrder: UInt8 = 16
    private static let opcodeWindowListToSpace: UInt8 = 18
    private static let opcodeWindowToSpace: UInt8 = 19

    /// Path to active SA socket, if any exists.
    ///
    /// `yabai-sa` is accepted deliberately: it is the same Dock payload with
    /// the same opcode table, so weft can drive it when the user already has
    /// `yabai --load-sa` in place. It is checked second so weft's own socket
    /// always wins when both exist.
    public static func socketPath() -> String? {
        let user = NSUserName()
        guard !user.isEmpty else { return nil }
        let candidates = [
            "/tmp/weft-sa_\(user).socket",
            "/tmp/yabai-sa_\(user).socket",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// The Dock-spaces pointer is what opcode 2 uses. A scripting-addition
    /// socket can be alive with this bit clear when its byte patterns do not
    /// match a new macOS release; in that state the opcode acknowledges the
    /// request but does nothing.
    private static let attributeDockSpaces: UInt32 = 0x01

    /// Cached handshake. It is a connect + round trip, and capability checks
    /// run on the command path; the addition is loaded into Dock and does not
    /// come and go within a few seconds.
    private static let availabilityLock = NSLock()
    nonisolated(unsafe) private static var cachedHandshake: (
        version: String?, attrib: UInt32?, at: Date
    )?
    private static let availabilityTTL: TimeInterval = 5

    /// Check if the scripting addition socket is active and responsive.
    public static func isAvailable() -> Bool {
        handshake() != nil
    }

    /// Whether instant desktop switching is actually initialized, not merely
    /// whether the socket answers. This distinction is observable on a new
    /// macOS release: yabai-sa still starts its socket but reports attrib 0
    /// when none of its Dock patterns matched.
    public static func supportsSpaceFocus() -> Bool {
        guard let status = handshake() else { return false }
        return status.attrib & attributeDockSpaces != 0
    }

    /// Forget the cached handshake — call after a Dock restart reloads the SA.
    public static func invalidateAvailability() {
        availabilityLock.withLock { cachedHandshake = nil }
    }

    /// Query the scripting addition handshake: version and capabilities attribute mask.
    public static func handshake() -> (version: String, attrib: UInt32)? {
        let now = Date()
        if let cached = availabilityLock.withLock({ cachedHandshake }),
           now.timeIntervalSince(cached.at) < availabilityTTL
        {
            guard let version = cached.version, let attrib = cached.attrib else { return nil }
            return (version, attrib)
        }
        let status = requestHandshake()
        availabilityLock.withLock {
            cachedHandshake = (status?.version, status?.attrib, now)
        }
        return status
    }

    private static func requestHandshake() -> (version: String, attrib: UInt32)? {
        guard let response = send(opcode: opcodeHandshake) else { return nil }
        guard response.count >= 1 else { return nil }
        // Format: version string null-terminated, followed by uint32 attrib
        var nullIndex: Int?
        for (i, b) in response.enumerated() {
            if b == 0 {
                nullIndex = i
                break
            }
        }
        guard let idx = nullIndex else { return nil }
        let verData = response.prefix(idx)
        let ver = String(data: verData, encoding: .utf8) ?? "unknown"
        var attrib: UInt32 = 0
        if response.count >= idx + 1 + 4 {
            let attribData = response.subdata(in: (idx + 1)..<(idx + 5))
            attrib = attribData.withUnsafeBytes { $0.load(as: UInt32.self) }
        }
        return (ver, attrib)
    }

    /// Instantly switch focus to space `sid` without Mission Control animations.
    public static func focusSpace(_ sid: SpaceID) -> Bool {
        guard supportsSpaceFocus() else { return false }
        var payload = Data()
        var sidLE = UInt64(sid).littleEndian
        withUnsafeBytes(of: &sidLE) { payload.append(contentsOf: $0) }
        return send(opcode: opcodeSpaceFocus, payload: payload) != nil
    }

    /// Move window `wid` to space `sid` without switching active space.
    public static func moveWindowToSpace(_ wid: WindowID, _ sid: SpaceID) -> Bool {
        var payload = Data()
        var sidLE = UInt64(sid).littleEndian
        var widLE = UInt32(wid).littleEndian
        withUnsafeBytes(of: &sidLE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &widLE) { payload.append(contentsOf: $0) }
        return send(opcode: opcodeWindowToSpace, payload: payload) != nil
    }

    /// Toggle sticky tag for window `wid`.
    public static func setSticky(_ wid: WindowID, _ on: Bool) -> Bool {
        var payload = Data()
        var widLE = UInt32(wid).littleEndian
        let val: UInt8 = on ? 1 : 0
        withUnsafeBytes(of: &widLE) { payload.append(contentsOf: $0) }
        payload.append(val)
        return send(opcode: opcodeWindowSticky, payload: payload) != nil
    }

    /// Order window `aWid` relative to `bWid`.
    public static func orderWindow(_ aWid: WindowID, _ order: Int32, _ bWid: WindowID) -> Bool {
        var payload = Data()
        var aLE = UInt32(aWid).littleEndian
        var ordLE = Int32(order).littleEndian
        var bLE = UInt32(bWid).littleEndian
        withUnsafeBytes(of: &aLE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &ordLE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &bLE) { payload.append(contentsOf: $0) }
        return send(opcode: opcodeWindowOrder, payload: payload) != nil
    }

    // MARK: - Socket transport

    @discardableResult
    private static func send(opcode: UInt8, payload: Data = Data()) -> Data? {
        guard let sockPath = socketPath() else { return nil }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        // Bounded both ways. Every caller is on the command path, and keybinds
        // run one at a time: a Dock that accepts the connection and never
        // answers would otherwise park `recv` forever, and every keybind after
        // it would queue behind that one without a word in the log.
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        let tvSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, tvSize)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, tvSize)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = sockPath.utf8CString
        guard utf8.count <= maxPath else { return nil }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxPath) { dest in
                for i in 0..<utf8.count {
                    dest[i] = utf8[i]
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, addrLen)
            }
        }
        guard connectRes == 0 else { return nil }

        // Packet structure:
        // 2 bytes: Int16 payload length (little endian)
        // Body: 1 byte opcode + payload
        var packet = Data()
        var lengthLE = Int16(1 + payload.count).littleEndian
        withUnsafeBytes(of: &lengthLE) { packet.append(contentsOf: $0) }
        packet.append(opcode)
        packet.append(payload)

        let sent = packet.withUnsafeBytes { ptr in
            Darwin.send(fd, ptr.baseAddress, packet.count, 0)
        }
        guard sent == packet.count else { return nil }

        // Await response or confirmation byte
        var buffer = [UInt8](repeating: 0, count: 256)
        let bytesRead = Darwin.recv(fd, &buffer, buffer.count, 0)
        if bytesRead > 0 {
            return Data(buffer.prefix(bytesRead))
        }
        // A timeout is no answer at all, not an empty acknowledgement.
        if bytesRead < 0 { return nil }
        return Data()
    }
}
