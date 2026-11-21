import Foundation

/// What the widgets read (round 8). A small, purpose-built copy of
/// `MCPockStatus` — just what the three widgets draw, nothing that needs
/// masking again (it's built from the already-masked status), small enough
/// to sit in the App Group container. Compiled into the app (which builds
/// and writes it) and the widget extension (which only reads it).
struct MCPockWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentSchema = 1
    var schema = MCPockWidgetSnapshot.currentSchema
    /// When mcpock wrote this (not "when a widget last redrew" — the widget
    /// shows this via a live relative-time `Text`, so it keeps counting up on
    /// its own between refreshes).
    var generated: Date
    var checking: Bool
    var firstCheckDone: Bool
    /// Servers she can see (hidden ones left out), same as the panel's own count.
    var totalServers: Int
    var problemCount: Int
    var fineCount: Int
    /// Up to `problemLimit`, worst first — the small/medium widgets' list.
    var problems: [Problem]
    /// Up to `agentLimit`, worst first, aka last — the per-agent widget's rows.
    var agents: [Agent]
    /// How many of `problemCount` are broken (1.9.1): the status widget's mark
    /// is red only then, amber for the rest, like the menu bar icon. nil in a
    /// snapshot from 1.9.0 or earlier.
    var brokenCount: Int? = nil
    /// The probe interval in seconds, 0 for Manual (r3 7183): the widget derives
    /// from it how old is too old. nil in a snapshot from 1.10.9 or earlier.
    var checkEverySeconds: Int? = nil
    /// Servers that are on in at least one agent (premium look, 22 Nov): the
    /// widgets' "41 in use". nil in a snapshot from 1.17 or earlier.
    var inUse: Int? = nil
    /// Tools turned off across them: "12 off". nil when the app did not say.
    var toolsOff: Int? = nil
    /// All agents, not only the listed few: "4 more agents". nil in older snapshots.
    var agentCount: Int? = nil

    struct Problem: Codable, Equatable, Sendable, Identifiable {
        var name: String
        /// Plain words for a glance, not the panel's own wording: "broken"
        /// reads as an alarm on a home screen, so this says "not answering" instead.
        var status: String
        /// True for a broken server (1.9.1): its dot is red; slow, needs
        /// sign-in and set up differently are amber, as in the panel. nil in
        /// a snapshot from 1.9.0 or earlier.
        var isBroken: Bool? = nil
        /// The agents that use it, by name, for the grey line under it (22 Nov).
        var agents: [String]? = nil
        var id: String { name }
        /// Red dot (broken), else amber. An older snapshot says nothing, so
        /// it keeps the pre-1.9.1 red.
        var showsRed: Bool { isBroken ?? true }
    }

    struct Agent: Codable, Equatable, Sendable, Identifiable {
        var name: String
        /// The agent's logo asset (`agent-cursor`...), the same one the app's
        /// Agents tab shows; nil keeps a plain dot. Optional so an older
        /// snapshot still decodes.
        var logo: String? = nil
        var serverCount: Int
        var problemCount: Int
        var fineCount: Int
        /// How many of `problemCount` are broken (1.9.1): that part of the bar
        /// is red, the rest of the problems amber. nil in older snapshots.
        var brokenCount: Int? = nil
        /// Switched off in this agent (22 Nov): "21 of 29". nil in older snapshots.
        var offCount: Int? = nil
        var id: String { name }
        /// The red part of the ring; an older snapshot paints all problems red.
        var redCount: Int { min(brokenCount ?? problemCount, problemCount) }
        /// Neither fine nor a problem: off, paused, not checked. The bare track.
        var quietCount: Int { max(serverCount - problemCount - fineCount, 0) }
        /// "21 of 29" when some are off, "29" when none are.
        var countWords: String {
            let off = min(max(offCount ?? 0, 0), serverCount)
            return off > 0 ? "\(serverCount - off) of \(serverCount)" : "\(serverCount)"
        }
    }

    /// The status widget's mark: red when something is broken, amber when
    /// only slow, sign-in or set-up problems are left (like the menu bar
    /// icon's diamond and ring). An older snapshot keeps the red.
    var markIsRed: Bool { (brokenCount ?? problemCount) > 0 }

    /// "41 in use · 12 off": the widgets' grey line. Falls back to the plain
    /// server count for a snapshot that has neither number.
    var inUseLine: String {
        guard let inUse else { return "\(totalServers) server\(totalServers == 1 ? "" : "s")" }
        guard let toolsOff, toolsOff > 0 else { return "\(inUse) in use" }
        return "\(inUse) in use \u{00B7} \(toolsOff) off"
    }

    /// The ring's numbers: broken, the other problems, fine, and the rest
    /// (off, paused, not checked) as the bare track.
    var ringCounts: (broken: Int, attention: Int, fine: Int, quiet: Int) {
        let red = min(brokenCount ?? problemCount, problemCount)
        return (red, problemCount - red, fineCount, max(totalServers - problemCount - fineCount, 0))
    }

    /// How long after `generated` the widgets stop trusting the snapshot (r3
    /// 7183): three check intervals, at least 10 minutes, like
    /// `StatusReport.freshnessNote`; 2 hours for Manual or an older snapshot.
    var staleAfter: TimeInterval {
        guard let seconds = checkEverySeconds, seconds > 0 else { return 2 * 3600 }
        return max(Double(seconds) * 3, 600)
    }

    /// True when mcpock has not written for longer than `staleAfter`: it is
    /// probably quit or asleep, so the widgets grey out instead of staying green.
    func isStale(now: Date) -> Bool {
        now.timeIntervalSince(generated) > staleAfter
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Build from the full status file (pure — `WidgetSnapshotTests`). Reuses
    /// `StatusReport.problems(in:)` for the worst-first, not-hidden ordering
    /// so the widgets never drift from what `mcpock_problems` already says.
    /// `logo` maps an agent name to its asset: the app passes
    /// `HealthMonitor.widgetLogo`, which the widget can't see.
    static func build(
        from status: MCPockStatus, problemLimit: Int = 4, agentLimit: Int = 5,
        toolsOff: Int? = nil,
        logo: (String) -> String? = { _ in nil }
    ) -> MCPockWidgetSnapshot {
        let allProblems = StatusReport.problems(in: status)
        let problems = allProblems.prefix(problemLimit).map {
            Problem(name: $0.name, status: plainWord(for: $0.status), isBroken: $0.status == "broken",
                    agents: agentNames($0.agents))
        }
        let agents = (status.perAgent ?? []).prefix(agentLimit).map {
            Agent(name: $0.name, logo: logo($0.name), serverCount: $0.serverCount, problemCount: $0.problemCount,
                  fineCount: $0.fineCount, brokenCount: $0.brokenCount, offCount: $0.offCount)
        }
        return MCPockWidgetSnapshot(
            generated: status.generated,
            checking: status.checking,
            firstCheckDone: status.firstCheckDone,
            totalServers: status.counts.total,   // already the shown rows (r3 09ec)
            problemCount: allProblems.count,
            fineCount: status.counts.fine,
            problems: Array(problems),
            agents: Array(agents),
            brokenCount: allProblems.filter { $0.status == "broken" }.count,
            checkEverySeconds: status.checkEverySeconds,
            inUse: status.counts.total - (status.counts.turnedOff ?? 0),
            toolsOff: toolsOff,
            agentCount: status.perAgent?.count
        )
    }

    /// "Claude Code (MyApp)" and "Claude Code" are one agent on a widget line.
    static func agentNames(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.map { label in
            label.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? label
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The panel's status word, in the plainer language a widget glance wants.
    static func plainWord(for status: String) -> String {
        switch status {
        case "broken": return "not answering"
        default: return status
        }
    }
}
