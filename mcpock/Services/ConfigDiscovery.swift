import Foundation

enum ConfigDiscovery {
    /// Discover configured MCP servers from known config files. Missing files are skipped.
    static func discover() -> [ServerConfig] {
        discover(registry: AgentRegistry.known, scanRoots: ConfigScanner.defaultRoots)
    }

    /// Testable core: registry entries + a scan of `scanRoots`, deduped by canonical
    /// file path (registry wins), normalized to `ServerConfig`s.
    ///
    /// Round 6: a project-scoped entry (Claude Code's `projects.<path>.mcpServers`)
    /// whose project folder no longer exists is skipped (`droppingStaleProjects`):
    /// its agent can't start it either, so it must not show as broken ("Could not
    /// start: The file WeeklyContentCalendar doesn't exist"). The same server
    /// declared elsewhere just loses that one source.
    static func discover(
        registry: [KnownAgent],
        scanRoots: [String],
        folderExists: (String) -> Bool = ConfigDiscovery.isExistingFolder
    ) -> [ServerConfig] {
        var servers: [ServerConfig] = []
        var claimedPaths = Set<String>()

        // 1. Registry: exact paths with friendly labels.
        for agent in registry {
            let canonical = ConfigScanner.canonicalPath(agent.path)
            guard let text = try? String(contentsOfFile: agent.path, encoding: .utf8),
                  let parsed = agent.shape.parse(text) else { continue }
            let entries = droppingStaleProjects(parsed, folderExists: folderExists)
            claimedPaths.insert(canonical)
            let source = ServerSource(label: agent.label, path: agent.path)
            servers.append(contentsOf: configs(from: entries, source: source, idPrefix: "reg:\(agent.label)"))
        }

        // 2. Scan: everything else, deduped against the registry.
        for hit in ConfigScanner.scan(roots: scanRoots) where !claimedPaths.contains(hit.path) {
            claimedPaths.insert(hit.path)
            let source = ServerSource(
                label: label(forScannedPath: hit.path, derived: hit.label, registry: registry),
                path: hit.path
            )
            servers.append(contentsOf: configs(
                from: droppingStaleProjects(hit.entries, folderExists: folderExists),
                source: source,
                idPrefix: "scan:\(hit.path)",
                projectPath: claudeProjectFolder(forScannedPath: hit.path)
            ))
        }

        return servers.sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) != .orderedSame {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.source.label < $1.source.label
        }
    }

    /// Entries whose own `projectPath` names a folder that is gone are left out;
    /// global entries (no project) always stay.
    static func droppingStaleProjects(
        _ entries: [DiscoveredEntry],
        folderExists: (String) -> Bool
    ) -> [DiscoveredEntry] {
        entries.filter { entry in
            guard let project = entry.projectPath, !project.isEmpty else { return true }
            return folderExists(project)
        }
    }

    /// True when `path` (tilde expanded) is an existing directory.
    static func isExistingFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let expanded = (path as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Label for a scanned file. A file that lives inside a known agent's own config
    /// directory (`~/.hermes/profiles/scribe/config.yaml` next to Hermes's
    /// `~/.hermes/config.yaml`) is that agent's: "Hermes · scribe", not a bare
    /// "scribe" that reads as an agent nobody installed. Registry paths that sit
    /// directly in `~` (Claude Code's `~/.claude.json`) claim nothing.
    ///
    /// A scanned `.mcp.json` is Claude Code's project-scope config (that file name
    /// is Claude Code's convention), so it is labelled Claude Code, not after its
    /// folder: `~/.claude/.mcp.json` used to show up as an agent called "claude".
    /// Its folder becomes the project (`claudeProjectFolder`), so it reads
    /// "Claude Code (.claude)" like any other project-scoped Claude Code server.
    static func label(forScannedPath path: String, derived: String, registry: [KnownAgent]) -> String {
        if claudeProjectFolder(forScannedPath: path) != nil { return AgentRegistry.claudeCodeLabel }
        let home = NSHomeDirectory()
        for agent in registry {
            let dir = (agent.path as NSString).deletingLastPathComponent
            guard dir != home, path.hasPrefix(dir + "/") else { continue }
            return "\(agent.label) · \(derived)"
        }
        return derived
    }

    /// The project folder of a scanned Claude Code `.mcp.json` (the folder it sits
    /// in, where Claude Code starts its servers), or nil for any other file.
    static func claudeProjectFolder(forScannedPath path: String) -> String? {
        guard (path as NSString).lastPathComponent == ".mcp.json" else { return nil }
        return (path as NSString).deletingLastPathComponent
    }

    /// Build `ServerConfig`s from shape-extracted entries, reusing the shared
    /// `parseEntry` normalization (transport inference, env, id). `projectPath`
    /// applies to entries that don't carry their own (a whole file that belongs
    /// to one project).
    static func configs(
        from entries: [DiscoveredEntry],
        source: ServerSource,
        idPrefix: String,
        projectPath: String? = nil
    ) -> [ServerConfig] {
        entries.compactMap { e in
            let scope = e.projectPath.map { "proj:\($0)" } ?? "global"
            return parseEntry(
                name: e.name,
                entry: e.entry,
                source: source,
                projectPath: e.projectPath ?? projectPath,
                idPrefix: "\(idPrefix):\(scope)"
            )
        }
    }

    private static func parseEntry(
        name: String,
        entry: [String: Any],
        source: ServerSource,
        projectPath: String?,
        idPrefix: String
    ) -> ServerConfig? {
        let typeString = (entry["type"] as? String)?.lowercased()
        let urlString = entry["url"] as? String
        let command = entry["command"] as? String
        let args = (entry["args"] as? [String]) ?? []
        let env = stringifyEnv(entry["env"])
        let headers = stringifyEnv(entry["headers"])
        let builtin = (entry["builtin"] as? Bool) ?? false

        let transport: TransportKind
        if let typeString {
            switch typeString {
            case "http", "streamable-http", "streamablehttp":
                transport = .http
            case "sse":
                transport = .sse
            case "stdio":
                transport = .stdio
            default:
                transport = urlString != nil ? .http : .stdio
            }
        } else if urlString != nil {
            transport = .http
        } else {
            transport = .stdio
        }

        if transport == .stdio {
            guard let command, !command.isEmpty else { return nil }
            return ServerConfig(
                id: "\(idPrefix):\(name)",
                name: name,
                source: source,
                projectPath: projectPath,
                transport: .stdio,
                command: command,
                args: args,
                env: env,
                url: nil,
                headers: [:],
                builtin: builtin
            )
        }

        guard let urlString, !urlString.isEmpty else { return nil }
        let helper = (entry["headersHelper"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = ServerConfig(
            id: "\(idPrefix):\(name)",
            name: name,
            source: source,
            projectPath: projectPath,
            transport: transport,
            command: nil,
            args: [],
            env: env,
            url: urlString,
            headers: headers,
            builtin: builtin
        )
        if let helper, !helper.isEmpty { config.headersHelper = helper }
        return config
    }

    private static func stringifyEnv(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (k, v) in dict {
            if let s = v as? String {
                result[k] = s
            } else if let n = v as? NSNumber {
                result[k] = n.stringValue
            } else {
                result[k] = String(describing: v)
            }
        }
        return result
    }
}
