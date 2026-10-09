import Foundation

/// Discovers MCP servers from Goose's `~/.config/goose/config.yaml`.
///
/// Goose stores servers under a top-level `extensions:` map. Each extension has a
/// `type` — only `stdio`, `sse` and `streamable_http` are real MCP subprocesses;
/// `platform` and `builtin` are Goose-internal and are skipped, as are
/// `enabled: false` entries. The server's identity is its **YAML key** (`wake:`),
/// the same name every other agent uses for it, so the rows group. Goose's
/// `name:` is a display title ("Wake (agent session history)", "Chrome
/// DevTools") and is ignored: using it split Wake into its own row (round 5).
/// Reading the YAML itself is `YAMLBlock`'s job; this file only maps Goose's field
/// names onto the standard `command`/`args`/`env`/`url`/`headers` entry.
enum GooseConfig {
    static func servers(fromYAML text: String) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for (key, fields) in YAMLBlock.entries(in: text, under: "extensions") {
            if let entry = entry(fromFields: fields) {
                result[key] = entry
            }
        }
        return result
    }

    /// Shape adapter: YAML text → discovered entries, or nil if not the Goose shape.
    static func shapeEntries(_ text: String) -> [DiscoveredEntry]? {
        let servers = servers(fromYAML: text)
        guard !servers.isEmpty else { return nil }
        return servers.map { DiscoveredEntry(name: $0.key, entry: $0.value) }
    }

    /// One extension's fields → its entry, or nil if it's disabled, Goose-internal,
    /// or missing its endpoint.
    private static func entry(fromFields fields: [String: YAMLBlock.Value]) -> [String: Any]? {
        if let enabled = fields["enabled"]?.scalar, enabled != "true" { return nil }
        let type = fields["type"]?.scalar ?? ""
        guard type == "stdio" || type == "sse" || type == "streamable_http" else { return nil }

        var entry: [String: Any] = [:]
        if type == "stdio" {
            guard let cmd = fields["cmd"]?.scalar, !cmd.isEmpty else { return nil }
            entry["command"] = cmd
            entry["args"] = fields["args"]?.list ?? []
            entry["type"] = "stdio"
        } else {
            guard let uri = fields["uri"]?.scalar, !uri.isEmpty else { return nil }
            entry["url"] = uri
            entry["type"] = (type == "sse") ? "sse" : "http"
            // Auth headers for sse / streamable_http extensions. Without these an
            // authenticated local server (e.g. reed.md's bearer token) probes as 401.
            if let headers = fields["headers"]?.map, !headers.isEmpty { entry["headers"] = headers }
        }
        if let envs = fields["envs"]?.map, !envs.isEmpty { entry["env"] = envs }
        return entry
    }
}
