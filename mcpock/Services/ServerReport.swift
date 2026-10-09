import Foundation

/// What the server menu's "Copy Details" and "Ask an Agent" put on the
/// clipboard (1.5.3). Both start from the status file's entry for the row
/// (`StatusSnapshot.server`), so they carry exactly the status file's masking:
/// env and header names only, secret-looking arguments, URL secrets and echoed
/// keys replaced with dots. Pure, so `ServerReportTests` pins the texts down.
enum ServerReport {
    /// The row as the status file would hold it, secrets masked.
    static func entry(for group: ServerGroup, servers: [ServerSnapshot]) -> MCPockStatus.Server {
        let byID = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return StatusSnapshot.server(group, byID: byID, hidden: false, pinned: false)
    }

    // MARK: - Copy Details

    /// "Copy Details": name, state, every agent with its config path,
    /// transport and masked command or URL, the tool count, when it was last
    /// checked. The same for every state; errors are "Copy Errors"' job.
    static func detailsText(_ server: MCPockStatus.Server, now: Date) -> String {
        var lines = ["MCP server: \(server.name)", "Status: \(server.status)"]
        if let differs = server.differs, !differs.isEmpty {
            lines.append("Set up differently: \(differs)")
        }
        if let onPurpose = server.differsOnPurpose, !onPurpose.isEmpty {
            lines.append("Set up differently, marked as intended: \(onPurpose)")
        }
        if !server.transports.isEmpty {
            lines.append("Transport: \(server.transports.joined(separator: " / "))")
        }
        lines.append("Tools: \(server.toolCount)")
        lines.append("Last checked: " + (server.lastChecked.map { checkedText($0, now: now) } ?? "not yet"))
        let count = server.sources.count
        lines.append("")
        lines.append("Used by (\(count) declaration\(count == 1 ? "" : "s")):")
        for source in server.sources {
            var head = "- \(source.agent) (\(source.transport), \(stateWord(source))"
            if source.differs { head += ", set up differently" }
            lines.append(head + ")")
            if !source.configPath.isEmpty { lines.append("  config: \(source.configPath)") }
            if !source.target.isEmpty { lines.append("  runs: \(source.target)") }
            if !source.envNames.isEmpty {
                lines.append("  env: \(source.envNames.joined(separator: ", ")) (values not shown)")
            }
            if !source.headerNames.isEmpty {
                lines.append("  headers: \(source.headerNames.joined(separator: ", ")) (values not shown)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "2026-09-24 14:05 (3 min ago)": the clock time survives a paste read an
    /// hour later, the age reads at a glance.
    static func checkedText(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: date)) (\(RelativeAge.text(since: date, now: now)))"
    }

    /// A declaration's raw state in the status file's plain words.
    private static func stateWord(_ source: MCPockStatus.Source) -> String {
        switch source.state {
        case HealthState.healthy.rawValue: return "fine"
        case HealthState.degraded.rawValue:
            return (source.failure ?? "").hasPrefix("Needs authentication") ? "needs sign-in" : "slow"
        case HealthState.broken.rawValue: return "broken"
        case HealthState.unknown.rawValue: return "not checked yet"
        case HealthState.paused.rawValue: return "paused"
        case HealthState.selfManaged.rawValue: return "managed by its app"
        default: return source.state
        }
    }

    // MARK: - Errors, masked

    /// Each failing declaration's full error and what it runs, masked. Empty
    /// when nothing fails.
    static func errorLines(_ server: MCPockStatus.Server) -> [String] {
        var lines: [String] = []
        for source in server.sources {
            guard let failure = source.failure, !failure.isEmpty else { continue }
            lines.append("- \(source.agent): \(failure)")
            if !source.target.isEmpty { lines.append("  runs: \(source.target)") }
        }
        return lines
    }

    // MARK: - Ask an Agent

    /// Only a row with something to ask about offers "Ask an Agent": broken,
    /// slow, needs sign-in, or set up differently (not marked as intended).
    static func canAskAgent(_ group: ServerGroup) -> Bool {
        PanelSections.needsYou(group)
    }

    /// The problem in one clause, after "mcpock reports that <name> ".
    static func problemClause(_ server: MCPockStatus.Server) -> String {
        let reason = server.reason.flatMap { $0.isEmpty ? nil : $0 }
        switch server.status {
        case "broken": return "is broken" + (reason.map { " (\($0))" } ?? "")
        case "slow": return "is slow to answer" + (reason.map { " (\($0))" } ?? "")
        case "needs sign-in": return "needs sign-in" + (reason.map { " (\($0))" } ?? "")
        case "set up differently":
            return "is set up differently across my agents" + (server.differs.map { ": \($0)" } ?? "")
        default: return "needs a look (status: \(server.status))"
        }
    }

    /// "Ask an Agent": a prompt for any agent that asks it to investigate and
    /// advise, never to fix on its own. `mcpockAgents` are the agents that
    /// have mcpock's own MCP server set up; with any, the prompt mentions
    /// `mcpock_server` for fresh details.
    static func askAgentPrompt(_ server: MCPockStatus.Server, mcpockAgents: [String], now: Date) -> String {
        var clause = problemClause(server)
        if !clause.hasSuffix(".") { clause += "." }
        var lines = [
            "Please help me understand a problem with one of my MCP servers. Investigate and advise only: "
                + "don't change any file, config or setting, and don't install, remove or restart anything.",
            "",
            "mcpock, a menu bar app on my Mac that checks my MCP servers, reports that \"\(server.name)\" \(clause)",
            "",
            "Please tell me:",
            "1. What the problem is, in plain words.",
            "2. The likely causes, most likely first, and what you checked to tell them apart.",
            "3. My options to fix it, each with its trade-offs.",
            "4. Which option you recommend, and why.",
            "Then ask me before you change anything.",
            "",
            "You may look without changing anything: read the config files listed below, and run the server's "
                + "command by hand to see its output. Secrets below are masked as \(SecretMask.dots); "
                + "don't print real keys or tokens back to me.",
        ]
        if !mcpockAgents.isEmpty {
            lines.append("")
            lines.append("mcpock has its own read-only MCP server, \"\(ConnectSnippets.serverName)\" (set up in "
                + "\(CardText.list(mcpockAgents))). If its tools are available to you, call mcpock_server with "
                + "name \"\(server.name)\" for the latest details.")
        }
        lines.append("")
        lines.append("Server details")
        lines.append(detailsText(server, now: now))
        let errors = errorLines(server)
        if !errors.isEmpty {
            lines.append("")
            let failing = server.sources.filter { !($0.failure ?? "").isEmpty }.count
            lines.append(failing == 1 ? "Error" : "Errors")
            lines.append(contentsOf: errors)
        }
        return lines.joined(separator: "\n")
    }

    /// The agents that have mcpock's own MCP server set up: an entry named
    /// "mcpock", or one that runs the bundled `mcpock-mcp` helper. Display
    /// names, in discovery order, each once.
    ///
    /// Transition (1.6.0): a config an agent hasn't moved over yet may still
    /// carry the old entry name "mcpbar", or run the old `mcpbar-mcp` helper
    /// path (the app it came from is gone, but the config line lingers until
    /// the agent re-adds it). Recognising both keeps "Ask an Agent" naming
    /// the tool while configs move; drop this once every config is confirmed
    /// moved.
    static func mcpockAgents(in servers: [ServerSnapshot]) -> [String] {
        var agents: [String] = []
        for snapshot in servers {
            let config = snapshot.config
            let normalized = HealthMonitor.normalizedName(config.name)
            let named = normalized == ConnectSnippets.serverName || normalized == "mcpbar"
            let helperName = ((config.command ?? "") as NSString).lastPathComponent
            let runsHelper = helperName == "mcpock-mcp" || helperName == "mcpbar-mcp"
            guard named || runsHelper else { continue }
            let agent = AgentBadge.displayLabel(config.source.label)
            if !agents.contains(agent) { agents.append(agent) }
        }
        return agents
    }
}
