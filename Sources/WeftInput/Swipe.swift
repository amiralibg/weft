import AppKit
import CoreGraphics
import Foundation

/// Recognises one horizontal swipe of exactly `fingers` fingers from the
/// touches a trackpad reports, at most once per gesture.
///
/// Pure: fed positions, returns a verdict. The tap that feeds it is below.
public struct SwipeTracker: Sendable, Equatable {
    public enum Swipe: Sendable, Equatable {
        /// The fingers moved left — macOS's gesture for the desktop to the
        /// right, so weft's for the next workspace.
        case left
        case right
    }

    public var fingers: Int
    /// How far the fingers travel before it counts, as a fraction of the
    /// trackpad's width. About as far as macOS wants before it commits to a
    /// desktop switch.
    public var threshold: Double

    private var startX: Double?
    private var startY: Double?
    private var fired = false

    public init(fingers: Int, threshold: Double = 0.12) {
        self.fingers = fingers
        self.threshold = threshold
    }

    /// The touches on the pad now, in normalized trackpad coordinates
    /// (0…1 both ways), resting ones already left out.
    ///
    /// A different number of fingers is no gesture: lifting one ends it and
    /// putting all of them down starts the next. Mostly-vertical travel is
    /// not a swipe either — three-finger drag and Mission Control's swipe up
    /// both move the same fingers.
    public mutating func update(_ touches: [CGPoint]) -> Swipe? {
        guard touches.count == fingers else {
            startX = nil
            startY = nil
            fired = false
            return nil
        }
        let x = touches.reduce(0) { $0 + Double($1.x) } / Double(touches.count)
        let y = touches.reduce(0) { $0 + Double($1.y) } / Double(touches.count)
        guard let sx = startX, let sy = startY else {
            startX = x
            startY = y
            return nil
        }
        guard !fired else { return nil }
        let dx = x - sx, dy = y - sy
        guard abs(dx) >= threshold, abs(dx) > 2 * abs(dy) else { return nil }
        fired = true
        return dx < 0 ? .left : .right
    }
}

/// The listen-only tap behind the workspace swipe.
///
/// Its own tap, separate from the keyboard one, and only while the swipe is
/// on: a trackpad reports a gesture event for every frame of every scroll,
/// and a user who never swipes should not pay for weft reading them. Listen
/// only, so nothing it does can hold up the event it is looking at.
final class GestureTap: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker: SwipeTracker
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let onSwipe: (SwipeTracker.Swipe) -> Void

    init(fingers: Int, onSwipe: @escaping (SwipeTracker.Swipe) -> Void) {
        self.tracker = SwipeTracker(fingers: fingers)
        self.onSwipe = onSwipe
    }

    /// `NSEventTypeGesture`. `CGEventType` has no case for it; the raw value
    /// is what the WindowServer uses for every multitouch sample.
    static let gestureType: UInt32 = 29

    /// Install on the calling thread's run loop. False when macOS refuses
    /// the tap (Input Monitoring off).
    func install() -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << CGEventMask(Self.gestureType),
            callback: gestureCallback,
            userInfo: refcon
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        lock.withLock {
            self.tap = tap
            self.source = source
        }
        return true
    }

    /// Remove from the calling thread's run loop — the one it was installed on.
    func uninstall() {
        let (tap, source) = lock.withLock { () -> (CFMachPort?, CFRunLoopSource?) in
            defer { self.tap = nil; self.source = nil }
            return (self.tap, self.source)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
    }

    fileprivate func reenable() {
        lock.withLock {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
    }

    fileprivate func handle(_ event: CGEvent) {
        guard let ns = NSEvent(cgEvent: event), ns.type == .gesture else { return }
        let touching = ns.allTouches().filter { touch in
            !touch.isResting && (touch.phase == .began || touch.phase == .moved || touch.phase == .stationary)
        }
        let points = touching.map { $0.normalizedPosition }
        let swipe = lock.withLock { tracker.update(points) }
        if let swipe { onSwipe(swipe) }
    }
}

private func gestureCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let box = Unmanaged<GestureTap>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        box.reenable()
    } else if type.rawValue == GestureTap.gestureType {
        box.handle(event)
    }
    return Unmanaged.passUnretained(event)
}
