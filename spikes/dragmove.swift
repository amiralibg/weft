// spikes/dragmove.swift — move a window to another desktop with SIP on, by
// doing what a person does: hold it, swipe, let go.
//
// spikes/spacesip.swift established that macOS 27 refuses every SkyLight route
// to this from an ordinary connection — sixteen probes across direct calls,
// the window's owner connection, transactions, space ownership, the drag
// pipeline and per-process assignment. Two of them (SLSSetWindowTags,
// SLSProcessAssignToSpace) return kCGErrorSuccess and do nothing at all, which
// is why weft verifies every mutation by re-reading rather than by return code.
//
// So the remaining SIP-on route is not an API. A user moves a window to
// another desktop by grabbing its title bar and swiping, and weft can already
// swipe (Sources/WeftPlatform/DockSwipe.swift, shipped in 0.8.0). This holds
// the window while that swipe happens, drops it there, and swipes back.
//
//   ./build.sh dragmove
//   ./dragmove list                 displays and desktops
//   ./dragmove test                 own helper window, one desktop right, verified
//   ./dragmove window <wid> <sid>   a real window, named explicitly
//
// It moves your view: two desktop switches per move, both instant. `test` uses
// a window this spike creates, so nothing of yours is dragged.
//
// The mouse button is the hazard. A synthetic left-down that never gets its
// left-up leaves the session in a dragging state that no application can
// clear, so every path out of the drag — success, failure, a swipe that never
// lands — goes through the same `defer` that releases it.
//
// Swipe technique from jurplel/InstantSpaceSwitcher (MIT); macOS 27 field
// layout from joshuarli/iss (0BSD) and mmathys/noswoosh (MIT).

import AppKit
import CoreGraphics
import Foundation

@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?
@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?
@_silgen_name("SLSGetWindowBounds")
func SLSGetWindowBounds(_ cid: Int32, _ wid: UInt32, _ out: UnsafeMutablePointer<CGRect>) -> Int32
/// The instrument the sticky experiment actually needs.
///
/// Dock's per-application "All Desktops" is a policy, not a retag: after
/// setting it the menu shows ✓ while `SLSCopySpacesForWindows` still reports
/// the one desktop the window was created on. Membership is the wrong
/// question; presence on the desktop you are looking at is the right one.
@_silgen_name("SLSWindowIsOnCurrentSpace")
func SLSWindowIsOnCurrentSpace(_ cid: Int32, _ wid: UInt32) -> Bool

let cid = SLSMainConnectionID()

func spaces(of wid: UInt32) -> [UInt64] {
    guard let r = SLSCopySpacesForWindows(cid, 0x7, [NSNumber(value: wid)] as CFArray)?
        .takeRetainedValue() as? [NSNumber]
    else { return [] }
    return r.map { $0.uint64Value }
}

func bounds(of wid: UInt32) -> CGRect? {
    var r = CGRect.zero
    return SLSGetWindowBounds(cid, wid, &r) == 0 ? r : nil
}

struct Display {
    let uuid: String
    let ids: [UInt64]
    let current: UInt64
}

func displays() -> [Display] {
    guard let raw = SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else {
        return []
    }
    return raw.compactMap { d in
        guard let uuid = d["Display Identifier"] as? String,
              let list = d["Spaces"] as? [[String: Any]]
        else { return nil }
        return Display(
            uuid: uuid,
            ids: list.compactMap { ($0["id64"] as? NSNumber)?.uint64Value },
            current: ((d["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value ?? 0
        )
    }
}

// MARK: - The swipe
//
// A condensed copy of Sources/WeftPlatform/DockSwipe.swift. One difference
// that matters: DockSwipe warps the pointer onto the target display before
// swiping, because Dock sends a swipe to the display under the pointer. Here
// the pointer is holding a window, so it must not be moved — which is also why
// this spike only claims the single-display case.

enum Swipe {
    private static func field(_ n: UInt32) -> CGEventField { unsafeBitCast(n, to: CGEventField.self) }
    static let fEventType = field(55)
    static let fHIDType = field(110)
    static let fSwipeMask = field(115)
    static let fMotion = field(123)
    static let fProgress = field(124)
    static let fPositionX = field(125)
    static let fPositionY = field(126)
    static let fVelocityX = field(129)
    static let fVelocityY = field(130)
    static let fPhase = field(132)

    static let marker: Int64 = 0x5745_4654
    static let phaseEnded: Int64 = 4

    static let osMajor: Int = {
        var buf = [CChar](repeating: 0, count: 32)
        var size = buf.count
        guard sysctlbyname("kern.osproductversion", &buf, &size, nil, 0) == 0 else { return 0 }
        let text = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return Int(text.split(separator: ".").first ?? "0") ?? 0
    }()
    static var needsPayload: Bool { osMajor >= 27 }

    static func fixed1616(_ v: Double) -> Int32 {
        let f = Int32(truncatingIfNeeded: Int64(v * 65536.0))
        if f == 0 && v != 0 { return v > 0 ? 1 : -1 }
        return f
    }

    static func payload(phase: Int64, motion: Int64, progress: Double, px: Double, py: Double,
                        vx: Double, vy: Double, mask: Int64, ts: UInt64) -> [UInt8] {
        let withVelocity = vx != 0 || vy != 0 || phase == phaseEnded
        var out: [UInt8] = []
        func le<T: FixedWidthInteger>(_ v: T) {
            withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
        }
        le(ts); le(UInt64(0)); le(UInt32(0)); le(UInt32(0)); le(UInt32(withVelocity ? 2 : 1))
        le(UInt32(40)); le(UInt32(23))
        le((UInt32(truncatingIfNeeded: phase) & 0xFF) << 24)
        out += [0, 0, 0, 0]
        le(fixed1616(px)); le(fixed1616(py)); le(Int32(0))
        le(UInt32(truncatingIfNeeded: mask))
        le(UInt16(truncatingIfNeeded: motion)); le(UInt16(3))
        le(fixed1616(progress))
        if withVelocity {
            le(UInt32(28)); le(UInt32(9)); le(UInt32(0))
            out += [1, 0, 0, 0]
            le(fixed1616(vx)); le(fixed1616(vy)); le(Int32(0))
        }
        return out
    }

    static func appending(_ p: [UInt8], to serialized: [UInt8]) -> [UInt8]? {
        guard serialized.count >= 4, serialized[0..<4].elementsEqual([0, 0, 0, 2]),
              p.count <= 0xFFFF
        else { return nil }
        var out = serialized
        out += [UInt8(p.count >> 8), UInt8(p.count & 0xFF), UInt8(4205 >> 8), UInt8(4205 & 0xFF)]
        return out + p
    }

    static func post(right: Bool) -> Bool {
        var events: [CGEvent] = []
        for phase: Int64 in [1, 2, phaseEnded] {
            guard let e = CGEvent(source: nil) else { return false }
            e.setIntegerValueField(fEventType, value: 30)  // DockControl
            e.setIntegerValueField(fHIDType, value: 23)  // dock swipe
            e.setIntegerValueField(fPhase, value: phase)
            e.setIntegerValueField(fMotion, value: 1)  // horizontal
            if needsPayload {
                // 27 reads a posted swipe's direction the other way round.
                e.setDoubleValueField(fProgress, value: right ? -1e-4 : 1e-4)
                e.setDoubleValueField(fPositionX, value: 0.1)
                if phase == phaseEnded {
                    e.setDoubleValueField(fVelocityX, value: right ? -9999 : 9999)
                }
                guard let data = e.data else { return false }
                let bytes = payload(
                    phase: phase, motion: 1,
                    progress: e.getDoubleValueField(fProgress),
                    px: e.getDoubleValueField(fPositionX), py: e.getDoubleValueField(fPositionY),
                    vx: e.getDoubleValueField(fVelocityX), vy: e.getDoubleValueField(fVelocityY),
                    mask: e.getIntegerValueField(fSwipeMask),
                    ts: e.timestamp != 0 ? e.timestamp : mach_absolute_time()
                )
                guard let full = appending(bytes, to: [UInt8](data as Data)),
                      let rebuilt = CGEvent(withDataAllocator: nil, data: Data(full) as CFData)
                else { return false }
                rebuilt.setIntegerValueField(.eventSourceUserData, value: marker)
                events.append(rebuilt)
            } else {
                e.setDoubleValueField(fProgress, value: right ? 1e-4 : -1e-4)
                e.setDoubleValueField(fVelocityX, value: right ? 2000 : -2000)
                e.setDoubleValueField(fVelocityY, value: right ? 2000 : -2000)
                e.setIntegerValueField(.eventSourceUserData, value: marker)
                events.append(e)
            }
        }
        for (i, e) in events.enumerated() {
            e.post(tap: .cgSessionEventTap)
            guard needsPayload else { continue }
            guard let companion = CGEvent(source: nil) else { return false }
            companion.setIntegerValueField(fEventType, value: 29)  // gesture
            companion.setIntegerValueField(.eventSourceUserData, value: marker)
            companion.post(tap: .cgSessionEventTap)
            if i < events.count - 1 { usleep(10_000) }
        }
        return true
    }

    /// One step, waiting for the WindowServer to agree it landed.
    @discardableResult
    static func step(right: Bool, on uuid: String, timeout: TimeInterval = 1.0) -> UInt64? {
        let before = displays().first { $0.uuid == uuid }?.current
        guard post(right: right) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let now = displays().first(where: { $0.uuid == uuid })?.current, now != before {
                return now
            }
            usleep(5_000)
        } while Date() < deadline
        return nil
    }
}

/// The swipe, from either implementation.
///
/// `--ext` runs the `dockswipe` spike instead of the copy above. That is the
/// control this experiment turns on: dockswipe is the reference weft ships in
/// 0.8.0 and it lands in ~20ms unheld, so if the drag works with `--ext` and
/// not without, the copy above is wrong; if it fails both ways, holding the
/// mouse is what Dock will not take a swipe through.
///
/// Everything is read from CommandLine directly rather than a global: top-level
/// variables in a Swift script initialise in source order, and this is called
/// from a function defined above them.
@discardableResult
func swipeStep(right: Bool, on uuid: String) -> UInt64? {
    guard CommandLine.arguments.contains("--ext") else {
        return Swipe.step(right: right, on: uuid)
    }
    let before = displays().first { $0.uuid == uuid }?.current
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent().appendingPathComponent("dockswipe")
    p.arguments = [right ? "right" : "left"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    let deadline = Date().addingTimeInterval(1.5)
    repeat {
        if let now = displays().first(where: { $0.uuid == uuid })?.current, now != before {
            return now
        }
        usleep(5_000)
    } while Date() < deadline
    return nil
}

/// The keyboard route to the next desktop, as this Mac actually has it bound.
///
/// Not ⌃→. "Move left/right a space" are symbolic hotkeys 79 and 81, and on
/// this machine they are remapped to ⌘⌥H and ⌘⌥L (parameters 104/4 and 108/37,
/// modifier 0x180000), which is why a posted ⌃→ did nothing and proved nothing.
/// Hardcoded because a spike only has to be right about the machine it runs on;
/// the real implementation would read com.apple.symbolichotkeys the way
/// SpaceControl.missionControlSwitchShortcuts() already does.
enum SpaceKey {
    static let right: CGKeyCode = 37  // 'l'
    static let left: CGKeyCode = 4  // 'h'
    static let flags: CGEventFlags = [.maskCommand, .maskAlternate]

    static func press(_ code: CGKeyCode) {
        for down in [true, false] {
            guard let k = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            else { return }
            k.flags = flags
            k.setIntegerValueField(.eventSourceUserData, value: Swipe.marker)
            k.post(tap: .cgSessionEventTap)
            usleep(30_000)
        }
    }
}

// MARK: - The drag

/// Hold `wid` by its title bar, swipe one desktop `right`, drop it, swipe back.
///
/// Returns the desktop the window ended up on. The window must be on the
/// current desktop: this grabs it by a screen coordinate, and a window on
/// another desktop has no coordinate to grab.
func dragAcross(wid: UInt32, right: Bool) -> (landed: UInt64?, note: String) {
    guard let frame = bounds(of: wid) else { return (nil, "no bounds for \(wid)") }
    guard let display = displays().first(where: { $0.ids.contains(spaces(of: wid).first ?? 0) })
    else { return (nil, "window is on no managed display") }
    let origin = display.current

    // Title bar: below the top edge, clear of the traffic lights on the left
    // and of any toolbar control on the right.
    let grab = CGPoint(x: frame.midX, y: frame.minY + 11)
    let restore = CGEvent(source: nil)?.location

    func mouse(_ type: CGEventType, _ at: CGPoint) {
        guard let e = CGEvent(
            mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)
        else { return }
        e.setIntegerValueField(.eventSourceUserData, value: Swipe.marker)
        e.post(tap: .cgSessionEventTap)
    }

    mouse(.leftMouseDown, grab)
    // Every exit releases the button. A synthetic down with no up leaves the
    // whole session stuck in a drag that no app can clear.
    defer {
        mouse(.leftMouseUp, CGEvent(source: nil)?.location ?? grab)
        if let restore { CGWarpMouseCursorPosition(restore) }
    }

    // macOS starts a window drag on movement, not on the press alone.
    for dy in stride(from: 2.0, through: 8.0, by: 2.0) {
        mouse(.leftMouseDragged, CGPoint(x: grab.x, y: grab.y + dy))
        usleep(12_000)
    }

    guard let landedSpace = swipeStep(right: right, on: display.uuid) else {
        return (nil, "the swipe did not land while the window was held")
    }
    // Let the desktop settle under the held window before letting go, then
    // nudge once more so the drop lands on this desktop rather than replaying
    // the last movement on the old one.
    usleep(120_000)
    mouse(.leftMouseDragged, CGPoint(x: grab.x, y: grab.y + 10))
    usleep(40_000)
    mouse(.leftMouseUp, CGPoint(x: grab.x, y: grab.y + 10))
    usleep(200_000)

    let after = spaces(of: wid)
    // Back where the user was. Swipe the other way regardless of whether the
    // move worked: leaving them on another desktop is worse than a failed move.
    swipeStep(right: !right, on: display.uuid)

    return (
        after.first,
        after.contains(landedSpace)
            ? "moved to \(landedSpace)"
            : "swipe landed on \(landedSpace) but the window stayed on \(after)"
    )
}

// MARK: - Modes

let args = Array(CommandLine.arguments.dropFirst())
let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path

if args.first == "helper" {
    // A real, draggable window of our own, so `test` never touches yours.
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let w = NSWindow(
        contentRect: NSRect(x: 300, y: 300, width: 480, height: 320),
        styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    w.title = "weft drag probe"
    w.orderFrontRegardless()
    app.activate(ignoringOtherApps: true)
    print("WID \(w.windowNumber)")
    fflush(stdout)
    app.run()
    exit(0)
}

/// Which desktops a window is on. Needed from the shell, because the sticky
/// experiment is driven by osascript against Dock's menu and still has to be
/// verified against the WindowServer rather than against the menu closing.
if args.first == "spaces", args.count >= 2, let wid = UInt32(args[1]) {
    let on = spaces(of: wid)
    let current = displays().first { $0.current != 0 }?.current ?? 0
    // Presence comes from the PUBLIC window list. `SLSWindowIsOnCurrentSpace`
    // returned false for a window provably on the current desktop — it failed
    // its own control — so whatever it means, it is not this. Four separate
    // instruments in this investigation have now reported confidently wrong
    // answers (rc=0 from calls that did nothing, a "supported" predicate for a
    // tag that was dropped, membership for a policy that does not retag, and
    // this), which is the argument for judging every one of them against a
    // case whose answer is already known.
    let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]] ?? [])
        .compactMap { $0[kCGWindowNumber as String] as? UInt32 }
    print(
        "window \(wid) on \(on) (\(on.count) desktop\(on.count == 1 ? "" : "s")); "
            + "current desktop \(current); onScreen=\(onScreen.contains(wid)) "
            + "[SLSWindowIsOnCurrentSpace says \(SLSWindowIsOnCurrentSpace(cid, wid)), untrusted]")
    exit(on.isEmpty ? 1 : 0)
}

if args.first == "list" {
    for d in displays() {
        print("display \(d.uuid)")
        for s in d.ids { print("  space \(s)\(s == d.current ? "  <- current" : "")") }
    }
    exit(0)
}

guard AXIsProcessTrusted() else {
    print("not trusted for Accessibility — posting events will be ignored")
    exit(1)
}

/// The control `key` needs. Without it a failed `key` run cannot separate
/// "holding the mouse blocks the keystroke" from "⌃→ is not bound at all" —
/// macOS ships several of these Mission Control shortcuts switched off, which
/// is the whole reason weft has `missionControlSwitchShortcuts()`.
if args.first == "keyonly" {
    let display = displays().first { $0.current != 0 }
    let before = display?.current

    SpaceKey.press(SpaceKey.right)
    usleep(700_000)
    let after = displays().first { $0.uuid == display?.uuid }?.current
    print("⌘⌥L with nothing held: desktop \(before ?? 0) -> \(after ?? 0)")
    if after != before {
        SpaceKey.press(SpaceKey.left)  // putting the user back
        usleep(500_000)
    }
    print(
        after != before
            ? "YES — the space shortcut is bound and switches desktops, so `key` tests the hold"
            : "no — the shortcut did not switch desktops, so `key` says nothing about holding")
    exit(0)
}

if args.first == "window", args.count >= 2, let wid = UInt32(args[1]) {
    let right = args.count < 3 || args[2] != "left"
    print("before: \(spaces(of: wid))")
    let (landed, note) = dragAcross(wid: wid, right: right)
    print("after:  \(spaces(of: wid))  \(note)")
    exit(landed != nil ? 0 : 1)
}

guard args.first == "test" || args.first == "dragonly" || args.first == "key" else {
    print("usage: dragmove <list|test|dragonly|key|window <wid> [left]>")
    exit(2)
}

// Spawn our own window, move it, report, kill it.
let helper = Process()
helper.executableURL = URL(fileURLWithPath: selfPath)
helper.arguments = ["helper"]
let pipe = Pipe()
helper.standardOutput = pipe
// Not inherited: with `2>&1` the helper would hold the shell's pipe open after
// this process exits, and the reader on the other end waits for EOF forever.
helper.standardError = FileHandle.nullDevice
// Line-buffered, so output survives being killed mid-run. Block buffering is
// why the first hung run printed nothing at all.
setvbuf(stdout, nil, _IOLBF, 0)
try? helper.run()
defer { helper.terminate() }

var wid: UInt32 = 0
let deadline = Date().addingTimeInterval(5)
var text = ""
while Date() < deadline, wid == 0 {
    text += String(data: pipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
    if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("WID ") }) {
        wid = UInt32(line.dropFirst(4).trimmingCharacters(in: .whitespaces)) ?? 0
    }
    usleep(20_000)
}
guard wid != 0 else {
    print("helper never reported a window")
    exit(1)
}
usleep(400_000)

/// Post one left-button event, marked so weft's own tap would let it through.
func post(_ type: CGEventType, _ at: CGPoint) {
    guard let e = CGEvent(
        mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)
    else { return }
    e.setIntegerValueField(.eventSourceUserData, value: Swipe.marker)
    e.post(tap: .cgSessionEventTap)
}

// Does the grab grab? Every conclusion above assumes the synthetic press lands
// on the title bar and starts a real window drag. If it does not, nothing has
// been testing a dragged window at all — it has been testing a button held
// over the desktop. No swipe, no desktop switch: just pick the window up, move
// it, and see whether the WindowServer agrees it moved.
if args.first == "dragonly" {
    guard let start = bounds(of: wid) else {
        print("no bounds for \(wid)")
        exit(1)
    }
    let grab = CGPoint(x: start.midX, y: start.minY + 11)
    print("window at \(start.origin), grabbing \(grab)")
    post(.leftMouseDown, grab)
    for i in 1...12 {
        post(.leftMouseDragged, CGPoint(x: grab.x + Double(i) * 5, y: grab.y + Double(i) * 3.4))
        usleep(15_000)
    }
    // Released explicitly rather than by `defer`: exit() does not run defers,
    // and a synthetic press with no release is the one failure here that would
    // be felt outside this process.
    post(.leftMouseUp, CGPoint(x: grab.x + 60, y: grab.y + 40))
    usleep(150_000)
    let moved = bounds(of: wid)
    print("window now at \(moved?.origin ?? .zero)")
    print(
        moved.map { $0.origin != start.origin } == true
            ? "YES — the synthetic grab drags the window"
            : "no — the grab never took hold, so nothing so far tested a dragged window")
    helper.terminate()
    exit(0)
}

/// Hold the window and press ⌃→, which is how a person moves a window to the
/// next desktop. Unlike a swipe this is a keystroke, and keystrokes are not
/// part of the gesture stream Dock appears to ignore mid-drag.
if args.first == "key" {
    guard let frame = bounds(of: wid) else {
        print("no bounds for \(wid)")
        exit(1)
    }
    let display = displays().first { $0.ids.contains(spaces(of: wid).first ?? 0) }
    let origin = display?.current
    let grab = CGPoint(x: frame.midX, y: frame.minY + 11)
    post(.leftMouseDown, grab)
    for dy in stride(from: 2.0, through: 8.0, by: 2.0) {
        post(.leftMouseDragged, CGPoint(x: grab.x, y: grab.y + dy))
        usleep(12_000)
    }
    // One press moves one desktop, so reaching an arbitrary desktop means
    // pressing repeatedly while still holding. If only the first press travels,
    // the feature can never reach anything but a neighbour — which would decide
    // the shape of the real implementation.
    let steps = max(1, args.count > 1 ? (Int(args[1]) ?? 1) : 1)
    for i in 1...steps {
        SpaceKey.press(SpaceKey.right)
        usleep(600_000)
        print("  press \(i): desktop \(displays().first { $0.uuid == display?.uuid }?.current ?? 0)")
    }
    let now = displays().first { $0.uuid == display?.uuid }?.current
    post(.leftMouseUp, CGPoint(x: grab.x, y: grab.y + 10))
    usleep(300_000)
    print("desktop \(origin ?? 0) -> \(now ?? 0); window on \(spaces(of: wid))")
    if now != origin {
        // Back the same number of desktops, each given time to commit. A read
        // taken before the switch lands reports the old desktop and invites an
        // over-correction — which is exactly how this run left the user two
        // desktops from where they started once already.
        for _ in 1...steps {
            SpaceKey.press(SpaceKey.left)
            usleep(600_000)
        }
        let back = displays().first { $0.uuid == display?.uuid }?.current
        print(
            "restored to \(back ?? 0)"
                + (back == origin ? "" : "  *** NOT where we started (\(origin ?? 0)) ***"))
    }
    print(
        spaces(of: wid).first != origin && now != origin
            ? "YES — a held window follows the space shortcut to the next desktop"
            : "no — \(now == origin ? "the shortcut did not switch desktops while held" : "the desktop switched but the window stayed")")
    helper.terminate()
    exit(0)
}

let before = spaces(of: wid)
print("helper window \(wid) on \(before)")
let (landed, note) = dragAcross(wid: wid, right: true)
let after = spaces(of: wid)
print("after: \(after)  —  \(note)")
print(
    landed != nil && after != before
        ? "\nYES — a held window crosses a synthetic swipe. This works with SIP on."
        : "\nno — the window did not travel with the swipe.")
