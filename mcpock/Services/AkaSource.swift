import Foundation

/// aka (a desktop agent app, round 5) keeps its MCP servers in its own database,
/// not in a config file. Its local sidecar lists them read-only at
/// `GET http://127.0.0.1:6464/api/mcp/servers`:
///
///     {"servers": [{"id": 9, "name": "markdownify", "transportType": "stdio",
///                   "path": "mcp-markdownify-server", "enabled": true,
///                   "authType": "none", "apiKey": null, "env": {...}, ...}]}
///
/// Round 6 mirrors aka's own launcher (`src/server/processor/mcp/client.ts`:
/// `parseStdioCommand`, `isHttpTransport`, `connectHttp`), read, not guessed:
/// - `path` starting with `http://` or `https://` is Streamable HTTP, whatever
///   `transportType` says; auth is `authType` (or bearer when only an `apiKey`
///   is set), and bearer sends `Authorization: Bearer <apiKey>`. OAuth tokens
///   stay in aka.
/// - anything else is stdio: `path` split on spaces and tabs, quotes group (no
///   backslash escapes, empty words dropped). A first word that starts with `@`
///   or has no `/` is an npm package run as `bun x -y <words>`; a `.py` path
///   runs as `python <words>`; a `.js`/`.ts`/`.mjs` path as `bun run <words>`;
///   any other path is the executable itself. `env` goes to stdio only.
/// - only `enabled` servers, like aka's startup load.
/// aka's desktop build swaps `bun` for its bundled copy and runs vendored
/// packages from its resources; its sidecar runs from source with the user's own
/// bun, so `bun` here is the user's (`bunCommand`).
///
/// Discovery asks once per rescan, off the main thread, with a short timeout;
/// when the sidecar isn't running the source is simply absent (no row, no
/// error). The payload carries secrets (`apiKey`, env values, OAuth fields):
/// only what a probe needs is kept, in memory, like every other source. The UI
/// shows env and header names only, and nothing here logs.
enum AkaSource {
    static let label = "aka"
    static let endpoint = URL(string: "http://127.0.0.1:6464/api/mcp/servers")!
    static let timeout: TimeInterval = 1.5

    /// aka's data folder, what Open Config… opens (there is no config file).
    static var dataFolder: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/pipali")
    }

    /// The sidecar's servers as configs, or none when it doesn't answer in time.
    static func discover() async -> [ServerConfig] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: endpoint),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return configs(fromJSON: data)
    }

    /// The payload mapped onto configs labelled "aka". Pure apart from `bun`,
    /// which tests replace.
    static func configs(
        fromJSON data: Data,
        bun: String = AkaSource.bunCommand()
    ) -> [ServerConfig] {
        let source = ServerSource(label: label, path: dataFolder)
        return ConfigDiscovery.configs(
            from: entries(fromJSON: data, bun: bun),
            source: source,
            idPrefix: "aka:sidecar"
        )
    }

    /// One standard entry (`command`/`args`/`env` or `url`/`headers`) per enabled
    /// server, launched the way aka launches it. Every other field (ids, OAuth,
    /// status, last error, `transportType`) is dropped here.
    static func entries(fromJSON data: Data, bun: String) -> [DiscoveredEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["servers"] as? [[String: Any]] else { return [] }
        return servers.compactMap { server in
            guard (server["enabled"] as? Bool) ?? true,
                  let name = server["name"] as? String, !name.isEmpty,
                  let path = (server["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty
            else { return nil }
            var entry: [String: Any] = [:]
            if isHTTP(path) {
                entry["type"] = "http"
                entry["url"] = path
                let key = (server["apiKey"] as? String) ?? ""
                let auth = (server["authType"] as? String) ?? (key.isEmpty ? "none" : "bearer")
                if auth == "bearer" && !key.isEmpty {
                    entry["headers"] = ["Authorization": "Bearer \(key)"]
                }
            } else {
                guard let launch = stdioLaunch(path, bun: bun) else { return nil }
                entry["type"] = "stdio"
                entry["command"] = launch.command
                entry["args"] = launch.args
                if let env = server["env"] as? [String: Any], !env.isEmpty { entry["env"] = env }
            }
            return DiscoveredEntry(name: name, entry: entry)
        }
    }

    /// aka's `isHttpTransport`: the prefix alone decides.
    static func isHTTP(_ path: String) -> Bool {
        path.hasPrefix("http://") || path.hasPrefix("https://")
    }

    /// aka's `parseStdioCommand`, with `bun` standing in for the command name.
    static func stdioLaunch(_ path: String, bun: String) -> (command: String, args: [String])? {
        let words = splitCommandLine(path)
        guard let first = words.first else { return nil }
        let rest = Array(words.dropFirst())
        if first.hasPrefix("@") || !first.contains("/") {
            return (bun, ["x", "-y", first] + rest)
        }
        if first.hasSuffix(".py") { return ("python", [first] + rest) }
        if first.hasSuffix(".js") || first.hasSuffix(".ts") || first.hasSuffix(".mjs") {
            return (bun, ["run", first] + rest)
        }
        return (first, rest)
    }

    /// aka's `splitCommandLine`: spaces and tabs split, a quote runs to the same
    /// quote character, quote marks themselves are dropped, empty words vanish.
    /// `"/Applications/Safari Technology Preview.app/…/safaridriver" --mcp` is two
    /// words.
    static func splitCommandLine(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for char in line {
            if let open = quote {
                if char == open { quote = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == " " || char == "\t" {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The `bun` aka's sidecar runs packages with. aka finds it on the login
    /// shell's PATH; mcpock, started by launchd, has a short PATH, so this looks
    /// on mcpock's PATH first, then where bun installs itself (`$BUN_INSTALL/bin`,
    /// `~/.bun/bin`). Plain `bun` when none is there (the probe then says so).
    static func bunCommand(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        lookUp: (String) -> String = { PathResolver.resolveCommand($0, env: [:]) },
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        let onPath = lookUp("bun")
        if onPath.contains("/") && isExecutable(onPath) { return onPath }
        var candidates: [String] = []
        if let install = environment["BUN_INSTALL"], !install.isEmpty {
            candidates.append((install as NSString).appendingPathComponent("bin/bun"))
        }
        candidates.append((NSHomeDirectory() as NSString).appendingPathComponent(".bun/bin/bun"))
        return candidates.first(where: isExecutable) ?? "bun"
    }
}
