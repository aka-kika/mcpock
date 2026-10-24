import Foundation

enum ConfigDiscovery {
    /// Discover configured MCP servers from known config files. Missing files are skipped.
    static func discover() -> [ServerConfig] {
        discover(registry: AgentRegistry.known, scanRoots: ConfigScanner.defaultRoots)
    }

    /// A timer round's read (9180): the known agents' files and the files the
    /// last full scan found, no folder walk. Unchanged files are not parsed
    /// again (`ParsedFileCache`).
    static func discover(knownScanFiles: [String]) -> [ServerConfig] {
        discover(registry: AgentRegistry.known, scanRoots: [], knownScanFiles: knownScanFiles)
    }

    /// The scan-found files among `configs`, for the next timer round.
    static func scanFiles(in configs: [ServerConfig]) -> [String] {
        Array(Set(configs.filter { $0.id.hasPrefix("scan:") }.map(\.source.path))).sorted()
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
        knownScanFiles: [String]? = nil,
        folderExists: (String) -> Bool = ConfigDiscovery.isExistingFolder
    ) -> [ServerConfig] {
        var servers: [ServerConfig] = []
        var claimedPaths = Set<String>()

        // 1. Registry: exact paths with friendly labels.
        for agent in registry {
            let canonical = ConfigScanner.canonicalPath(agent.path)
            let parsed: [DiscoveredEntry]? = ParsedFileCache.value(path: agent.path, kind: "registry") {
                if let parseData = agent.shape.parseData {
                    return (try? Data(contentsOf: URL(fileURLWithPath: agent.path))).flatMap(parseData)
                }
                return (try? String(contentsOfFile: agent.path, encoding: .utf8)).flatMap(agent.shape.parse)
            }
            guard let parsed else { continue }
            let entries = droppingStaleProjects(parsed, folderExists: folderExists)
            claimedPaths.insert(canonical)
            let source = ServerSource(label: agent.label, path: agent.path)
            servers.append(contentsOf: configs(from: entries, source: source, idPrefix: "reg:\(agent.label)"))
        }

        // A project's `.mcp.json` servers run only when Claude Code was told to
        // run them there (review 2026-10-20 db0c; off ones: Argon 2026-10-17 #8).
        let claudeJSON = registry.first { $0.label == AgentRegistry.claudeCodeLabel }?.path
        let approvals = claudeJSON.flatMap { path in
            ParsedFileCache.value(path: path, kind: "approvals") {
                (try? String(contentsOfFile: path, encoding: .utf8)).map { ClaudeProjectApproval.projects(claudeJSON: $0) }
            }
        } ?? [:]
        let userSettings = claudeJSON
            .map { (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent(".claude/settings.json") }
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .flatMap(ClaudeProjectApproval.object)

        // 2. Scan: everything else, deduped against the registry.
        let hits = knownScanFiles.map(ConfigScanner.scan(files:)) ?? ConfigScanner.scan(roots: scanRoots)
        for hit in hits where !claimedPaths.contains(hit.path) {
            claimedPaths.insert(hit.path)
            let source = ServerSource(
                label: label(forScannedPath: hit.path, derived: hit.label, registry: registry),
                path: hit.path
            )
            let folder = claudeProjectFolder(forScannedPath: hit.path)
            let approval = folder.map {
                ClaudeProjectApproval.forFolder($0, projects: approvals, userSettings: userSettings)
            }
            servers.append(contentsOf: configs(
                from: droppingStaleProjects(hit.entries, folderExists: folderExists).filter { approval?.allows($0.name) ?? true },
                source: source,
                idPrefix: "scan:\(hit.path)",
                projectPath: folder
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
        // A command given as a list (["npx", "pkg"]) runs its first word with
        // the rest in front of `args`, as the agents that accept it do (r3 e412).
        let listed = (entry["command"] as? [String])?.filter { !$0.isEmpty }
        let command = (entry["command"] as? String) ?? listed?.first
        let args = (listed.map { Array($0.dropFirst()) } ?? []) + ((entry["args"] as? [String]) ?? [])
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
            // No command (and no url): kept as a row that says so, instead of
            // vanishing while the agent still lists it (r3 e412).
            let command = command.flatMap { $0.isEmpty ? nil : $0 }
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
        let helper = source.label == AgentRegistry.claudeCodeLabel
            ? (entry["headersHelper"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
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

/// Parsed config files, kept until the file changes (r3 d40b): the
/// multi-MB `~/.claude.json` was read and parsed twice every round. Keyed
/// by path and kind; a file's modification time, size and inode say
/// whether it changed. A file over `maxBytes` is not read at all.
enum ParsedFileCache {
    static let maxBytes = 64 * 1024 * 1024

    private struct Stamp: Equatable {
        let modified: Date
        let size: Int
        let inode: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: (stamp: Stamp, value: Any?)] = [:]

    static func value<T>(path: String, kind: String, _ make: () -> T?) -> T? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, size <= maxBytes else { return nil }
        let stamp = Stamp(modified: attributes[.modificationDate] as? Date ?? .distantPast, size: size,
                          inode: attributes[.systemFileNumber] as? Int ?? 0)
        let key = kind + "\u{1F}" + path
        lock.lock()
        let hit = entries[key]
        lock.unlock()
        if let hit, hit.stamp == stamp, let value = hit.value as? T? { return value }
        let value = make()
        lock.lock()
        entries[key] = (stamp, value)
        lock.unlock()
        return value
    }

    static func removeAll() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }
}
