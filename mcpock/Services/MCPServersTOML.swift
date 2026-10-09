import Foundation

/// Discovers MCP servers from the standard `[mcp_servers.*]` TOML shape, as written
/// by Grok (`~/.grok/config.toml`) and Codex (`~/.codex/config.toml`).
///
/// Servers are TOML tables — `[mcp_servers.<name>]` with `command` / `args` / `url` /
/// `enabled`, and optional `[mcp_servers.<name>.env]` and `[mcp_servers.<name>.headers]`
/// sub-tables.
/// This is a *minimal* TOML reader scoped to exactly that shape (no full TOML spec:
/// no inline tables, no dotted keys inside a table, no integers/dates), so it stays
/// dependency-free. Output matches the JSON `mcpServers` map so it reuses the same
/// `ConfigDiscovery` parsing pipeline as Claude Code / Cursor.
enum MCPServersTOML {
    /// Parse `[mcp_servers.*]` tables into a `name → entry` map. `enabled = false`
    /// servers are dropped. Non-`mcp_servers` sections are ignored.
    static func servers(fromTOML text: String) -> [String: [String: Any]] {
        var entries: [String: [String: Any]] = [:]
        var enabledFlags: [String: Bool] = [:]

        // Current TOML table path, e.g. ["mcp_servers", "foo"] or [..., "foo", "env"].
        var path: [String] = []
        // Accumulator for arrays that span multiple lines.
        var pendingArrayKey: String?
        var pendingArrayText = ""
        var pendingArrayServer: String?

        func serverName(for path: [String]) -> String? {
            guard path.count >= 2, path[0] == "mcp_servers" else { return nil }
            return path[1]
        }

        func flushArray() {
            defer { pendingArrayKey = nil; pendingArrayText = ""; pendingArrayServer = nil }
            guard let key = pendingArrayKey, let name = pendingArrayServer else { return }
            var e = entries[name] ?? [:]
            e[key] = parseInlineArray(pendingArrayText)
            entries[name] = e
        }

        for rawTextLine in text.components(separatedBy: "\n") {
            // Strip inline comments up front — `enabled = true  # keep` is legal TOML,
            // and an unstripped comment corrupts every value comparison below (it even
            // flipped `enabled = true` servers to disabled).
            let rawLine = stripComment(rawTextLine)

            if pendingArrayKey != nil {
                pendingArrayText += "\n" + rawLine
                if rawLine.contains("]") { flushArray() }
                continue
            }

            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Array-of-tables `[[...]]` — not used by mcp_servers, so reset path.
            if trimmed.hasPrefix("[[") {
                path = []
                continue
            }
            // Table header `[a.b.c]`.
            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                let inner = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
                path = splitKey(inner)
                if let name = serverName(for: path), path.count == 2, entries[name] == nil {
                    entries[name] = [:]
                }
                continue
            }

            // key = value under the current table.
            guard let name = serverName(for: path),
                  let eq = firstUnquotedIndex(of: "=", in: rawLine) else { continue }
            let key = String(rawLine[rawLine.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let valuePart = String(rawLine[rawLine.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            let isServerLevel = path.count == 2
            // `env` and `headers` are the only nested tables Grok writes. Dropping
            // `headers` probes an authenticated server with no Authorization and
            // reports a false HTTP 401 (reed-md).
            let submapKey: String? = (path.count == 3 && (path[2] == "env" || path[2] == "headers")) ? path[2] : nil

            // Multi-line array opener: `args = [` with no closing bracket yet.
            if isServerLevel, valuePart.hasPrefix("["), !valuePart.contains("]") {
                pendingArrayKey = key
                pendingArrayText = valuePart
                pendingArrayServer = name
                continue
            }

            if isServerLevel {
                switch key {
                case "command", "url":
                    var e = entries[name] ?? [:]
                    e[key] = unquote(valuePart)
                    entries[name] = e
                case "args":
                    var e = entries[name] ?? [:]
                    e["args"] = parseInlineArray(valuePart)
                    entries[name] = e
                case "enabled":
                    enabledFlags[name] = (valuePart == "true")
                default:
                    break
                }
            } else if let submapKey {
                var e = entries[name] ?? [:]
                var map = (e[submapKey] as? [String: String]) ?? [:]
                map[unquote(key)] = unquote(valuePart)
                e[submapKey] = map
                entries[name] = e
            }
        }
        if pendingArrayKey != nil { flushArray() }

        return entries.filter { enabledFlags[$0.key] != false }
    }

    /// Shape adapter: TOML text → discovered entries, or nil if not the Grok shape.
    static func shapeEntries(_ text: String) -> [DiscoveredEntry]? {
        let servers = servers(fromTOML: text)
        guard !servers.isEmpty else { return nil }
        return servers.map { DiscoveredEntry(name: $0.key, entry: $0.value) }
    }

    // MARK: - Minimal TOML helpers

    /// Drop an unquoted `#` comment (and everything after it) from a line.
    /// Respects single/double quotes and backslash escapes inside basic strings.
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for idx in line.indices {
            let c = line[idx]
            if escaped {
                escaped = false
                continue
            }
            if let q = quote {
                if q == "\"", c == "\\" {
                    escaped = true
                } else if c == q {
                    quote = nil
                }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" {
                return String(line[..<idx])
            }
        }
        return line
    }

    /// Split a table-header path on `.`, respecting quoted segments.
    private static func splitKey(_ s: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var quote: Character?
        for c in s {
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "." {
                parts.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            } else {
                cur.append(c)
            }
        }
        parts.append(cur.trimmingCharacters(in: .whitespaces))
        return parts
    }

    /// Index of the first `target` character not inside a quoted string.
    private static func firstUnquotedIndex(of target: Character, in s: String) -> String.Index? {
        var quote: Character?
        var idx = s.startIndex
        while idx < s.endIndex {
            let c = s[idx]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == target {
                return idx
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    /// Strip one layer of matching surrounding quotes.
    private static func unquote(_ s: String) -> String {
        let v = s.trimmingCharacters(in: .whitespaces)
        if v.count >= 2,
           (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            return String(v.dropFirst().dropLast())
        }
        return v
    }

    /// Pull the quoted string elements out of a (possibly multi-line) TOML array.
    /// Brackets, commas and whitespace between elements are ignored.
    private static func parseInlineArray(_ text: String) -> [String] {
        var result: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" || c == "'" {
                let quote = c
                var s = ""
                i += 1
                while i < chars.count, chars[i] != quote {
                    if chars[i] == "\\", quote == "\"", i + 1 < chars.count {
                        let n = chars[i + 1]
                        switch n {
                        case "n": s += "\n"
                        case "t": s += "\t"
                        case "\"": s += "\""
                        case "\\": s += "\\"
                        default: s.append(n)
                        }
                        i += 2
                        continue
                    }
                    s.append(chars[i])
                    i += 1
                }
                result.append(s)
            }
            i += 1
        }
        return result
    }
}
