import Foundation
import WeftCore

// MARK: - Values

/// TOML-subset values. Supported: strings (with \" \\ escapes), ints, floats,
/// bools, arrays, inline tables. No dates, no multi-line strings, no dotted
/// keys — rejected with line numbers (strictness catches typos).
public enum TomlValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case float(Double)
    case bool(Bool)
    case array([TomlValue])
    case table([String: TomlValue])
}

public struct TomlError: Error, Sendable, Equatable {
    public var line: Int
    public var message: String
    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

// MARK: - Document model

/// Parsed document: [section] tables + [[array]] element lists, in order.
public struct TomlDocument: Sendable, Equatable {
    /// "general", "keys", "mode.resize", ... → table
    public var tables: [String: [String: TomlValue]] = [:]
    /// "space", "rule", ... → list of tables
    public var arrays: [String: [[String: TomlValue]]] = [:]
    /// 1-based source lines: "general.inner-gap", "space#0.label",
    /// section headers as "general" / "space#0". Powers error messages.
    public var lines: [String: Int] = [:]
}

private struct Line {
    var number: Int
    var text: String  // code without trailing comment
}

// Strip comments (# outside strings) and blank lines, keeping numbers.
private func physicalLines(_ input: String) throws -> [Line] {
    var out: [Line] = []
    for (i, raw) in input.components(separatedBy: "\n").enumerated() {
        let no = i + 1
        var text = ""
        var inString = false
        var escaped = false
        for ch in raw {
            if inString {
                text.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
                text.append(ch)
            } else if ch == "#" {
                break
            } else {
                text.append(ch)
            }
        }
        if inString {
            throw TomlError(line: no, message: "unterminated string")
        }
        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(Line(number: no, text: text))
        }
    }
    return out
}

private func unescape(_ s: String, line: Int) throws -> String {
    var out = ""
    out.reserveCapacity(s.count)
    var it = s.makeIterator()
    while let ch = it.next() {
        if ch == "\\" {
            guard let e = it.next() else { throw TomlError(line: line, message: "dangling escape") }
            switch e {
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "n": out.append("\n")
            case "t": out.append("\t")
            default: throw TomlError(line: line, message: "bad escape \\\(e)")
            }
        } else {
            out.append(ch)
        }
    }
    return out
}

/// Split `a, b, {c = 1}` at top-level commas (nesting-aware).
private func splitTopLevel(_ s: Substring, line: Int) throws -> [String] {
    var parts: [String] = []
    var depth = 0
    var inString = false
    var escaped = false
    var cur = ""
    for ch in s {
        if inString {
            cur.append(ch)
            if escaped { escaped = false } else if ch == "\\" { escaped = true }
            else if ch == "\"" { inString = false }
        } else if ch == "\"" {
            inString = true
            cur.append(ch)
        } else if ch == "[" || ch == "{" {
            depth += 1
            cur.append(ch)
        } else if ch == "]" || ch == "}" {
            depth -= 1
            if depth < 0 { throw TomlError(line: line, message: "unbalanced bracket") }
            cur.append(ch)
        } else if ch == "," && depth == 0 {
            parts.append(cur)
            cur = ""
        } else {
            cur.append(ch)
        }
    }
    if inString || depth != 0 { throw TomlError(line: line, message: "unbalanced value") }
    parts.append(cur)
    return parts
}

private func parseValue(_ text: String, line: Int) throws -> TomlValue {
    let t = text.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("\"") {
        guard t.hasSuffix("\""), t.count >= 2 else {
            throw TomlError(line: line, message: "unterminated string")
        }
        return .string(try unescape(String(t.dropFirst().dropLast()), line: line))
    }
    if t.hasPrefix("[") {
        guard t.hasSuffix("]") else { throw TomlError(line: line, message: "unterminated array") }
        let inner = t.dropFirst().dropLast()
        if inner.trimmingCharacters(in: .whitespaces).isEmpty { return .array([]) }
        return .array(try splitTopLevel(inner, line: line).map { try parseValue($0, line: line) })
    }
    if t.hasPrefix("{") {
        guard t.hasSuffix("}") else { throw TomlError(line: line, message: "unterminated inline table") }
        let inner = t.dropFirst().dropLast()
        var table: [String: TomlValue] = [:]
        if !inner.trimmingCharacters(in: .whitespaces).isEmpty {
            for part in try splitTopLevel(inner, line: line) {
                let (k, v) = try parsePair(part, line: line)
                table[k] = v
            }
        }
        return .table(table)
    }
    switch t {
    case "true": return .bool(true)
    case "false": return .bool(false)
    default: break
    }
    if let i = Int(t) { return .int(i) }
    if let f = Double(t) { return .float(f) }
    throw TomlError(line: line, message: "bad value: \(t)")
}

private func parsePair(_ text: String, line: Int) throws -> (String, TomlValue) {
    // Split at the first = outside strings/brackets.
    var inString = false
    var escaped = false
    var depth = 0
    var idx: String.Index?
    for i in text.indices {
        let ch = text[i]
        if inString {
            if escaped { escaped = false } else if ch == "\\" { escaped = true }
            else if ch == "\"" { inString = false }
        } else if ch == "\"" { inString = true }
        else if ch == "[" || ch == "{" { depth += 1 }
        else if ch == "]" || ch == "}" { depth -= 1 }
        else if ch == "=", depth == 0 { idx = i; break }
    }
    guard let eq = idx else { throw TomlError(line: line, message: "expected key = value") }
    let rawKey = text[..<eq].trimmingCharacters(in: .whitespaces)
    guard !rawKey.isEmpty, !rawKey.contains("."), !rawKey.contains(" ") else {
        throw TomlError(line: line, message: "bad key (no dotted keys in weft config): \(rawKey)")
    }
    let key: String
    if rawKey.hasPrefix("\"") {
        guard rawKey.hasSuffix("\""), rawKey.count >= 2 else {
            throw TomlError(line: line, message: "bad quoted key: \(rawKey)")
        }
        key = try unescape(String(rawKey.dropFirst().dropLast()), line: line)
    } else {
        key = String(rawKey)
    }
    let value = try parseValue(String(text[text.index(after: eq)...]), line: line)
    return (key, value)
}

/// Parse a weft.toml subset document. Errors carry 1-based line numbers.
public func parseTOML(_ input: String) throws -> TomlDocument {
    var doc = TomlDocument()
    var table: String?
    var array: String?
    var seenTables = Set<String>()
    for line in try physicalLines(input) {
        let t = line.text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[[") {
            guard t.hasSuffix("]]") else { throw TomlError(line: line.number, message: "bad [[section]]") }
            let name = String(t.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else {
                throw TomlError(line: line.number, message: "bad section name: \(name)")
            }
            table = nil
            array = name
            doc.lines["\(name)#\(doc.arrays[name]?.count ?? 0)"] = line.number
            doc.arrays[name, default: []].append([:])
        } else if t.hasPrefix("[") {
            guard t.hasSuffix("]") else { throw TomlError(line: line.number, message: "bad [section]") }
            let name = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else {
                throw TomlError(line: line.number, message: "bad section name: \(name)")
            }
            if !seenTables.insert(name).inserted {
                throw TomlError(line: line.number, message: "duplicate [\(name)]")
            }
            table = name
            array = nil
            doc.lines[name] = line.number
            doc.tables[name] = [:]
        } else {
            let (k, v) = try parsePair(t, line: line.number)
            if let array {
                guard var list = doc.arrays[array], !list.isEmpty else {
                    throw TomlError(line: line.number, message: "internal: no array element")
                }
                if list[list.count - 1][k] != nil {
                    throw TomlError(line: line.number, message: "duplicate key '\(k)'")
                }
                list[list.count - 1][k] = v
                doc.arrays[array] = list
                doc.lines["\(array)#\(list.count - 1).\(k)"] = line.number
            } else if let table {
                if doc.tables[table]?[k] != nil {
                    throw TomlError(line: line.number, message: "duplicate key '\(k)'")
                }
                doc.tables[table]?[k] = v
                doc.lines["\(table).\(k)"] = line.number
            } else {
                throw TomlError(line: line.number, message: "key outside any section")
            }
        }
    }
    return doc
}
