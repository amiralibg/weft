import ApplicationServices
import AppKit
import Foundation
@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSGetWindowBounds") func SLSGetWindowBounds(_ c: Int32,_ w: UInt32,_ o: UnsafeMutablePointer<CGRect>) -> Int32
@_silgen_name("SLSMoveWindow") func SLSMoveWindow(_ c: Int32,_ w: UInt32,_ p: UnsafePointer<CGPoint>) -> Int32
@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ e: AXUIElement,_ o: UnsafeMutablePointer<UInt32>) -> AXError
let cid = SLSMainConnectionID()
func sls(_ w: UInt32) -> CGRect? { var r = CGRect.zero; return SLSGetWindowBounds(cid,w,&r)==0 ? r : nil }
func axPos(_ e: AXUIElement) -> CGPoint {
    var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &v)
    var p = CGPoint.zero; if let v { AXValueGetValue(v as! AXValue, .cgPoint, &p) }; return p
}
func setAX(_ e: AXUIElement, _ p: CGPoint) { var p = p
    AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint,&p)!) }

// find the one AX-reachable window on the active space
var target: (UInt32, AXUIElement, String)? = nil
for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
    let a = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(a, 0.3)
    var v: CFTypeRef?; AXUIElementCopyAttributeValue(a, kAXWindowsAttribute as CFString, &v)
    for e in (v as? [AXUIElement] ?? []) {
        var wid: UInt32 = 0
        guard _AXUIElementGetWindow(e,&wid) == .success, wid != 0, let b = sls(wid),
              b.width > 200, b.height > 200 else { continue }
        target = (wid, e, app.localizedName ?? "?")
    }
}
guard let (wid, el, name) = target, let orig = sls(wid) else { print("no target"); exit(1) }
print("target: \(name) wid=\(wid) orig=\(orig)\n")

print("— A. does SLSMoveWindow desync the app's own AX frame? —")
for x in [500.0, 900.0, 200.0] {
    var p = CGPoint(x: x, y: orig.minY)
    SLSMoveWindow(cid, wid, &p); usleep(80_000)
    let s = sls(wid)!.minX, a = axPos(el).x
    print(String(format: "   requested %.0f -> SkyLight %.0f, AX %.0f  %@",
                 x, s, a, abs(s-a) < 2 ? "IN SYNC" : "*** DESYNC ***"))
}
setAX(el, orig.origin); usleep(80_000)

print("\n— B. does SLSMoveWindow bypass the AX off-screen clamp? —")
for x in [-2000.0, -5000.0, -20000.0] {
    var p = CGPoint(x: x, y: orig.minY)
    SLSMoveWindow(cid, wid, &p); usleep(80_000)
    let s = sls(wid)!.minX
    print(String(format: "   park %-8.0f -> SkyLight %-10.0f %@", x, s,
                 abs(s-x) < 2 ? "OK not clamped" : "CLAMPED"))
}
setAX(el, orig.origin); usleep(80_000)
print("\n   restored -> \(sls(wid)!.minX)")
