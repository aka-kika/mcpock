import Foundation
import os

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
        let hiddenNames = Set(groups.filter { HealthMonitor.staysHidden($0, isHidden: isHidden($0.name)) }.map(\.name))
        let staysHidden = { (group: ServerGroup) in hiddenNames.contains(group.name) }
        let visible = groups.filter { !staysHidden($0) }

        let entries = groups.map { group in
            server(group, byID: byID, hidden: staysHidden(group), pinned: isPinned(group.name))
        }
        // Counts and per-agent rows cover what the panel lists, so they agree
        // with the problems list and the widgets (Argon 2026-10-16 #6).
        let shown = entries.filter { !$0.hidden }
        let counts = MCPockStatus.Counts(
            total: shown.count,   // the shown rows, like every other count (r3 09ec)
            broken: shown.filter { $0.status == "broken" }.count,
            slow: shown.filter { $0.status == "slow" }.count,
            needsSignIn: shown.filter { $0.status == "needs sign-in" }.count,
            differs: shown.filter { $0.status == "set up differently" }.count,
            checking: shown.filter { $0.status == "checking" }.count,
            fine: shown.filter { $0.status == "fine" }.count,
            paused: shown.filter { $0.status == "paused" }.count,
            selfManaged: shown.filter { $0.status == "managed by its app" }.count,
            hidden: groups.count - visible.count,
            needsAppOpen: shown.filter { $0.needsApp != nil }.count
        )
        // Round 8 (widgets): the Agents tab's own rows, same order it uses
        // (worst first, aka last) — `AgentSections.build` is already pure and
        // already what the tab itself calls.
        let perAgent = AgentSections.build(groups: visible).map { section in
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
        case .degraded: return group.needsSignIn ? "needs sign-in" : group.notCheckedHere ? "not checked" : "slow"
        case .healthy: return group.differsNeedsAttention ? "set up differently" : "fine"
        case .unknown: return "checking"
        case .paused: return "paused"
        case .selfManaged: return "managed by its app"
        case .needsApp: return "needs \(group.needsAppName ?? "its app") open"
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
            let known = config.map(SecretMask.knownSecrets(of:)) ?? []
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
            .flatMap(SecretMask.knownSecrets(of:))
        return MCPockStatus.Server(
            name: group.name,
            state: group.state.rawValue,
            status: status,
            needsAttention: ["broken", "slow", "needs sign-in", "not checked", "set up differently"].contains(status),
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
            needsApp: group.state == .needsApp ? (group.needsAppName ?? "its app") : nil,
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
    /// Writes run one at a time, in the order they were queued, and a write
    /// that a newer snapshot already passed is skipped (r3 09ec).
    private let queue = DispatchQueue(label: "mcpock.status-writer", qos: .utility)
    private var lastQueued = 0
    private let order = WriteOrder()

    /// Remembers the newest snapshot number written; an older one never lands after it.
    final class WriteOrder: @unchecked Sendable {
        private let newest = OSAllocatedUnfairLock(initialState: 0)
        /// True when `number` may be written (nothing newer has been).
        func claim(_ number: Int) -> Bool {
            newest.withLock { latest in
                guard number > latest else { return false }
                latest = number
                return true
            }
        }
    }
    /// After each write: nil when it worked, else why it failed. A failed
    /// write used to be dropped, and agents read old results with nothing
    /// saying so (review 2026-10-20, f341).
    var onWrite: ((String?) -> Void)?
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
            self.lastQueued += 1
            let number = self.lastQueued
            let order = self.order
            let failure = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
                self.queue.async {
                    guard order.claim(number) else { return done.resume(returning: nil) }
                    do {
                        try Self.write(status, to: directory)
                        done.resume(returning: nil)
                    } catch {
                        done.resume(returning: error.localizedDescription)
                    }
                }
            }
            self.onWrite?(failure)
        }
    }

    nonisolated static func write(_ status: MCPockStatus, to directory: URL) throws {
        try ensurePrivateDirectory(directory)
        let json = try MCPockStatus.encoder().encode(status)
        try writePrivate(json, to: directory.appendingPathComponent(MCPockStatus.fileName))
        let markdown = markdown(status)
        try writePrivate(Data(markdown.utf8), to: directory.appendingPathComponent(MCPockStatus.markdownFileName))
    }

    /// The folder, mode 0700, fixed if it already exists with a wider mode
    /// (r3 247f): server names and error text are for this user only.
    nonisolated static func ensurePrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Atomic write, then mode 0600. The folder is 0700, so the file is never
    /// readable by others in between (r3 247f).
    nonisolated static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
