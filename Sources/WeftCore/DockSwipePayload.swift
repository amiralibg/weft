import Foundation

/// The bytes behind weft's synthetic Dock swipe on macOS 27.
///
/// macOS 27 ignores a synthetic swipe unless the event carries a serialized
/// IOHID queue element under CGEvent field 4205. That field has no setter, so
/// the event is serialized, the field appended, and the event rebuilt from the
/// result. The layout lives here, pure, so a test pins it rather than a user's
/// Mac discovering that it moved.
///
/// Layout from joshuarli/iss (0BSD) and mmathys/noswoosh (MIT).
public enum DockSwipePayload {
    /// The CGEvent field the payload travels in.
    public static let fieldTag = 4205
    /// Gesture phase values, as the event's phase field carries them.
    public static let phaseEnded: Int64 = 4

    public struct Gesture: Equatable, Sendable {
        public var phase: Int64
        public var motion: Int64
        public var progress: Double
        public var positionX: Double
        public var positionY: Double
        public var velocityX: Double
        public var velocityY: Double
        public var swipeMask: Int64
        public var timestamp: UInt64

        public init(
            phase: Int64, motion: Int64, progress: Double,
            positionX: Double, positionY: Double,
            velocityX: Double, velocityY: Double,
            swipeMask: Int64, timestamp: UInt64
        ) {
            self.phase = phase
            self.motion = motion
            self.progress = progress
            self.positionX = positionX
            self.positionY = positionY
            self.velocityX = velocityX
            self.velocityY = velocityY
            self.swipeMask = swipeMask
            self.timestamp = timestamp
        }
    }

    /// A queue header (28 bytes) and a fluid-touch gesture record (40), then a
    /// velocity record (28) on the ending phase or whenever there is velocity.
    /// macOS 27 refuses an ending phase without one, even at zero velocity.
    /// Little-endian throughout.
    public static func bytes(for g: Gesture) -> [UInt8] {
        let withVelocity = g.velocityX != 0 || g.velocityY != 0 || g.phase == phaseEnded
        var out: [UInt8] = []
        out.reserveCapacity(withVelocity ? 96 : 68)
        // Queue element header.
        out.le(g.timestamp)
        out.le(UInt64(0))  // sender id
        out.le(UInt32(0))  // options
        out.le(UInt32(0))  // attribute length
        out.le(UInt32(withVelocity ? 2 : 1))
        // Fluid-touch gesture: a 16-byte event base, then the gesture.
        out.le(UInt32(40))
        out.le(UInt32(23))
        out.le((UInt32(truncatingIfNeeded: g.phase) & 0xFF) << 24)
        out += [0, 0, 0, 0]  // depth, reserved
        out.le(fixed1616(g.positionX))
        out.le(fixed1616(g.positionY))
        out.le(Int32(0))
        out.le(UInt32(truncatingIfNeeded: g.swipeMask))
        out.le(UInt16(truncatingIfNeeded: g.motion))
        out.le(UInt16(3))  // flavor: Dock primary
        out.le(fixed1616(g.progress))
        if withVelocity {
            out.le(UInt32(28))
            out.le(UInt32(9))
            out.le(UInt32(0))
            out += [1, 0, 0, 0]  // depth 1, reserved
            out.le(fixed1616(g.velocityX))
            out.le(fixed1616(g.velocityY))
            out.le(Int32(0))
        }
        return out
    }

    /// `serialized` with `payload` appended as field `fieldTag`: a big-endian
    /// length, the big-endian tag, then the bytes. Nil for any serialization
    /// format but version 2, the only one this layout is known for.
    public static func appending(_ payload: [UInt8], to serialized: [UInt8]) -> [UInt8]? {
        guard serialized.count >= 4, serialized[0..<4].elementsEqual([0, 0, 0, 2]),
              payload.count <= 0xFFFF
        else { return nil }
        var out = serialized
        out += [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        out += [UInt8(fieldTag >> 8), UInt8(fieldTag & 0xFF)]
        out += payload
        return out
    }

    /// 16.16 fixed point that never rounds a non-zero value to zero. The
    /// swipe's progress is deliberately tiny, and its sign is the direction.
    public static func fixed1616(_ value: Double) -> Int32 {
        let fixed = Int32(truncatingIfNeeded: Int64(value * 65536.0))
        if fixed == 0 && value != 0 { return value > 0 ? 1 : -1 }
        return fixed
    }
}

private extension Array where Element == UInt8 {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
