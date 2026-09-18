// S9 — emulated workspaces: can weft park a desktop's windows off screen and
// bring them back, the way AeroSpace does instead of using native Spaces?
//
// Two numbers decide whether that architecture is open to weft, and neither
// can be reasoned out — they are properties of the apps on the machine:
//
//   1. **Does the app accept being put off screen?** An app enforces its own
//      geometry at every step of a frame write (§S1, and `axWriteOrder` in
//      WeftCore exists because of it). One that clamps its position to the
//      visible frame cannot be hidden this way at all, and a window manager
//      that leaves a window sitting in the middle of the screen when the user
//      switched away from it is worse than one that animates.
//   2. **What does a switch cost?** Switching workspaces is a frame write per
//      window on the outgoing desktop plus one per window on the incoming
//      one. weft has measured a single Chromium relayout at 1.2s. If a switch
//      costs half a second the trade against a native-Space animation is lost.
//
// Both AX and the WindowServer are measured, because they fail differently.
// An AX write asks the application to move and it may refuse; `SLSMoveWindow`
// moves the window without the application being told, so it cannot refuse —
// but then its own idea of where it is goes stale, which is the fault the S4
// nudge protocol exists to repair.
//
//   ./build.sh virtual
//   ./virtual                  # dry run: what it would move, and where to
//   ./virtual --park ax        # park, measure, restore
//   ./virtual --park sls
//   ./virtual --restore <file> # put everything back after a crash
//
// Nothing here touches a space. No window changes desktop, and every window
// is written back to the frame it started on.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

typealias SLConnectionID = Int32
@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> SLConnectionID
@_silgen_name("SLSGetWindowBounds") func SLSGetWindowBounds(_ c: SLConnectionID, _ w: UInt32, _ r: UnsafeMutablePointer<CGRect>) -> Int32
@_silgen_name("SLSMoveWindow") func SLSMoveWindow(_ c: SLConnectionID, _ w: UInt32, _ p: UnsafeMutablePointer<CGPoint>) -> Int32
@_silgen_name("SLSCopySpacesForWindows") func SLSCopySpacesForWindows(_ c: SLConnectionID, _ m: Int32, _ w: CFArray) -> CFArray
@_silgen_name("SLSCopyManagedDisplaySpaces") func SLSCopyManagedDisplaySpaces(_ c: SLConnectionID) -> CFArray
@_silgen_name("SLSManagedDisplayGetCurrentSpace") func SLSManagedDisplayGetCurrentSpace(_ c: SLConnectionID, _ u: CFString) -> UInt64
@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ e: AXUIElement, _ w: UnsafeMutablePointer<UInt32>) -> AXError

let cid = SLSMainConnectionID()
let ownPID = ProcessInfo.processInfo.processIdentifier

// The host this spike is driven from. Parking its window loses the terminal
// the results are being read in, which is a poor trade for one more data point.
var skipApps = ["Claude", "Terminal", "iTerm2", "borders", "WeftBar", "weft-bar"]

func bounds(_ wid: UInt32) -> CGRect? {
    var r = CGRect.zero
    return SLSGetWindowBounds(cid, wid, &r) == 0 ? r : nil
}

func currentSpaces() -> [(uuid: String, sid: UInt64)] {
    guard let raw = SLSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }
    return raw.compactMap { d in
        guard let u = d["Display Identifier"] as? String else { return nil }
        return (u, SLSManagedDisplayGetCurrentSpace(cid, u as CFString))
    }
}

func spaces(of wid: UInt32) -> [UInt64] {
    (SLSCopySpacesForWindows(cid, 0x7, [NSNumber(value: wid)] as CFArray) as? [NSNumber])?
        .map { $0.uint64Value } ?? []
}

// MARK: - Discovery (the same filter WorldReader applies)

struct Win {
    let wid: UInt32
    let pid: Int32
    let app: String
    let title: String
    let frame: CGRect
}

/// `--all` widens the sample to every window on every desktop.
///
/// The question this spike answers is per application — does *this* app let
/// its window be put off screen — and an app answers it the same way wherever
/// its window happens to live. A machine whose windows are spread over eight
/// desktops otherwise offers a sample of one, and measuring the desktops
/// nobody is looking at disturbs nothing on screen.
func windowsOnCurrentDesktops(all: Bool = false) -> [Win] {
    let showing = Set(currentSpaces().map { $0.sid })
    guard let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    var out: [Win] = []
    for w in info {
        guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        guard (b["Width"] as? Double ?? 0) > 100, (b["Height"] as? Double ?? 0) > 100 else { continue }
        let pid = Int32(w[kCGWindowOwnerPID as String] as? Int ?? 0)
        guard pid != 0, pid != ownPID else { continue }
        let app = w[kCGWindowOwnerName as String] as? String ?? "?"
        guard !skipApps.contains(app) else { continue }
        // Menu-bar extras: agent apps, never real windows (WorldReader §).
        guard NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular else { continue }
        let wid = UInt32(w[kCGWindowNumber as String] as? Int ?? 0)
        guard wid != 0 else { continue }
        let home = spaces(of: wid)
        guard all ? !home.isEmpty : !Set(home).isDisjoint(with: showing) else { continue }
        guard let f = bounds(wid) else { continue }
        out.append(Win(wid: wid, pid: pid, app: app,
                       title: w[kCGWindowName as String] as? String ?? "", frame: f))
    }
    return out.sorted { $0.wid < $1.wid }
}

// MARK: - Moving

var elementCache: [UInt32: AXUIElement] = [:]

func element(_ w: Win) -> AXUIElement? {
    if let e = elementCache[w.wid] { return e }
    let appEl = AXUIElementCreateApplication(w.pid)
    AXUIElementSetMessagingTimeout(appEl, 0.5)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &v) == .success,
          let els = v as? [AXUIElement] else { return nil }
    for e in els {
        var got: UInt32 = 0
        if _AXUIElementGetWindow(e, &got) == .success, got == w.wid {
            elementCache[w.wid] = e
            return e
        }
    }
    return nil
}

enum Method: String { case ax, sls }

@discardableResult
func move(_ w: Win, to origin: CGPoint, by method: Method) -> Bool {
    switch method {
    case .sls:
        var p = origin
        return SLSMoveWindow(cid, w.wid, &p) == 0
    case .ax:
        guard let el = element(w) else { return false }
        var o = origin
        guard let value = AXValueCreate(.cgPoint, &o) else { return false }
        return AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, value) == .success
    }
}

// MARK: - Where "off screen" is
//
// AeroSpace parks in a monitor's bottom corner, and documents that macOS will
// not let a window leave the visible area entirely: a 1px sliver stays. This
// asks for the corner and then measures what was actually granted, which is
// the honest form of that claim for this machine.

func parkPoint(for w: Win) -> CGPoint {
    let screen = NSScreen.screens.first {
        $0.frame.intersects(CGRect(x: w.frame.minX, y: w.frame.minY, width: 1, height: 1))
    } ?? NSScreen.main ?? NSScreen.screens[0]
    // Top-left origin, the coordinate space SLS and AX both report in.
    let full = screen.frame
    let flippedTop = (NSScreen.screens.map { $0.frame.maxY }.max() ?? full.maxY) - full.maxY
    return CGPoint(x: full.maxX - 1, y: flippedTop + full.height - 1)
}

// MARK: - State file, so a crash is recoverable

let stateURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("weft-virtual-spike-\(Int(Date().timeIntervalSince1970)).json")

func save(_ wins: [Win]) {
    let rows = wins.map { ["wid": Int($0.wid), "pid": Int($0.pid),
                           "x": $0.frame.minX, "y": $0.frame.minY] as [String: Any] }
    guard let data = try? JSONSerialization.data(withJSONObject: rows, options: .prettyPrinted) else { return }
    try? data.write(to: stateURL)
    print("original frames saved to \(stateURL.path)")
    print("  if this spike dies mid-run:  ./virtual --restore \(stateURL.path)\n")
}

func restore(from path: String) {
    guard let data = FileManager.default.contents(atPath: path),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { print("cannot read \(path)"); exit(1) }
    for r in rows {
        guard let wid = r["wid"] as? Int, let pid = r["pid"] as? Int,
              let x = r["x"] as? Double, let y = r["y"] as? Double else { continue }
        let w = Win(wid: UInt32(wid), pid: Int32(pid), app: "", title: "", frame: .zero)
        move(w, to: CGPoint(x: x, y: y), by: .ax)
        move(w, to: CGPoint(x: x, y: y), by: .sls)
        print("restored \(wid) -> \(x),\(y)")
    }
}

// MARK: - Visible area
//
// "Did it park" is not "did it land on the pixel asked for". macOS refuses to
// put a window's title bar below the bottom of the screen, so the y always
// comes back short by a few dozen points; that is the clamp working as
// designed, not the app refusing. The question a user cares about is how much
// of the window they can still see, so that is what is measured.

func screenUnion() -> [CGRect] {
    let top = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
    return NSScreen.screens.map {
        CGRect(x: $0.frame.minX, y: top - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
    }
}

/// The largest visible patch of `frame`, in points.
func visiblePatch(_ frame: CGRect) -> CGSize {
    var best = CGSize.zero
    for s in screenUnion() {
        let i = frame.intersection(s)
        guard !i.isNull, i.width * i.height > best.width * best.height else { continue }
        best = i.size
    }
    return best
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}

// MARK: - Visiting a desktop
//
// One window per desktop is the normal shape of a machine that already uses
// native Spaces, and it makes the sample on any one desktop useless. The
// verdict wanted here is per application, so `--visit` goes to each desktop in
// turn — with the same bound shortcut the carry uses — and asks the windows
// there. It is a handful of visible switches, once, to answer a question about
// an architecture.

func displayOrder() -> (uuid: String, ids: [UInt64], current: UInt64)? {
    guard let raw = SLSCopyManagedDisplaySpaces(cid) as? [[String: Any]],
          let d = raw.first, let uuid = d["Display Identifier"] as? String else { return nil }
    let ids = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
    return (uuid, ids, SLSManagedDisplayGetCurrentSpace(cid, uuid as CFString))
}

func pressSpaceKey(right: Bool) {
    // 79 / 81 — "Move left/right a space". Read from the user's own symbolic
    // hotkeys in weft; hard-coded here to this machine's ⌘⌥H / ⌘⌥L.
    let code: CGKeyCode = right ? 37 : 4
    for down in [true, false] {
        guard let k = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
        k.flags = [.maskCommand, .maskAlternate]
        k.setIntegerValueField(.eventSourceUserData, value: 0x5745_4654)
        k.post(tap: .cgSessionEventTap)
        usleep(20_000)
    }
}

@discardableResult
func goTo(_ sid: UInt64) -> Bool {
    guard let d = displayOrder(), let from = d.ids.firstIndex(of: d.current),
          let to = d.ids.firstIndex(of: sid) else { return false }
    for _ in 0..<abs(to - from) {
        let before = displayOrder()?.current
        pressSpaceKey(right: to > from)
        let deadline = Date().addingTimeInterval(1.5)
        repeat {
            if displayOrder()?.current != before { break }
            usleep(5_000)
        } while Date() < deadline
    }
    usleep(250_000)
    return displayOrder()?.current == sid
}

// MARK: - Run

struct Result {
    let app: String
    let desktop: UInt64
    let parkMs: Double
    let landed: CGRect
    let visible: CGSize
    let stayed: Bool
    let restored: Bool
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--restore"), i + 1 < args.count {
    restore(from: args[i + 1])
    exit(0)
}
if args.contains("--include-host") { skipApps = ["borders", "WeftBar", "weft-bar"] }
let method = Method(rawValue: args.firstIndex(of: "--park").map { args[$0 + 1] } ?? "") ?? .ax
let dryRun = !args.contains("--park")
let visit = args.contains("--visit")
let everywhere = visit || args.contains("--all")

let wins = windowsOnCurrentDesktops(all: everywhere)
guard let start = displayOrder() else { print("no display"); exit(1) }
print("display \(start.uuid.prefix(8)) showing desktop \(start.current) of \(start.ids)")
print("\(wins.count) window(s) on \(everywhere ? "every desktop" : "the showing desktop"), "
    + "skipping \(skipApps.joined(separator: ", "))\n")
guard !wins.isEmpty else { print("nothing to measure"); exit(0) }

print(pad("app", 22) + pad("wid", 8) + pad("desktop", 9) + pad("frame", 26) + "parks at")
for w in wins {
    let p = parkPoint(for: w)
    print(pad(w.app, 22) + pad("\(w.wid)", 8)
        + pad(spaces(of: w.wid).map(String.init).joined(separator: ","), 9)
        + pad("(\(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))x\(Int(w.frame.height)))", 26)
        + "(\(Int(p.x)),\(Int(p.y)))")
}
if dryRun {
    print("\ndry run. `--park ax` or `--park sls` to measure; add `--visit` to")
    print("go to each desktop in turn so every app gets asked on screen.")
    exit(0)
}

save(wins)
print("method: \(method.rawValue)\(visit ? ", visiting each desktop" : "")\n")

var groups: [UInt64: [Win]] = [:]
for w in wins {
    guard let home = spaces(of: w.wid).first else { continue }
    groups[home, default: []].append(w)
}
if !visit { groups = groups.filter { $0.key == start.current } }

var results: [Result] = []
var switchCost: [(desktop: UInt64, count: Int, parkMs: Double, restoreMs: Double)] = []

for (sid, group) in groups.sorted(by: { $0.key < $1.key }) {
    if visit, sid != displayOrder()?.current, !goTo(sid) {
        print("could not reach desktop \(sid); skipping \(group.count) window(s)")
        continue
    }
    var perWindow: [UInt32: Double] = [:]
    let t0 = Date()
    for w in group {
        let s = Date()
        move(w, to: parkPoint(for: w), by: method)
        perWindow[w.wid] = Date().timeIntervalSince(s) * 1000
    }
    let parkMs = Date().timeIntervalSince(t0) * 1000
    usleep(400_000)
    var landedBy: [UInt32: CGRect] = [:]
    for w in group { landedBy[w.wid] = bounds(w.wid) ?? w.frame }
    usleep(800_000)
    var stayed: [UInt32: Bool] = [:]
    for w in group {
        let now = bounds(w.wid) ?? w.frame
        stayed[w.wid] = !(abs(now.minX - w.frame.minX) < 20 && abs(now.minY - w.frame.minY) < 20)
    }
    let t1 = Date()
    for w in group { move(w, to: CGPoint(x: w.frame.minX, y: w.frame.minY), by: method) }
    let restoreMs = Date().timeIntervalSince(t1) * 1000
    usleep(400_000)
    for w in group {
        let back = bounds(w.wid) ?? .zero
        results.append(Result(
            app: w.app, desktop: sid, parkMs: perWindow[w.wid] ?? 0,
            landed: landedBy[w.wid] ?? w.frame,
            visible: visiblePatch(landedBy[w.wid] ?? w.frame),
            stayed: stayed[w.wid] ?? false,
            restored: abs(back.minX - w.frame.minX) < 2 && abs(back.minY - w.frame.minY) < 2))
    }
    switchCost.append((sid, group.count, parkMs, restoreMs))
}

if visit { _ = goTo(start.current) }

print(pad("app", 22) + pad("desktop", 9) + pad("ms", 7) + pad("landed", 16)
    + pad("still visible", 16) + pad("stayed", 8) + "restored")
for r in results {
    print(pad(r.app, 22) + pad("\(r.desktop)", 9)
        + pad(String(format: "%.0f", r.parkMs), 7)
        + pad("(\(Int(r.landed.minX)),\(Int(r.landed.minY)))", 16)
        + pad("\(Int(r.visible.width))x\(Int(r.visible.height))pt", 16)
        + pad(r.stayed ? "yes" : "NO", 8)
        + (r.restored ? "yes" : "NO"))
}

// Hidden enough that nobody notices: a sliver down one edge is what AeroSpace
// documents and lives with; a window still showing a usable patch is not
// hidden at all, and that is the verdict that decides this architecture.
let hidden = results.filter { $0.visible.width <= 8 || $0.visible.height <= 8 }
let totalPark = switchCost.reduce(0) { $0 + $1.parkMs }
let totalRestore = switchCost.reduce(0) { $0 + $1.restoreMs }
print("""

\(results.count) window(s), method \(method.rawValue)
  hidden to a sliver:     \(hidden.count)/\(results.count)
  stayed parked for 1s:   \(results.filter { $0.stayed }.count)/\(results.count)
  restored exactly:       \(results.filter { $0.restored }.count)/\(results.count)
  park   \(String(format: "%.0f", totalPark)) ms for \(results.count) window(s) \
(\(String(format: "%.0f", totalPark / Double(max(results.count, 1)))) ms each, written one at a time)
  restore \(String(format: "%.0f", totalRestore)) ms
""")
let broken = results.filter { !$0.restored }
if broken.isEmpty {
    try? FileManager.default.removeItem(at: stateURL)
} else {
    print("NOT restored: \(broken.map { $0.app }.joined(separator: ", "))")
    print("run: ./virtual --restore \(stateURL.path)")
}
