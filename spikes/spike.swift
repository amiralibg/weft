import ApplicationServices
import AppKit
import Foundation

@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSGetWindowBounds") func SLSGetWindowBounds(_ c: Int32, _ w: UInt32, _ o: UnsafeMutablePointer<CGRect>) -> Int32
@_silgen_name("SLSMoveWindow") func SLSMoveWindow(_ c: Int32, _ w: UInt32, _ p: UnsafePointer<CGPoint>) -> Int32
@_silgen_name("SLSCopySpacesForWindows") func SLSCopySpacesForWindows(_ c: Int32, _ s: Int32, _ w: CFArray) -> Unmanaged<CFArray>
@_silgen_name("SLSCopyManagedDisplaySpaces") func SLSCopyManagedDisplaySpaces(_ c: Int32) -> Unmanaged<CFArray>
@_silgen_name("SLSManagedDisplayGetCurrentSpace") func SLSManagedDisplayGetCurrentSpace(_ c: Int32, _ u: CFString) -> UInt64
@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ e: AXUIElement, _ o: UnsafeMutablePointer<UInt32>) -> AXError

let cid = SLSMainConnectionID()
func ms(_ n: UInt64) -> Double { Double(n) / 1_000_000 }
@inline(__always) func timed<T>(_ b: () -> T) -> (T, UInt64) {
    let t = DispatchTime.now().uptimeNanoseconds
    let r = b(); return (r, DispatchTime.now().uptimeNanoseconds - t)
}
func pctl(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted(); let i = Int((p/100)*Double(s.count-1)+0.5)
    return s[min(max(i,0), s.count-1)]
}
func bounds(_ w: UInt32) -> CGRect? { var r = CGRect.zero; return SLSGetWindowBounds(cid,w,&r)==0 ? r : nil }
func spacesFor(_ w: UInt32) -> [UInt64] {
    (SLSCopySpacesForWindows(cid, 0x7, [NSNumber(value: w)] as CFArray)
        .takeRetainedValue() as? [NSNumber] ?? []).map { $0.uint64Value }
}
func activeSpaces() -> Set<UInt64> {
    let d = SLSCopyManagedDisplaySpaces(cid).takeRetainedValue() as! [[String: Any]]
    return Set(d.map { SLSManagedDisplayGetCurrentSpace(cid, $0["Display Identifier"] as! CFString) })
}

struct Win { let wid: UInt32; let app: String; let title: String; let spaces: [UInt64]; var el: AXUIElement? }

/// Discovery via the WindowServer (sees ALL spaces), AX bound only when reachable.
func discover() -> [Win] {
    let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var candidates: [(UInt32, String, String, pid_t)] = []
    for w in info {
        guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        guard (b["Width"] as? Double ?? 0) > 100, (b["Height"] as? Double ?? 0) > 100 else { continue }
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        guard owner != "borders" else { continue }
        candidates.append((UInt32(w[kCGWindowNumber as String] as? Int ?? 0), owner,
                           w[kCGWindowName as String] as? String ?? "",
                           pid_t(w[kCGWindowOwnerPID as String] as? Int ?? 0)))
    }
    // bind AX elements for whatever the AX API will hand us right now
    var axByWid: [UInt32: AXUIElement] = [:]
    for pid in Set(candidates.map { $0.3 }) {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.15)
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &v)
        for e in (v as? [AXUIElement] ?? []) {
            var wid: UInt32 = 0
            if _AXUIElementGetWindow(e, &wid) == .success, wid != 0 { axByWid[wid] = e }
        }
    }
    return candidates.map { Win(wid: $0.0, app: $0.1, title: $0.2, spaces: spacesFor($0.0), el: axByWid[$0.0]) }
        .filter { !$0.spaces.isEmpty }
}

func setPos(_ e: AXUIElement, _ p: CGPoint) -> (AXError, UInt64) {
    var p = p; let v = AXValueCreate(.cgPoint, &p)!
    return timed { AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, v) }
}
func setSize(_ e: AXUIElement, _ s: CGSize) -> (AXError, UInt64) {
    var s = s; let v = AXValueCreate(.cgSize, &s)!
    return timed { AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, v) }
}

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "list"
let act = activeSpaces()

switch cmd {
case "list":
    for w in discover() {
        print("wid=\(w.wid)  \(w.app.padding(toLength: 16, withPad: " ", startingAt: 0))  ax=\(w.el != nil ? "yes" : "NO ")  spaces=\(w.spaces)  \(w.title.prefix(34))")
    }

case "s1":                                   // AX frame-set latency, active space only
    let iters = args.count > 1 ? Int(args[1])! : 40
    let targets = discover().filter { $0.el != nil && !Set($0.spaces).isDisjoint(with: act) }
    guard !targets.isEmpty else { print("no AX-reachable window on the active space"); exit(1) }
    for w in targets {
        guard let el = w.el, let orig = bounds(w.wid) else { continue }
        var pT: [Double] = [], sT: [Double] = [], vT: [Double] = [], fT: [Double] = []
        var corr = 0, errs = 0
        for i in 0..<iters {
            let d = CGFloat(i % 2 == 0 ? 60 : 0)
            let tgt = CGRect(x: orig.minX + d, y: orig.minY, width: orig.width - d, height: orig.height - d)
            let t0 = DispatchTime.now().uptimeNanoseconds
            let (e1, tp) = setPos(el, tgt.origin)
            let (e2, ts) = setSize(el, tgt.size)
            if e1 != .success || e2 != .success { errs += 1 }
            let (got, tv) = timed { bounds(w.wid) }
            if let g = got, abs(g.minX - tgt.minX) > 1 || abs(g.minY - tgt.minY) > 1 {
                corr += 1; _ = setPos(el, tgt.origin)
            }
            let t1 = DispatchTime.now().uptimeNanoseconds
            pT.append(ms(tp)); sT.append(ms(ts)); vT.append(ms(tv)); fT.append(ms(t1 - t0))
        }
        _ = setPos(el, orig.origin); _ = setSize(el, orig.size); _ = setPos(el, orig.origin)
        print("\(w.app)  wid=\(w.wid)  n=\(iters)")
        for (n, xs) in [("setPosition", pT), ("setSize", sT), ("SLSGetBounds", vT), ("FULL frame-set", fT)] {
            print(String(format: "   %-15s p50 %6.2f  p99 %6.2f  max %6.2f ms",
                         (n as NSString).utf8String!, pctl(xs,50), pctl(xs,99), xs.max() ?? 0))
        }
        print("   re-position corrections: \(corr)/\(iters)   AX errors: \(errs)\n")
    }

case "s4":                                   // parking clamp test
    let targets = discover().filter { $0.el != nil && !Set($0.spaces).isDisjoint(with: act) }
    guard let w = targets.first, let el = w.el, let orig = bounds(w.wid) else { print("none"); exit(1) }
    print("\(w.app) wid=\(w.wid) original \(orig)")
    for park in [-2000.0, -5000.0, -20000.0] {
        let p = CGPoint(x: park, y: orig.minY)
        let (_, t) = setPos(el, p)
        usleep(60_000)
        let got = bounds(w.wid)
        print(String(format: "  park x=%-8.0f -> actual x=%-10.0f %@  (%.2f ms)",
                     park, got?.minX ?? .nan,
                     abs((got?.minX ?? 0) - park) < 2 ? "OK not clamped" : "CLAMPED", ms(t)))
    }
    _ = setPos(el, orig.origin)
    print("  restored -> \(bounds(w.wid)?.minX ?? .nan)")

case "s2":                                   // SLSMoveWindow position-only coherence
    let targets = discover().filter { $0.el != nil && !Set($0.spaces).isDisjoint(with: act) }
    guard let w = targets.first, let el = w.el, let orig = bounds(w.wid) else { print("none"); exit(1) }
    print("\(w.app) wid=\(w.wid) original \(orig)")
    var slsT: [Double] = [], axT: [Double] = []
    for i in 0..<20 {
        var p = CGPoint(x: orig.minX + CGFloat(i % 2 == 0 ? 120 : 0), y: orig.minY)
        let (rc, t) = timed { SLSMoveWindow(cid, w.wid, &p) }
        slsT.append(ms(t))
        if i == 0 { print("  SLSMoveWindow rc=\(rc)") }
    }
    let slsSeen = bounds(w.wid)
    var axPos: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &axPos)
    var axPoint = CGPoint.zero
    if let v = axPos { AXValueGetValue(v as! AXValue, .cgPoint, &axPoint) }
    print("  after SLSMoveWindow: SkyLight says x=\(slsSeen?.minX ?? .nan), AX says x=\(axPoint.x)")
    print(String(format: "  SLSMoveWindow p50 %.3f ms  vs  AX setPosition below", pctl(slsT,50)))
    for i in 0..<20 {
        let (_, t) = setPos(el, CGPoint(x: orig.minX + CGFloat(i % 2 == 0 ? 120 : 0), y: orig.minY))
        axT.append(ms(t))
    }
    print(String(format: "  AX setPosition p50 %.3f ms   → SLS is %.0fx faster",
                 pctl(axT,50), pctl(axT,50) / max(pctl(slsT,50), 0.0001)))
    _ = setPos(el, orig.origin)

default: print("usage: spike list|s1|s2|s4")
}
