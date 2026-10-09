import Foundation

/// Builds the status file agents read through `mcpock-mcp` (round 7) from the
/// monitor's snapshots. Pure, so `StatusSnapshotTests` checks the wording and,
/// above all, that no env value, header value or secret-looking argument ever
/// reaches the file.
enum StatusSnapshot {
    static func build(
        servers: [ServerSnapshot],
        isHidden: (String) -> Bool,
        isPinned: (String) -> Bool,
        acknowledged: [String: [String]] = [:],
        checking: Bool,
        firstCheckDone: Bool,
        interval: ProbeInterval,
        now: Date,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        appVersion: String = MCPJSONRPC.clientVersion
    ) -> MCPockStatus {
        let groups = HealthMonitor.groupByName(servers, acknowledged: acknowledged)
        let byID = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visible = groups.filter { !isHidden($0.name) }

        let entries = groups.map { group in
            server(group, byID: byID, hidden: isHidden(group.name), pinned: isPinned(group.name))
        }
        let counts = MCPockStatus.Counts(
            total: groups.count,
            broken: entries.filter { $0.status == "broken" }.count,
            slow: entries.filter { $0.status == "slow" }.count,
            needsSignIn: entries.filter { $0.status == "needs sign-in" }.count,
            differs: entries.filter { $0.status == "set up differently" }.count,
            checking: entries.filter { $0.status == "checking" }.count,
            fine: entries.filter { $0.status == "fine" }.count,
            paused: entries.filter { $0.status == "paused" }.count,
            selfManaged: entries.filter { $0.status == "managed by its app" }.count,
            hidden: groups.count - visible.count
        )
        // Round 8 (widgets): the Agents tab's own rows, same order it uses
        // (worst first, aka last) — `AgentSections.build` is already pure and
        // already what the tab itself calls.
        let perAgent = AgentSections.build(groups: groups).map { section in
            MCPockStatus.AgentStatus(
                name: section.displayName,
                serverCount: section.servers.count,
                problemCount: section.problems.count,
                fineCount: section.fineCount,
                brokenCount: section.brokenCount
            )
        }
        return MCPockStatus(
            schema: MCPockStatus.currentSchema,
            generated: now,
            appVersion: appVersion,
            pid: pid,
            checking: checking,
            firstCheckDone: firstCheckDone,
            checkEverySeconds: interval.rawValue,
            summary: PanelText.summary(visible, firstPass: !firstCheckDone),
            counts: counts,
            servers: entries,
            perAgent: perAgent
        )
    }

    /// "broken", "slow", "needs sign-in", "set up differently", "fine",
    /// "checking", "paused", "managed by its app".
    static func statusWords(_ group: ServerGroup) -> String {
        switch group.state {
        case .broken: return "broken"
        case .degraded: return group.needsSignIn ? "needs sign-in" : "slow"
        case .healthy: return group.differsNeedsAttention ? "set up differently" : "fine"
        case .unknown: return "checking"
        case .paused: return "paused"
        case .selfManaged: return "managed by its app"
        }
    }

    /// One row as the status file holds it, secrets masked. Also what the
    /// right-click "Copy Details" and "Ask an Agent" build on (1.5.3), so the
    /// clipboard gets exactly the status file's masking.
    static func server(
        _ group: ServerGroup,
        byID: [String: ServerSnapshot],
        hidden: Bool,
        pinned: Bool
    ) -> MCPockStatus.Server {
        let status = statusWords(group)
        let oddLabels = Set(group.differs.map(\.label))
        let sources = group.sources.map { source -> MCPockStatus.Source in
            let config = byID[source.configID]?.config
            let known = config.map { SecretMask.knownSecrets(env: $0.env, headers: $0.headers) } ?? []
            let target: String
            if let config {
                target = config.transport == .stdio
                    ? SecretMask.commandLine(command: config.command, args: config.args, known: known)
                    : SecretMask.url(config.url ?? "", known: known)
            } else {
                // No config to read the parts from: mask the joined line as text.
                target = SecretMask.scrub(source.target)
            }
            return MCPockStatus.Source(
                agent: AgentBadge.displayLabel(source.label),
                configPath: source.path,
                transport: source.transport.rawValue,
                target: target,
                envNames: source.envKeys,
                headerNames: source.headerKeys,
                state: source.state.rawValue,
                failure: source.failureReason.map { SecretMask.scrub($0, known: known) },
                differs: oddLabels.contains(source.label)
            )
        }
        var paths: [String] = []
        for source in group.sources where !source.path.isEmpty && !paths.contains(source.path) {
            paths.append(source.path)
        }
        let allKnown = group.sources.compactMap { byID[$0.configID]?.config }
            .flatMap { SecretMask.knownSecrets(env: $0.env, headers: $0.headers) }
        return MCPockStatus.Server(
            name: group.name,
            state: group.state.rawValue,
            status: status,
            needsAttention: ["broken", "slow", "needs sign-in", "set up differently"].contains(status),
            reason: ShortReason.line(for: group).map { SecretMask.scrub($0, known: allKnown) },
            hidden: hidden,
            pinned: pinned,
            transports: CardText.transports(of: group).components(separatedBy: " / ").filter { !$0.isEmpty },
            toolCount: group.tools.count,
            tools: group.tools.map(\.name),
            lastChecked: group.lastChecked,
            agents: group.agents.map { AgentBadge.displayLabel($0) },
            configPaths: paths,
            differs: group.isDiffering ? SecretMask.scrub(CardText.differsSentence(for: group), known: allKnown) : nil,
            differsOnPurpose: group.isDifferentOnPurpose
                ? SecretMask.scrub(CardText.onPurposeSentence(for: group), known: allKnown) : nil,
            note: group.state == .healthy ? CardText.slowStartNote(group.slowStartSeconds) : nil,
            sources: sources
        )
    }
}

/// Writes the status file (and a Markdown copy for agents without MCP) a
/// moment after the monitor's results change, coalescing the burst of
/// changes a probe cycle makes into one write. The file is written atomically,
/// off the main thread.
@MainActor
final class StatusWriter {
    let directory: URL
    private var pending: Task<Void, Never>?
    /// How long to wait for more changes before writing.
    static let delay: Duration = .milliseconds(800)

    init(directory: URL = MCPockStatus.defaultDirectory()) {
        self.directory = directory
    }

    var statusURL: URL { directory.appendingPathComponent(MCPockStatus.fileName) }

    /// Write soon. `make` runs on the main actor when the write happens, so it
    /// sees the latest state, not the state at the first change.
    func schedule(_ make: @escaping @MainActor () -> MCPockStatus?) {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard let self else { return }
            self.pending = nil
            guard let status = make() else { return }
            let directory = self.directory
            await Task.detached(priority: .utility) {
                try? Self.write(status, to: directory)
            }.value
        }
    }

    nonisolated static func write(_ status: MCPockStatus, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = try MCPockStatus.encoder().encode(status)
        try json.write(to: directory.appendingPathComponent(MCPockStatus.fileName), options: .atomic)
        let markdown = markdown(status)
        try Data(markdown.utf8).write(to: directory.appendingPathComponent(MCPockStatus.markdownFileName), options: .atomic)
    }

    /// `status.md`: the same text `mcpock_problems` returns, for an agent that
    /// can read a file but has no MCP.
    nonisolated static func markdown(_ status: MCPockStatus) -> String {
        var lines = ["# mcpock status", ""]
        lines.append("Written \(ISO8601DateFormatter().string(from: status.generated)) by mcpock \(status.appVersion). "
            + "Rewritten whenever its results change.")
        lines.append("")
        lines.append(contentsOf: StatusReport.problemLines(status, now: status.generated))
        return lines.joined(separator: "\n") + "\n"
    }
}
