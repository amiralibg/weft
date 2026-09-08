import ApplicationServices
import AppKit
import Foundation
@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSGetWindowBounds") func SLSGetWindowBounds(_ c: Int32,_ w: UInt32,_ o: UnsafeMutablePointer<CGRect>) -> Int32
@_silgen_name("SLSMoveWindow") func SLSMoveWindow(_ c: Int32,_ w: UInt32,_ p: UnsafePointer<CGPoint>) -> Int32
@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ e: AXUIElement,_ o: UnsafeMutablePointer<UInt32>) -> AXError
let cid = SLSMainConnectionID()
func sls(_ w: UInt32) -> CGRect? { var r = CGRect.zero; return SLSGetWindowBounds(cid,w,&r)==0 ? r : nil }
func setAX(_ e: AXUIElement,_ p: CGPoint) { var p = p
    AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint,&p)!) }

for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
    let a = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(a, 0.5)
    var v: CFTypeRef?; AXUIElementCopyAttributeValue(a, kAXWindowsAttribute as CFString, &v)
    for e in (v as? [AXUIElement] ?? []) {
        var wid: UInt32 = 0
        guard _AXUIElementGetWindow(e,&wid) == .success, wid != 0, let b = sls(wid) else { continue }
        guard b.minX < -200 || b.minY < -200 else { continue }
        print("rescuing \(app.localizedName ?? "?") wid=\(wid) at \(b.minX),\(b.minY)")
        var home = CGPoint(x: 8, y: 48)
        SLSMoveWindow(cid, wid, &home); usleep(60_000)      // WindowServer back on-screen
        setAX(e, CGPoint(x: 60, y: 90)); usleep(60_000)      // nudge to break the AX no-op
        setAX(e, home); usleep(60_000)                       // resync to the real target
        print("   -> now \(sls(wid)!)")
    }
}
