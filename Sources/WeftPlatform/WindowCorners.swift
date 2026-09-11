import CoreGraphics
import Foundation
import SkyLightShim
import WeftCore

/// A window's own corner radius, as the WindowServer has it.
///
/// macOS 26 rounds windows by kind — a window with a toolbar more than a
/// plain titled one — so one configured radius fits some windows and leaves
/// the border's corners standing off the rest. SkyLight knows each window's
/// radius (`SLSWindowIteratorGetResolvedCornerRadii`); this asks it.
///
/// Verified against live windows before use: the query takes the connection,
/// a CFArray of window numbers and an options word (0), and the radii call
/// returns a new CFArray of four doubles, one per corner. The calls are
/// private, so they are resolved at runtime rather than linked — a macOS that
/// renames or drops them costs the automatic radius, never the renderer:
/// every lookup then returns nil and the configured radius is used.
public enum WindowCorners {
    private typealias QueryFn = @convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    private typealias CopyFn = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias AdvanceFn = @convention(c) (CFTypeRef) -> Bool
    private typealias WindowIDFn = @convention(c) (CFTypeRef) -> UInt32
    private typealias RadiiFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?

    private struct API: @unchecked Sendable {
        let query: QueryFn
        let copyWindows: CopyFn
        let advance: AdvanceFn
        let windowID: WindowIDFn
        let radii: RadiiFn
        let cid: Int32
    }

    private static let api: API? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW
        ) else { return nil }
        func resolve<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let query = resolve("SLSWindowQueryWindows", as: QueryFn.self),
              let copyWindows = resolve("SLSWindowQueryResultCopyWindows", as: CopyFn.self),
              let advance = resolve("SLSWindowIteratorAdvance", as: AdvanceFn.self),
              let windowID = resolve("SLSWindowIteratorGetWindowID", as: WindowIDFn.self),
              let radii = resolve("SLSWindowIteratorGetResolvedCornerRadii", as: RadiiFn.self)
        else { return nil }
        return API(
            query: query, copyWindows: copyWindows, advance: advance,
            windowID: windowID, radii: radii, cid: Int32(SLSMainConnectionID())
        )
    }()

    public static var isAvailable: Bool { api != nil }

    /// The radius of each window the WindowServer answered for. One query
    /// for the lot; WindowServer-local, no app IPC.
    public static func radii(of wids: [WindowID]) -> [WindowID: Double] {
        guard let api, !wids.isEmpty else { return [:] }
        let list = wids.map { NSNumber(value: $0) } as CFArray
        // Both objects come back owned (yabai releases both), so they are
        // taken retained and ARC lets them go.
        guard let query = api.query(api.cid, list, 0)?.takeRetainedValue(),
              let iterator = api.copyWindows(query)?.takeRetainedValue()
        else { return [:] }
        var out: [WindowID: Double] = [:]
        while api.advance(iterator) {
            let wid = api.windowID(iterator)
            // A fresh array per call, four corners, identical on every
            // window seen so far; the largest is the safe one to follow.
            if let corners = api.radii(iterator)?.takeRetainedValue() as? [Double],
               let radius = corners.max()
            {
                out[WindowID(wid)] = radius
            }
        }
        return out
    }

    public static func radius(of wid: WindowID) -> Double? {
        radii(of: [wid])[wid]
    }
}
