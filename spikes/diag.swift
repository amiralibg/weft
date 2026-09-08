import ApplicationServices
import AppKit
import Foundation
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ el: AXUIElement, _ out: UnsafeMutablePointer<UInt32>) -> AXError

for app in NSWorkspace.shared.runningApplications {
    guard app.activationPolicy == .regular else { continue }
    let pid = app.processIdentifier
    let el = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(el, 1.0)
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v)
    let wins = v as? [AXUIElement] ?? []
    var widInfo: [String] = []
    for w in wins {
        var wid: UInt32 = 0
        let e = _AXUIElementGetWindow(w, &wid)
        let sub = { () -> String in
            var s: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &s)
            return s as? String ?? "-"
        }()
        widInfo.append("wid=\(wid) err=\(e.rawValue) sub=\(sub)")
    }
    print("\(app.localizedName ?? "?") pid=\(pid) copyErr=\(err.rawValue) windows=\(wins.count) \(widInfo)")
}
