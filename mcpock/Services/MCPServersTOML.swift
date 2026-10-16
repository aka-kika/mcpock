import Foundation

/// Discovers MCP servers from the standard `[mcp_servers.*]` TOML shape, as written
/// by Grok (`~/.grok/config.toml`) and Codex (`~/.codex/config.toml`).
///
/// Servers are TOML tables — `[mcp_servers.<name>]` with `command` / `args` / `url` /
/// `type` / `enabled`, and `env` and `headers` (Codex: `http_headers`) either as
/// inline tables (`env = { KEY = "v" }`, how Codex documents it) or as
/// `[mcp_servers.<name>.env]` sub-tables.
/// This is a *minimal* TOML reader scoped to exactly that shape (no full TOML spec:
/// no dotted keys inside a table, no multi-line strings, no integers/dates), so it
/// stays dependency-free. Output matches the JSON `mcpServers` map so it reuses the same
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
        // Open `[` minus `]` so far, outside strings: a `]` inside an element
        // (`"--glob=[a]"`) does not end the array (review, 2026-10-14).
        var pendingArrayDepth = 0

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

        // A config saved with Windows line endings left `\r` on every line, so
        // `enabled = true\r` read as disabled and `"npx"\r` kept its quotes
        // (Argon 2026-10-16 #2). Same normalization as YAMLBlock.
        let text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for rawTextLine in text.components(separatedBy: "\n") {
            // Strip inline comments up front — `enabled = true  # keep` is legal TOML,
            // and an unstripped comment corrupts every value comparison below (it even
            // flipped `enabled = true` servers to disabled).
            let rawLine = stripComment(rawTextLine)

            if pendingArrayKey != nil {
                pendingArrayText += "\n" + rawLine
                pendingArrayDepth += bracketDepth(rawLine)
                if pendingArrayDepth <= 0 { flushArray() }
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
            let submapKey: String? = path.count == 3 ? submapName(path[2]) : nil

            // Multi-line array opener: `args = [` with no closing bracket yet.
            if isServerLevel, valuePart.hasPrefix("["), bracketDepth(valuePart) > 0 {
                pendingArrayKey = key
                pendingArrayText = valuePart
                pendingArrayServer = name
                pendingArrayDepth = bracketDepth(valuePart)
                continue
            }

            if isServerLevel {
                switch key {
                case "command", "url", "type":
                    var e = entries[name] ?? [:]
                    e[key] = unquote(valuePart)
                    entries[name] = e
                case "env", "headers", "http_headers":
                    guard valuePart.hasPrefix("{") else { break }
                    var e = entries[name] ?? [:]
                    let mapKey = submapName(key) ?? key
                    var map = (e[mapKey] as? [String: String]) ?? [:]
                    map.merge(parseInlineTable(valuePart)) { _, new in new }
                    e[mapKey] = map
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

    /// The entry key a nested table fills: `env`, or `headers` (Codex writes
    /// `http_headers`). Nil for any other table.
    private static func submapName(_ key: String) -> String? {
        switch key {
        case "env": return "env"
        case "headers", "http_headers": return "headers"
        default: return nil
        }
    }

    /// `[` minus `]` in a line, skipping both inside quoted strings.
    private static func bracketDepth(_ line: String) -> Int {
        var depth = 0
        forEachUnquoted(line) { c, _ in
            if c == "[" { depth += 1 } else if c == "]" { depth -= 1 }
            return false
        }
        return depth
    }

    /// Calls `body` with each character outside quoted strings (and its
    /// index) until it returns true. Double-quoted (basic) strings honour
    /// backslash escapes; single-quoted (literal) strings have none.
    private static func forEachUnquoted(_ s: String, _ body: (Character, String.Index) -> Bool) {
        var quote: Character?
        var escaped = false
        for idx in s.indices {
            let c = s[idx]
            if escaped {
                escaped = false
            } else if let q = quote {
                if q == "\"", c == "\\" {
                    escaped = true
                } else if c == q {
                    quote = nil
                }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if body(c, idx) {
                return
            }
        }
    }

    /// `{ KEY = "v", "OTHER" = 'w' }` → its string pairs. A value that isn't a
    /// string (a number, a boolean) is kept as written.
    private static func parseInlineTable(_ text: String) -> [String: String] {
        var inner = text.trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("{") else { return [:] }
        inner.removeFirst()
        if let close = lastUnquotedIndex(of: "}", in: inner) { inner = String(inner[..<close]) }
        var map: [String: String] = [:]
        for pair in splitUnquoted(inner, on: ",") {
            guard let eq = firstUnquotedIndex(of: "=", in: pair) else { continue }
            let key = unquote(String(pair[..<eq]))
            guard !key.isEmpty else { continue }
            map[key] = unquote(String(pair[pair.index(after: eq)...]))
        }
        return map
    }

    private static func splitUnquoted(_ s: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var start = s.startIndex
        forEachUnquoted(s) { c, idx in
            if c == separator {
                parts.append(String(s[start..<idx]))
                start = s.index(after: idx)
            }
            return false
        }
        parts.append(String(s[start...]))
        return parts
    }

    private static func lastUnquotedIndex(of target: Character, in s: String) -> String.Index? {
        var found: String.Index?
        forEachUnquoted(s) { c, idx in
            if c == target { found = idx }
            return false
        }
        return found
    }

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
        var found: String.Index?
        forEachUnquoted(s) { c, idx in
            if c == target { found = idx; return true }
            return false
        }
        return found
    }

    /// Strip one layer of matching surrounding quotes. A double-quoted (basic)
    /// string also has its escapes read (`\"`, `\\`, `\n`, `\u00e9`…); a
    /// single-quoted (literal) one is taken as written.
    private static func unquote(_ s: String) -> String {
        let v = s.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") {
            return String(v.dropFirst().dropLast())
        }
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
            let chars = Array(v)
            var i = 0
            return readString(chars, &i)
        }
        return v
    }

    /// Reads the quoted string starting at `chars[i]` (its opening quote) and
    /// leaves `i` on its closing quote.
    private static func readString(_ chars: [Character], _ i: inout Int) -> String {
        let quote = chars[i]
        var s = ""
        i += 1
        while i < chars.count, chars[i] != quote {
            if chars[i] == "\\", quote == "\"", i + 1 < chars.count {
                let n = chars[i + 1]
                i += 2
                switch n {
                case "n": s += "\n"
                case "t": s += "\t"
                case "r": s += "\r"
                case "b": s += "\u{08}"
                case "f": s += "\u{0C}"
                case "u", "U":
                    let width = n == "u" ? 4 : 8
                    let hex = String(chars[min(i, chars.count)..<min(i + width, chars.count)])
                    if hex.count == width, let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                        s.unicodeScalars.append(scalar)
                        i += width
                    } else {
                        s.append(n)
                    }
                default: s.append(n)   // \" and \\ included
                }
                continue
            }
            s.append(chars[i])
            i += 1
        }
        return s
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
                result.append(readString(chars, &i))
            }
            i += 1
        }
        return result
    }
}
