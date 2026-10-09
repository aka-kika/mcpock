import Foundation

/// What the helper found when it looked for mcpock's status file.
enum StatusLoad: Sendable {
    case missing(path: String)
    case unreadable(path: String, detail: String)
    case loaded(MCPockStatus)

    /// Read and decode the file at `url`. Never throws: every outcome is a case.
    static func read(from url: URL) -> StatusLoad {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing(path: url.path) }
        do {
            let data = try Data(contentsOf: url)
            return .loaded(try MCPockStatus.decoder().decode(MCPockStatus.self, from: data))
        } catch {
            return .unreadable(path: url.path, detail: error.localizedDescription)
        }
    }
}

/// The plain-text answers behind the helper's three tools (round 7). Pure:
/// the snapshot, the clock and "is that pid alive" come in as values, so
/// `StatusReportTests` runs them on a fixture file.
enum StatusReport {
    static let notRunningYet = "mcpock isn't running or hasn't checked yet. "
        + "Open mcpock from the menu bar (its first check starts when you open its panel), then ask again."

    /// One line on how much to trust the snapshot, or nil when it is fresh.
    static func freshnessNote(_ status: MCPockStatus, now: Date, isRunning: Bool) -> String? {
        let age = RelativeAge.text(since: status.generated, now: now)
        if !isRunning {
            return "mcpock isn't running. This is what it saw last (\(age)); open mcpock for fresh results."
        }
        if !status.firstCheckDone {
            return "mcpock is still on its first check, so some servers aren't checked yet. Ask again in a minute."
        }
        let seconds = now.timeIntervalSince(status.generated)
        if status.checkEverySeconds == 0 {
            // Manual: the file only changes when she presses Refresh.
            return seconds > 3600
                ? "mcpock checks only when asked (Manual). These results are from \(age); press Refresh in mcpock for fresh ones."
                : nil
        }
        let limit = max(Double(status.checkEverySeconds) * 3, 600)
        return seconds > limit
            ? "This snapshot is old (\(age)); mcpock may be asleep or stuck. Press Refresh in mcpock for fresh results."
            : nil
    }

    /// The header every answer starts with: the note about freshness (if any),
    /// or the reason there is nothing to read.
    private static func preamble(_ load: StatusLoad, now: Date, isRunning: (Int32) -> Bool) -> (MCPockStatus?, [String]) {
        switch load {
        case .missing:
            return (nil, [notRunningYet])
        case .unreadable(let path, let detail):
            return (nil, ["mcpock's status file at \(path) couldn't be read (\(detail)). Open mcpock so it writes a fresh one."])
        case .loaded(let status):
            let note = freshnessNote(status, now: now, isRunning: isRunning(status.pid))
            return (status, note.map { [$0, ""] } ?? [])
        }
    }

    // MARK: - mcpock_status

    static func statusText(_ load: StatusLoad, now: Date, isRunning: (Int32) -> Bool) -> String {
        let (status, head) = preamble(load, now: now, isRunning: isRunning)
        guard let status else { return head.joined(separator: "\n") }
        let c = status.counts
        var lines = head
        lines.append("mcpock \(status.appVersion): \(status.summary)")
        lines.append("Updated \(RelativeAge.text(since: status.generated, now: now))"
            + (status.checking ? " (a check is running)" : "")
            + " · checks \(intervalText(status.checkEverySeconds))")
        lines.append("")
        lines.append("Servers: \(c.total)")
        lines.append("- broken: \(c.broken)")
        lines.append("- slow: \(c.slow)")
        lines.append("- needs sign-in: \(c.needsSignIn)")
        lines.append("- set up differently: \(c.differs)")
        lines.append("- fine: \(c.fine)")
        if c.checking > 0 { lines.append("- not checked yet: \(c.checking)") }
        if c.paused > 0 { lines.append("- paused in mcpock: \(c.paused)") }
        if c.selfManaged > 0 { lines.append("- managed by their own app: \(c.selfManaged)") }
        if c.hidden > 0 { lines.append("- hidden in mcpock: \(c.hidden)") }
        let needs = problems(in: status).count
        lines.append("")
        lines.append(needs == 0
            ? "Nothing needs attention."
            : "\(needs) need\(needs == 1 ? "s" : "") attention: call mcpock_problems for the details.")
        return lines.joined(separator: "\n")
    }

    // MARK: - mcpock_problems

    /// Servers that need attention and aren't hidden, worst first (the file
    /// is already in mcpock's order: broken, slow, then the rest by name).
    static func problems(in status: MCPockStatus) -> [MCPockStatus.Server] {
        status.servers.filter { $0.needsAttention && !$0.hidden }
            .enumerated()
            .sorted { (rank($0.element.status), $0.offset) < (rank($1.element.status), $1.offset) }
            .map(\.element)
    }

    static func problemsText(_ load: StatusLoad, now: Date, isRunning: (Int32) -> Bool) -> String {
        let (status, head) = preamble(load, now: now, isRunning: isRunning)
        guard let status else { return head.joined(separator: "\n") }
        return (head + problemLines(status, now: now)).joined(separator: "\n")
    }

    /// The body of `mcpock_problems`, also the app's `status.md`.
    static func problemLines(_ status: MCPockStatus, now: Date) -> [String] {
        let list = problems(in: status)
        let hiddenProblems = status.servers.filter { $0.needsAttention && $0.hidden }.map(\.name)
        var lines: [String] = []
        if list.isEmpty {
            lines.append("Nothing needs attention. \(status.summary) (updated \(RelativeAge.text(since: status.generated, now: now))).")
        } else {
            lines.append("\(list.count) MCP server\(list.count == 1 ? " needs" : "s need") attention "
                + "(\(status.summary); updated \(RelativeAge.text(since: status.generated, now: now))).")
            for (index, server) in list.enumerated() {
                lines.append("")
                lines.append(contentsOf: serverLines(server, number: index + 1, full: false, now: now))
            }
            lines.append("")
            lines.append("Fix each server in the config file(s) listed with it. mcpock only reads configs, it never "
                + "changes them. After a fix, mcpock's next check (or its Refresh button) confirms it.")
        }
        if !hiddenProblems.isEmpty {
            lines.append("")
            lines.append("Hidden in mcpock and left out: \(hiddenProblems.joined(separator: ", ")). "
                + "Call mcpock_server with a name for its details.")
        }
        return lines
    }

    // MARK: - mcpock_server

    static func serverText(_ load: StatusLoad, name: String, now: Date, isRunning: (Int32) -> Bool) -> String {
        let (status, head) = preamble(load, now: now, isRunning: isRunning)
        guard let status else { return head.joined(separator: "\n") }
        let key = normalized(name)
        guard !key.isEmpty, let server = status.servers.first(where: { normalized($0.name) == key }) else {
            let names = status.servers.map(\.name)
            let known = names.isEmpty ? "none yet" : names.joined(separator: ", ")
            return (head + ["No server named \"\(name)\" in mcpock. Known servers: \(known)."]).joined(separator: "\n")
        }
        return (head + serverLines(server, number: nil, full: true, now: now)).joined(separator: "\n")
    }

    /// One server as text. `full` adds tools, env/header names and every source.
    static func serverLines(_ s: MCPockStatus.Server, number: Int?, full: Bool, now: Date) -> [String] {
        var lines: [String] = []
        let title = (number.map { "\($0). " } ?? "") + "\(s.name) — \(s.status)"
        lines.append(title)
        let indent = number == nil ? "" : "   "
        if let reason = s.reason, !reason.isEmpty { lines.append(indent + "Reason: \(reason)") }
        if let note = s.note, !note.isEmpty { lines.append(indent + "Note: \(note)") }
        if let differs = s.differs, !differs.isEmpty { lines.append(indent + "Set up differently: \(differs)") }
        if let onPurpose = s.differsOnPurpose, !onPurpose.isEmpty {
            lines.append(indent + "Set up differently, marked as intended: \(onPurpose)")
        }
        lines.append(indent + "Transport: \(s.transports.joined(separator: " / "))")
        lines.append(indent + "Used by: \(s.agents.joined(separator: ", "))")
        if !s.configPaths.isEmpty {
            lines.append(indent + "Config files:")
            lines.append(contentsOf: s.configPaths.map { indent + "- \($0)" })
        }
        if let checked = s.lastChecked {
            lines.append(indent + "Last checked: \(RelativeAge.text(since: checked, now: now))")
        }
        if s.hidden { lines.append(indent + "Hidden in mcpock") }
        let shown = full ? s.sources : s.sources.filter { $0.failure != nil || $0.differs }
        if !shown.isEmpty {
            lines.append(indent + (full ? "Declarations:" : "Details:"))
            for source in shown {
                var line = indent + "- \(source.agent) (\(source.transport), \(source.state))"
                if source.differs { line += ", the odd one out" }
                lines.append(line)
                lines.append(indent + "  config: \(source.configPath)")
                if !source.target.isEmpty { lines.append(indent + "  runs: \(source.target)") }
                if let failure = source.failure { lines.append(indent + "  error: \(failure)") }
                if full, !source.envNames.isEmpty {
                    lines.append(indent + "  env: \(source.envNames.joined(separator: ", ")) (values not shown)")
                }
                if full, !source.headerNames.isEmpty {
                    lines.append(indent + "  headers: \(source.headerNames.joined(separator: ", ")) (values not shown)")
                }
            }
        }
        if full {
            lines.append("Tools (\(s.toolCount)): " + (s.tools.isEmpty ? "none reported" : s.tools.joined(separator: ", ")))
        }
        return lines
    }

    // MARK: - Helpers

    static func intervalText(_ seconds: Int) -> String {
        switch seconds {
        case 0: return "only when asked"
        case 60: return "every minute"
        case 3600: return "every hour"
        case let s where s % 3600 == 0: return "every \(s / 3600) hours"
        case let s where s % 60 == 0: return "every \(s / 60) min"
        default: return "every \(seconds) s"
        }
    }

    /// Case and separators ignored, like mcpock's own grouping.
    static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func rank(_ status: String) -> Int {
        switch status {
        case "broken": return 0
        case "slow": return 1
        case "needs sign-in": return 2
        default: return 3
        }
    }
}
