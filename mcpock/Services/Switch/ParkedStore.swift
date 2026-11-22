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
///       "servers": { "<name>": { "raw": "<the entry's JSON, as written>",
///                                "after": "<the entry above it>", "before": "<the entry below it>" } } }
///
/// `after` and `before` (22 Nov) are where it sat, so Turn On puts it back in
/// its own place and not at the end; a store from before has neither.
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

    /// The store's file, for a plan that changes an entry while it waits (review 22 Nov).
    static func fileURL(agent: String, directory: URL) -> URL { url(agent: agent, directory: directory) }

    /// The store's text with one waiting entry's JSON replaced, written the
    /// way `save` writes it; nil when the text is not a store or has no such entry.
    static func text(replacing name: String, raw: String, in text: String) -> String? {
        guard var root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              var servers = root["servers"] as? [String: Any], var fields = servers[name] as? [String: Any] else { return nil }
        fields["raw"] = raw   // where it sat stays as it is
        servers[name] = fields
        root["servers"] = servers
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Where an entry sat in its list: the names of its neighbours.
    struct Place: Equatable, Sendable {
        var after: String?
        var before: String?
    }

    /// One waiting entry: its JSON text and where it sat.
    private struct Entry {
        var raw: String
        var place = Place()

        var json: [String: Any] {
            var out: [String: Any] = ["raw": raw]
            if let after = place.after { out["after"] = after }
            if let before = place.before { out["before"] = before }
            return out
        }
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
    private static func read(agent: String, directory: URL) throws -> (file: String, servers: [String: Entry]) {
        let file = url(agent: agent, directory: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return ("", [:]) }
        guard let data = try? Data(contentsOf: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw StoreError.unreadable }
        var servers: [String: Entry] = [:]
        for (name, value) in root["servers"] as? [String: Any] ?? [:] {
            guard let fields = value as? [String: Any], let raw = fields["raw"] as? String else { continue }
            servers[name] = Entry(raw: raw, place: Place(after: fields["after"] as? String, before: fields["before"] as? String))
        }
        return (root["file"] as? String ?? "", servers)
    }

    private static func load(agent: String, directory: URL) -> (file: String, servers: [String: Entry]) {
        (try? read(agent: agent, directory: directory)) ?? ("", [:])
    }

    /// The servers parked for `agent`, name to the entry's JSON text. Only
    /// those that came from `configPath`: a store left by another setup is
    /// not this file's.
    static func entries(agent: String, configPath: String, directory: URL) -> [String: String] {
        let stored = load(agent: agent, directory: directory)
        return stored.file == configPath ? stored.servers.mapValues(\.raw) : [:]
    }

    /// Where a waiting entry sat in `configPath`'s list; empty for one parked before 22 Nov.
    static func place(of name: String, agent: String, configPath: String, directory: URL) -> Place {
        let stored = load(agent: agent, directory: directory)
        return stored.file == configPath ? (stored.servers[name]?.place ?? Place()) : Place()
    }

    /// Parks one entry. Refused, with nothing written, when the store can't
    /// be read or still holds servers parked from another config file: those
    /// would be lost (fable-1). An empty store from another file starts over.
    static func add(name: String, raw: String, place: Place = Place(), agent: String, configPath: String, directory: URL) throws {
        var stored = try read(agent: agent, directory: directory)
        if stored.file != configPath {
            guard stored.servers.isEmpty else { throw StoreError.otherFile(stored.file) }
            stored = (configPath, [:])
        }
        stored.servers[name] = Entry(raw: raw, place: place)
        try save(stored, agent: agent, directory: directory)
    }

    static func remove(name: String, agent: String, directory: URL) throws {
        var stored = try read(agent: agent, directory: directory)
        guard stored.servers.removeValue(forKey: name) != nil else { return }
        try save(stored, agent: agent, directory: directory)
    }

    private static func save(_ stored: (file: String, servers: [String: Entry]), agent: String, directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = url(agent: agent, directory: directory)
        let root: [String: Any] = ["file": stored.file, "servers": stored.servers.mapValues(\.json)]
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
