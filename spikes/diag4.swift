import ApplicationServices
import AppKit
import Foundation

@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSCopyManagedDisplaySpaces") func SLSCopyManagedDisplaySpaces(_ c: Int32) -> Unmanaged<CFArray>
@_silgen_name("SLSCopySpacesForWindows") func SLSCopySpacesForWindows(_ c: Int32, _ sel: Int32, _ w: CFArray) -> Unmanaged<CFArray>
@_silgen_name("SLSManagedDisplayGetCurrentSpace") func SLSManagedDisplayGetCurrentSpace(_ c: Int32, _ u: CFString) -> UInt64

let cid = SLSMainConnectionID()

// active space per display
let displays = SLSCopyManagedDisplaySpaces(cid).takeRetainedValue() as! [[String: Any]]
var activeSpaces = Set<UInt64>()
for d in displays {
    let uuid = d["Display Identifier"] as! CFString
    let cur = SLSManagedDisplayGetCurrentSpace(cid, uuid)
    activeSpaces.insert(cur)
    let spaces = (d["Spaces"] as? [[String: Any]] ?? []).map { $0["ManagedSpaceID"] as? UInt64 ?? 0 }
    print("display \(uuid) active=\(cur) spaces=\(spaces)")
}
print()

func spacesFor(_ wid: UInt32) -> [UInt64] {
    let arr = [NSNumber(value: wid)] as CFArray
    let r = SLSCopySpacesForWindows(cid, 0x7, arr).takeRetainedValue() as? [NSNumber] ?? []
    return r.map { $0.uint64Value }
}

// candidate real windows from the WindowServer
let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var byApp: [String: [(UInt32, String, [UInt64])]] = [:]
for w in info {
    guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let h = b["Height"] as? Double ?? 0, wd = b["Width"] as? Double ?? 0
    guard h > 100, wd > 100 else { continue }          // drop 1710x39 / 64x64 / 0x0 noise
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    guard owner != "borders" else { continue }
    let wid = UInt32(w[kCGWindowNumber as String] as? Int ?? 0)
    let name = w[kCGWindowName as String] as? String ?? ""
    byApp[owner, default: []].append((wid, name, spacesFor(wid)))
}

for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(el, 2.0)
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v)
    let axN = (v as? [AXUIElement])?.count ?? 0
    let name = app.localizedName ?? "?"
    let real = byApp[name] ?? []
    let onActive = real.contains { !Set($0.2).isDisjoint(with: activeSpaces) }
    print("\(name): AX=\(axN)  WindowServer=\(real.count)  onActiveSpace=\(onActive)")
    for (wid, t, sp) in real { print("    wid=\(wid) spaces=\(sp) \(t.prefix(40))") }
}
