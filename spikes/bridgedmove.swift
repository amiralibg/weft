// spikes/bridgedmove.swift — does SkyLight's bridged window-management
// operation move another process's window to another desktop with SIP on?
//
// S8 tried sixteen SkyLight routes and every one was refused from an ordinary
// connection. That result is why weft left native desktops (WORKSPACES.md,
// REDESIGN.md). yabai 7.1.25 (asmvik/yabai#2788) added a route S8 never tried:
//
//   op = [[SLSBridgedMoveWindowsToManagedSpaceOperation alloc]
//            initWithWindows:<CFArray of wids> spaceID:<sid>]
//   SLSPerformAsynchronousBridgedWindowManagementOperation(op)
//
// The perform function is a C++ static (`__ZL54…`), so dlsym cannot see it.
// yabai finds it by walking SkyLight's LC_SYMTAB in memory; this does the same.
//
//   ./build.sh bridgedmove
//   ./bridgedmove list            symbol, class, desktops on every display
//   ./bridgedmove run             helper window -> last desktop -> back
//   ./bridgedmove run cross       helper window -> another display's desktop -> back
//   ./bridgedmove move <wid> <n>  a real window to desktop n (1-based) of its display
//
// Same rules as S8:
//   - Judged only by re-reading SLSCopySpacesForWindows. The perform call's
//     return value is printed and trusted for nothing.
//   - `run` acts on a helper process's window, never one of yours, and kills
//     the helper afterwards.
//   - Never switches your desktop, and says so if your desktop changed anyway.

import AppKit
import Foundation
import MachO

// MARK: - SkyLight

@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?
@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?
@_silgen_name("SLSSpaceGetType") func SLSSpaceGetType(_ cid: Int32, _ sid: UInt64) -> Int32

let cid = SLSMainConnectionID()

let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
let performSymbol =
    "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"
let operationClass = "SLSBridgedMoveWindowsToManagedSpaceOperation"

/// A symbol from an image's own symbol table, local ones included. dlsym only
/// sees exports; this is yabai's macho_find_symbol in Swift.
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

typealias PerformFn = @convention(c) (UnsafeMutableRawPointer) -> Int64
typealias AllocFn = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
typealias InitFn = @convention(c) (UnsafeMutableRawPointer, Selector, CFArray, UInt64) -> UnsafeMutableRawPointer?
typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer, Selector) -> Void

let msgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")!  // RTLD_DEFAULT

func perform() -> PerformFn? {
    machoFindSymbol(image: skyLightPath, symbol: performSymbol).map { unsafeBitCast($0, to: PerformFn.self) }
}

/// Builds and performs one operation. Returns the perform call's raw result,
/// or why it could not be made. The result proves nothing about the move.
func bridgedMove(_ wids: [UInt32], to sid: UInt64) -> String {
    guard let perform = perform() else { return "perform symbol not found" }
    guard let cls = objc_getClass(operationClass) as? AnyClass else { return "class \(operationClass) missing" }
    let alloc = unsafeBitCast(msgSend, to: AllocFn.self)
    let initOp = unsafeBitCast(msgSend, to: InitFn.self)
    let release = unsafeBitCast(msgSend, to: ReleaseFn.self)
    guard let fresh = alloc(cls, sel_registerName("alloc")) else { return "alloc returned nil" }
    let list = wids.map { NSNumber(value: $0) } as CFArray
    guard let op = initOp(fresh, sel_registerName("initWithWindows:spaceID:"), list, sid) else {
        return "init returned nil"
    }
    let rc = perform(op)
    release(op, sel_registerName("release"))
    return "perform=\(rc)"
}

// MARK: - Desktops

func spaces(of wid: UInt32) -> [UInt64] {
    let arr = [NSNumber(value: wid)] as CFArray
    guard let r = SLSCopySpacesForWindows(cid, 0x7, arr)?.takeRetainedValue() as? [NSNumber] else { return [] }
    return r.map { $0.uint64Value }
}

struct Display {
    let uuid: String
    let spaces: [UInt64]
    let current: UInt64
    /// Ordinary desktops only: a fullscreen app's space is not a target.
    var desktops: [UInt64] { spaces.filter { SLSSpaceGetType(cid, $0) == 0 } }
}

func displays() -> [Display] {
    guard let raw = SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
    return raw.compactMap { d in
        guard let uuid = d["Display Identifier"] as? String, let list = d["Spaces"] as? [[String: Any]] else {
            return nil
        }
        let cur = ((d["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value ?? 0
        return Display(uuid: uuid, spaces: list.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }, current: cur)
    }
}

func currentByDisplay() -> [String: UInt64] {
    Dictionary(uniqueKeysWithValues: displays().map { ($0.uuid, $0.current) })
}

/// Polls until `wid` reports exactly `[sid]`, because the operation is
/// asynchronous. Returns the latency, or nil and the last answer.
func waitFor(_ wid: UInt32, on sid: UInt64, timeout: Double = 1.5) -> (ms: Double?, last: [UInt64]) {
    let start = Date()
    var last = spaces(of: wid)
    while Date().timeIntervalSince(start) < timeout {
        last = spaces(of: wid)
        if last == [sid] { return (Date().timeIntervalSince(start) * 1000, last) }
        usleep(5_000)
    }
    return (nil, last)
}

/// One move, judged by read-back. Prints a row and returns whether it landed.
@discardableResult
func moveAndCheck(_ wid: UInt32, to sid: UInt64, label: String) -> Bool {
    let before = spaces(of: wid)
    let desktopBefore = currentByDisplay()
    let rc = bridgedMove([wid], to: sid)
    let (ms, after) = waitFor(wid, on: sid)
    let switched = currentByDisplay() != desktopBefore
    let verdict = ms.map { String(format: "MOVED in %.1f ms", $0) } ?? "no movement"
    print("  \(label): \(before) -> \(after)  [\(rc)]  \(verdict)\(switched ? "  !! your desktop changed" : "")")
    return ms != nil
}

// MARK: - Helper process
//
// Another application's window from the WindowServer's side: its own process,
// its own connection, exactly as Safari's is. Regular activation policy, so it
// is an app in the sense Dock means.

func runHelper(widFile: String) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let w = NSWindow(
        contentRect: NSRect(x: 240, y: 240, width: 420, height: 300),
        styleMask: [.titled, .closable], backing: .buffered, defer: false
    )
    w.title = "weft bridged-move probe"
    w.orderFrontRegardless()
    _ = Unmanaged.passRetained(w)  // the helper is killed outright
    try? "\(w.windowNumber)\n".write(toFile: widFile, atomically: true, encoding: .utf8)
    app.run()
    exit(0)
}

// MARK: - Commands

func list() {
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    print("macOS \(os)")
    let p = machoFindSymbol(image: skyLightPath, symbol: performSymbol)
    print("perform symbol: \(p.map { "found at \($0)" } ?? "NOT FOUND")")
    print("exported by dlsym too: \(dlsym(UnsafeMutableRawPointer(bitPattern: -2), String(performSymbol.dropFirst())) != nil)")
    print("class \(operationClass): \(objc_getClass(operationClass) != nil ? "present" : "MISSING")")
    for (i, d) in displays().enumerated() {
        let rows = d.spaces.map { sid -> String in
            let t = SLSSpaceGetType(cid, sid)
            return "\(sid)\(t == 0 ? "" : "(type \(t))")\(sid == d.current ? "*" : "")"
        }
        print("display \(i + 1) \(d.uuid): \(rows.joined(separator: " "))")
    }
}

func run(cross: Bool) {
    guard perform() != nil, objc_getClass(operationClass) != nil else {
        list()
        print("cannot run: the route is not present on this build")
        exit(1)
    }
    guard let d = displays().first(where: { $0.current != 0 }) else {
        print("no current desktop")
        exit(1)
    }
    let target: UInt64? = cross
        ? displays().first(where: { $0.uuid != d.uuid })?.current
        : d.desktops.last(where: { $0 != d.current })
    guard let target else {
        print(cross ? "need a second display" : "need a second desktop on the current display: add one in Mission Control")
        exit(1)
    }

    let widFile = NSTemporaryDirectory() + "weft-bridged-\(getpid())"
    try? FileManager.default.removeItem(atPath: widFile)
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    helper.arguments = ["helper", widFile]
    try! helper.run()
    defer {
        helper.terminate()
        try? FileManager.default.removeItem(atPath: widFile)
    }

    var wid: UInt32?
    for _ in 0..<200 where wid == nil {
        usleep(10_000)
        wid = (try? String(contentsOfFile: widFile, encoding: .utf8)).flatMap {
            UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    guard let wid else {
        print("helper never reported a window")
        exit(1)
    }
    _ = waitFor(wid, on: d.current, timeout: 1)

    print("helper pid \(helper.processIdentifier), window \(wid), desktop \(d.current) -> \(target)")
    let out = moveAndCheck(wid, to: target, label: "away")
    let back = moveAndCheck(wid, to: d.current, label: "back")
    print(out && back ? "RESULT: the bridged operation moves another process's window, both ways"
          : "RESULT: refused (see rows above)")
}

func move(wid: UInt32, index: Int) {
    guard let on = spaces(of: wid).first,
          let d = displays().first(where: { $0.spaces.contains(on) })
    else {
        print("window \(wid) is on no desktop this can see")
        exit(1)
    }
    let ds = d.desktops
    guard (1...ds.count).contains(index) else {
        print("desktop \(index) out of range: display has \(ds.count)")
        exit(1)
    }
    moveAndCheck(wid, to: ds[index - 1], label: "window \(wid)")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "list": list()
case "run": run(cross: args.count > 2 && args[2] == "cross")
case "helper" where args.count > 2: runHelper(widFile: args[2])
case "move" where args.count > 3:
    guard let wid = UInt32(args[2]), let n = Int(args[3]) else { fallthrough }
    move(wid: wid, index: n)
default:
    print("usage: bridgedmove list | run [cross] | move <wid> <desktop 1-based>")
    exit(2)
}
