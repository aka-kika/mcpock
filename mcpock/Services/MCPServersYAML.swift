import Foundation

/// Discovers MCP servers from the YAML `mcp_servers:` shape, as written by
/// Hermes (`~/.hermes/config.yaml` and its per-profile `config.yaml`s).
///
///     mcp_servers:
///       foo:
///         command: npx
///         args:
///           - -y
///           - some-server
///         env:
///           KEY: value
///       bar:
///         type: http
///         url: http://127.0.0.1:8742/mcp
///         headers:
///           Authorization: Bearer …
///
/// The field names already match the JSON `mcpServers` entry, so this is a thin
/// map over `YAMLBlock`; `enabled: false` servers are dropped like everywhere else.
enum MCPServersYAML {
    static func servers(fromYAML text: String) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for (name, fields) in YAMLBlock.entries(in: text, under: "mcp_servers") {
            if let enabled = fields["enabled"]?.scalar, enabled == "false" { continue }
            var entry: [String: Any] = [:]
            if let command = fields["command"]?.scalar, !command.isEmpty { entry["command"] = command }
            if let url = fields["url"]?.scalar, !url.isEmpty { entry["url"] = url }
            if let type = fields["type"]?.scalar, !type.isEmpty { entry["type"] = type }
            if let args = fields["args"]?.list { entry["args"] = args }
            if let env = fields["env"]?.map, !env.isEmpty { entry["env"] = env }
            if let headers = fields["headers"]?.map, !headers.isEmpty { entry["headers"] = headers }
            guard entry["command"] != nil || entry["url"] != nil else { continue }
            result[name] = entry
        }
        return result
    }

    /// Shape adapter: YAML text → discovered entries, or nil if not this shape.
    static func shapeEntries(_ text: String) -> [DiscoveredEntry]? {
        let servers = servers(fromYAML: text)
        guard !servers.isEmpty else { return nil }
        return servers.map { DiscoveredEntry(name: $0.key, entry: $0.value) }
    }
}
