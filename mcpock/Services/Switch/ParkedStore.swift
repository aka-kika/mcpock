import Foundation

/// Where a switched-off server waits when its agent keeps nothing it does not
/// know in its own config (1.14). Claude Desktop rewrites
/// `claude_desktop_config.json` on every launch and drops unknown keys (seen
/// with the real app, 2026-11-10), so an entry parked inside that file was
/// gone after one launch. Such an entry is moved here instead, exactly as it
/// was written, and moved back on Turn On.
///
/// One small file per agent in `~/Library/Application Support/mcpock/parked/`,
/// readable only by the user (it holds what the config held, keys included):
///
///     { "file": "<the config it came from>",
///       "servers": { "<name>": { "raw": "<the entry's JSON, as written>" } } }
enum ParkedStore {
    static var defaultDirectory: URL {
        MCPockStatus.defaultDirectory().appendingPathComponent("parked", isDirectory: true)
    }

    /// "claude-desktop.json" for "Claude Desktop".
    static func fileName(forAgent label: String) -> String {
        String(label.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }) + ".json"
    }

    private static func url(agent: String, directory: URL) -> URL {
        directory.appendingPathComponent(fileName(forAgent: agent))
    }

    private static func load(agent: String, directory: URL) -> (file: String, servers: [String: String]) {
        guard let data = try? Data(contentsOf: url(agent: agent, directory: directory)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ("", [:]) }
        var servers: [String: String] = [:]
        for (name, value) in root["servers"] as? [String: Any] ?? [:] {
            if let raw = (value as? [String: Any])?["raw"] as? String { servers[name] = raw }
        }
        return (root["file"] as? String ?? "", servers)
    }

    /// The servers parked for `agent`, name to the entry's JSON text. Only
    /// those that came from `configPath`: a store left by another setup is
    /// not this file's.
    static func entries(agent: String, configPath: String, directory: URL) -> [String: String] {
        let stored = load(agent: agent, directory: directory)
        return stored.file == configPath ? stored.servers : [:]
    }

    static func add(name: String, raw: String, agent: String, configPath: String, directory: URL) throws {
        var stored = load(agent: agent, directory: directory)
        if stored.file != configPath { stored = (configPath, [:]) }
        stored.servers[name] = raw
        try save(stored, agent: agent, directory: directory)
    }

    static func remove(name: String, agent: String, directory: URL) throws {
        var stored = load(agent: agent, directory: directory)
        guard stored.servers.removeValue(forKey: name) != nil else { return }
        try save(stored, agent: agent, directory: directory)
    }

    private static func save(_ stored: (file: String, servers: [String: String]), agent: String, directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = url(agent: agent, directory: directory)
        let root: [String: Any] = ["file": stored.file, "servers": stored.servers.mapValues { ["raw": $0] }]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
