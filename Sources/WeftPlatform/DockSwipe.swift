import ApplicationServices
import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

/// Weft's own desktop switcher: a synthetic Dock swipe.
///
/// No scripting addition, SIP left on — Accessibility, which weft already
/// needs, is the only requirement. Dock commits the switch through its own
/// gesture pipeline, so its Spaces model stays the authority, and a swipe with
/// near-zero progress and a large velocity has no distance left to animate.
/// Measured on macOS 27.0 (26A428) across two displays: every step landed
/// 15–43 ms after posting (spikes/dockswipe.swift).
///
/// The event fields are private and have changed once already — macOS 27
/// added the IOHID payload check — so every switch is verified against the
/// WindowServer, and a release that stops taking the swipe fails loudly.
///
/// Technique from jurplel/InstantSpaceSwitcher (MIT); field numbers and the
/// macOS 27 layout from joshuarli/iss (0BSD) and mmathys/noswoosh (MIT).
public enum DockSwipe {
    // MARK: - Release gate

    private static let osVersion: (major: Int, minor: Int) = {
        var buf = [CChar](repeating: 0, count: 32)
        var size = buf.count
        guard sysctlbyname("kern.osproductversion", &buf, &size, nil, 0) == 0 else { return (0, 0) }
        let text = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let parts = text.split(separator: ".").map { Int($0) ?? 0 }
        return (parts.first ?? 0, parts.count > 1 ? parts[1] : 0)
    }()

    /// Whether a synthetic swipe switches cleanly on this release.
    ///
    /// 26.0–26.5 do switch, but the WindowServer drops the destination's
    /// surfaces on a switch with no travel and the user lands on a blank
    /// desktop (noswoosh issue #1); the ⌃N keystroke is the better answer
    /// there. Earlier releases are unverified, so they are not claimed.
    public static var isSupported: Bool {
        osVersion.major >= 27 || (osVersion.major == 26 && osVersion.minor >= 6)
    }

    private static var needsPayload: Bool { osVersion.major >= 27 }

    // MARK: - Switching

    /// Switch the display that owns `sid` to it, one swipe per desktop.
    ///
    /// A swipe moves one desktop, through fullscreen spaces too, so the step
    /// count comes from that display's full list rather than weft's ordinals.
    /// Each step waits for its landing before the next is posted: Dock drops
    /// a gesture that arrives while the previous one is still committing.
    /// True only once the WindowServer reports `sid` as current.
    public static func focusSpace(_ sid: SpaceID) -> Bool {
        guard isSupported, AXIsProcessTrusted() else { return false }
        guard var display = managedDisplays().first(where: { $0.ids.contains(sid) }),
              let target = display.ids.firstIndex(of: sid)
        else { return false }
        if display.current == sid { return true }
        routePointer(to: display.uuid)
        while display.current != sid {
            guard let here = display.ids.firstIndex(of: display.current) else { return false }
            let right = target > here
            let next = display.ids[here + (right ? 1 : -1)]
            guard post(right: right), let landed = wait(for: next, on: display.uuid) else {
                return false
            }
            display = landed
        }
        return true
    }

    struct ManagedDisplay {
        let uuid: String
        let ids: [SpaceID]
        let current: SpaceID
    }

    static func managedDisplays() -> [ManagedDisplay] {
        guard let raw = SLSCopyManagedDisplaySpaces(WorldReader.cid) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { d in
            guard let uuid = d["Display Identifier"] as? String,
                  let spaces = d["Spaces"] as? [[String: Any]]
            else { return nil }
            let current = ((d["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
                ?? SLSManagedDisplayGetCurrentSpace(WorldReader.cid, uuid as CFString)
            return ManagedDisplay(
                uuid: uuid,
                ids: spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value },
                current: current
            )
        }
    }

    private static func wait(
        for sid: SpaceID, on uuid: String, timeout: TimeInterval = 0.5
    ) -> ManagedDisplay? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let d = managedDisplays().first(where: { $0.uuid == uuid }), d.current == sid {
                return d
            }
            usleep(2_000)
        } while Date() < deadline
        return nil
    }

    /// Dock sends a swipe to the display under the pointer, not the one with
    /// keyboard focus. Put the pointer on the target display first, or a
    /// switch meant for one monitor moves the other.
    ///
    /// With "Displays have separate Spaces" off there is one managed display,
    /// identified as "Main"; it matches no UUID and nothing moves.
    private static func routePointer(to uuid: String) {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success, count > 1 else { return }
        for id in ids.prefix(Int(count)) {
            guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  (CFUUIDCreateString(nil, cf) as String?) == uuid
            else { continue }
            let bounds = CGDisplayBounds(id)
            if let at = CGEvent(source: nil)?.location, bounds.contains(at) { return }
            CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
            return
        }
    }

    // MARK: - Events

    private static func field(_ n: UInt32) -> CGEventField { unsafeBitCast(n, to: CGEventField.self) }
    private static let fEventType = field(55)
    private static let fHIDType = field(110)
    private static let fSwipeMask = field(115)
    private static let fMotion = field(123)
    private static let fProgress = field(124)
    private static let fPositionX = field(125)
    private static let fPositionY = field(126)
    private static let fVelocityX = field(129)
    private static let fVelocityY = field(130)
    private static let fPhase = field(132)

    private static let typeGesture: Int64 = 29
    private static let typeDockControl: Int64 = 30
    private static let hidDockSwipe: Int64 = 23
    private static let motionHorizontal: Int64 = 1
    /// The "WEFT" user-data marker weft's own input tap lets through.
    private static let marker: Int64 = 0x5745_4654
    /// Between phases on the macOS 27 path. 27.0 took them back to back in
    /// the spike, but a 27 beta dropped them (InstantSpaceSwitcher #88), and
    /// 20 ms per step is nothing next to the animation this replaces.
    private static let phaseGapMicroseconds: useconds_t = 10_000

    /// Build all three phases before posting any: a sequence cut short leaves
    /// Dock mid-gesture on a half-drawn desktop.
    private static func post(right: Bool) -> Bool {
        var events: [CGEvent] = []
        for phase: Int64 in [1, 2, DockSwipePayload.phaseEnded] {
            guard var event = dockEvent(phase: phase, right: right) else { return false }
            if needsPayload {
                guard let augmented = withPayload(event) else { return false }
                event = augmented
            }
            // After the serialization round trip, which drops user data.
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            events.append(event)
        }
        for (i, event) in events.enumerated() {
            event.post(tap: .cgSessionEventTap)
            guard needsPayload else { continue }
            // macOS 27 wants each DockControl event paired with a gesture event.
            guard let companion = CGEvent(source: nil) else { return false }
            companion.setIntegerValueField(fEventType, value: typeGesture)
            companion.setIntegerValueField(.eventSourceUserData, value: marker)
            companion.post(tap: .cgSessionEventTap)
            if i < events.count - 1 { usleep(phaseGapMicroseconds) }
        }
        return true
    }

    private static func dockEvent(phase: Int64, right: Bool) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        event.setIntegerValueField(fEventType, value: typeDockControl)
        event.setIntegerValueField(fHIDType, value: hidDockSwipe)
        event.setIntegerValueField(fPhase, value: phase)
        event.setIntegerValueField(fMotion, value: motionHorizontal)
        if needsPayload {
            // 27 reads a posted swipe's direction the other way round.
            event.setDoubleValueField(fProgress, value: right ? -1e-4 : 1e-4)
            event.setDoubleValueField(fPositionX, value: 0.1)
            if phase == DockSwipePayload.phaseEnded {
                // The fling on the last phase is what commits the switch.
                event.setDoubleValueField(fVelocityX, value: right ? -9999 : 9999)
            }
        } else {
            // Near zero, not FLT_TRUE_MIN: a subnormal flushes to zero on Apple
            // Silicon and takes the sign — the direction — with it.
            event.setDoubleValueField(fProgress, value: right ? 1e-4 : -1e-4)
            event.setDoubleValueField(fVelocityX, value: right ? 2000 : -2000)
            event.setDoubleValueField(fVelocityY, value: right ? 2000 : -2000)
        }
        return event
    }

    private static func withPayload(_ event: CGEvent) -> CGEvent? {
        guard let data = event.data else { return nil }
        let gesture = DockSwipePayload.Gesture(
            phase: event.getIntegerValueField(fPhase),
            motion: event.getIntegerValueField(fMotion),
            progress: event.getDoubleValueField(fProgress),
            positionX: event.getDoubleValueField(fPositionX),
            positionY: event.getDoubleValueField(fPositionY),
            velocityX: event.getDoubleValueField(fVelocityX),
            velocityY: event.getDoubleValueField(fVelocityY),
            swipeMask: event.getIntegerValueField(fSwipeMask),
            timestamp: event.timestamp != 0 ? event.timestamp : mach_absolute_time()
        )
        guard let bytes = DockSwipePayload.appending(
            DockSwipePayload.bytes(for: gesture), to: [UInt8](data as Data)
        ) else { return nil }
        return CGEvent(withDataAllocator: nil, data: Data(bytes) as CFData)
    }
}
