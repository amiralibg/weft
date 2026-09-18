// WeftPlatform/ParkLedger.swift — what is parked, on disk, before it is parked.
//
// Hiding a workspace means moving its windows off screen (WORKSPACES.md,
// S9). The windows are then in a place nothing else in weft looks: they are
// not in any layout the daemon rebuilt after a restart, and `rescue()` cannot
// see them either, because a parked window keeps a point of itself on screen
// and `rescue()` only heals windows that are off every display. A daemon that
// dies with a workspace hidden therefore leaves those windows at the corner
// with no record anywhere of where they came from.
//
// This file is that record. It is written before the move, never after, and
// the whole of it is rewritten on every park — so what is on disk is either
// the truth or one step stale, and a stale entry is recoverable where a
// missing one is not.

import Foundation
import WeftCore

/// One window weft moved off screen: where to put it back, and where it was
/// left.
public struct ParkedWindow: Codable, Sendable, Equatable {
    /// Where to put the window back.
    ///
    /// The frame the window actually had when it was parked, read from
    /// `SLSGetWindowBounds` — not the frame the layout computed for it. An
    /// app that refuses its tile is exactly the app whose restore would
    /// otherwise land somewhere it has never been, and after a crash there is
    /// nothing else to restore from: trees are not persisted, and a float
    /// workspace's arrangement belongs to the user rather than to weft.
    public var frame: Frame

    /// Where weft left the window, and the reason a recycled window id cannot
    /// do any damage.
    ///
    /// The WindowServer hands out window ids again after the window that held
    /// one is gone, and a daemon that crashed never ran `forgetWindow`, so an
    /// entry read at startup may name a window weft never touched. Before
    /// moving anything, compare this against the window's live bounds: a
    /// window that is not sitting on the park corner is not the window that
    /// was parked, and the entry is discarded rather than acted on.
    ///
    /// This is deliberately not a hook into `forgetWindow`. That runs in a
    /// loop inside `evictOrderedOut`, so pruning the ledger there would put a
    /// synchronous fsync on a hot path — and it could not help in the case
    /// this file exists for, because a crashed daemon never reaches it.
    public var parkedAt: Spot

    public var wid: WindowID

    public struct Spot: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public init(wid: WindowID, frame: Frame, parkedAt: Spot) {
        self.wid = wid
        self.frame = frame
        self.parkedAt = parkedAt
    }
}

/// The park ledger: `~/.config/weft/parked.json`, beside `labels.json` and
/// `layouts.json`.
///
/// Every other file weft writes is fire-and-forget, because losing a label or
/// a layout override is cosmetic. This one is written synchronously and
/// fsynced, because losing an entry is a window the user cannot reach.
public struct ParkLedger: Sendable {
    /// The shape on disk. An array of records rather than a
    /// `[WindowID: ParkedWindow]` dictionary: `JSONEncoder` cannot key a JSON
    /// object by `UInt32`, and what it emits instead is a flat array of
    /// alternating keys and values — a shape nobody would choose for a file
    /// that has to be readable by hand after a crash.
    struct Contents: Codable, Equatable {
        var version: Int
        var parked: [ParkedWindow]
    }

    /// Bumped when the shape changes, and read before anything else.
    ///
    /// The other persistence files can be thrown away when they do not parse —
    /// `loadLabels` returns `[]` and the user renames a desktop again. Throwing
    /// this one away strands windows, so a build that meets a file it does not
    /// understand has to be able to say so rather than read it as "nothing is
    /// parked".
    public static let version = 1

    public let url: URL

    /// The path is an argument so tests get a temp directory. The default is
    /// the only one the daemon ever passes.
    public init(url: URL = ParkLedger.defaultURL()) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/weft/parked.json")
    }

    // MARK: - Reading

    /// What the ledger says, with "no file" and "a file I cannot read" kept
    /// apart.
    ///
    /// Collapsing the two into an empty list is what would make the stranding
    /// silent: the daemon would start, find nothing to unpark, and tile around
    /// windows sitting at the corner without ever saying why.
    public enum State: Sendable, Equatable {
        /// No ledger file. Nothing was parked, or everything parked has
        /// already been put back.
        case nothingParked
        /// These windows were parked and have not been put back.
        case parked([ParkedWindow])
        /// There is a file and it cannot be understood. Something may be
        /// parked and this build cannot say what — the caller logs it.
        case unreadable(String)
    }

    public func load() -> State {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Absent is the ordinary case and the only one that means nothing
            // is parked. A file that exists and will not open is not.
            if !FileManager.default.fileExists(atPath: url.path) { return .nothingParked }
            return .unreadable("could not read \(url.path): \(error.localizedDescription)")
        }
        let contents: Contents
        do {
            contents = try JSONDecoder().decode(Contents.self, from: data)
        } catch {
            return .unreadable("could not decode \(url.path): \(error)")
        }
        guard contents.version == Self.version else {
            return .unreadable(
                "\(url.path) is version \(contents.version); this build understands "
                    + "\(Self.version)"
            )
        }
        return contents.parked.isEmpty ? .nothingParked : .parked(contents.parked)
    }

    // MARK: - Writing

    /// Why a ledger write did not land. Every case is a reason to move no
    /// windows at all.
    public enum WriteError: Error, CustomStringConvertible {
        case directory(String)
        case encode(String)
        case open(String, Int32)
        case write(String, Int32)
        case sync(String, Int32)
        case rename(String, Int32)

        public var description: String {
            switch self {
            case .directory(let why): return "could not create the ledger's directory: \(why)"
            case .encode(let why): return "could not encode the ledger: \(why)"
            case .open(let path, let e): return "could not open \(path): \(Self.strerror(e))"
            case .write(let path, let e): return "could not write \(path): \(Self.strerror(e))"
            case .sync(let path, let e): return "could not fsync \(path): \(Self.strerror(e))"
            case .rename(let path, let e): return "could not rename \(path): \(Self.strerror(e))"
            }
        }

        private static func strerror(_ e: Int32) -> String {
            String(cString: Foundation.strerror(e))
        }
    }

    /// Replace the ledger with exactly these windows, durably, before the
    /// caller moves anything.
    ///
    /// Synchronous, and it fsyncs. The sequence is write-to-temp, fsync the
    /// temp, rename over the real path, fsync the directory: the rename is
    /// what makes a reader see either the old ledger or the new one and never
    /// half of either, and the two fsyncs are what make each of those survive
    /// the machine going away rather than only the process. Throwing before
    /// the rename leaves the previous ledger exactly as it was.
    ///
    /// One call per workspace switch, not one per window — the windows of a
    /// hidden workspace go into a single ledger, and then move. That makes
    /// these two fsyncs the only part of a switch that is not microseconds.
    public func save(_ entries: [ParkedWindow]) throws {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        } catch {
            throw WriteError.directory(error.localizedDescription)
        }
        let encoder = JSONEncoder()
        // Sorted keys so two ledgers holding the same windows are the same
        // bytes, which is what makes a diff of this file mean anything.
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(Contents(version: Self.version, parked: entries))
        } catch {
            throw WriteError.encode("\(error)")
        }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw WriteError.open(tmp.path, errno) }
        do {
            try Self.writeAll(fd: fd, data: data, path: tmp.path)
            guard fsync(fd) == 0 else { throw WriteError.sync(tmp.path, errno) }
        } catch {
            close(fd)
            unlink(tmp.path)
            throw error
        }
        close(fd)
        guard rename(tmp.path, url.path) == 0 else {
            let e = errno
            unlink(tmp.path)
            throw WriteError.rename(tmp.path, e)
        }
        // The rename is atomic the moment it returns; this is what makes it
        // durable across a panic or a power cut rather than only across a
        // crash of this process. One syscall, and the alternative is a
        // ledger that a reboot can lose.
        let dfd = open(dir.path, O_RDONLY)
        if dfd >= 0 {
            fsync(dfd)
            close(dfd)
        }
    }

    /// Nothing is parked any more. Absent is how the ledger says that, so the
    /// file goes rather than being rewritten empty.
    ///
    /// A failure here is not a stranded window — the windows are already back
    /// on screen — so this reports and the caller logs.
    @discardableResult
    public func clear() -> Bool {
        if unlink(url.path) == 0 { return true }
        return errno == ENOENT
    }

    /// `write(2)` until the whole buffer is gone. A short write is legal and a
    /// truncated ledger is a window weft cannot put back.
    private static func writeAll(fd: Int32, data: Data, path: String) throws {
        var written = 0
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            while written < buf.count {
                let n = write(fd, base.advanced(by: written), buf.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw WriteError.write(path, errno)
                }
                if n == 0 { throw WriteError.write(path, EIO) }
                written += n
            }
        }
    }
}
