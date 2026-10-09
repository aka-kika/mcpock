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

    static let json = ConfigShape(id: "json") { JSONConfigShape.parse($0) }
    static let mcpServersTOML = ConfigShape(id: "mcp-servers-toml") { MCPServersTOML.shapeEntries($0) }
    static let gooseYAML = ConfigShape(id: "goose-yaml") { GooseConfig.shapeEntries($0) }
    static let mcpServersYAML = ConfigShape(id: "mcp-servers-yaml") { MCPServersYAML.shapeEntries($0) }

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
