// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste
//
// A deliberately small TOML subset, enough for config.toml:
//   # comments, [table] headers (bare names), key = value lines,
//   values: "basic strings" (escapes \" \\ \n \t), integers (decimal,
//   optional sign, "_" separators), booleans, and single-line arrays of
//   strings (["a", "b"]).
// Anything else (other arrays, inline tables, floats, dates, dotted keys,
// multi-line strings or arrays) is rejected with a line number: no silent
// guessing.

import Foundation

public enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case strings([String])

    public var typeName: String {
        switch self {
        case .string: return "string"
        case .integer: return "integer"
        case .boolean: return "boolean"
        case .strings: return "array of strings"
        }
    }
}

public struct TOMLError: Error, Equatable, CustomStringConvertible {
    public var line: Int
    public var message: String
    public var description: String { line > 0 ? "line \(line): \(message)" : message }
    public init(line: Int, message: String) { self.line = line; self.message = message }
}

/// Parsed document: table name ("" = top level) → key → (value, line).
public struct TOMLDocument: Sendable {
    public var tables: [String: [String: (value: TOMLValue, line: Int)]] = [:]
    public var tableLines: [String: Int] = [:]

    public static func parse(_ text: String) throws -> TOMLDocument {
        var doc = TOMLDocument()
        doc.tables[""] = [:]
        var current = ""
        var lineNo = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNo += 1
            let line = try stripComment(String(rawLine), line: lineNo).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), !line.hasPrefix("[[") else {
                    throw TOMLError(line: lineNo, message: "malformed table header")
                }
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                guard isBareKey(name) else { throw TOMLError(line: lineNo, message: "invalid table name \"\(name)\"") }
                guard doc.tableLines[name] == nil else { throw TOMLError(line: lineNo, message: "table [\(name)] defined twice") }
                doc.tableLines[name] = lineNo
                doc.tables[name] = [:]
                current = name
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                throw TOMLError(line: lineNo, message: "expected key = value")
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard isBareKey(key) else { throw TOMLError(line: lineNo, message: "invalid key \"\(key)\"") }
            guard doc.tables[current]?[key] == nil else {
                throw TOMLError(line: lineNo, message: "key \"\(key)\" defined twice")
            }
            doc.tables[current]?[key] = (try parseValue(rawValue, line: lineNo), lineNo)
        }
        return doc
    }

    static func isBareKey(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }

    /// Removes a trailing # comment that is not inside a string.
    static func stripComment(_ s: String, line: Int) throws -> String {
        var inString = false
        var escaped = false
        var out = ""
        for ch in s {
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "#" {
                break
            }
            out.append(ch)
        }
        return out
    }

    static func parseValue(_ s: String, line: Int) throws -> TOMLValue {
        if s.isEmpty { throw TOMLError(line: line, message: "missing value") }
        if s == "true" { return .boolean(true) }
        if s == "false" { return .boolean(false) }
        if s.hasPrefix("\"") {
            if s.hasPrefix("\"\"\"") { throw TOMLError(line: line, message: "multi-line strings are not supported") }
            var out = ""
            var escaped = false
            var closed = false
            for ch in s.dropFirst() {
                if closed { throw TOMLError(line: line, message: "unexpected text after string") }
                if escaped {
                    switch ch {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: throw TOMLError(line: line, message: "unsupported escape \\\(ch)")
                    }
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    closed = true
                } else {
                    out.append(ch)
                }
            }
            guard closed else { throw TOMLError(line: line, message: "unterminated string") }
            return .string(out)
        }
        if s.hasPrefix("[") { return try parseStringArray(s, line: line) }
        if s.hasPrefix("'") { throw TOMLError(line: line, message: "use double quotes for strings") }
        var digits = s
        var sign = 1
        if digits.hasPrefix("+") { digits.removeFirst() } else if digits.hasPrefix("-") { sign = -1; digits.removeFirst() }
        guard !digits.isEmpty, !digits.hasPrefix("_"), !digits.hasSuffix("_"), !digits.contains("__"),
              digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "_") }),
              digits.count <= 12,
              let n = Int(digits.replacingOccurrences(of: "_", with: "")) else {
            throw TOMLError(line: line, message: "unsupported value \(s) (expected \"string\", integer, true or false)")
        }
        return .integer(sign * n)
    }

    /// ["a", "b"] on one line; a trailing comma is allowed.
    static func parseStringArray(_ s: String, line: Int) throws -> TOMLValue {
        guard s.hasSuffix("]") else {
            throw TOMLError(line: line, message: "arrays must be on one line and end with ]")
        }
        let inner = s.dropFirst().dropLast()
        var items: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        var elements: [String] = []
        for ch in inner {
            if inString {
                current.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
                current.append(ch)
            } else if ch == "," {
                elements.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        guard !inString else { throw TOMLError(line: line, message: "unterminated string") }
        elements.append(current)
        for (i, raw) in elements.enumerated() {
            let e = raw.trimmingCharacters(in: .whitespaces)
            if e.isEmpty && i == elements.count - 1 && i > 0 { continue }   // trailing comma
            if e.isEmpty && elements.count == 1 { continue }                // []
            guard e.hasPrefix("\""), case .string(let v) = try parseValue(e, line: line) else {
                throw TOMLError(line: line, message: "arrays may only hold \"strings\"")
            }
            items.append(v)
        }
        return .strings(items)
    }
}
