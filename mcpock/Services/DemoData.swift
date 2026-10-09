import Foundation

/// A curated, fully offline sample set for screenshots — the website and
/// README must never show real server names, paths or tokens.
///
/// Turned on by the launch argument `--demo` or the environment variable
/// `MCPOCK_DEMO=1`; off, and invisible, otherwise (no menu, no setting, no
/// banner). `MCPockApp.init` checks `isActive()` once at launch and, only
/// then, swaps `HealthMonitor.discover` and `HealthMonitor.probe` for the
/// closures here, points the monitor/panel at a throwaway `UserDefaults`
/// suite, and gives `UsageStore` its own fake readers and a scratch
/// directory. Demo mode never scans this Mac, never spawns a process, never
/// opens a network connection, and never touches the real status file,
/// widget snapshot (unless `--demo-widgets` asks for it), usage file or saved
/// settings.
///
/// Every health state the panel can draw appears at least once, across the
/// agents mcpock's screenshots need to show (Claude Code, Cursor, Grok,
/// Goose, Hermes, Claude Desktop, Codex): nine healthy servers, one needs
/// sign-in (HTTP 401), one slow, one broken, one set up differently (two
/// agents disagreeing about how to launch the same server), one paused.
enum DemoData {
    // MARK: - On/off

    /// True when the app should show this sample data instead of the user's real
    /// setup. Parameters are injectable only so a test can check the
    /// detection logic without touching the real process arguments.
    static func isActive(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.contains("--demo") || environment["MCPOCK_DEMO"] == "1"
    }

    /// `--demo-widgets` on top of demo mode (1.9.0): the sample set also goes
    /// to the desktop widgets, for widget screenshots. The widgets' file is
    /// shared, so this replaces the real setup's widget data until the real
    /// app runs again and rewrites it. Never true without demo mode.
    static func writesWidgets(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        isActive(arguments: arguments, environment: environment) && arguments.contains("--demo-widgets")
    }

    // MARK: - Isolation (never the user's real files or defaults)

    /// A fixed, non-UUID suite name: every demo launch starts from the same
    /// clean slate (wiped in `makeThrowawayDefaults`), so nothing from an
    /// earlier demo run — someone poking a row for a screenshot — carries
    /// over. Never `.standard`; that domain is the real app.
    private static let suiteName = "com.mcpock.app.demo"

    /// A throwaway `UserDefaults` suite for the monitor and panel to persist
    /// into, wiped first so every launch looks identical. Same pattern the
    /// unit tests use (`UserDefaults(suiteName:)`), except this suite is
    /// meant to be reused between demo launches, not deleted afterward.
    static func makeThrowawayDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// Pre-seeds the one preference the sample set needs before
    /// `HealthMonitor.init` reads it: `cloudflare-docs` starts paused, the
    /// same way a real paused server would (`HealthMonitor.merged` reads
    /// this at discovery time).
    static func seedPreferences(_ defaults: UserDefaults) {
        AppPreferences.savePausedServers([HealthMonitor.normalizedName(pausedServerName)], to: defaults)
    }

    /// A scratch directory for the usage store, so `UsageStore.load()` never
    /// even reads the real `usage.json` — `isHostingTests` already stops
    /// it writing one, this stops it reading one too.
    static func throwawayDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-demo", isDirectory: true)
    }

    // MARK: - Servers

    private static let pausedServerName = "cloudflare-docs"

    /// One declared server: its config plus the canned probe result it
    /// always returns. `extra`, set once (stripe), gives the same server
    /// name a second declaration under a different agent with a different
    /// launch target, so the panel shows a real "set up differently" row.
    private struct Spec {
        let name: String
        let agent: String
        let path: String
        let command: String
        let args: [String]
        let env: [String: String]
        let result: ProbeResult
        let extra: (agent: String, path: String, command: String, args: [String])?

        init(
            _ name: String, agent: String, path: String, command: String, args: [String],
            env: [String: String] = [:], result: ProbeResult,
            extra: (agent: String, path: String, command: String, args: [String])? = nil
        ) {
            self.name = name
            self.agent = agent
            self.path = path
            self.command = command
            self.args = args
            self.env = env
            self.result = result
            self.extra = extra
        }
    }

    private static func tool(_ name: String, _ description: String) -> MCPToolInfo {
        MCPToolInfo(name: name, description: description)
    }

    /// The 14 servers. Real-sounding names and tools, generic un-expanded
    /// paths (`~/.claude.json`, never an expanded `/Users/...` path), and
    /// wording that matches how the real probes phrase a failure
    /// (`ProbeError.errorDescription`, `StdioProbe.reason`), so a screenshot
    /// reads exactly like the real app.
    private static let specs: [Spec] = [
        Spec("github", agent: "Code", path: "~/.claude.json",
             command: "npx", args: ["-y", "@modelcontextprotocol/server-github"],
             result: ProbeResult(state: .healthy, failureReason: nil, tools: [
                tool("create_issue", "Open a new issue in a repository."),
                tool("search_repositories", "Search GitHub repositories by name or topic."),
                tool("get_pull_request", "Fetch a pull request's details and review status."),
             ])),
        Spec("brave-search", agent: "Code", path: "~/.claude.json",
             command: "npx", args: ["-y", "@modelcontextprotocol/server-brave-search"],
             result: ProbeResult(state: .healthy, failureReason: nil, tools: [
                tool("web_search", "Search the web and return ranked results."),
             ])),
        Spec("filesystem", agent: "Cursor", path: "~/.cursor/mcp.json",
             command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "~/Projects"],
             result: ProbeResult(state: .healthy, failureReason: nil, tools: [
                tool("read_file", "Read the contents of a file."),
                tool("write_file", "Write text to a file, creating it if needed."),
                tool("list_directory", "List the files and folders in a directory."),
             ])),
        Spec("memory", agent: "Cursor", path: "~/.cursor/mcp.json",
             command: "npx", args: ["-y", "@modelcontextprotocol/server-memory"],
             result: ProbeResult(state: .healthy, failureReason: nil, tools: [
                tool("create_entities", "Add entities to the knowledge graph."),
                tool("search_nodes", "Search the knowledge graph by keyword."),
             ])),
        Spec("slack", agent: "Grok", path: "~/.grok/config.toml",
             command: "npx", args: ["-y", "@modelcontextprotocol/server-slack"],
             result: ProbeResult(state: .healthy, failureReason: nil, tools: [
                tool("send_message", "Post a message to a channel."),
                tool("list_channels", "List the channels in a workspace."),
                tool("get_user_info", "Look up a workspace member's profile."),
             ])),
        // Paused: never probed (`HealthMonitor.shouldProbe`); this result is
        // never read, kept only so every spec shape is the same.
        Spec("cloudflare-docs", agent: "Grok", path: "~/.grok/config.toml",
             command: "npx", args: ["-y", "@cloudflare/mcp-server-docs"],
             result: ProbeResult(state: .healthy, failureReason: nil, tools: [
                tool("search_docs", "Search Cloudflare's developer documentation."),
             ])),
        Spec("playwright", agent: "Goose", path: "~/.config/goose/config.yaml",
             command: "npx", args: ["-y", "@playwright/mcp"],
             result: ProbeResult(state: .healthy, failureReason: nil, tools: [
                tool("navigate", "Open a URL in the browser."),
                tool("screenshot", "Capture a screenshot of the current page."),
                tool("click", "Click an element on the page."),
             ])),
        // Slow: a transient timeout, same wording as a real one
        // (`ProbeError.timeout`), shows amber before it would ever go red.
        Spec("figma", agent: "Goose", path: "~/.config/goose/config.yaml",
             command: "npx", args: ["-y", "figma-developer-mcp"],
             result: ProbeResult(state: .broken, failureReason: "Timed out after 10s",
                                  tools: nil, transientFailure: true)),
        Spec("context7", agent: "Hermes", path: "~/.hermes/config.yaml",
             command: "npx", args: ["-y", "@upstash/context7-mcp"],
             result: ProbeResult(state: .healthy, failureReason: nil, tools: [
                tool("resolve_library_id", "Find a library's Context7 ID from its name."),
                tool("get_library_docs", "Fetch up-to-date documentation for a library."),
             ])),
        // Needs sign-in: the exact "Needs authentication (HTTP …)" wording
        // `ServerGroup.needsSignIn` matches (`ProbeError.httpError`), so the
        // row reads "Needs sign-in" and stays a stable amber, never red.
        Spec("notion", agent: "Hermes", path: "~/.hermes/config.yaml",
             command: "npx", args: ["-y", "@notionhq/notion-mcp-server"],
             result: ProbeResult(state: .broken, failureReason: "Needs authentication (HTTP 401)",
                                  tools: nil, needsAttention: true)),
        Spec("linear", agent: "Claude Desktop", path: "~/Library/Application Support/Claude/claude_desktop_config.json",
             command: "npx", args: ["-y", "@linear/mcp-server"],
             result: ProbeResult(state: .healthy, failureReason: nil, tools: [
                tool("create_issue", "Create a new issue in a Linear project."),
                tool("list_issues", "List issues assigned to you or your team."),
                tool("update_issue", "Change an issue's status, assignee or priority."),
             ])),
        // Set up differently: Cursor and Claude Desktop each launch stripe a
        // different way, so `Differs.detect` names both (no majority — a
        // 1-vs-1 split) and the row reads "Set up differently" while both
        // instances stay healthy.
        Spec("stripe", agent: "Cursor", path: "~/.cursor/mcp.json",
             command: "npx", args: ["-y", "@stripe/mcp"],
             result: ProbeResult(state: .healthy, failureReason: nil, tools: [
                tool("create_payment_link", "Create a shareable payment link."),
                tool("list_charges", "List recent charges."),
             ]),
             extra: (agent: "Claude Desktop",
                     path: "~/Library/Application Support/Claude/claude_desktop_config.json",
                     command: "stripe-mcp", args: ["--tools=all"])),
        Spec("sentry", agent: "Codex", path: "~/.codex/config.toml",
             command: "npx", args: ["-y", "@sentry/mcp-server"],
             result: ProbeResult(state: .healthy, failureReason: nil, tools: [
                tool("list_issues", "List recent error issues for a project."),
                tool("get_event", "Fetch one error event's details and stack trace."),
                tool("resolve_issue", "Mark an issue as resolved."),
             ])),
        // Broken: a definitive, readable failure — same "Non-zero exit (N)
        // — Error: …" shape a real stdio crash reports.
        Spec("postgres", agent: "Codex", path: "~/.codex/config.toml",
             command: "npx",
             args: ["-y", "@modelcontextprotocol/server-postgres", "postgres://demo:demo@localhost:5432/demo"],
             result: ProbeResult(state: .broken,
                                  failureReason: "Non-zero exit (1) — Error: connect ECONNREFUSED 127.0.0.1:5432",
                                  tools: nil)),
    ]

    private static func makeConfig(
        name: String, agent: String, path: String, command: String, args: [String], env: [String: String]
    ) -> ServerConfig {
        ServerConfig(
            id: "\(agent):\(name)",
            name: name,
            source: ServerSource(label: agent, path: path),
            projectPath: nil,
            transport: .stdio,
            command: command,
            args: args,
            env: env,
            url: nil,
            headers: [:]
        )
    }

    /// Every declared instance (15: the 14 servers, plus stripe's second
    /// declaration), in a stable order. What `HealthMonitor.discover` is
    /// swapped for in demo mode.
    static let configs: [ServerConfig] = specs.flatMap { spec -> [ServerConfig] in
        var out = [makeConfig(name: spec.name, agent: spec.agent, path: spec.path,
                               command: spec.command, args: spec.args, env: spec.env)]
        if let extra = spec.extra {
            out.append(makeConfig(name: spec.name, agent: extra.agent, path: extra.path,
                                   command: extra.command, args: extra.args, env: [:]))
        }
        return out
    }

    /// The canned result for every config above, keyed by `ServerConfig.id`.
    private static let probeResultsByID: [String: ProbeResult] = {
        var out: [String: ProbeResult] = [:]
        for spec in specs {
            out["\(spec.agent):\(spec.name)"] = spec.result
            if let extra = spec.extra {
                out["\(extra.agent):\(spec.name)"] = spec.result
            }
        }
        return out
    }()

    /// What `HealthMonitor.probe` is swapped for in demo mode: a fixed
    /// answer per server, never a spawn or a network call.
    static func probeResult(for config: ServerConfig) -> ProbeResult {
        probeResultsByID[config.id] ?? ProbeResult(state: .healthy, failureReason: nil, tools: [])
    }

    // MARK: - Usage counts

    /// One agent's usage events, handed out exactly once: the cursor comes
    /// back non-empty, so a later refresh (a real probe cycle firing
    /// `HealthMonitor.onCycleFinished`) returns nothing new — the same
    /// shape a real reader has once it has caught up.
    private struct DemoUsageReader: UsageReader {
        let agent: String
        let events: [UsageEvent]

        func read(since cursor: UsageCursor, knownServers: Set<String>) -> (events: [UsageEvent], cursor: UsageCursor) {
            guard cursor.values.isEmpty else { return ([], cursor) }
            return (events, UsageCursor(values: ["seeded": 1]))
        }
    }

    /// Plausible call counts, never real transcripts: a fixed event
    /// list per agent, spread over today, this month and further back so
    /// the 7-day, 30-day and all-time windows each show a different,
    /// believable number, the same way a real setup would.
    static var usageReaders: [UsageReader] {
        let now = Date()
        func events(_ agent: String, _ server: String, recent: Int, mid: Int, old: Int) -> [UsageEvent] {
            func day(_ count: Int, agoDays: Int) -> [UsageEvent] {
                guard count > 0 else { return [] }
                let date = Calendar.current.date(byAdding: .day, value: -agoDays, to: now) ?? now
                return (0..<count).map { _ in UsageEvent(agent: agent, server: server, date: date) }
            }
            // Within the last 7 days, within 30 but not 7, and older than 30
            // (counted only in "All time") — one bucket for each window.
            return day(recent, agoDays: 2) + day(mid, agoDays: 20) + day(old, agoDays: 55)
        }
        let byAgent: [String: [UsageEvent]] = [
            "Code": events("Code", "github", recent: 18, mid: 42, old: 31)
                + events("Code", "brave-search", recent: 20, mid: 33, old: 12),
            "Cursor": events("Cursor", "filesystem", recent: 25, mid: 30, old: 10)
                + events("Cursor", "memory", recent: 7, mid: 9, old: 3)
                + events("Cursor", "stripe", recent: 5, mid: 6, old: 2),
            "Grok": events("Grok", "slack", recent: 15, mid: 25, old: 18)
                + events("Grok", "cloudflare-docs", recent: 0, mid: 2, old: 5),
            "Goose": events("Goose", "playwright", recent: 6, mid: 14, old: 9)
                + events("Goose", "figma", recent: 2, mid: 3, old: 1),
            "Hermes": events("Hermes", "context7", recent: 12, mid: 20, old: 5)
                + events("Hermes", "notion", recent: 0, mid: 1, old: 0),
            "Claude Desktop": events("Claude Desktop", "linear", recent: 9, mid: 11, old: 4)
                + events("Claude Desktop", "stripe", recent: 3, mid: 4, old: 1),
            "Codex": events("Codex", "sentry", recent: 4, mid: 8, old: 2)
                + events("Codex", "postgres", recent: 1, mid: 2, old: 0),
        ]
        return byAgent.map { agent, events in DemoUsageReader(agent: agent, events: events) }
    }
}
