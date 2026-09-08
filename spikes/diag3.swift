import ApplicationServices
import AppKit
import Foundation
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ el: AXUIElement, _ out: UnsafeMutablePointer<UInt32>) -> AXError

func winCount(_ el: AXUIElement) -> Int {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v)
    return (v as? [AXUIElement])?.count ?? 0
}

for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(el, 2.0)
    let before = winCount(el)
    guard before == 0 else {
        print("\(app.localizedName ?? "?"): \(before) windows already — no poke needed")
        continue
    }
    let t0 = DispatchTime.now().uptimeNanoseconds
    let e1 = AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    let e2 = AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    let after = winCount(el)
    print(String(format: "%@: 0 -> %d windows after poke (manual=%d enhanced=%d, %.1f ms)",
                 app.localizedName ?? "?", after, e1.rawValue, e2.rawValue, dt))
}
