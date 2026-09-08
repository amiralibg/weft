import AppKit
@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSGetWindowBounds") func SLSGetWindowBounds(_ c: Int32,_ w: UInt32,_ o: UnsafeMutablePointer<CGRect>) -> Int32
let cid = SLSMainConnectionID()
for w in CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] ?? [] {
    guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
    let b = w[kCGWindowBounds as String] as? [String:Any] ?? [:]
    guard (b["Width"] as? Double ?? 0) > 200, (b["Height"] as? Double ?? 0) > 200 else { continue }
    let o = w[kCGWindowOwnerName as String] as? String ?? "?"
    guard o != "borders" else { continue }
    var r = CGRect.zero; SLSGetWindowBounds(cid, UInt32(w[kCGWindowNumber as String] as? Int ?? 0), &r)
    print("\(o.padding(toLength:16,withPad:" ",startingAt:0)) \(r)")
}
