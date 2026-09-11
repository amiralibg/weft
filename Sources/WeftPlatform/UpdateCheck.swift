import Foundation
import WeftCore

/// "A newer weft exists" — asked of GitHub, at most once a day, never in a way
/// that blocks anything.
///
/// weft installs from a curl script or a git clone, so there is no App Store or
/// Sparkle feed to tell anyone a release happened. Without this, the only way a
/// user learns about a fix is by going back to the repository they installed
/// from months ago — which nobody does, so in practice every install stays on
/// whatever version it started on.
///
/// What this type deliberately does NOT do: download anything, replace
/// anything, or run an installer. It answers "is there a newer version", and
/// nothing else. Acting on the answer is WeftBar's menu item, and only when
/// the user clicks it and confirms — it runs the release's own
/// `install-release.sh`, the same path as the curl one-liner.
public enum UpdateCheck {
    public struct Result: Codable, Sendable, Equatable {
        /// Latest tag as published, e.g. "0.2.0" (the leading "v" is stripped).
        public var latest: String
        /// Where to send someone who wants it.
        public var url: String
        /// When this answer was fetched. Drives the throttle.
        public var checkedAt: Date

        public var isNewerThanRunning: Bool {
            WeftVersion.isNewer(latest, than: WeftVersion.current)
        }
    }

    /// How long a cached answer is trusted. A window manager restarts often —
    /// every config reload, every login — and a check per launch would be both
    /// pointless and rude to a public API.
    public static let interval: TimeInterval = 24 * 60 * 60

    public static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/weft/.update-check.json")
    }

    private static let releasesAPI =
        "https://api.github.com/repos/amiralibg/weft/releases/latest"

    /// The last answer, however old. Cheap, offline, and what every UI reads.
    public static func cached() -> Result? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(Result.self, from: data)
    }

    public static func isStale(_ result: Result?) -> Bool {
        guard let result else { return true }
        return Date().timeIntervalSince(result.checkedAt) >= interval
    }

    /// Fetch if the cached answer has aged out, otherwise return it unchanged.
    ///
    /// Failure is not reported and not retried early: no network, a rate limit,
    /// GitHub being down — none of these are the user's problem, and none of
    /// them should produce a dialog in a window manager. The stale answer (or
    /// nothing) is returned and the next check happens on the normal schedule.
    public static func refreshIfNeeded(
        enabled: Bool, completion: @escaping @Sendable (Result?) -> Void
    ) {
        let existing = cached()
        guard enabled else { return completion(nil) }
        guard isStale(existing) else { return completion(existing) }

        guard let url = URL(string: releasesAPI) else { return completion(existing) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // GitHub rejects API requests without one, and an honest string is more
        // useful in their logs than a browser impersonation.
        request.setValue("weft/\(WeftVersion.current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else { return completion(existing) }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let page = (json["html_url"] as? String)
                ?? "https://github.com/amiralibg/weft/releases/latest"
            let result = Result(latest: latest, url: page, checkedAt: Date())
            // Cache even when it is not newer: that is what stops the next
            // launch asking again.
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if let encoded = try? JSONEncoder().encode(result) {
                try? encoded.write(to: cacheURL, options: .atomic)
            }
            completion(result)
        }.resume()
    }

    /// The one-liner that installs whatever is current. Shown, never run.
    public static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/amiralibg/weft/main/scripts/install-release.sh | bash"
}
