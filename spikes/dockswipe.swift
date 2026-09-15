// spikes/dockswipe.swift — can weft switch desktops with no scripting addition?
//
// Posts a synthetic Dock swipe with near-zero progress and a large velocity.
// Dock commits the switch through its own pipeline, so its Spaces model stays
// authoritative, and there is no distance left to animate. SIP stays on; the
// only requirement is Accessibility, which posting events needs anyway.
//
// Field numbers and the macOS 27 IOHID payload layout follow joshuarli/iss
// (0BSD) and mmathys/noswoosh (MIT), which established the technique.
//
//   ./build.sh dockswipe
//   ./dockswipe list          displays, every space (fullscreen too), trust
//   ./dockswipe right|left    one step; report whether and when it landed
//   ./dockswipe to <n>        1-based index in the pointer display's list
//
// WEFT_SWIPE_PACE_MS sets the gap between phases on the macOS 27 path
// (default 10; 0 posts them back to back).

import AppKit
import ApplicationServices
import Foundation

@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSCopyManagedDisplaySpaces") func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>

let cid = SLSMainConnectionID()

// MARK: - Spaces

struct DisplaySpaces {
    let uuid: String
    let ids: [UInt64]
    let types: [Int]
    let current: UInt64
    var currentIndex: Int? { ids.firstIndex(of: current) }
}

func readDisplays() -> [DisplaySpaces] {
    guard let raw = SLSCopyManagedDisplaySpaces(cid).takeRetainedValue() as? [[String: Any]] else {
        return []
    }
    return raw.compactMap { d in
        guard let uuid = d["Display Identifier"] as? String,
              let spaces = d["Spaces"] as? [[String: Any]]
        else { return nil }
        let current = ((d["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value ?? 0
        return DisplaySpaces(
            uuid: uuid,
            ids: spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value },
            types: spaces.map { ($0["type"] as? NSNumber)?.intValue ?? -1 },
            current: current
        )
    }
}

func pointerDisplayUUID() -> String? {
    guard let location = CGEvent(source: nil)?.location else { return nil }
    var id = CGDirectDisplayID()
    var matched: UInt32 = 0
    guard CGGetDisplaysWithPoint(location, 1, &id, &matched) == .success, matched > 0,
          let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, uuid) as String
}

/// The list a swipe will move through: Dock routes it to the display under
/// the pointer. One managed display ("Displays have separate Spaces" off, or a
/// single screen) reports "Main" rather than a UUID, so it is just the one.
func targetDisplay() -> DisplaySpaces? {
    let all = readDisplays()
    if all.count == 1 { return all[0] }
    let uuid = pointerDisplayUUID()
    return all.first { $0.uuid == uuid } ?? all.first
}

func macOSMajor() -> Int {
    var buf = [CChar](repeating: 0, count: 32)
    var size = buf.count
    guard sysctlbyname("kern.osproductversion", &buf, &size, nil, 0) == 0 else { return 0 }
    return Int(String(cString: buf).split(separator: ".").first ?? "") ?? 0
}

// MARK: - Synthetic swipe

func field(_ n: UInt32) -> CGEventField { unsafeBitCast(n, to: CGEventField.self) }
let fEventType = field(55)
let fHIDType = field(110)
let fSwipeMask = field(115)
let fMotion = field(123)
let fProgress = field(124)
let fPositionX = field(125)
let fPositionY = field(126)
let fVelocityX = field(129)
let fVelocityY = field(130)
let fPhase = field(132)

let kGesture: Int64 = 29
let kDockControl: Int64 = 30
let kHIDDockSwipe: Int64 = 23
let kMotionHorizontal: Int64 = 1
let kPayloadTag = 4205
let weftMarker: Int64 = 0x5745_4654  // "WEFT", what weft's input tap lets through

enum Phase: Int64 { case began = 1, changed = 2, ended = 4 }

let needsPayload = macOSMajor() >= 27
let paceMs = Int(ProcessInfo.processInfo.environment["WEFT_SWIPE_PACE_MS"] ?? "") ?? 10

func fixed1616(_ v: Double) -> Int32 {
    let f = Int32(truncatingIfNeeded: Int64(v * 65536.0))
    return f == 0 && v != 0 ? (v > 0 ? 1 : -1) : f
}

extension Array where Element == UInt8 {
    mutating func le<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}

/// The serialized IOHID queue element macOS 27 checks a synthetic swipe
/// against: a header, a fluid-touch gesture record and a velocity record.
func iohidPayload(_ ev: CGEvent) -> [UInt8] {
    let phase = ev.getIntegerValueField(fPhase)
    let velX = ev.getDoubleValueField(fVelocityX)
    let velY = ev.getDoubleValueField(fVelocityY)
    let withVelocity = velX != 0 || velY != 0 || phase == Phase.ended.rawValue
    var p: [UInt8] = []
    p.le(ev.timestamp != 0 ? ev.timestamp : mach_absolute_time())
    p.le(UInt64(0))  // sender id
    p.le(UInt32(0))  // options
    p.le(UInt32(0))  // attribute length
    p.le(UInt32(withVelocity ? 2 : 1))
    // Fluid-touch gesture, 40 bytes.
    p.le(UInt32(40))
    p.le(UInt32(23))
    p.le((UInt32(truncatingIfNeeded: phase) & 0xFF) << 24)
    p += [0, 0, 0, 0]
    p.le(fixed1616(ev.getDoubleValueField(fPositionX)))
    p.le(fixed1616(ev.getDoubleValueField(fPositionY)))
    p.le(Int32(0))
    p.le(UInt32(truncatingIfNeeded: ev.getIntegerValueField(fSwipeMask)))
    p.le(UInt16(truncatingIfNeeded: ev.getIntegerValueField(fMotion)))
    p.le(UInt16(3))  // Dock primary
    p.le(fixed1616(ev.getDoubleValueField(fProgress)))
    if withVelocity {
        // Velocity, 28 bytes.
        p.le(UInt32(28))
        p.le(UInt32(9))
        p.le(UInt32(0))
        p += [1, 0, 0, 0]
        p.le(fixed1616(velX))
        p.le(fixed1616(velY))
        p.le(Int32(0))
    }
    return p
}

/// Field 4205 has no setter; append it to the serialized event and rebuild.
func withPayload(_ ev: CGEvent) -> CGEvent? {
    guard let data = ev.data else { return nil }
    var bytes = [UInt8](data as Data)
    guard bytes.count >= 4, bytes[0...3] == [0, 0, 0, 2] else { return nil }
    let payload = iohidPayload(ev)
    bytes += [UInt8((payload.count >> 8) & 0xFF), UInt8(payload.count & 0xFF)]
    bytes += [UInt8((kPayloadTag >> 8) & 0xFF), UInt8(kPayloadTag & 0xFF)]
    bytes += payload
    return CGEvent(withDataAllocator: nil, data: Data(bytes) as CFData)
}

func dockEvent(_ phase: Phase, right: Bool) -> CGEvent? {
    guard let ev = CGEvent(source: nil) else { return nil }
    ev.setIntegerValueField(fEventType, value: kDockControl)
    ev.setIntegerValueField(fHIDType, value: kHIDDockSwipe)
    ev.setIntegerValueField(fPhase, value: phase.rawValue)
    ev.setIntegerValueField(fMotion, value: kMotionHorizontal)
    if needsPayload {
        // 27 reads direction the other way round: rightward is negative.
        ev.setDoubleValueField(fProgress, value: right ? -1e-4 : 1e-4)
        ev.setDoubleValueField(fPositionX, value: 0.1)
        if phase == .ended {
            ev.setDoubleValueField(fVelocityX, value: right ? -9999 : 9999)
        }
    } else {
        // Not FLT_TRUE_MIN: a subnormal flushes to zero on Apple Silicon and
        // the sign, which is the direction, goes with it.
        ev.setDoubleValueField(fProgress, value: right ? 1e-4 : -1e-4)
        ev.setDoubleValueField(fVelocityX, value: right ? 2000 : -2000)
        ev.setDoubleValueField(fVelocityY, value: right ? 2000 : -2000)
    }
    return ev
}

/// Build all three phases first: a sequence cut short leaves Dock mid-gesture.
func postSwipe(right: Bool) -> Bool {
    var events: [CGEvent] = []
    for phase in [Phase.began, .changed, .ended] {
        guard var ev = dockEvent(phase, right: right) else { return false }
        if needsPayload {
            guard let augmented = withPayload(ev) else { return false }
            ev = augmented
        }
        // After the round trip, which drops user data.
        ev.setIntegerValueField(.eventSourceUserData, value: weftMarker)
        events.append(ev)
    }
    for (i, ev) in events.enumerated() {
        ev.post(tap: .cgSessionEventTap)
        if needsPayload {
            // 27 wants each DockControl paired with a gesture event.
            guard let companion = CGEvent(source: nil) else { return false }
            companion.setIntegerValueField(fEventType, value: kGesture)
            companion.setIntegerValueField(.eventSourceUserData, value: weftMarker)
            companion.post(tap: .cgSessionEventTap)
            if paceMs > 0, i < events.count - 1 { usleep(useconds_t(paceMs * 1000)) }
        }
    }
    return true
}

/// Wait for the display's current space to become `target`. Nil on timeout.
func waitForSpace(_ uuid: String, _ target: UInt64, timeout: TimeInterval) -> Double? {
    let t0 = Date()
    while Date().timeIntervalSince(t0) < timeout {
        if readDisplays().first(where: { $0.uuid == uuid })?.current == target {
            return Date().timeIntervalSince(t0) * 1000
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
    }
    return nil
}

/// One step. True when the WindowServer reports the neighbour as current.
func step(right: Bool) -> Bool {
    guard let d = targetDisplay(), let i = d.currentIndex else {
        print("no current space for the target display")
        return false
    }
    let j = i + (right ? 1 : -1)
    guard d.ids.indices.contains(j) else {
        print("already at the \(right ? "last" : "first") space")
        return false
    }
    guard postSwipe(right: right) else {
        print("could not build the swipe events")
        return false
    }
    if let ms = waitForSpace(d.uuid, d.ids[j], timeout: 1.0) {
        print(String(format: "space %d -> %d landed after %.1f ms", i + 1, j + 1, ms))
        return true
    }
    print("space \(i + 1) -> \(j + 1): nothing changed within 1 s")
    return false
}

// MARK: - CLI

let args = Array(CommandLine.arguments.dropFirst())
print("macOS \(macOSMajor()), payload path \(needsPayload), pace \(paceMs) ms, "
    + "Accessibility \(AXIsProcessTrusted() ? "granted" : "NOT granted")")

switch args.first {
case "list", nil:
    let pointer = pointerDisplayUUID()
    for d in readDisplays() {
        print("display \(d.uuid)\(d.uuid == pointer ? "  (pointer)" : "")")
        for (i, sid) in d.ids.enumerated() {
            print("  \(i + 1). sid \(sid) type \(d.types[i])\(sid == d.current ? "  <- current" : "")")
        }
    }
case "right", "left":
    guard AXIsProcessTrusted() else { print("posting needs Accessibility"); exit(1) }
    exit(step(right: args[0] == "right") ? 0 : 1)
case "to":
    guard AXIsProcessTrusted() else { print("posting needs Accessibility"); exit(1) }
    guard args.count == 2, let n = Int(args[1]), let d = targetDisplay(),
          let i = d.currentIndex, d.ids.indices.contains(n - 1)
    else { print("usage: dockswipe to <1-based index on the pointer's display>"); exit(2) }
    let t0 = Date()
    for _ in 0..<abs(n - 1 - i) {
        guard step(right: n - 1 > i) else { exit(1) }
    }
    print(String(format: "total %.1f ms", Date().timeIntervalSince(t0) * 1000))
default:
    print("usage: dockswipe [list | right | left | to <n>]")
    exit(2)
}
