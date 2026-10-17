import Foundation

/// One MCP server as extracted from a config file, before normalization.
/// `entry` mirrors a JSON `mcpServers` value (command/args/env/url/type/headers).
struct DiscoveredEntry {
    let name: String
    let entry: [String: Any]
    let projectPath: String?

    init(name: String, entry: [String: Any], projectPath: String? = nil) {
        self.name = name
        self.entry = entry
        self.projectPath = projectPath
    }

    /// Usable server: has a non-empty command (stdio) or url (http/sse).
    var hasEndpoint: Bool {
        (entry["command"] as? String)?.isEmpty == false
            || (entry["url"] as? String)?.isEmpty == false
    }
}

/// A recognizable MCP config format. `parse` returns nil when the text isn't this
/// shape or contains no usable server (the false-positive gate).
struct ConfigShape {
    let id: String
    let parse: (String) -> [DiscoveredEntry]?
    /// Set for an agent that keeps its servers in its own settings (a binary
    /// preferences plist) instead of a text config: the registry reads the raw
    /// bytes and hands them here, and `parse` is never called. The scan never
    /// uses these shapes.
    var parseData: ((Data) -> [DiscoveredEntry]?)? = nil

    /// True for an agent whose servers live in its own settings, not in a file
    /// anyone should edit by hand.
    var isAppSettings: Bool { parseData != nil }

    static let json = ConfigShape(id: "json") { JSONConfigShape.parse($0) }
    /// The scan's JSON shape for a file whose name says nothing about MCP: only
    /// `mcpServers` counts. A bare `servers` or `mcp` block is too common in other
    /// apps' settings, and mcpock would start its `command` every minute.
    static let jsonMCPServersOnly = ConfigShape(id: "json") { JSONConfigShape.parse($0, genericKeys: false) }
    static let mcpServersTOML = ConfigShape(id: "mcp-servers-toml") { MCPServersTOML.shapeEntries($0) }
    static let gooseYAML = ConfigShape(id: "goose-yaml") { GooseConfig.shapeEntries($0) }
    static let mcpServersYAML = ConfigShape(id: "mcp-servers-yaml") { MCPServersYAML.shapeEntries($0) }

    /// Tinycast (1.10.1): its MCP servers live in its preferences plist.
    static let tinycastDefaults = ConfigShape(id: "tinycast-defaults", parse: { _ in nil }) {
        TinycastConfig.parse($0)
    }

    /// Order matters only for scan detection (first non-nil wins); JSON is cheapest.
    static let all: [ConfigShape] = [.json, .mcpServersTOML, .gooseYAML, .mcpServersYAML]
}

/// The JSON shapes agents write, all normalized to the de-facto `mcpServers` entry:
///
/// - `{"mcpServers": {...}}` — Claude Desktop, Cursor, Windsurf, Cline, Kimi Code,
///   MiniMax and most others;
/// - Claude Code's per-project `projects.<path>.mcpServers`;
/// - `{"servers": {...}}` — VS Code's `mcp.json`, and `{"mcp": {"servers": {...}}}`
///   in its `settings.json`;
/// - `{"mcp": {<name>: {...}}}` — OpenCode, whose `command` is an argv array and
///   whose env map is called `environment`.
///
/// `"enabled": false` and `"disabled": true` entries are dropped, matching the
/// TOML and YAML readers, and so are a Claude Code project's own servers named
/// in its `disabledMcpServers`.
///
/// `genericKeys: false` reads only `mcpServers`: the scan uses it for files whose
/// name is not a known MCP config name (see `ConfigScanner.scanShapes`).
enum JSONConfigShape {
    static func parse(_ text: String, genericKeys: Bool = true) -> [DiscoveredEntry]? {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data))
                ?? (try? JSONSerialization.jsonObject(with: Data(JSONC.plainJSON(text).utf8))),
              let root = obj as? [String: Any]
        else { return nil }

        var entries: [DiscoveredEntry] = []
        if let global = root["mcpServers"] as? [String: Any] {
            entries.append(contentsOf: extract(global, projectPath: nil))
        }
        if let projects = root["projects"] as? [String: Any] {
            for (projectPath, value) in projects {
                guard let project = value as? [String: Any],
                      let mcp = project["mcpServers"] as? [String: Any] else { continue }
                // Turned off in that project with /mcp (Argon 2026-10-17 #8). The
                // same list also names global servers, which stay: they run in
                // every other project.
                let off = Set(project["disabledMcpServers"] as? [String] ?? [])
                entries.append(contentsOf: extract(mcp, projectPath: projectPath).filter { !off.contains($0.name) })
            }
        }
        if genericKeys, let servers = root["servers"] as? [String: Any] {
            entries.append(contentsOf: extract(servers, projectPath: nil))
        }
        if genericKeys, let mcp = root["mcp"] as? [String: Any] {
            if let servers = mcp["servers"] as? [String: Any] {
                entries.append(contentsOf: extract(servers, projectPath: nil))
            } else {
                entries.append(contentsOf: extract(mcp, projectPath: nil))
            }
        }
        // Gate: only a source if it yields at least one usable server.
        return entries.contains(where: \.hasEndpoint) ? entries : nil
    }

    /// Claude Code's per-project lists of `.mcp.json` servers switched off in
    /// that project (`projects.<path>.disabledMcpjsonServers`), by folder.
    static func disabledMcpjsonServers(_ text: String) -> [String: Set<String>] {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let projects = root["projects"] as? [String: Any]
        else { return [:] }
        var result: [String: Set<String>] = [:]
        for (path, value) in projects {
            guard let names = (value as? [String: Any])?["disabledMcpjsonServers"] as? [String], !names.isEmpty
            else { continue }
            result[(path as NSString).standardizingPath] = Set(names)
        }
        return result
    }

    private static func extract(_ dict: [String: Any], projectPath: String?) -> [DiscoveredEntry] {
        dict.compactMap { name, value in
            guard var entry = value as? [String: Any] else { return nil }
            if (entry["enabled"] as? Bool) == false { return nil }
            // Cline, Roo Code and Windsurf say it the other way round.
            if (entry["disabled"] as? Bool) == true { return nil }
            normalize(&entry)
            return DiscoveredEntry(name: name, entry: entry, projectPath: projectPath)
        }
    }

    /// Fold OpenCode's spellings onto the standard keys: an argv-array `command`
    /// becomes `command` + `args`, and `environment` becomes `env`.
    private static func normalize(_ entry: inout [String: Any]) {
        if let argv = entry["command"] as? [String], let first = argv.first {
            entry["command"] = first
            if entry["args"] == nil { entry["args"] = Array(argv.dropFirst()) }
        }
        if entry["env"] == nil, let environment = entry["environment"] as? [String: Any] {
            entry["env"] = environment
        }
    }
}

/// JSON with comments (`.jsonc`: VS Code, OpenCode, Zed): `//` and `/* */`
/// comments and trailing commas are removed outside strings, so plain
/// `JSONSerialization` can read it (Argon 2026-10-16 #15). Tried only after a
/// strict parse fails.
enum JSONC {
    static func plainJSON(_ text: String) -> String {
        let chars = Array(text.unicodeScalars)
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(chars.count)
        var i = 0
        var inString = false
        // Where in `out` a comma sits that may still turn out to be trailing.
        var pendingComma: Int?
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if (c == "}" || c == "]"), let comma = pendingComma {
                out.remove(at: comma)
            }
            if c == "\"" { inString = true; pendingComma = nil }
            else if c == "," { pendingComma = out.count }
            else if !CharacterSet.whitespacesAndNewlines.contains(c) { pendingComma = nil }
            out.append(c)
            i += 1
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: out)
        return String(view)
    }
}

/// Tinycast keeps its MCP servers in its preferences
/// (`~/Library/Preferences/com.tinycast.app.plist`): `mcpEnabled` (Bool) and
/// `mcpServers`, JSON bytes holding an array of
/// `{"name", "isEnabled", "transport": {"stdio": {"command", "arguments",
/// "environmentKeys"}} | {"http": {"url", "headerName"}}, "oauth"}`.
///
/// Only the key names are in the plist; the values (environment variables, the
/// header, OAuth tokens) sit in Tinycast's own Keychain items, which mcpock can't
/// and shouldn't read. A server that needs one would look broken or "needs
/// sign-in" when mcpock starts it without, so it is marked `builtin` and shows
/// as managed by its app. A server that needs no secret is checked like any other.
enum TinycastConfig {
    static func parse(_ data: Data) -> [DiscoveredEntry]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any]
        else { return nil }
        // MCP switched off in Tinycast: it starts none of them, so neither do we.
        if (root["mcpEnabled"] as? Bool) == false { return nil }
        let raw: Data?
        if let bytes = root["mcpServers"] as? Data {
            raw = bytes
        } else if let text = root["mcpServers"] as? String {
            raw = text.data(using: .utf8)
        } else {
            raw = nil
        }
        guard let raw, let servers = (try? JSONSerialization.jsonObject(with: raw)) as? [[String: Any]] else {
            return nil
        }
        let entries = servers.compactMap(entry(from:))
        return entries.contains(where: \.hasEndpoint) ? entries : nil
    }

    private static func entry(from server: [String: Any]) -> DiscoveredEntry? {
        guard let name = server["name"] as? String, !name.isEmpty else { return nil }
        if (server["isEnabled"] as? Bool) == false { return nil }
        guard let transport = server["transport"] as? [String: Any] else { return nil }
        var entry: [String: Any] = [:]
        // `oauth` may be a flag or a settings object; either way a sign-in Tinycast holds.
        var needsSecret = false
        if let oauth = server["oauth"], !(oauth is NSNull) {
            needsSecret = (oauth as? Bool) ?? true
        }
        if let stdio = transport["stdio"] as? [String: Any] {
            entry["command"] = stdio["command"] as? String
            entry["args"] = (stdio["arguments"] as? [String]) ?? []
            if let keys = stdio["environmentKeys"] as? [String], !keys.isEmpty { needsSecret = true }
        } else if let http = transport["http"] as? [String: Any] {
            entry["type"] = "http"
            entry["url"] = http["url"] as? String
            if let header = http["headerName"] as? String, !header.isEmpty { needsSecret = true }
        } else {
            return nil
        }
        if needsSecret { entry["builtin"] = true }
        return DiscoveredEntry(name: name, entry: entry)
    }
}
