import Foundation

// A lossless, line-oriented view of weft.toml.
//
// The editor's job is to change the handful of values a form control owns and
// leave the file otherwise exactly as the user wrote it. The previous editor
// could not: it re-emitted `[general]` from its fields and pasted the other
// sections back as four text blobs, which threw away every comment in
// `[general]`, reordered the file, and migrated the header banner to the
// bottom on the first save.
//
// So: parse into sections of lines, hand the form a typed view of the few keys
// it owns, and write back by *editing those lines in place*. Anything the
// editor does not understand — a comment, an inline table, a key added
// by a future weft — is carried through untouched because it is never
// re-serialised from a model, only copied.

/// One line: a key/value pair we can address, or anything else, verbatim.
public enum TomlEntry: Equatable {
    /// Comment, blank line, or a line the parser did not recognise. Kept as
    /// written, including its indentation.
    case line(String)
    /// `key` is exactly as written (`inner-gap`, or `"alt-h"` with its
    /// quotes); `value` is the raw right-hand side, un-parsed.
    case pair(key: String, value: String)
}

/// A `[header]` and the lines under it. `header == nil` is the preamble — the
/// banner comment every weft.toml opens with, which has to stay on top.
public struct TomlSection: Identifiable, Equatable {
    public let id: UUID
    public var header: String?
    /// Comments and blanks that sit immediately above `header`. They belong to
    /// the section they introduce, so they travel with it when it moves.
    public var leading: [TomlEntry]
    public var entries: [TomlEntry]

    public init(id: UUID = UUID(), header: String?, leading: [TomlEntry] = [], entries: [TomlEntry] = []) {
        self.id = id
        self.header = header
        self.leading = leading
        self.entries = entries
    }

    public static func == (a: TomlSection, b: TomlSection) -> Bool {
        a.header == b.header && a.leading == b.leading && a.entries == b.entries
    }
}

public struct TomlDocument {
    public var sections: [TomlSection]

    // MARK: Parse

    public init(_ text: String) {
        var sections: [TomlSection] = []
        var pending: [TomlEntry] = []
        var current = TomlSection(header: nil)

        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                sections.append(current)
                current = TomlSection(header: trimmed, leading: pending)
                pending = []
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                // Held back: a run of comments before a header introduces the
                // section below it, not the one above.
                pending.append(.line(raw))
                continue
            }
            if !pending.isEmpty {
                current.entries.append(contentsOf: pending)
                pending = []
            }
            if let entry = Self.parsePair(trimmed) {
                current.entries.append(entry)
            } else {
                current.entries.append(.line(raw))
            }
        }
        current.entries.append(contentsOf: pending)
        sections.append(current)

        // Drop a preamble that holds nothing — a file that opens with
        // `[general]` should not gain a leading blank on every save.
        if sections.first?.header == nil, sections.first?.entries.isEmpty == true, sections.count > 1 {
            sections.removeFirst()
        }
        self.sections = sections
    }

    private static func parsePair(_ line: String) -> TomlEntry? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty, !key.contains(" ") || key.hasPrefix("\"") else {
            return nil
        }
        return .pair(key: key, value: value)
    }

    // MARK: Render

    public func render() -> String {
        var out: [String] = []
        for section in sections {
            for entry in section.leading { out.append(Self.text(entry)) }
            if let header = section.header { out.append(header) }
            for entry in section.entries { out.append(Self.text(entry)) }
        }
        // One trailing newline, never a growing stack of blank lines.
        while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }

    private static func text(_ entry: TomlEntry) -> String {
        switch entry {
        case .line(let s): return s
        case .pair(let key, let value): return "\(key) = \(value)"
        }
    }

    // MARK: Section lookup

    public func indices(ofHeader header: String) -> [Int] {
        sections.indices.filter { sections[$0].header == header }
    }

    public func firstIndex(ofHeader header: String) -> Int? {
        sections.firstIndex { $0.header == header }
    }

    /// Insert so a new `[[space]]` lands with the other spaces rather than at
    /// the bottom of the file under the keybindings.
    public mutating func insertSection(_ section: TomlSection, groupedWith header: String) {
        if let last = indices(ofHeader: header).last {
            sections.insert(section, at: last + 1)
        } else {
            sections.append(section)
        }
    }

    /// Ensure `[header]` exists and return its index.
    public mutating func ensureSection(_ header: String) -> Int {
        if let i = firstIndex(ofHeader: header) { return i }
        var section = TomlSection(header: header)
        section.leading = [.line("")]
        sections.append(section)
        return sections.count - 1
    }
}

// MARK: - Reading and writing keys

extension TomlSection {
    public static func normalize(_ key: String) -> String { TomlValue.unquote(key).lowercased() }

    public func rawValue(_ key: String) -> String? {
        let target = Self.normalize(key)
        for case .pair(let k, let v) in entries where Self.normalize(k) == target { return v }
        return nil
    }

    public var pairKeys: [String] {
        entries.compactMap { if case .pair(let k, _) = $0 { return k } else { return nil } }
    }

    public func string(_ key: String) -> String? { rawValue(key).map(TomlValue.unquote) }
    public func int(_ key: String) -> Int? { rawValue(key).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
    public func double(_ key: String) -> Double? {
        rawValue(key).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }
    public func bool(_ key: String) -> Bool? {
        switch rawValue(key)?.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// Replace the value in place, keeping the key where the user put it and
    /// keeping whatever comment sits above it.
    public mutating func setRaw(_ key: String, _ value: String) {
        let target = Self.normalize(key)
        for i in entries.indices {
            if case .pair(let k, _) = entries[i], Self.normalize(k) == target {
                entries[i] = .pair(key: k, value: value)
                return
            }
        }
        // New key: after the last pair, so it does not land below the
        // section's trailing comments.
        let insertAt = entries.lastIndex { if case .pair = $0 { return true } else { return false } }
            .map { $0 + 1 } ?? entries.count
        entries.insert(.pair(key: key, value: value), at: insertAt)
    }

    public mutating func set(_ key: String, string value: String) { setRaw(key, TomlValue.quote(value)) }
    public mutating func set(_ key: String, bool value: Bool) { setRaw(key, value ? "true" : "false") }
    public mutating func set(_ key: String, int value: Int) { setRaw(key, String(value)) }
    /// Trailing `.0` kept off whole numbers — `width = 4` reads better than
    /// `width = 4.0`, and the parser takes either.
    public mutating func set(_ key: String, double value: Double) {
        let rounded = (value * 100).rounded() / 100
        setRaw(key, rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded))
    }

    public mutating func remove(_ key: String) {
        let target = Self.normalize(key)
        entries.removeAll {
            if case .pair(let k, _) = $0 { return Self.normalize(k) == target }
            return false
        }
    }

    /// Drop every pair whose key is not in `keep`, leaving comments alone.
    /// Used by the keybinding editor, where the pairs *are* the model. Both
    /// sides are normalised, so it does not matter whether the caller passes
    /// `alt-h` or `"alt-h"`.
    public mutating func removePairs(notIn keep: Set<String>) {
        let wanted = Set(keep.map(Self.normalize))
        entries.removeAll {
            if case .pair(let k, _) = $0 { return !wanted.contains(Self.normalize(k)) }
            return false
        }
    }

    /// A value the editor must not rewrite: an array or inline table that runs
    /// past the end of its line. The parser keeps the continuation lines as
    /// opaque text, so replacing the first line alone would leave the tail
    /// behind as garbage.
    public func isMultiline(_ key: String) -> Bool {
        guard let raw = rawValue(key) else { return false }
        if raw.hasPrefix("["), !raw.hasSuffix("]") { return true }
        if raw.hasPrefix("{"), !raw.hasSuffix("}") { return true }
        return false
    }
}

public enum TomlValue {
    public static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        // Strip a trailing inline comment on an unquoted value.
        if !t.hasPrefix("\""), let hash = t.firstIndex(of: "#") {
            t = String(t[t.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
        }
        guard t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") else { return t }
        let inner = String(t.dropFirst().dropLast())
        return inner.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    public static func quote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// A keybind's value as the commands it runs: one quoted command, or a
    /// list of them run in order (`["space focus 3", "app toggle …"]`).
    public static func steps(_ raw: String) -> [String] {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[") else {
            let one = unquote(t)
            return one.isEmpty ? [] : [one]
        }
        var out: [String] = []
        var i = t.index(after: t.startIndex)
        while i < t.endIndex {
            let c = t[i]
            if c == "]" || c == "#" { break }
            guard c == "\"" else { i = t.index(after: i); continue }
            // A basic string, with its escapes.
            var text = ""
            var j = t.index(after: i)
            while j < t.endIndex, t[j] != "\"" {
                if t[j] == "\\", t.index(after: j) < t.endIndex {
                    j = t.index(after: j)
                }
                text.append(t[j])
                j = t.index(after: j)
            }
            out.append(text)
            i = j < t.endIndex ? t.index(after: j) : j
        }
        return out
    }

    /// The value to write for these commands: a plain string for one, a list
    /// for several.
    public static func literal(steps: [String]) -> String {
        steps.count == 1 ? quote(steps[0]) : "[" + steps.map(quote).joined(separator: ", ") + "]"
    }

    /// `{ top = 8, bottom = 8, … }` or a bare number applied to all four
    /// sides — weft accepts both, and a user who wrote the short form should
    /// get it back unless they actually make the sides differ.
    public static func sides(_ raw: String?) -> (top: Int, bottom: Int, left: Int, right: Int)? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespaces)
        if let n = Int(t) { return (n, n, n, n) }
        guard t.hasPrefix("{") else { return nil }
        func field(_ name: String) -> Int {
            guard let re = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*(-?\\d+)"),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let r = Range(m.range(at: 1), in: t)
            else { return 0 }
            return Int(t[r]) ?? 0
        }
        return (field("top"), field("bottom"), field("left"), field("right"))
    }

    public static func sidesLiteral(top: Int, bottom: Int, left: Int, right: Int) -> String {
        if top == bottom, bottom == left, left == right { return String(top) }
        return "{ top = \(top), bottom = \(bottom), left = \(left), right = \(right) }"
    }
}
