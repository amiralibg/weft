// spikes/spacetype.swift — which signal says "this space is fullscreen"?
//
// weft decides with `SLSSpaceGetType(cid, sid) == 4` (WeftCore/World.swift).
// On this Mac a fullscreen video sits on space 77, and that call returns **0** —
// an ordinary desktop. So weft lays the space out, tiles the 3824×2130
// fullscreen surface on it, and draws a border around a frame twice the size of
// the display. That is the "border around everything" bug.
//
// `SLSCopyManagedDisplaySpaces` hands back a dict per space with its own keys,
// which weft currently ignores in favour of the function. If the dict disagrees
// with the function, the fix is one line.
//
//   ./build.sh spacetype
//   ./spacetype
//
// Read-only: enumerates displays, spaces and windows. Moves nothing, switches
// nothing.

import AppKit
import CoreGraphics
import Foundation

@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?
@_silgen_name("SLSSpaceGetType") func SLSSpaceGetType(_ cid: Int32, _ sid: UInt64) -> Int32
@_silgen_name("SLSGetWindowBounds")
func SLSGetWindowBounds(_ cid: Int32, _ wid: UInt32, _ out: UnsafeMutablePointer<CGRect>) -> Int32
@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?

let cid = SLSMainConnectionID()

print("=== displays (CGDisplayBounds) ===")
var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
if CGGetActiveDisplayList(16, &ids, &count) == .success {
    for id in ids.prefix(Int(count)) {
        let b = CGDisplayBounds(id)
        // Two steps, not an optional chain: inside `?.takeRetainedValue()` any
        // further member is looked up on the unwrapped CFUUID.
        var uuid = "?"
        if let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let s = CFUUIDCreateString(nil, cf) as String?
        {
            uuid = s
        }
        print(String(
            format: "  %@  x=%.0f y=%.0f w=%.0f h=%.0f", uuid.prefix(13) as CVarArg,
            b.minX, b.minY, b.width, b.height))
    }
}

print("\n=== spaces: what the dict says vs what SLSSpaceGetType says ===")
if let raw = SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] {
    for d in raw {
        let uuid = (d["Display Identifier"] as? String) ?? "?"
        print("display \(uuid.prefix(13))")
        let current = ((d["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
        for s in (d["Spaces"] as? [[String: Any]]) ?? [] {
            guard let sid = (s["id64"] as? NSNumber)?.uint64Value else { continue }
            let fromFunc = SLSSpaceGetType(cid, sid)
            // Every key the dict carries, so a signal weft is not reading shows
            // up rather than having to be guessed at.
            let keys = s.keys.sorted().map { k -> String in
                let v = s[k]
                if let n = v as? NSNumber { return "\(k)=\(n)" }
                if let str = v as? String { return "\(k)=\(str.prefix(10))" }
                if let arr = v as? [Any] { return "\(k)=[\(arr.count)]" }
                return "\(k)=<\(type(of: v ?? "nil"))>"
            }
            let mark = sid == current ? " <- current" : ""
            print("  sid \(sid)  SLSSpaceGetType=\(fromFunc)\(mark)")
            print("      dict: \(keys.joined(separator: "  "))")
        }
    }
}

print("\n=== windows larger than every display ===")
if let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]]
{
    var displays: [CGRect] = []
    for id in ids.prefix(Int(count)) { displays.append(CGDisplayBounds(id)) }
    for w in info {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let wid = (w[kCGWindowNumber as String] as? Int).map({ UInt32($0) })
        else { continue }
        var r = CGRect.zero
        guard SLSGetWindowBounds(cid, wid, &r) == 0 else { continue }
        // Bigger than any display it could sit on: nothing weft should tile.
        guard !displays.contains(where: { $0.width >= r.width && $0.height >= r.height }) else {
            continue
        }
        let owner = (w[kCGWindowOwnerName as String] as? String) ?? "?"
        let name = (w[kCGWindowName as String] as? String) ?? ""
        let spaces = (SLSCopySpacesForWindows(cid, 0x7, [NSNumber(value: wid)] as CFArray)?
            .takeRetainedValue() as? [NSNumber])?.map { $0.uint64Value } ?? []
        print(String(
            format: "  wid %u  %@  %.0fx%.0f at (%.0f, %.0f)  spaces=%@  %@",
            wid, owner as CVarArg, r.width, r.height, r.minX, r.minY,
            String(describing: spaces) as CVarArg, name.prefix(30) as CVarArg))
    }
}
