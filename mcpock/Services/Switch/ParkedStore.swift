import Foundation

/// Where a switched-off server waits when its agent has no off flag (1.14:
/// Claude Desktop and Cursor). Claude Desktop rewrites
/// `claude_desktop_config.json` at launch and drops unknown keys (seen with
/// the real app, 2026-11-10), so an entry parked inside that file was gone
/// after one launch; a logged-in Cursor may rewrite `mcp.json` too. The entry
/// is moved here instead, exactly as it was written, and moved back on Turn On.
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

    enum StoreError: Error, Equatable {
        /// The store is there but can't be read as one: it may still hold
        /// parked servers, so it is never started over.
        case unreadable
        /// The store holds servers parked from another config file.
        case otherFile(String)
    }

    /// The store, or an empty one when there is none yet. A store that is
    /// there but can't be read throws: reading it as empty and saving over
    /// it lost every server parked in it (review 10 Nov, fable-1).
    private static func read(agent: String, directory: URL) throws -> (file: String, servers: [String: String]) {
        let file = url(agent: agent, directory: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return ("", [:]) }
        guard let data = try? Data(contentsOf: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw StoreError.unreadable }
        var servers: [String: String] = [:]
        for (name, value) in root["servers"] as? [String: Any] ?? [:] {
            if let raw = (value as? [String: Any])?["raw"] as? String { servers[name] = raw }
        }
        return (root["file"] as? String ?? "", servers)
    }

    private static func load(agent: String, directory: URL) -> (file: String, servers: [String: String]) {
        (try? read(agent: agent, directory: directory)) ?? ("", [:])
    }

    /// The servers parked for `agent`, name to the entry's JSON text. Only
    /// those that came from `configPath`: a store left by another setup is
    /// not this file's.
    static func entries(agent: String, configPath: String, directory: URL) -> [String: String] {
        let stored = load(agent: agent, directory: directory)
        return stored.file == configPath ? stored.servers : [:]
    }

    /// Parks one entry. Refused, with nothing written, when the store can't
    /// be read or still holds servers parked from another config file: those
    /// would be lost (fable-1). An empty store from another file starts over.
    static func add(name: String, raw: String, agent: String, configPath: String, directory: URL) throws {
        var stored = try read(agent: agent, directory: directory)
        if stored.file != configPath {
            guard stored.servers.isEmpty else { throw StoreError.otherFile(stored.file) }
            stored = (configPath, [:])
        }
        stored.servers[name] = raw
        try save(stored, agent: agent, directory: directory)
    }

    static func remove(name: String, agent: String, directory: URL) throws {
        var stored = try read(agent: agent, directory: directory)
        guard stored.servers.removeValue(forKey: name) != nil else { return }
        try save(stored, agent: agent, directory: directory)
    }

    private static func save(_ stored: (file: String, servers: [String: String]), agent: String, directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = url(agent: agent, directory: directory)
        let root: [String: Any] = ["file": stored.file, "servers": stored.servers.mapValues { ["raw": $0] }]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // 0600 from the first byte: it holds what the config held, keys included.
        let temp = directory.appendingPathComponent(".\(file.lastPathComponent).mcpock-\(UUID().uuidString)")
        do {
            try SwitchWriter.writeNew(data, to: temp, mode: 0o600)
            guard rename(temp.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
