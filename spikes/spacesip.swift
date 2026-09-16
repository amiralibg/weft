// spikes/spacesip.swift — can a window reach another desktop, and can one be
// made sticky, from an ordinary connection with SIP on?
//
// weft's capability notes record exactly two probes, both from 2026-09-04:
// SLSMoveWindowsToManagedSpace is silently ignored, and the SLSSetWindowTags
// sticky bit is silently ignored. From those two results the project concluded
// it needed a scripting addition injected into Dock — which costs SIP, sudo,
// and a byte-pattern table re-derived on most macOS releases. Two functions is
// a thin basis for that, and macOS itself does both operations with SIP on:
// Dock's "Options -> Assign To -> Desktop N" and "All Desktops" are ordinary
// calls made by an ordinary process.
//
//   ./build.sh spacesip
//   ./spacesip run            every probe, one subprocess each
//   ./spacesip list           topology: which desktop is current, which target
//
// Reading the first run's results taught me more about the harness than about
// macOS, and both lessons are built in here:
//
//   - Return codes like 12255232 (0xBB0000) are not error codes, they are an
//     uninitialised x0. Those functions return void, so `rc` proves nothing
//     either way; only a re-read of the WindowServer's own answer counts.
//   - SLSProcessAssignToSpace returned 0 (success) and the window did not
//     move — but per-process assignment governs where an application's windows
//     GO, not where its open windows ARE. Verifying it against an existing
//     window asks the wrong question. Here the helper opens a *second* window
//     after the call, and that is what gets measured.
//   - Sticky was judged by space-list membership alone. Now the tag is read
//     back with SLSGetWindowTags too, which separates "the WindowServer
//     refused the tag" from "the tag stuck but membership does not reflect it".
//
// Containment, because this runs against a live WindowServer:
//   - Never touches a window you own. Each probe spawns a helper process that
//     makes its own windows, and kills it afterwards.
//   - One subprocess per probe: these are undocumented functions called
//     through hand-written signatures, so a wrong guess costs one row of the
//     table rather than the run.
//   - Never switches your desktop. The target is the last desktop on the
//     current display, and nothing here calls SLSShowSpaces, SLSHideSpaces or
//     SLSManagedDisplaySetCurrentSpace, which are the calls that would.

import AppKit
import CoreServices
import Foundation

// MARK: - SkyLight

@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?
@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?
@_silgen_name("SLSGetConnectionPSN")
func SLSGetConnectionPSN(_ cid: Int32, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
/// The window's owning connection. Several SLS calls take a connection that is
/// the *subject* rather than the caller, so it is worth asking whether the
/// WindowServer accepts from us what it would accept from the window's owner.
@_silgen_name("SLSGetWindowOwner")
func SLSGetWindowOwner(_ cid: Int32, _ wid: UInt32, _ owner: UnsafeMutablePointer<Int32>) -> Int32

@_silgen_name("SLSMoveWindowsToManagedSpace")
func SLSMoveWindowsToManagedSpace(_ cid: Int32, _ wids: CFArray, _ sid: UInt64)
@_silgen_name("SLSSetWindowTags")
func SLSSetWindowTags(_ cid: Int32, _ wid: UInt32, _ tags: UnsafeMutablePointer<UInt64>, _ size: Int32) -> Int32
@_silgen_name("SLSGetWindowTags")
func SLSGetWindowTags(_ cid: Int32, _ wid: UInt32, _ tags: UnsafeMutablePointer<UInt64>, _ size: Int32) -> Int32

@_silgen_name("SLSAddWindowsToSpaces")
func SLSAddWindowsToSpaces(_ cid: Int32, _ wids: CFArray, _ sids: CFArray)
@_silgen_name("SLSRemoveWindowsFromSpaces")
func SLSRemoveWindowsFromSpaces(_ cid: Int32, _ wids: CFArray, _ sids: CFArray)
@_silgen_name("SLSSpaceAddWindowsAndRemoveFromSpaces")
func SLSSpaceAddWindowsAndRemoveFromSpaces(_ cid: Int32, _ sid: UInt64, _ wids: CFArray, _ selector: Int32)
@_silgen_name("SLSReassociateWindowsSpacesByGeometry")
func SLSReassociateWindowsSpacesByGeometry(_ cid: Int32, _ wids: CFArray) -> Int32

@_silgen_name("SLSTransactionCreate") func SLSTransactionCreate(_ cid: Int32) -> Unmanaged<AnyObject>?
@_silgen_name("SLSTransactionCommit") func SLSTransactionCommit(_ t: AnyObject, _ sync: Int32) -> Int32
@_silgen_name("SLSTransactionMoveWindowsToManagedSpace")
func SLSTransactionMoveWindowsToManagedSpace(_ t: AnyObject, _ wids: CFArray, _ sid: UInt64)
@_silgen_name("SLSTransactionAddWindowToSpaceAndRemoveFromSpaces")
func SLSTransactionAddWindowToSpaceAndRemoveFromSpaces(
    _ t: AnyObject, _ wid: UInt32, _ add: UInt64, _ remove: CFArray)
@_silgen_name("SLSTransactionBatchReassociateWindowsToSpace")
func SLSTransactionBatchReassociateWindowsToSpace(_ t: AnyObject, _ wids: CFArray, _ sid: UInt64)
@_silgen_name("SLSTransactionSetWindowTags")
func SLSTransactionSetWindowTags(
    _ t: AnyObject, _ wid: UInt32, _ tags: UnsafeMutablePointer<UInt64>, _ size: Int32)

@_silgen_name("SLSProcessAssignToSpace")
func SLSProcessAssignToSpace(_ cid: Int32, _ psn: UnsafePointer<ProcessSerialNumber>, _ sid: UInt64) -> Int32
@_silgen_name("SLSProcessAssignToAllSpaces")
func SLSProcessAssignToAllSpaces(_ cid: Int32, _ psn: UnsafePointer<ProcessSerialNumber>) -> Int32

// The pipeline macOS drives when a window is dragged onto another desktop.
// Signatures are guesses from the names; each runs in its own process.
@_silgen_name("SLSPackagesAddWindowToDraggingSpace")
func SLSPackagesAddWindowToDraggingSpace(_ cid: Int32, _ wid: UInt32) -> Int32
@_silgen_name("SLSPackagesAssignDraggedWindowToDestinationSpace")
func SLSPackagesAssignDraggedWindowToDestinationSpace(_ cid: Int32, _ wid: UInt32, _ sid: UInt64) -> Int32
@_silgen_name("SLSPackagesRemoveWindowFromDraggingSpace")
func SLSPackagesRemoveWindowFromDraggingSpace(_ cid: Int32, _ wid: UInt32) -> Int32

/// Space ownership. If a space will take us as an owner, the calls that refuse
/// us may stop refusing.
@_silgen_name("SLSSpaceAddOwner") func SLSSpaceAddOwner(_ cid: Int32, _ sid: UInt64, _ owner: Int32) -> Int32
@_silgen_name("SLSSpaceSetOwners")
func SLSSpaceSetOwners(_ cid: Int32, _ sid: UInt64, _ owners: CFArray) -> Int32

@_silgen_name("SLSDesktopTagBitModificationIsSupported")
func SLSDesktopTagBitModificationIsSupported(_ cid: Int32) -> Bool

/// The tag bit that means "on every desktop".
let stickyTag: UInt64 = 1 << 11

let cid = SLSMainConnectionID()

func spaces(of wid: UInt32) -> [UInt64] {
    let arr = [NSNumber(value: wid)] as CFArray
    guard let r = SLSCopySpacesForWindows(cid, 0x7, arr)?.takeRetainedValue() as? [NSNumber] else {
        return []
    }
    return r.map { $0.uint64Value }
}

func tags(of wid: UInt32) -> UInt64 {
    var t: UInt64 = 0
    _ = SLSGetWindowTags(cid, wid, &t, 64)
    return t
}

func ownerCID(of wid: UInt32) -> Int32 {
    var owner: Int32 = 0
    _ = SLSGetWindowOwner(cid, wid, &owner)
    return owner
}

struct Display {
    let uuid: String
    let spaces: [UInt64]
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
        let cur = ((d["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value ?? 0
        return Display(
            uuid: uuid,
            spaces: list.compactMap { ($0["id64"] as? NSNumber)?.uint64Value },
            current: cur
        )
    }
}

/// The last desktop on the current display: desktops are created left to right
/// and the rightmost is usually empty. Nothing depends on it being empty — a
/// helper window lands there for a moment and the helper is killed — so this
/// picks rather than searches, instead of claiming a certainty the WindowServer
/// will not sell us (no call lists a space's windows without walking them all).
func targetSpace() -> (current: UInt64, target: UInt64)? {
    guard let d = displays().first(where: { $0.current != 0 }) else { return nil }
    guard let last = d.spaces.last(where: { $0 != d.current }) else { return nil }
    return (d.current, last)
}

// MARK: - Helper process
//
// A window of our own making, in a process of its own, so every probe acts on
// something disposable. From the WindowServer's side this is another
// application's window exactly as Safari's is: its own connection, its own PSN.
//
// It opens a second window on SIGUSR1. That is what makes per-process
// assignment measurable: the question those calls answer is where the app's
// NEXT window goes, so a probe assigns, asks for a new window, and reads where
// that one landed. Window ids are written to a file rather than a pipe because
// the probe that needs them is a different process from the one that spawned
// the helper.

func runHelper(regular: Bool, widFile: String) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(regular ? .regular : .accessory)
    var made = 0

    func makeWindow() {
        made += 1
        let w = NSWindow(
            contentRect: NSRect(x: 200 + made * 40, y: 200, width: 420, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        w.title = "weft space probe \(made)"
        w.orderFrontRegardless()
        // Leaked deliberately: the helper is killed outright, and a window the
        // probe is still asking about must not be torn down underneath it.
        Unmanaged.passRetained(w)
        if let h = FileHandle(forWritingAtPath: widFile) {
            h.seekToEndOfFile()
            h.write("\(made) \(w.windowNumber)\n".data(using: .utf8)!)
            try? h.close()
        }
    }

    FileManager.default.createFile(atPath: widFile, contents: nil)
    makeWindow()

    let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    src.setEventHandler { makeWindow() }
    src.resume()
    signal(SIGUSR1, SIG_IGN)  // the DispatchSource is the handler now

    var psn = ProcessSerialNumber()
    _ = SLSGetConnectionPSN(SLSMainConnectionID(), &psn)
    print("PSN \(psn.highLongOfPSN) \(psn.lowLongOfPSN)")
    fflush(stdout)
    app.run()
    exit(0)
}

/// Window ids the helper has announced, as { index: wid }.
func readWIDs(_ path: String) -> [Int: UInt32] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var out: [Int: UInt32] = [:]
    for line in text.split(separator: "\n") {
        let p = line.split(separator: " ")
        if p.count == 2, let i = Int(p[0]), let w = UInt32(p[1]) { out[i] = w }
    }
    return out
}

// MARK: - Probes

enum Want {
    /// The window itself must end up on the target desktop.
    case move
    /// The window must report more than one desktop, or carry the sticky tag.
    case sticky
    /// A window opened *after* the call must land on the target desktop.
    case assignSpace
    /// A window opened after the call must report more than one desktop.
    case assignAll
}

struct Probe {
    let name: String
    let want: Want
    /// The per-process calls are about an application, and an accessory
    /// process is not one in the sense Dock's menu means.
    let regular: Bool
    let run: (UInt32, UInt64, UInt64, ProcessSerialNumber) -> String
}

let probes: [Probe] = [
    // The control. weft already records this as silently ignored; a run where
    // it passes means the machine changed, not the API.
    Probe(name: "SLSMoveWindowsToManagedSpace", want: .move, regular: false) { wid, _, target, _ in
        SLSMoveWindowsToManagedSpace(cid, [NSNumber(value: wid)] as CFArray, target)
        return "void"
    },
    Probe(name: "SLSMoveWindowsToManagedSpace(owner cid)", want: .move, regular: false) { wid, _, target, _ in
        let owner = ownerCID(of: wid)
        SLSMoveWindowsToManagedSpace(owner, [NSNumber(value: wid)] as CFArray, target)
        return "owner=\(owner)"
    },
    Probe(name: "SLSAddWindowsToSpaces + Remove", want: .move, regular: false) { wid, current, target, _ in
        let w = [NSNumber(value: wid)] as CFArray
        SLSAddWindowsToSpaces(cid, w, [NSNumber(value: target)] as CFArray)
        SLSRemoveWindowsFromSpaces(cid, w, [NSNumber(value: current)] as CFArray)
        return "void,void"
    },
    Probe(name: "SLSSpaceAddWindowsAndRemoveFromSpaces", want: .move, regular: false) { wid, _, target, _ in
        SLSSpaceAddWindowsAndRemoveFromSpaces(cid, target, [NSNumber(value: wid)] as CFArray, 0x7)
        return "void"
    },
    Probe(name: "SLSTransactionMoveWindowsToManagedSpace", want: .move, regular: false) { wid, _, target, _ in
        guard let t = SLSTransactionCreate(cid)?.takeRetainedValue() else { return "no transaction" }
        SLSTransactionMoveWindowsToManagedSpace(t, [NSNumber(value: wid)] as CFArray, target)
        return "commit=\(SLSTransactionCommit(t, 1))"
    },
    Probe(name: "SLSTransactionAddWindowToSpaceAndRemove", want: .move, regular: false) { wid, current, target, _ in
        guard let t = SLSTransactionCreate(cid)?.takeRetainedValue() else { return "no transaction" }
        SLSTransactionAddWindowToSpaceAndRemoveFromSpaces(
            t, wid, target, [NSNumber(value: current)] as CFArray)
        return "commit=\(SLSTransactionCommit(t, 1))"
    },
    Probe(name: "SLSTransactionBatchReassociateWindowsToSpace", want: .move, regular: false) { wid, _, target, _ in
        guard let t = SLSTransactionCreate(cid)?.takeRetainedValue() else { return "no transaction" }
        SLSTransactionBatchReassociateWindowsToSpace(t, [NSNumber(value: wid)] as CFArray, target)
        return "commit=\(SLSTransactionCommit(t, 1))"
    },
    Probe(name: "SLSSpaceAddOwner then move", want: .move, regular: false) { wid, _, target, _ in
        let rc = SLSSpaceAddOwner(cid, target, cid)
        let rc2 = SLSSpaceSetOwners(cid, target, [NSNumber(value: cid)] as CFArray)
        SLSMoveWindowsToManagedSpace(cid, [NSNumber(value: wid)] as CFArray, target)
        return "addOwner=\(rc) setOwners=\(rc2)"
    },
    Probe(name: "SLSPackages drag pipeline", want: .move, regular: false) { wid, _, target, _ in
        let a = SLSPackagesAddWindowToDraggingSpace(cid, wid)
        let b = SLSPackagesAssignDraggedWindowToDestinationSpace(cid, wid, target)
        let c = SLSPackagesRemoveWindowFromDraggingSpace(cid, wid)
        return "add=\(a) assign=\(b) remove=\(c)"
    },
    Probe(name: "SLSReassociateWindowsSpacesByGeometry", want: .move, regular: false) { wid, _, _, _ in
        "rc=\(SLSReassociateWindowsSpacesByGeometry(cid, [NSNumber(value: wid)] as CFArray))"
    },

    // Sticky.
    Probe(name: "SLSSetWindowTags(sticky)", want: .sticky, regular: false) { wid, _, _, _ in
        var t = stickyTag
        let rc = SLSSetWindowTags(cid, wid, &t, 64)
        return "rc=\(rc) supported=\(SLSDesktopTagBitModificationIsSupported(cid))"
    },
    Probe(name: "SLSSetWindowTags(sticky, owner cid)", want: .sticky, regular: false) { wid, _, _, _ in
        var t = stickyTag
        let owner = ownerCID(of: wid)
        return "rc=\(SLSSetWindowTags(owner, wid, &t, 64)) owner=\(owner)"
    },
    Probe(name: "SLSTransactionSetWindowTags(sticky)", want: .sticky, regular: false) { wid, _, _, _ in
        guard let t = SLSTransactionCreate(cid)?.takeRetainedValue() else { return "no transaction" }
        var bits = stickyTag
        SLSTransactionSetWindowTags(t, wid, &bits, 64)
        return "commit=\(SLSTransactionCommit(t, 1))"
    },
    Probe(name: "SLSAddWindowsToSpaces(every desktop)", want: .sticky, regular: false) { wid, _, _, _ in
        let all = displays().flatMap(\.spaces).map { NSNumber(value: $0) } as CFArray
        SLSAddWindowsToSpaces(cid, [NSNumber(value: wid)] as CFArray, all)
        return "void"
    },

    // Per-process assignment, measured against a window opened afterwards.
    Probe(name: "SLSProcessAssignToSpace", want: .assignSpace, regular: true) { _, _, target, psn in
        var p = psn
        return "rc=\(withUnsafePointer(to: &p) { SLSProcessAssignToSpace(cid, $0, target) })"
    },
    Probe(name: "SLSProcessAssignToAllSpaces", want: .assignAll, regular: true) { _, _, _, psn in
        var p = psn
        return "rc=\(withUnsafePointer(to: &p) { SLSProcessAssignToAllSpaces(cid, $0) })"
    },
]

// MARK: - Modes

let args = Array(CommandLine.arguments.dropFirst())
let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path

if args.first == "helper", args.count >= 3 {
    runHelper(regular: args[1] == "regular", widFile: args[2])
}

if args.first == "list" {
    for d in displays() {
        print("display \(d.uuid)")
        for s in d.spaces { print("  space \(s)\(s == d.current ? "  <- current" : "")") }
    }
    if let (c, t) = targetSpace() { print("\ncurrent \(c) -> target \(t)") }
    exit(0)
}

if args.first == "probe", args.count >= 8 {
    guard let p = probes.first(where: { $0.name == args[1] }),
          let wid = UInt32(args[2]), let current = UInt64(args[3]), let target = UInt64(args[4]),
          let hi = UInt32(args[5]), let lo = UInt32(args[6]), let helperPID = Int32(args[7]),
          args.count >= 9
    else {
        print("bad probe invocation")
        exit(2)
    }
    let widFile = args[8]
    let psn = ProcessSerialNumber(highLongOfPSN: hi, lowLongOfPSN: lo)
    let before = spaces(of: wid)
    let detail = p.run(wid, current, target, psn)
    // The WindowServer answers asynchronously; weft's own verify path waits
    // 150ms for the same reason.
    usleep(200_000)

    var subject = wid
    var note = ""
    if p.want == .assignSpace || p.want == .assignAll {
        // Ask the helper for a window opened *after* the assignment: that is
        // the one the call claims to govern.
        kill(helperPID, SIGUSR1)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, readWIDs(widFile)[2] == nil { usleep(50_000) }
        guard let second = readWIDs(widFile)[2] else {
            print("RESULT no | \(detail) | helper never opened a second window")
            exit(0)
        }
        usleep(300_000)
        subject = second
        note = " second-window=\(second)"
    }

    let after = spaces(of: subject)
    let tagged = tags(of: subject) & stickyTag != 0
    let ok: Bool
    switch p.want {
    case .move: ok = after.contains(target) && !after.contains(current)
    case .sticky: ok = after.count > 1 || tagged
    case .assignSpace: ok = after.contains(target)
    case .assignAll: ok = after.count > 1 || tagged
    }
    print(
        "RESULT \(ok ? "YES" : "no") | \(detail) | before=\(before) after=\(after) "
            + "stickyTag=\(tagged)\(note)")
    exit(0)
}

// MARK: - Runner

guard args.first == "run" || args.isEmpty else {
    print("usage: spacesip <run|list>")
    exit(2)
}

guard let (current, target) = targetSpace() else {
    print("need at least two desktops on one display")
    exit(1)
}
print("current desktop \(current), target desktop \(target)\n")

func startHelper(regular: Bool, widFile: String) -> (Process, UInt32, ProcessSerialNumber)? {
    try? FileManager.default.removeItem(atPath: widFile)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: selfPath)
    p.arguments = ["helper", regular ? "regular" : "accessory", widFile]
    let pipe = Pipe()
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return nil }

    var text = ""
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if let first = readWIDs(widFile)[1] {
            let d = pipe.fileHandleForReading.availableData
            text += String(data: d, encoding: .utf8) ?? ""
            if let psnLine = text.split(separator: "\n").first(where: { $0.hasPrefix("PSN ") }) {
                let parts = psnLine.dropFirst(4).split(separator: " ")
                let psn = ProcessSerialNumber(
                    highLongOfPSN: UInt32(parts.first ?? "0") ?? 0,
                    lowLongOfPSN: UInt32(parts.count > 1 ? parts[1] : "0") ?? 0
                )
                usleep(300_000)  // let the window settle onto a space
                return (p, first, psn)
            }
        }
        usleep(20_000)
    }
    p.terminate()
    return nil
}

var results: [(String, String, String)] = []
let widFile = NSTemporaryDirectory() + "weft-spacesip-wids"

for probe in probes {
    guard let (helper, wid, psn) = startHelper(regular: probe.regular, widFile: widFile) else {
        results.append((probe.name, "SKIP", "helper did not start"))
        print(probe.name.padding(toLength: 46, withPad: " ", startingAt: 0) + " SKIP")
        continue
    }

    let child = Process()
    child.executableURL = URL(fileURLWithPath: selfPath)
    child.arguments = [
        "probe", probe.name, String(wid), String(current), String(target),
        String(psn.highLongOfPSN), String(psn.lowLongOfPSN),
        String(helper.processIdentifier), widFile,
    ]
    let out = Pipe()
    child.standardOutput = out
    child.standardError = out
    var text = ""
    if (try? child.run()) != nil {
        let data = out.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        text = String(data: data, encoding: .utf8) ?? ""
    }
    helper.terminate()

    if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("RESULT ") }) {
        let body = String(line.dropFirst("RESULT ".count))
        let verdict = body.hasPrefix("YES") ? "YES" : "no"
        results.append((probe.name, verdict, String(body.dropFirst(verdict.count + 3))))
    } else if child.terminationStatus != 0 {
        // A signal here is the expected cost of calling an undocumented
        // function through a guessed signature, and is why each probe is its
        // own process rather than a line in this one.
        results.append((probe.name, "CRASH", "signal \(child.terminationStatus)"))
    } else {
        results.append((probe.name, "??", text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    print(
        results.last!.0.padding(toLength: 46, withPad: " ", startingAt: 0) + " "
            + results.last!.1)
}

print("\n" + String(repeating: "─", count: 96))
print("MOVE a window to another desktop, and STICKY, from an ordinary connection (SIP on)")
print(String(repeating: "─", count: 96))
for (name, verdict, detail) in results {
    print(
        name.padding(toLength: 46, withPad: " ", startingAt: 0) + " "
            + verdict.padding(toLength: 6, withPad: " ", startingAt: 0) + detail)
}
let wins = results.filter { $0.1 == "YES" }.map(\.0)
print(
    "\n"
        + (wins.isEmpty
            ? "nothing worked from an ordinary connection"
            : "works with SIP on: \(wins.joined(separator: ", "))"))
