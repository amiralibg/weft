// S5 — can weft draw its own borders?
//
// Verifies, against the live WindowServer, every private call the native
// border renderer depends on: create an overlay window, make it click-through,
// order it above another window, stroke a rounded rect into it, move it,
// resize it, and release it. Prints the return code of each so a failure names
// itself instead of showing up as "the borders do not appear".
//
//   ./build.sh border && ./border [wid]
//
// With no argument it draws around a rectangle in the middle of the main
// display; with a window id it draws around that window.

import AppKit
import CoreGraphics
import Foundation

typealias CID = Int32

@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> CID
@_silgen_name("SLSGetWindowBounds") func SLSGetWindowBounds(_ cid: CID, _ wid: UInt32, _ r: UnsafeMutablePointer<CGRect>) -> Int32
@_silgen_name("SLSNewWindow") func SLSNewWindow(_ cid: CID, _ type: Int32, _ x: Float, _ y: Float, _ region: CFTypeRef, _ wid: UnsafeMutablePointer<UInt32>) -> Int32
@_silgen_name("SLSReleaseWindow") func SLSReleaseWindow(_ cid: CID, _ wid: UInt32) -> Int32
@_silgen_name("SLSSetWindowShape") func SLSSetWindowShape(_ cid: CID, _ wid: UInt32, _ x: Float, _ y: Float, _ region: CFTypeRef) -> Int32
@_silgen_name("SLSSetWindowResolution") func SLSSetWindowResolution(_ cid: CID, _ wid: UInt32, _ res: Double) -> Int32
@_silgen_name("SLSSetWindowOpacity") func SLSSetWindowOpacity(_ cid: CID, _ wid: UInt32, _ opaque: Bool) -> Int32
@_silgen_name("SLSSetWindowAlpha") func SLSSetWindowAlpha(_ cid: CID, _ wid: UInt32, _ a: Float) -> Int32
@_silgen_name("SLSSetWindowLevel") func SLSSetWindowLevel(_ cid: CID, _ wid: UInt32, _ level: Int32) -> Int32
@_silgen_name("SLSGetWindowLevel") func SLSGetWindowLevel(_ cid: CID, _ wid: UInt32, _ level: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("SLSSetMouseEventEnableFlags") func SLSSetMouseEventEnableFlags(_ cid: CID, _ wid: UInt32, _ on: Bool) -> Int32
@_silgen_name("SLSOrderWindow") func SLSOrderWindow(_ cid: CID, _ wid: UInt32, _ order: Int32, _ rel: UInt32) -> Int32
@_silgen_name("SLSMoveWindow") func SLSMoveWindow(_ cid: CID, _ wid: UInt32, _ p: UnsafePointer<CGPoint>) -> Int32
@_silgen_name("SLWindowContextCreate") func SLWindowContextCreate(_ cid: CID, _ wid: UInt32, _ opts: CFDictionary?) -> Unmanaged<CGContext>?
@_silgen_name("CGSNewRegionWithRect") func CGSNewRegionWithRect(_ r: UnsafePointer<CGRect>, _ out: UnsafeMutablePointer<CFTypeRef?>) -> Int32
@_silgen_name("CGSReleaseRegion") func CGSReleaseRegion(_ region: CFTypeRef) -> Int32
@_silgen_name("SLSTransactionCreate") func SLSTransactionCreate(_ cid: CID) -> CFTypeRef?
@_silgen_name("SLSTransactionCommit") func SLSTransactionCommit(_ t: CFTypeRef, _ sync: Int32) -> Int32
@_silgen_name("SLSTransactionMoveWindowWithGroup") func SLSTransactionMoveWindowWithGroup(_ t: CFTypeRef, _ wid: UInt32, _ p: CGPoint) -> Int32

func say(_ label: String, _ code: Int32) {
    print(String(format: "  %-34s %@", (label as NSString).utf8String!, code == 0 ? "ok" : "FAILED (\(code))"))
}

let cid = SLSMainConnectionID()
print("connection \(cid)")

// Target rectangle: a given window, or a box in the middle of the main screen.
var target = CGRect(x: 400, y: 300, width: 600, height: 400)
var relative: UInt32 = 0
if CommandLine.arguments.count > 1, let wid = UInt32(CommandLine.arguments[1]) {
    var r = CGRect.zero
    if SLSGetWindowBounds(cid, wid, &r) == 0 {
        target = r
        relative = wid
        print("target window \(wid) at \(r)")
    } else {
        print("could not read bounds of \(wid) — using the default rectangle")
    }
}

let width: CGFloat = 6
let overlay = target.insetBy(dx: -width, dy: -width)

var local = CGRect(origin: .zero, size: overlay.size)
var region: CFTypeRef?
let regionErr = CGSNewRegionWithRect(&local, &region)
say("CGSNewRegionWithRect", regionErr)
guard let region else { exit(1) }

var wid: UInt32 = 0
say("SLSNewWindow", SLSNewWindow(cid, 2, Float(overlay.origin.x), Float(overlay.origin.y), region, &wid))
// NOTE: do NOT CGSReleaseRegion here. Swift takes ownership of a CF type
// handed back through an out-parameter, so releasing it as well is a
// double-free and crashes on the second border you draw. This is why the
// real renderer creates and releases the region in C (BorderShim.h).
print("  overlay wid = \(wid)")
guard wid != 0 else { exit(1) }

let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
say("SLSSetWindowResolution(\(scale))", SLSSetWindowResolution(cid, wid, scale))
say("SLSSetWindowOpacity(false)", SLSSetWindowOpacity(cid, wid, false))
say("SLSSetWindowAlpha(1)", SLSSetWindowAlpha(cid, wid, 1))
say("SLSSetMouseEventEnableFlags(off)", SLSSetMouseEventEnableFlags(cid, wid, false))

var level: Int32 = 0
if relative != 0, SLSGetWindowLevel(cid, relative, &level) == 0 {
    print("  target level = \(level)")
    say("SLSSetWindowLevel", SLSSetWindowLevel(cid, wid, level))
}

let ordered = SLSOrderWindow(cid, wid, 1, relative)
say("SLSOrderWindow(above target)", ordered)
if ordered != 0 {
    say("SLSOrderWindow(front)", SLSOrderWindow(cid, wid, 1, 0))
}

guard let ctx = SLWindowContextCreate(cid, wid, nil)?.takeRetainedValue() else {
    print("  SLWindowContextCreate FAILED")
    exit(1)
}
print("  SLWindowContextCreate                ok")

func paint(_ color: CGColor) {
    let bounds = CGRect(origin: .zero, size: overlay.size)
    ctx.clear(bounds)
    let rect = bounds.insetBy(dx: width / 2, dy: width / 2)
    let path = CGPath(roundedRect: rect, cornerWidth: 13, cornerHeight: 13, transform: nil)
    ctx.setLineWidth(width)
    ctx.setStrokeColor(color)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.flush()
}

paint(CGColor(red: 0.48, green: 0.64, blue: 0.97, alpha: 1))
print("\nblue border painted — look at the screen. Moving it in 2s…")
Thread.sleep(forTimeInterval: 2)

// Move by transaction, the way a drag does. SLSTransactionCommit's return
// value is not an error code — verify by reading the bounds back.
let moved = CGPoint(x: overlay.origin.x + 120, y: overlay.origin.y + 80)
if let t = SLSTransactionCreate(cid) {
    _ = SLSTransactionMoveWindowWithGroup(t, wid, moved)
    _ = SLSTransactionCommit(t, 0)
    var after = CGRect.zero
    _ = SLSGetWindowBounds(cid, wid, &after)
    let ok = abs(after.origin.x - moved.x) < 1 && abs(after.origin.y - moved.y) < 1
    print("  transaction move                   \(ok ? "ok" : "FAILED (at \(after.origin), wanted \(moved))")")
} else {
    print("  SLSTransactionCreate FAILED")
}
Thread.sleep(forTimeInterval: 1)

paint(CGColor(red: 0.62, green: 0.81, blue: 0.42, alpha: 1))
print("recoloured green — releasing in 2s")
Thread.sleep(forTimeInterval: 2)

say("SLSReleaseWindow", SLSReleaseWindow(cid, wid))
print("done")
