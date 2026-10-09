import Testing
@testable import WeftCore

private func gesture(
    phase: Int64, progress: Double = -1e-4, velocityX: Double = 0
) -> DockSwipePayload.Gesture {
    DockSwipePayload.Gesture(
        phase: phase, motion: 1, progress: progress,
        positionX: 0.1, positionY: 0,
        velocityX: velocityX, velocityY: 0,
        swipeMask: 0, timestamp: 0x0102_0304_0506_0708
    )
}

private func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
    UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
}

@Test func beganPhaseIsHeaderAndGestureOnly() {
    let b = DockSwipePayload.bytes(for: gesture(phase: 1))
    #expect(b.count == 28 + 40)
    #expect(u32(b, 24) == 1)  // event count
}

@Test func endedPhaseCarriesAVelocityRecordEvenAtZero() {
    let b = DockSwipePayload.bytes(for: gesture(phase: 4))
    #expect(b.count == 28 + 40 + 28)
    #expect(u32(b, 24) == 2)
    #expect(u32(b, 68) == 28)  // velocity record size
    #expect(u32(b, 72) == 9)  // velocity record type
    #expect(b[80] == 1)  // depth
}

@Test func gestureRecordLayout() {
    let b = DockSwipePayload.bytes(for: gesture(phase: 2, progress: -1e-4))
    #expect(b[0] == 0x08 && b[7] == 0x01)  // timestamp, little-endian
    #expect(u32(b, 28) == 40)  // gesture record size
    #expect(u32(b, 32) == 23)  // fluid-touch gesture
    #expect(u32(b, 36) == 2 << 24)  // phase in the options' top byte
    #expect(Int32(bitPattern: u32(b, 44)) == DockSwipePayload.fixed1616(0.1))
    #expect(b[60] == 1 && b[61] == 0)  // horizontal motion
    #expect(b[62] == 3 && b[63] == 0)  // Dock primary flavor
    #expect(Int32(bitPattern: u32(b, 64)) < 0)  // rightward on 27 is negative
}

@Test func fixedPointNeverLosesTheSign() {
    #expect(DockSwipePayload.fixed1616(1e-9) == 1)
    #expect(DockSwipePayload.fixed1616(-1e-9) == -1)
    #expect(DockSwipePayload.fixed1616(0) == 0)
    #expect(DockSwipePayload.fixed1616(1) == 65536)
    #expect(DockSwipePayload.fixed1616(-9999) == -9999 * 65536)
}

@Test func appendingWritesLengthThenTagBigEndian() throws {
    let payload = [UInt8](repeating: 0xAB, count: 96)
    let out = try #require(DockSwipePayload.appending(payload, to: [0, 0, 0, 2, 9]))
    #expect(Array(out.prefix(5)) == [0, 0, 0, 2, 9])
    #expect(Array(out[5..<9]) == [0, 96, 0x10, 0x6D])
    #expect(Array(out.suffix(96)) == payload)
}

@Test func appendingRefusesAnUnknownSerializationFormat() {
    #expect(DockSwipePayload.appending([1], to: [0, 0, 0, 1]) == nil)
    #expect(DockSwipePayload.appending([1], to: [0, 0]) == nil)
}
