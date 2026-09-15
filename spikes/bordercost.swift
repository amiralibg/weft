// spikes/bordercost.swift — what does a border cost the compositor, drawn which way?
//
// The in-process renderer removed in 0.7.4 cost +15.8pp of GPU. Its bisect
// found the cost was not painting but *being in the window stack*: one
// full-window transparent overlay per window, which the compositor blends
// over every frame the app underneath draws. This measures shapes that keep
// the border out of the window's area entirely, against the old overlay,
// against JankyBorders, and against nothing.
//
//   ./build.sh bordercost
//   ./bordercost show <full|ring|strips> [seconds]   draw one, to look at it
//   ./bordercost run [cycles] [hold-seconds]          the measurement
//
// Every variant draws the same picture: a 2pt rounded ring just outside every
// on-screen window, in one colour. JankyBorders gets the same width and colour
// for active and inactive, so all five conditions put the same pixels up.
//
// Conditions are shuffled within each cycle and compared per cycle against
// that cycle's "none", so background GPU load that drifts over minutes cancels.

import AppKit
import CoreGraphics
import Foundation
import IOKit

typealias CID = Int32

@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> CID
@_silgen_name("SLSNewWindow") func SLSNewWindow(_ cid: CID, _ type: Int32, _ x: Float, _ y: Float, _ region: CFTypeRef, _ wid: UnsafeMutablePointer<UInt32>) -> Int32
@_silgen_name("SLSReleaseWindow") func SLSReleaseWindow(_ cid: CID, _ wid: UInt32) -> Int32
@_silgen_name("SLSSetWindowResolution") func SLSSetWindowResolution(_ cid: CID, _ wid: UInt32, _ res: Double) -> Int32
@_silgen_name("SLSSetWindowOpacity") func SLSSetWindowOpacity(_ cid: CID, _ wid: UInt32, _ opaque: Bool) -> Int32
@_silgen_name("SLSSetWindowTags") func SLSSetWindowTags(_ cid: CID, _ wid: UInt32, _ tags: UnsafeMutablePointer<UInt64>, _ size: Int32) -> Int32
@_silgen_name("SLSSetWindowLevel") func SLSSetWindowLevel(_ cid: CID, _ wid: UInt32, _ level: Int32) -> Int32
@_silgen_name("SLSGetWindowLevel") func SLSGetWindowLevel(_ cid: CID, _ wid: UInt32, _ level: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("SLSOrderWindow") func SLSOrderWindow(_ cid: CID, _ wid: UInt32, _ order: Int32, _ rel: UInt32) -> Int32
@_silgen_name("SLWindowContextCreate") func SLWindowContextCreate(_ cid: CID, _ wid: UInt32, _ opts: CFDictionary?) -> Unmanaged<CGContext>?
@_silgen_name("CGSNewRegionWithRect") func CGSNewRegionWithRect(_ r: UnsafePointer<CGRect>, _ out: UnsafeMutablePointer<CFTypeRef?>) -> Int32
@_silgen_name("CGSNewRegionWithRectList") func CGSNewRegionWithRectList(_ r: UnsafePointer<CGRect>, _ count: Int32, _ out: UnsafeMutablePointer<CFTypeRef?>) -> Int32

let cid = SLSMainConnectionID()
let strokeWidth: CGFloat = 2
let cornerRadius: CGFloat = 16
let color = CGColor(red: 0x7a / 255.0, green: 0xa2 / 255.0, blue: 0xf7 / 255.0, alpha: 1)
let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)

// MARK: - Targets

struct Target { let wid: UInt32; let frame: CGRect }

func targets() -> [Target] {
    let me = ProcessInfo.processInfo.processIdentifier
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return info.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
              (w[kCGWindowOwnerName as String] as? String) != "borders",
              let n = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? [String: Double],
              let width = b["Width"], let height = b["Height"], width > 100, height > 100
        else { return nil }
        return Target(wid: UInt32(n), frame: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: width, height: height))
    }
}

// MARK: - Drawing

/// Our own window at `frame` (global, top-left origin), shaped to `shape`
/// (window-local rects), ordered directly above `above`.
func makeWindow(frame: CGRect, shape: [CGRect], opaque: Bool, above: UInt32) -> (UInt32, CGContext)? {
    var region: CFTypeRef?
    // Swift owns a region handed back through an out-parameter; never release it.
    _ = shape.withUnsafeBufferPointer { CGSNewRegionWithRectList($0.baseAddress!, Int32(shape.count), &region) }
    guard let region else { return nil }
    var wid: UInt32 = 0
    guard SLSNewWindow(cid, 2, Float(frame.minX), Float(frame.minY), region, &wid) == 0, wid != 0 else { return nil }
    _ = SLSSetWindowResolution(cid, wid, scale)
    var tags: UInt64 = (1 << 1) | (1 << 9)  // out of hit testing
    _ = SLSSetWindowTags(cid, wid, &tags, 64)
    _ = SLSSetWindowOpacity(cid, wid, opaque)
    var level: Int32 = 0
    if SLSGetWindowLevel(cid, above, &level) == 0 { _ = SLSSetWindowLevel(cid, wid, level) }
    guard let ctx = SLWindowContextCreate(cid, wid, nil)?.takeRetainedValue() else {
        _ = SLSReleaseWindow(cid, wid)
        return nil
    }
    return (wid, ctx)
}

func order(_ wid: UInt32, above: UInt32) {
    if SLSOrderWindow(cid, wid, 1, above) != 0 { _ = SLSOrderWindow(cid, wid, 1, 0) }
}

/// Stroke the ring as it sits in the whole overlay (size `overlay`), seen
/// through a window whose top-left is at `origin` inside it.
func strokeRing(_ ctx: CGContext, overlay: CGSize, windowRect: CGRect) {
    ctx.clear(CGRect(origin: .zero, size: windowRect.size))
    ctx.saveGState()
    // Quartz is bottom-left: the window's bottom sits at overlay height - maxY.
    ctx.translateBy(x: -windowRect.minX, y: -(overlay.height - windowRect.maxY))
    let inset = strokeWidth / 2
    let rect = CGRect(origin: .zero, size: overlay).insetBy(dx: inset, dy: inset)
    let r = cornerRadius + inset
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.setLineWidth(strokeWidth)
    ctx.setStrokeColor(color)
    ctx.strokePath()
    ctx.restoreGState()
    ctx.flush()
}

enum Variant: String, CaseIterable { case none, full, ring, strips, janky }

var ours: [UInt32] = []
var contexts: [CGContext] = []  // kept alive while shown
var janky: Process?

func show(_ v: Variant) {
    let w = strokeWidth
    for t in targets() {
        let outer = t.frame.insetBy(dx: -w, dy: -w)
        let size = outer.size
        let c = cornerRadius + w  // corner square side
        switch v {
        case .none, .janky:
            break
        case .full:
            // What 0.7.4 removed: the whole rectangle, transparent in the middle.
            let local = CGRect(origin: .zero, size: size)
            if let (wid, ctx) = makeWindow(frame: outer, shape: [local], opaque: false, above: t.wid) {
                strokeRing(ctx, overlay: size, windowRect: local)
                order(wid, above: t.wid)
                ours.append(wid); contexts.append(ctx)
            }
        case .ring:
            // One window, shaped to the ring: two full-width bands, two side
            // bands. The corners' rounding lives inside the bands.
            let shape = [
                CGRect(x: 0, y: 0, width: size.width, height: c),
                CGRect(x: 0, y: size.height - c, width: size.width, height: c),
                CGRect(x: 0, y: c, width: w, height: size.height - 2 * c),
                CGRect(x: size.width - w, y: c, width: w, height: size.height - 2 * c),
            ]
            if let (wid, ctx) = makeWindow(frame: outer, shape: shape, opaque: false, above: t.wid) {
                strokeRing(ctx, overlay: size, windowRect: CGRect(origin: .zero, size: size))
                order(wid, above: t.wid)
                ours.append(wid); contexts.append(ctx)
            }
        case .strips:
            // Four opaque strips (no blending, tiny stores) and four small
            // transparent corner pieces that carry the rounding.
            let pieces: [(CGRect, Bool)] = [
                (CGRect(x: c, y: 0, width: size.width - 2 * c, height: w), true),
                (CGRect(x: c, y: size.height - w, width: size.width - 2 * c, height: w), true),
                (CGRect(x: 0, y: c, width: w, height: size.height - 2 * c), true),
                (CGRect(x: size.width - w, y: c, width: w, height: size.height - 2 * c), true),
                (CGRect(x: 0, y: 0, width: c, height: c), false),
                (CGRect(x: size.width - c, y: 0, width: c, height: c), false),
                (CGRect(x: 0, y: size.height - c, width: c, height: c), false),
                (CGRect(x: size.width - c, y: size.height - c, width: c, height: c), false),
            ]
            for (piece, opaque) in pieces where piece.width > 0 && piece.height > 0 {
                let global = piece.offsetBy(dx: outer.minX, dy: outer.minY)
                let local = CGRect(origin: .zero, size: piece.size)
                guard let (wid, ctx) = makeWindow(frame: global, shape: [local], opaque: opaque, above: t.wid) else { continue }
                if opaque {
                    ctx.setFillColor(color)
                    ctx.fill(local)
                    ctx.flush()
                } else {
                    strokeRing(ctx, overlay: size, windowRect: piece)
                }
                order(wid, above: t.wid)
                ours.append(wid); contexts.append(ctx)
            }
        }
    }
    if v == .janky {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/borders")
        p.arguments = ["width=2.0", "style=round", "hidpi=on", "active_color=0xff7aa2f7", "inactive_color=0xff7aa2f7"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        janky = p
    }
}

func hide() {
    for wid in ours { _ = SLSReleaseWindow(cid, wid) }
    ours = []
    contexts = []
    if let p = janky {
        p.terminate()
        p.waitUntilExit()
        janky = nil
    }
}

// MARK: - Measuring

func gpuUtilisation() -> Double? {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iter) }
    var best: Double?
    while case let service = IOIteratorNext(iter), service != 0 {
        defer { IOObjectRelease(service) }
        if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any],
           let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
            best = max(best ?? 0, u)
        }
    }
    return best
}

func windowServerCPUSeconds() -> Double {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "cputime=", "-p", "\(windowServerPID)"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // [[hh:]mm:]ss.cc
    return text.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
}

let windowServerPID: Int32 = {
    NSWorkspace.shared.runningApplications.first { $0.localizedName == "WindowServer" }?.processIdentifier
        ?? Int32(String(decoding: {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-x", "WindowServer"]
            let pipe = Pipe()
            p.standardOutput = pipe
            try? p.run()
            p.waitUntilExit()
            return pipe.fileHandleForReading.readDataToEndOfFile()
        }(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}()

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return .nan }
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}

struct Sample { var gpu: Double; var wsCPU: Double; var windows: Int; var footprint: Double }

func measure(_ v: Variant, hold: TimeInterval) -> Sample {
    let baseFootprint = footprintMB()
    show(v)
    let windows = ours.count
    pump(3)  // settle: creation and first paint are not steady state
    let footprint = footprintMB() - baseFootprint
    let ws0 = windowServerCPUSeconds()
    var gpu: [Double] = []
    let end = Date(timeIntervalSinceNow: hold)
    while Date() < end {
        if let u = gpuUtilisation() { gpu.append(u) }
        pump(0.25)
    }
    let ws = (windowServerCPUSeconds() - ws0) / hold * 100
    hide()
    pump(2)
    return Sample(gpu: median(gpu), wsCPU: ws, windows: windows, footprint: footprint)
}

// MARK: - CLI

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "show":
    guard args.count >= 2, let v = Variant(rawValue: args[1]) else {
        print("usage: bordercost show <full|ring|strips|janky> [seconds]"); exit(2)
    }
    show(v)
    print("\(v.rawValue): \(ours.count) window(s) around \(targets().count) target(s)")
    pump(Double(args.count > 2 ? args[2] : "") ?? 5)
    hide()
case "run":
    let cycles = Int(args.count > 1 ? args[1] : "") ?? 5
    let hold = Double(args.count > 2 ? args[2] : "") ?? 12
    print("targets \(targets().count), cycles \(cycles), hold \(Int(hold)) s, WindowServer pid \(windowServerPID)")
    var results: [Variant: [Sample]] = [:]
    var deltas: [Variant: [Double]] = [:]
    var wsDeltas: [Variant: [Double]] = [:]
    for cycle in 1...cycles {
        var cycleResults: [Variant: Sample] = [:]
        for v in Variant.allCases.shuffled() {
            let s = measure(v, hold: hold)
            cycleResults[v] = s
            results[v, default: []].append(s)
            print(String(format: "cycle %d %-6@ gpu %5.1f%%  WindowServer %5.1f%% cpu  windows %3d  +%.1f MB",
                         cycle, v.rawValue, s.gpu, s.wsCPU, s.windows, s.footprint))
        }
        let base = cycleResults[.none]!
        for v in Variant.allCases where v != .none {
            deltas[v, default: []].append(cycleResults[v]!.gpu - base.gpu)
            wsDeltas[v, default: []].append(cycleResults[v]!.wsCPU - base.wsCPU)
        }
    }
    print("\npaired against none, per cycle (mean ± sd, t):")
    for v in Variant.allCases where v != .none {
        func summary(_ d: [Double]) -> String {
            let mean = d.reduce(0, +) / Double(d.count)
            let sd = d.count > 1 ? sqrt(d.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(d.count - 1)) : 0
            let t = sd > 0 ? mean / (sd / sqrt(Double(d.count))) : 0
            return String(format: "%+5.1f ± %4.1f (t=%5.2f)", mean, sd, t)
        }
        let s = results[v]!
        print(String(format: "%-6@ gpu %@ pp   WindowServer %@ pp cpu   median windows %d   +%.1f MB",
                     v.rawValue, summary(deltas[v]!), summary(wsDeltas[v]!),
                     Int(median(s.map { Double($0.windows) })), median(s.map(\.footprint))))
    }
default:
    print("usage: bordercost [show <variant> [seconds] | run [cycles] [hold-seconds]]")
    exit(2)
}
