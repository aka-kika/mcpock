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
/// `"enabled": false` entries are dropped, matching the TOML and YAML readers.
enum JSONConfigShape {
    static func parse(_ text: String) -> [DiscoveredEntry]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
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
                entries.append(contentsOf: extract(mcp, projectPath: projectPath))
            }
        }
        if let servers = root["servers"] as? [String: Any] {
            entries.append(contentsOf: extract(servers, projectPath: nil))
        }
        if let mcp = root["mcp"] as? [String: Any] {
            if let servers = mcp["servers"] as? [String: Any] {
                entries.append(contentsOf: extract(servers, projectPath: nil))
            } else {
                entries.append(contentsOf: extract(mcp, projectPath: nil))
            }
        }
        // Gate: only a source if it yields at least one usable server.
        return entries.contains(where: \.hasEndpoint) ? entries : nil
    }

    private static func extract(_ dict: [String: Any], projectPath: String?) -> [DiscoveredEntry] {
        dict.compactMap { name, value in
            guard var entry = value as? [String: Any] else { return nil }
            if (entry["enabled"] as? Bool) == false { return nil }
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
