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

// MARK: - MultitouchSupport Bindings

private typealias MTDeviceRef = UnsafeMutableRawPointer

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var foo3: Int32
    var foo4: Int32
    var normalizedVector: MTVector
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var mmVector: MTVector
    var zero2_0: Int32
    var zero2_1: Int32
    var unk2: Float
}

private typealias MTFrameCallbackWithRefcon = @convention(c) (
    MTDeviceRef?,
    UnsafeRawPointer?,
    Int32,
    Double,
    Int32,
    UnsafeMutableRawPointer?
) -> Int32

private struct MultitouchAPI: @unchecked Sendable {
    static let shared = MultitouchAPI()

    let createList: (@convention(c) () -> Unmanaged<CFMutableArray>?)?
    let registerCallback: (@convention(c) (MTDeviceRef, MTFrameCallbackWithRefcon, UnsafeMutableRawPointer?) -> Void)?
    let unregisterCallback: (@convention(c) (MTDeviceRef, MTFrameCallbackWithRefcon) -> Void)?
    let start: (@convention(c) (MTDeviceRef, Int32) -> Void)?
    let stop: (@convention(c) (MTDeviceRef) -> Void)?

    init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
            self.createList = nil
            self.registerCallback = nil
            self.unregisterCallback = nil
            self.start = nil
            self.stop = nil
            return
        }
        if let sym = dlsym(handle, "MTDeviceCreateList") {
            self.createList = unsafeBitCast(sym, to: (@convention(c) () -> Unmanaged<CFMutableArray>?).self)
        } else { self.createList = nil }

        if let sym = dlsym(handle, "MTRegisterContactFrameCallbackWithRefcon") {
            self.registerCallback = unsafeBitCast(sym, to: (@convention(c) (MTDeviceRef, MTFrameCallbackWithRefcon, UnsafeMutableRawPointer?) -> Void).self)
        } else { self.registerCallback = nil }

        if let sym = dlsym(handle, "MTUnregisterContactFrameCallback") {
            self.unregisterCallback = unsafeBitCast(sym, to: (@convention(c) (MTDeviceRef, MTFrameCallbackWithRefcon) -> Void).self)
        } else { self.unregisterCallback = nil }

        if let sym = dlsym(handle, "MTDeviceStart") {
            self.start = unsafeBitCast(sym, to: (@convention(c) (MTDeviceRef, Int32) -> Void).self)
        } else { self.start = nil }

        if let sym = dlsym(handle, "MTDeviceStop") {
            self.stop = unsafeBitCast(sym, to: (@convention(c) (MTDeviceRef) -> Void).self)
        } else { self.stop = nil }
    }
}

private let multitouchCallback: MTFrameCallbackWithRefcon = { device, rawTouches, count, timestamp, frame, refcon in
    guard let refcon else { return 0 }
    let tap = Unmanaged<GestureTap>.fromOpaque(refcon).takeUnretainedValue()
    tap.handle(rawTouches: rawTouches, count: Int(count))
    return 0
}

/// The multitouch listener behind the workspace swipe.
///
/// Uses macOS's private MultitouchSupport framework to receive raw trackpad touch frames.
/// A CGEventTap cannot be used because Quartz Event Taps do not carry touch contact arrays
/// (NSEvent.allTouches is always empty on synthesized CGEvents).
final class GestureTap: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker: SwipeTracker
    private let onSwipe: (SwipeTracker.Swipe) -> Void
    private var devices: [MTDeviceRef] = []
    private var installed = false
    private var selfBox: Unmanaged<GestureTap>?

    init(fingers: Int, onSwipe: @escaping (SwipeTracker.Swipe) -> Void) {
        self.tracker = SwipeTracker(fingers: fingers)
        self.onSwipe = onSwipe
    }

    /// Start listening to connected trackpads. Returns false if MultitouchSupport cannot be loaded
    /// or no multitouch devices are found.
    func install() -> Bool {
        guard let createList = MultitouchAPI.shared.createList,
              let registerCallback = MultitouchAPI.shared.registerCallback,
              let start = MultitouchAPI.shared.start
        else { return false }

        guard let listRef = createList() else { return false }
        let list = listRef.takeRetainedValue() as NSArray
        guard list.count > 0 else { return false }

        let retainedSelf = Unmanaged.passRetained(self)
        let refcon = retainedSelf.toOpaque()

        var startedDevices: [MTDeviceRef] = []
        for devObj in list {
            let dev = unsafeBitCast(devObj as AnyObject, to: MTDeviceRef.self)
            registerCallback(dev, multitouchCallback, refcon)
            start(dev, 0)
            startedDevices.append(dev)
        }

        lock.withLock {
            self.selfBox = retainedSelf
            self.devices = startedDevices
            self.installed = true
        }
        return true
    }

    /// Stop listening to trackpads and unregister callbacks.
    func uninstall() {
        let (devs, box) = lock.withLock { () -> ([MTDeviceRef], Unmanaged<GestureTap>?) in
            guard self.installed else { return ([], nil) }
            self.installed = false
            let devs = self.devices
            let box = self.selfBox
            self.devices = []
            self.selfBox = nil
            return (devs, box)
        }

        guard let box else { return }
        let api = MultitouchAPI.shared
        for dev in devs {
            api.stop?(dev)
            api.unregisterCallback?(dev, multitouchCallback)
        }
        box.release()
    }

    deinit {
        uninstall()
    }

    fileprivate func handle(rawTouches: UnsafeRawPointer?, count: Int) {
        guard let rawTouches, count > 0 else {
            lock.withLock { _ = tracker.update([]) }
            return
        }
        let touches = rawTouches.assumingMemoryBound(to: MTTouch.self)
        var points: [CGPoint] = []
        for i in 0..<count {
            let t = touches[i]
            // state 3 = make touch (finger down), state 4 = touching (moving or resting)
            if t.state == 3 || t.state == 4 {
                points.append(CGPoint(x: Double(t.normalizedVector.position.x), y: Double(t.normalizedVector.position.y)))
            }
        }
        let swipe = lock.withLock { tracker.update(points) }
        if let swipe { onSwipe(swipe) }
    }
}
