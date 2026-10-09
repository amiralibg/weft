// spikes/nativeops.swift — the rest of SkyLight's bridged operation family,
// and the facts a native-Spaces weft needs before it is designed (NATIVE.md).
//
// S10 showed SLSBridgedMoveWindowsToManagedSpaceOperation moves another
// process's window with SIP on. SkyLight has ~90 sibling classes going through
// the same two perform functions (one async, one sync). This asks the ones a
// native design would lean on, plus four questions about moved windows.
//
//   ./build.sh nativeops
//   ./nativeops list                  displays, desktops, animating, symbols
//   ./nativeops create                bridged SpaceCreate; read back; destroy it
//   ./nativeops create keep           …and leave it, to look at Mission Control
//   ./nativeops destroy <sid>         bridged SpaceDestroy
//   ./nativeops switch <n>            bridged SetCurrentSpace to desktop n of the
//                                     pointer display; is Dock still in sync?
//   ./nativeops animating             IsAnimating timeline around a Dock swipe
//   ./nativeops axhidden              AX frame write to a window on a hidden desktop
//   ./nativeops cross                 does the frame follow a cross-display move?
//   ./nativeops batch                 five windows in one operation
//   ./nativeops windows               real windows: id, app, desktops
//   ./nativeops moveto <wid> <sid>    a real window to a space id, any display
//   ./nativeops sticky                bridged AddWindowsToSpaces over every desktop
//
// Same rules as S8/S10: judged by read-back only, helper windows only (its own
// process, regular policy), the user's desktop restored when a probe changes it.

import AppKit
import ApplicationServices
import Foundation
import MachO

// MARK: - SkyLight

@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?
@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?
@_silgen_name("SLSSpaceGetType") func SLSSpaceGetType(_ cid: Int32, _ sid: UInt64) -> Int32
@_silgen_name("SLSManagedDisplayGetCurrentSpace")
func SLSManagedDisplayGetCurrentSpace(_ cid: Int32, _ uuid: CFString) -> UInt64
@_silgen_name("SLSManagedDisplayIsAnimating")
func SLSManagedDisplayIsAnimating(_ cid: Int32, _ uuid: CFString) -> Bool
@_silgen_name("SLSGetWindowBounds")
func SLSGetWindowBounds(_ cid: Int32, _ wid: UInt32, _ out: UnsafeMutablePointer<CGRect>) -> Int32

let cid = SLSMainConnectionID()
let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
let asyncSymbol =
    "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"
let syncSymbol =
    "__ZL54_SLSPerformSynchronousBridgedWindowManagementOperationP46SLSSynchronousBridgedWindowManagementOperation"

/// yabai's macho_find_symbol, as in bridgedmove.swift.
func machoFindSymbol(image target: String, symbol: String) -> UnsafeMutableRawPointer? {
    for i in 0..<_dyld_image_count() {
        guard let name = _dyld_get_image_name(i), String(cString: name) == target,
              let raw = _dyld_get_image_header(i)
        else { continue }
        let slide = _dyld_get_image_vmaddr_slide(i)
        let header = UnsafeRawPointer(raw).assumingMemoryBound(to: mach_header_64.self)
        var linkedit: segment_command_64?
        var symtab: symtab_command?
        var cmd = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let lc = cmd.load(as: load_command.self)
            if lc.cmd == LC_SEGMENT_64 {
                let seg = cmd.load(as: segment_command_64.self)
                let segname = withUnsafeBytes(of: seg.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if segname == SEG_LINKEDIT { linkedit = seg }
            } else if lc.cmd == LC_SYMTAB {
                symtab = cmd.load(as: symtab_command.self)
            }
            cmd = cmd.advanced(by: Int(lc.cmdsize))
        }
        guard let linkedit, let symtab else { return nil }
        let base = Int(linkedit.vmaddr) - Int(linkedit.fileoff) + slide
        guard let strs = UnsafeRawPointer(bitPattern: base + Int(symtab.stroff)),
              let syms = UnsafeRawPointer(bitPattern: base + Int(symtab.symoff))
        else { return nil }
        for s in 0..<Int(symtab.nsyms) {
            let entry = syms.advanced(by: s * MemoryLayout<nlist_64>.size).load(as: nlist_64.self)
            let name = String(cString: strs.advanced(by: Int(entry.n_un.n_strx)).assumingMemoryBound(to: CChar.self))
            if name == symbol { return UnsafeMutableRawPointer(bitPattern: Int(entry.n_value) + slide) }
        }
        return nil
    }
    return nil
}

typealias PerformFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
let asyncPerform = machoFindSymbol(image: skyLightPath, symbol: asyncSymbol).map { unsafeBitCast($0, to: PerformFn.self) }
let syncPerform = machoFindSymbol(image: skyLightPath, symbol: syncSymbol).map { unsafeBitCast($0, to: PerformFn.self) }

let msgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")!
typealias AllocFn = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?

func alloc(_ cls: String) -> UnsafeMutableRawPointer {
    guard let c = objc_getClass(cls) as? AnyClass else { fatalError("class \(cls) missing") }
    return unsafeBitCast(msgSend, to: AllocFn.self)(c, sel_registerName("alloc"))!
}

func performAsync(_ op: UnsafeMutableRawPointer?) {
    guard let op, let asyncPerform else { print("  !! async perform unavailable or init nil"); return }
    _ = asyncPerform(op)
}

/// The sync perform returns a result object (or nil). Nothing is trusted from
/// it beyond printing; every probe still reads back.
func performSync(_ op: UnsafeMutableRawPointer?) -> AnyObject? {
    guard let op, let syncPerform else { print("  !! sync perform unavailable or init nil"); return nil }
    guard let r = syncPerform(op) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(r).takeUnretainedValue()
}

// Initialisers, one cast each.
func opWindowsSpace(_ cls: String, _ wids: [UInt32], _ sid: UInt64) -> UnsafeMutableRawPointer? {
    typealias F = @convention(c) (UnsafeMutableRawPointer, Selector, CFArray, UInt64) -> UnsafeMutableRawPointer?
    return unsafeBitCast(msgSend, to: F.self)(alloc(cls), sel_registerName("initWithWindows:spaceID:"),
                                               wids.map { NSNumber(value: $0) } as CFArray, sid)
}
func opWindowsSpaces(_ cls: String, _ wids: [UInt32], _ sids: [UInt64]) -> UnsafeMutableRawPointer? {
    typealias F = @convention(c) (UnsafeMutableRawPointer, Selector, CFArray, CFArray) -> UnsafeMutableRawPointer?
    return unsafeBitCast(msgSend, to: F.self)(alloc(cls), sel_registerName("initWithWindows:spaces:"),
                                               wids.map { NSNumber(value: $0) } as CFArray,
                                               sids.map { NSNumber(value: $0) } as CFArray)
}
func opSpace(_ cls: String, _ sid: UInt64) -> UnsafeMutableRawPointer? {
    typealias F = @convention(c) (UnsafeMutableRawPointer, Selector, UInt64) -> UnsafeMutableRawPointer?
    return unsafeBitCast(msgSend, to: F.self)(alloc(cls), sel_registerName("initWithSpaceID:"), sid)
}
func opDisplaySpace(_ cls: String, _ uuid: String, _ sid: UInt64) -> UnsafeMutableRawPointer? {
    typealias F = @convention(c) (UnsafeMutableRawPointer, Selector, CFString, UInt64) -> UnsafeMutableRawPointer?
    return unsafeBitCast(msgSend, to: F.self)(alloc(cls), sel_registerName("initWithDisplayIdentifier:spaceID:"),
                                               uuid as CFString, sid)
}
func opCreate(options: UInt32, values: NSDictionary) -> UnsafeMutableRawPointer? {
    typealias F = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, CFDictionary) -> UnsafeMutableRawPointer?
    return unsafeBitCast(msgSend, to: F.self)(alloc("SLSBridgedSpaceCreateOperation"),
                                               sel_registerName("initWithOptions:values:"), options, values as CFDictionary)
}

// MARK: - Reads

func spaces(of wid: UInt32) -> [UInt64] {
    let arr = [NSNumber(value: wid)] as CFArray
    guard let r = SLSCopySpacesForWindows(cid, 0x7, arr)?.takeRetainedValue() as? [NSNumber] else { return [] }
    return r.map { $0.uint64Value }.sorted()
}

func bounds(_ wid: UInt32) -> CGRect {
    var r = CGRect.zero
    _ = SLSGetWindowBounds(cid, wid, &r)
    return r
}

struct Display {
    let uuid: String
    let spaces: [UInt64]
    let current: UInt64
    var desktops: [UInt64] { spaces.filter { SLSSpaceGetType(cid, $0) == 0 } }
}

func displays() -> [Display] {
    guard let raw = SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
    return raw.compactMap { d in
        guard let uuid = d["Display Identifier"] as? String, let list = d["Spaces"] as? [[String: Any]] else { return nil }
        let cur = ((d["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value ?? 0
        return Display(uuid: uuid, spaces: list.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }, current: cur)
    }
}

func cgDisplays() -> [(id: CGDirectDisplayID, uuid: String, frame: CGRect)] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).map { id in
        let u = CGDisplayCreateUUIDFromDisplayID(id)!.takeRetainedValue()
        return (id, CFUUIDCreateString(nil, u)! as String, CGDisplayBounds(id))
    }
}

func displayName(of rect: CGRect) -> String {
    let best = cgDisplays().max { a, b in
        a.frame.intersection(rect).width * a.frame.intersection(rect).height
            < b.frame.intersection(rect).width * b.frame.intersection(rect).height
    }
    return best.map { "display \($0.uuid.prefix(8)) \($0.frame)" } ?? "no display"
}

func currents() -> [String: UInt64] {
    Dictionary(uniqueKeysWithValues: displays().map { ($0.uuid, $0.current) })
}

func wait(_ timeout: Double = 1.5, _ cond: () -> Bool) -> Double? {
    let t0 = Date()
    while Date().timeIntervalSince(t0) < timeout {
        if cond() { return Date().timeIntervalSince(t0) * 1000 }
        usleep(2_000)
    }
    return nil
}

func ms(_ v: Double?) -> String { v.map { String(format: "%.1f ms", $0) } ?? "TIMEOUT" }

/// Dock's own persisted model, which is what Mission Control draws from.
func dockKnows(_ sid: UInt64) -> Bool {
    CFPreferencesAppSynchronize("com.apple.spaces" as CFString)
    guard let v = CFPreferencesCopyAppValue("SpacesDisplayConfiguration" as CFString, "com.apple.spaces" as CFString)
    else { return false }
    return "\(v)".contains("ManagedSpaceID = \(sid);")
}

// MARK: - Helper process

func runHelper(widFile: String, count: Int) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    var wids: [Int] = []
    for i in 0..<count {
        let w = NSWindow(
            contentRect: NSRect(x: 200 + i * 40, y: 200 + i * 30, width: 420, height: 300),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        w.title = "weft nativeops probe \(i + 1)"
        w.orderFrontRegardless()
        _ = Unmanaged.passRetained(w)
        wids.append(w.windowNumber)
    }
    try? (wids.map(String.init).joined(separator: " ") + "\n").write(toFile: widFile, atomically: true, encoding: .utf8)
    app.run()
    exit(0)
}

final class Helper {
    let process = Process()
    let wids: [UInt32]
    var pid: pid_t { process.processIdentifier }
    private let widFile: String

    init(count: Int = 1) {
        widFile = NSTemporaryDirectory() + "weft-nativeops-\(getpid())"
        try? FileManager.default.removeItem(atPath: widFile)
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["helper", widFile, "\(count)"]
        try! process.run()
        var got: [UInt32] = []
        for _ in 0..<300 where got.count != count {
            usleep(10_000)
            got = ((try? String(contentsOfFile: widFile, encoding: .utf8)) ?? "")
                .split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { UInt32($0) }
        }
        guard got.count == count else { print("helper never reported its windows"); exit(1) }
        wids = got
        let here = displays().first(where: { $0.current != 0 })!.current
        _ = wait(1) { wids.allSatisfy { spaces(of: $0) == [here] } }
    }

    func stop() {
        process.terminate()
        try? FileManager.default.removeItem(atPath: widFile)
    }
}

/// The pointer display, unless it has a single desktop: then the pointer is
/// warped to the display with the most (Dock swipes act on the pointer's
/// display) and put back when the probe exits.
var savedPointer: CGPoint?
func pointerDisplay() -> Display {
    let loc = CGEvent(source: nil)?.location ?? .zero
    let uuid0 = cgDisplays().first { $0.frame.contains(loc) }?.uuid
    let d0 = displays().first { $0.uuid.caseInsensitiveCompare(uuid0 ?? "") == .orderedSame }
    if let d0, d0.desktops.count < 2, let best = displays().max(by: { $0.desktops.count < $1.desktops.count }),
       best.desktops.count > 1, let f = cgDisplays().first(where: { $0.uuid.caseInsensitiveCompare(best.uuid) == .orderedSame })?.frame {
        if savedPointer == nil { savedPointer = loc; atexit { if let p = savedPointer { CGWarpMouseCursorPosition(p) } } }
        CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: f.midY))
        return best
    }
    let uuid = cgDisplays().first { $0.frame.contains(loc) }?.uuid
    return displays().first { $0.uuid.caseInsensitiveCompare(uuid ?? "") == .orderedSame } ?? displays()[0]
}

func runSibling(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/dockswipe")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Probes

func list() {
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("async perform: \(asyncPerform != nil ? "found" : "MISSING")   sync perform: \(syncPerform != nil ? "found" : "MISSING")")
    for (i, d) in displays().enumerated() {
        let rows = d.spaces.map { sid -> String in
            let t = SLSSpaceGetType(cid, sid)
            return "\(sid)\(t == 0 ? "" : "(type \(t))")\(sid == d.current ? "*" : "")\(dockKnows(sid) ? "" : "(dock?)")"
        }
        print("display \(i + 1) \(d.uuid): \(rows.joined(separator: " "))  animating=\(SLSManagedDisplayIsAnimating(cid, d.uuid as CFString))")
    }
}

func create(keep: Bool) {
    let before = displays()
    let beforeIDs = Set(before.flatMap(\.spaces))
    print("before: \(before.map { "\($0.uuid.prefix(8)): \($0.spaces)" })")
    var made: UInt64?
    for (opts, vals) in [(UInt32(1), [:] as NSDictionary), (0, [:])] where made == nil {
        let r = performSync(opCreate(options: opts, values: vals))
        let rid = (r as? NSObject)?.responds(to: Selector(("spaceID"))) == true
            ? ((r as! NSObject).value(forKey: "spaceID") as? NSNumber)?.uint64Value : nil
        print("  create(options: \(opts)) -> result \(r.map { String(describing: type(of: $0)) } ?? "nil") spaceID=\(rid.map(String.init) ?? "-")")
        _ = wait(1) { Set(displays().flatMap(\.spaces)) != beforeIDs }
        let after = displays()
        let new = Set(after.flatMap(\.spaces)).subtracting(beforeIDs)
        print("  after: \(after.map { "\($0.uuid.prefix(8)): \($0.spaces)" })  new managed: \(new.sorted())")
        if let sid = new.first ?? rid {
            made = sid
            print("  type \(SLSSpaceGetType(cid, sid)); Dock's com.apple.spaces knows it: \(wait(2) { dockKnows(sid) } != nil)")
            print("  your desktops unchanged: \(currents() == Dictionary(uniqueKeysWithValues: before.map { ($0.uuid, $0.current) }))")
        }
    }
    guard let sid = made else { print("RESULT: no desktop was created"); return }
    if keep { print("kept \(sid): open Mission Control to look, then ./nativeops destroy \(sid)"); return }
    destroy(sid)
}

/// Create an unmanaged space, then ask for it to be placed in the pointer
/// display's managed list at the end. Is that a Mission Control desktop?
func attach() {
    let d = pointerDisplay()
    let r = performSync(opCreate(options: 1, values: [:])) as? NSObject
    guard let sid = (r?.value(forKey: "spaceID") as? NSNumber)?.uint64Value else { print("create gave no id"); return }
    print("created \(sid), type \(SLSSpaceGetType(cid, sid)); attaching to \(d.uuid.prefix(8)) at index \(d.spaces.count)")
    typealias F = @convention(c) (UnsafeMutableRawPointer, Selector, UInt64, CFString, UInt32) -> UnsafeMutableRawPointer?
    let op = unsafeBitCast(msgSend, to: F.self)(alloc("SLSBridgedMoveManagedSpaceToDisplayIndexOperation"),
        sel_registerName("initWithSpaceID:displayIdentifier:index:"), sid, d.uuid as CFString, UInt32(d.spaces.count))
    performAsync(op)
    let t = wait(1.5) { displays().first { $0.uuid == d.uuid }?.spaces.contains(sid) == true }
    print("  in the display's managed list: \(t != nil ? "yes, \(ms(t))" : "no"); type now \(SLSSpaceGetType(cid, sid)); Dock knows: \(wait(2) { dockKnows(sid) } != nil)")
    print("  list: \(displays().map { "\($0.uuid.prefix(8)): \($0.spaces)" })")
    destroy(sid)
    usleep(300_000)
    print("  after destroy: type \(SLSSpaceGetType(cid, sid)), managed lists \(displays().map { $0.spaces })")
}

func destroy(_ sid: UInt64) {
    let t = Date()
    performAsync(opSpace("SLSBridgedSpaceDestroyOperation", sid))
    let gone = wait(2) { !displays().flatMap(\.spaces).contains(sid) }
    print("  destroy \(sid): \(gone != nil ? "gone in \(ms(gone))" : "STILL THERE after \(Date().timeIntervalSince(t))s")"
          + "; Dock still lists it: \(dockKnows(sid))")
}

func switchTo(_ n: Int) {
    let d = pointerDisplay()
    let ds = d.desktops
    guard (1...ds.count).contains(n) else { print("desktop \(n) out of range (\(ds.count))"); exit(1) }
    let start = d.current, target = ds[n - 1]
    print("display \(d.uuid.prefix(8)): \(start) -> \(target)")
    let t = Date()
    if CommandLine.arguments.contains("showhide") {
        typealias F = @convention(c) (UnsafeMutableRawPointer, Selector, CFArray) -> UnsafeMutableRawPointer?
        let mk = { (cls: String, sids: [UInt64]) in
            unsafeBitCast(msgSend, to: F.self)(alloc(cls), sel_registerName("initWithSpaces:"), sids.map { NSNumber(value: $0) } as CFArray)
        }
        performAsync(mk("SLSBridgedShowSpacesOperation", [target]))
        performAsync(mk("SLSBridgedHideSpacesOperation", [start]))
    }
    performAsync(opDisplaySpace("SLSBridgedManagedDisplaySetCurrentSpaceOperation", d.uuid, target))
    let landed = wait(2) { SLSManagedDisplayGetCurrentSpace(cid, d.uuid as CFString) == target }
    print("  set-current: \(landed != nil ? "landed in \(ms(landed))" : "no switch after \(Date().timeIntervalSince(t))s")")
    guard landed != nil else { return }
    usleep(600_000)
    let onscreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    let onTarget = onscreen.filter { spaces(of: $0).contains(target) }.count
    let onStart = onscreen.filter { spaces(of: $0).contains(start) && !spaces(of: $0).contains(target) }.count
    for w in onscreen where spaces(of: w).contains(start) && !spaces(of: w).contains(target) {
        let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, w) as? [[String: Any]])?.first ?? [:]
        print("    old-desktop window \(w) \(info[kCGWindowOwnerName as String] ?? "?") spaces \(spaces(of: w)) bounds \(bounds(w))")
    }
    print("  on-screen layer-0 windows: \(onTarget) from the target desktop, \(onStart) still from the old one")
    print("  managed-spaces dict agrees: \(displays().first { $0.uuid == d.uuid }?.current == target)")
    if CommandLine.arguments.contains("stay") {
        print("  staying on \(target): open Mission Control and check which desktop it highlights")
        return
    }
    // Dock sync: a swipe goes from Dock's idea of the current desktop. If Dock
    // followed, one step right lands on the desktop after target.
    if let idx = ds.firstIndex(of: target), idx + 1 < ds.count || idx > 0 {
        let dir = idx + 1 < ds.count ? "right" : "left"
        let expect = ds[dir == "right" ? idx + 1 : idx - 1]
        let out = runSibling([dir])
        usleep(800_000)
        let now = SLSManagedDisplayGetCurrentSpace(cid, d.uuid as CFString)
        print("  dock swipe \(dir) afterwards: now \(now), expected \(expect) -> Dock \(now == expect ? "IN SYNC" : "OUT OF SYNC")  [\(out.replacingOccurrences(of: "\n", with: " | "))]")
    }
    if let i = ds.firstIndex(of: start) {
        print("  restoring: \(runSibling(["to", "\(i + 1)"]).replacingOccurrences(of: "\n", with: " | "))")
    }
}

func animating() {
    let d = pointerDisplay()
    let uuid = d.uuid as CFString
    var log: [(Double, Bool, UInt64)] = []
    let t0 = Date()
    let done = DispatchSemaphore(value: 0)
    Thread {
        var last: (Bool, UInt64)?
        while Date().timeIntervalSince(t0) < 3 {
            let s = (SLSManagedDisplayIsAnimating(cid, uuid), SLSManagedDisplayGetCurrentSpace(cid, uuid))
            if last == nil || last! != s { log.append((Date().timeIntervalSince(t0) * 1000, s.0, s.1)); last = s }
            usleep(1_000)
        }
        done.signal()
    }.start()
    let dir = d.desktops.last == d.current ? "left" : "right"
    let back = dir == "right" ? "left" : "right"
    usleep(200_000)
    let a = Date().timeIntervalSince(t0) * 1000
    _ = runSibling([dir])
    usleep(1_000_000)
    let b = Date().timeIntervalSince(t0) * 1000
    // A bridged set-current back, to see whether it animates at all.
    performAsync(opDisplaySpace("SLSBridgedManagedDisplaySetCurrentSpaceOperation", d.uuid, d.current))
    done.wait()
    print(String(format: "swipe %@ posted at %.0f ms; bridged set-current back at %.0f ms", dir, a, b))
    for (t, anim, cur) in log { print(String(format: "  %7.1f ms  animating=%@  current=%llu", t, anim ? "YES" : "no ", cur)) }
    if SLSManagedDisplayGetCurrentSpace(cid, uuid) != d.current { _ = runSibling([back]) }
}

func axWindows(_ pid: pid_t) -> [AXUIElement] {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &v)
    return (v as? [AXUIElement]) ?? []
}

func axHidden() {
    let d = pointerDisplay()
    guard let other = d.desktops.first(where: { $0 != d.current }) else { print("need a second desktop"); exit(1) }
    let h = Helper()
    defer { h.stop() }
    let wid = h.wids[0]
    _ = wait(1) { !axWindows(h.pid).isEmpty }
    guard let el = axWindows(h.pid).first else { print("no AX window for helper"); return }
    print("window \(wid) on \(spaces(of: wid)) at \(bounds(wid)); AX windows visible: \(axWindows(h.pid).count)")
    performAsync(opWindowsSpace("SLSBridgedMoveWindowsToManagedSpaceOperation", [wid], other))
    print("  moved to \(other): \(ms(wait { spaces(of: wid) == [other] }))")
    print("  app's AX window list while hidden: \(axWindows(h.pid).count) (S0 predicts 0)")
    var pos = CGPoint(x: 333, y: 222), size = CGSize(width: 640, height: 480)
    let t = Date()
    let e1 = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &pos)!)
    let e2 = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    let took = Date().timeIntervalSince(t) * 1000
    let applied = wait(1) { bounds(wid) == CGRect(origin: pos, size: size) }
    print(String(format: "  AX set pos/size on the held element: rc %d/%d in %.1f ms; WindowServer bounds %@ -> %@",
                 e1.rawValue, e2.rawValue, took, "\(bounds(wid))", applied != nil ? "APPLIED" : "not applied"))
    print("  still on \(spaces(of: wid)) after the write (\(spaces(of: wid) == [other] ? "stayed hidden" : "MOVED"))"
          + "; your desktop still \(SLSManagedDisplayGetCurrentSpace(cid, d.uuid as CFString))")
    performAsync(opWindowsSpace("SLSBridgedMoveWindowsToManagedSpaceOperation", [wid], d.current))
    print("  moved back: \(ms(wait { spaces(of: wid) == [d.current] })); frame now \(bounds(wid))")
}

func cross() {
    let ds = displays()
    guard ds.count > 1 else { print("need a second display"); exit(1) }
    let here = pointerDisplay()
    let there = ds.first { $0.uuid != here.uuid }!
    let h = Helper()
    defer { h.stop() }
    let wid = h.wids[0]
    let b0 = bounds(wid)
    print("window \(wid) at \(b0) on \(displayName(of: b0))")
    performAsync(opWindowsSpace("SLSBridgedMoveWindowsToManagedSpaceOperation", [wid], there.current))
    print("  moved to \(there.current): \(ms(wait { spaces(of: wid) == [there.current] }))")
    usleep(300_000)
    let b1 = bounds(wid)
    print("  frame after: \(b1) on \(displayName(of: b1)) -> \(b1 == b0 ? "UNCHANGED (frame did not follow)" : "changed")")
    performAsync(opWindowsSpace("SLSBridgedMoveWindowsToManagedSpaceOperation", [wid], here.current))
    _ = wait { spaces(of: wid) == [here.current] }
    usleep(300_000)
    print("  back: \(spaces(of: wid)) frame \(bounds(wid))")
}

func batch() {
    let d = pointerDisplay()
    guard let other = d.desktops.first(where: { $0 != d.current }) else { print("need a second desktop"); exit(1) }
    let h = Helper(count: 5)
    defer { h.stop() }
    print("windows \(h.wids) on \(d.current) -> \(other)")
    performAsync(opWindowsSpace("SLSBridgedMoveWindowsToManagedSpaceOperation", h.wids, other))
    let all = wait { h.wids.allSatisfy { spaces(of: $0) == [other] } }
    print("  one operation, five windows: \(all != nil ? "all landed in \(ms(all))" : "partial: \(h.wids.map { spaces(of: $0) })")")
    performAsync(opWindowsSpace("SLSBridgedMoveWindowsToManagedSpaceOperation", h.wids, d.current))
    print("  back: \(ms(wait { h.wids.allSatisfy { spaces(of: $0) == [d.current] } }))")
}

func sticky() {
    let d = pointerDisplay()
    let h = Helper()
    defer { h.stop() }
    let wid = h.wids[0]
    let all = d.desktops
    print("window \(wid) on \(spaces(of: wid)); adding to \(all)")
    performAsync(opWindowsSpaces("SLSBridgedAddWindowsToSpacesOperation", [wid], all))
    let ok = wait { spaces(of: wid) == all.sorted() }
    print("  bridged AddWindowsToSpaces: \(ok != nil ? "on every desktop in \(ms(ok))" : "now on \(spaces(of: wid))")")
    let rest = all.filter { $0 != d.current }
    performAsync(opWindowsSpaces("SLSBridgedRemoveWindowsFromSpacesOperation", [wid], rest))
    let back = wait { spaces(of: wid) == [d.current] }
    print("  bridged RemoveWindowsFromSpaces: \(back != nil ? "back to one in \(ms(back))" : "now on \(spaces(of: wid))")")
}

// MARK: - Main

let args = CommandLine.arguments
let before = currents()
switch args.count > 1 ? args[1] : "" {
case "list": list()
case "create": create(keep: args.count > 2 && args[2] == "keep")
case "destroy" where args.count > 2: destroy(UInt64(args[2])!)
case "exists" where args.count > 2:
    let sid = UInt64(args[2])!
    print("space \(sid): type \(SLSSpaceGetType(cid, sid)), in managed list: \(displays().flatMap(\.spaces).contains(sid))")
case "attach": attach()
case "windows":
    // Real windows with their ids and desktops, for `moveto`.
    for w in (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []) {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let b = w[kCGWindowBounds as String] as? [String: Double],
              (b["Width"] ?? 0) > 200, (b["Height"] ?? 0) > 200,
              let wid = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              !spaces(of: wid).isEmpty, (w[kCGWindowOwnerName as String] as? String) != "borders"
        else { continue }
        print("\(wid)\t\(w[kCGWindowOwnerName as String] ?? "?")\tdesktops \(spaces(of: wid))\t\(w[kCGWindowName as String] ?? "")")
    }
case "watch":
    // Swipe by hand while this runs: does IsAnimating ever go true, and when
    // does the current-space read change relative to it?
    print("watching every display for 10 s — swipe now")
    let t0 = Date()
    var last: [String: (Bool, UInt64)] = [:]
    while Date().timeIntervalSince(t0) < 10 {
        for d in displays() {
            let s = (SLSManagedDisplayIsAnimating(cid, d.uuid as CFString), SLSManagedDisplayGetCurrentSpace(cid, d.uuid as CFString))
            if last[d.uuid] == nil || last[d.uuid]! != s {
                print(String(format: "  %7.1f ms  %@  animating=%@  current=%llu", Date().timeIntervalSince(t0) * 1000,
                             String(d.uuid.prefix(8)), s.0 ? "YES" : "no ", s.1))
                last[d.uuid] = s
            }
        }
        usleep(1_000)
    }
case "moveto" where args.count > 3:
    // A real window to a space id, any display. Prints where it ended up.
    let wid = UInt32(args[2])!, sid = UInt64(args[3])!
    let b0 = bounds(wid), s0 = spaces(of: wid)
    performAsync(opWindowsSpace("SLSBridgedMoveWindowsToManagedSpaceOperation", [wid], sid))
    let t = wait { spaces(of: wid) == [sid] }
    usleep(300_000)
    print("window \(wid): \(s0) -> \(spaces(of: wid)) \(t != nil ? "MOVED in \(ms(t))" : "no movement")")
    print("  frame \(b0) -> \(bounds(wid)) (\(displayName(of: bounds(wid))))")
case "switch" where args.count > 2: switchTo(Int(args[2])!)
case "animating": animating()
case "axhidden": axHidden()
case "cross": cross()
case "batch": batch()
case "sticky": sticky()
case "helper" where args.count > 3: runHelper(widFile: args[2], count: Int(args[3])!)
default:
    print("usage: nativeops list | create [keep] | destroy <sid> | switch <n> | animating | axhidden | cross | batch | sticky | windows | moveto <wid> <sid> | watch | switch <n> showhide [stay]")
    exit(2)
}
if !["switch", "animating", "helper"].contains(args.count > 1 ? args[1] : ""), currents() != before {
    print("!! your desktop changed during this probe: \(before) -> \(currents())")
}
