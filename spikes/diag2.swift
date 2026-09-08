import AppKit
import Foundation

let opts: CGWindowListOption = [.excludeDesktopElements]
let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
print("CGWindowList (layer 0, named) — ground truth:")
for w in info {
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    guard layer == 0 else { continue }
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let wid = w[kCGWindowNumber as String] as? Int ?? 0
    let name = w[kCGWindowName as String] as? String ?? ""
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
    let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    print(String(format: "  wid=%-6d %-18s onscreen=%-5s alpha=%.1f %.0fx%.0f  %@",
                 wid, (owner as NSString).utf8String!, (String(onscreen) as NSString).utf8String!,
                 alpha, b["Width"] as? Double ?? 0, b["Height"] as? Double ?? 0,
                 String(name.prefix(30))))
}
