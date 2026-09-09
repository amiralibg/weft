import ApplicationServices
import CoreGraphics
import Foundation
import Security

/// TCC answers for **this** process, read live.
///
/// "Live" is the whole point of the file. The two calls you would reach for
/// first answer out of a per-process cache that is filled once, at launch:
///
///   - `CGPreflightScreenCaptureAccess()` keeps returning false for the entire
///     life of a process that started without the grant, however many times
///     the user toggles the switch.
///   - an event tap that failed `CGEvent.tapCreate` at launch never retries
///     itself, so `tapInstalled` stays false forever.
///
/// A daemon that reports either verbatim tells the user the grant they just
/// made did not work — which is exactly what the Setup window used to do.
public enum Permissions {
    /// Live already: `AXIsProcessTrusted` hits TCC on every call.
    public static func accessibility() -> Bool { AXIsProcessTrusted() }

    /// Live, via the window list rather than the preflight.
    ///
    /// Without Screen Recording macOS redacts `kCGWindowName` for every window
    /// this process does not own, and un-redacts it the moment the grant lands
    /// — no restart, no cache. The preflight is still tried first because it
    /// is authoritative when it says yes and costs nothing.
    public static func screenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return otherAppWindowTitlesVisible() == true
    }

    /// `true`/`false` when the window list can answer, `nil` when it cannot —
    /// no other process has a normal on-screen window at this moment, so a
    /// missing title proves nothing either way.
    public static func otherAppWindowTitlesVisible() -> Bool? {
        let mine = Int(ProcessInfo.processInfo.processIdentifier)
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        var sawCandidate = false
        for info in infos {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int, owner != mine,
                  (info[kCGWindowLayer as String] as? Int) == 0
            else { continue }
            sawCandidate = true
            if let name = info[kCGWindowName as String] as? String, !name.isEmpty {
                return true
            }
        }
        return sawCandidate ? false : nil
    }

    /// Whether this binary's TCC grants can survive being rebuilt.
    ///
    /// macOS stores a grant against a program's *designated requirement*. Sign
    /// with a certificate — even a self-signed one — and that requirement is
    /// `identifier "..." and certificate leaf = H"..."`, which every future
    /// build still satisfies. Ad-hoc sign it, as `swift build` does, and there
    /// is no identity to name, so the requirement falls back to the code
    /// directory hash: a rebuilt binary is a different program and the grant
    /// stops applying to it.
    ///
    /// It stops applying *silently*. TCC leaves the row in System Settings
    /// with its switch on, so the pane says granted while every AX call is
    /// refused — the single most confusing state weft can be in, and the one
    /// the Setup window has to name out loud when it happens.
    ///
    /// Ad-hoc signatures carry no certificates, so the presence of a
    /// certificate chain is the whole test.
    public static func hasStableSigningIdentity() -> Bool {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let codeRef else { return false }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(codeRef, [], &staticRef) == errSecSuccess,
              let staticRef
        else { return false }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticRef, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef
        ) == errSecSuccess,
            let info = infoRef as? [String: Any]
        else { return false }
        let certs = info[kSecCodeInfoCertificates as String] as? [Any]
        return !(certs?.isEmpty ?? true)
    }

    /// What TCC thinks, before any tap is attempted. Useful only as a hint:
    /// it can say yes while `CGEvent.tapCreate` still fails, and the
    /// difference is "no keybinds work at all", so the tap stays the source of
    /// truth for Input Monitoring.
    public static func inputMonitoringPreflight() -> Bool {
        CGPreflightListenEventAccess()
    }
}
