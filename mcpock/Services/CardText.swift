import Foundation

/// The detail card's wording (v1.5 spec, Phase 3), kept out of the view so
/// `CardTextTests` can pin it down: the sub line, the "why" lines, the differs
/// sentence, shortened config paths and masked secrets.
enum CardText {
    /// "14 tools · stdio · checked 1 min ago".
    static func subLine(for group: ServerGroup, now: Date) -> String {
        var parts: [String] = []
        let tools = group.tools.count
        parts.append(tools == 0 ? "No tools yet" : "\(tools) tool\(tools == 1 ? "" : "s")")
        let transports = transports(of: group)
        if !transports.isEmpty { parts.append(transports) }
        if group.state == .paused {
            parts.append("paused")
        } else if group.state == .selfManaged {
            parts.append("not checked by mcpock")
        } else if let checked = group.lastChecked {
            parts.append("checked " + PanelText.ago(checked, now: now))
        } else {
            parts.append("not checked yet")
        }
        if group.state == .healthy, let note = slowStartNote(group.slowStartSeconds) {
            parts.append(note)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "Slow to start (over 20 s)": the first try timed out, the retry answered.
    /// N is how long the first try waited (the limit), because that is the cold
    /// start she may want to know about; the retry is usually quicker. Nil when
    /// there is nothing to say.
    static func slowStartNote(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return "Slow to start (over \(Int(seconds.rounded())) s)"
    }

    /// "stdio", "http", or "stdio / http" when the agents disagree.
    static func transports(of group: ServerGroup) -> String {
        var seen: [String] = []
        for source in group.sources where !seen.contains(source.transport.rawValue) {
            seen.append(source.transport.rawValue)
        }
        return seen.joined(separator: " / ")
    }

    // MARK: - Problem boxes (1.5.3, layout B)

    /// What sits under the card's title, top to bottom. A marked row never
    /// shows the "Set up differently" box (so "Mark as intended" is never
    /// offered twice); it shows the quiet "Marked as intended · Undo" line.
    enum Problem: Equatable {
        /// "Why it is broken / slow / needs sign-in": Ask an agent | Copy errors.
        case why
        /// "Set up differently": the two-by-two grid.
        case differs
        /// "Marked as intended · Undo".
        case marked
    }

    static func problems(for group: ServerGroup) -> [Problem] {
        var parts: [Problem] = []
        if group.state == .broken || group.state == .degraded { parts.append(.why) }
        // An open difference wins over the quiet line (1.9.0: a marked row
        // can have a new agent that differs), so Mark stays one click away.
        if group.differsNeedsAttention {
            parts.append(.differs)
        } else if group.isDifferentOnPurpose {
            parts.append(.marked)
        }
        return parts
    }

    /// The card's buttons, in sentence case (the menu says the same in title
    /// case, `MenuText`).
    static let compareButton = "Compare"
    static let askAgentButton = "Ask an agent"
    static let copyDetailsButton = "Copy details"
    static let copyErrorsButton = "Copy errors"
    static let markAsIntendedButton = "Mark as intended"
    static let markedLine = "Marked as intended"
    static let undoButton = "Undo"

    /// "Set up differently": two rows of two equal-width buttons.
    static let differsButtons = [
        [compareButton, askAgentButton],
        [copyDetailsButton, markAsIntendedButton],
    ]
    /// The why box: one row of two.
    static let whyButtons = [askAgentButton, copyErrorsButton]

    /// Title of the "why" box: broken, slow, or waiting for a sign-in.
    static func whyTitle(for group: ServerGroup) -> String {
        if group.needsSignIn { return "Why it needs sign-in" }
        return group.state == .broken ? "Why it is broken" : "Why it is slow"
    }

    /// One line per failing source: "Cursor: Non-zero exit (127) — command not found".
    static func whyLines(for group: ServerGroup) -> [String] {
        group.issues.map { "\(AgentBadge.displayLabel($0.label)): \($0.reason)" }
    }

    /// "Grok points at a different address than Claude Code and Cursor."
    /// With no majority to measure against, it says how the agents split:
    /// "Cursor and Grok use one command, Hermes and mcporter another", or
    /// "Claude Code, Cursor and Grok point at 3 different addresses". Empty when
    /// the row doesn't differ.
    static func differsSentence(for group: ServerGroup) -> String {
        guard group.isDiffering else { return "" }
        let odd = unique(group.differs.map { AgentBadge.displayLabel($0.label) })
        let oddSet = Set(group.differs.map(\.label))
        let compared = comparedSources(group)
        let others = unique(compared.filter { !oddSet.contains($0.label) }.map { AgentBadge.displayLabel($0.label) })
        let (one, many) = targetNouns(for: group)
        if others.isEmpty {
            let camps = camps(compared)
            if camps.count == 2 {
                let verb = camps[0].count == 1 ? "uses" : "use"
                return "\(list(camps[0])) \(verb) one \(one), \(list(camps[1])) another."
            }
            return "\(list(odd)) point at \(max(camps.count, 2)) different \(many)."
        }
        let verb = odd.count == 1 ? "points" : "point"
        return "\(list(odd)) \(verb) at a different \(one) than \(list(others))."
    }

    /// The same sentence for a row she marked as intended (1.5.2), built from
    /// the notes she acknowledged. Empty when it isn't marked.
    static func onPurposeSentence(for group: ServerGroup) -> String {
        guard group.isDifferentOnPurpose else { return "" }
        var acknowledged = group
        acknowledged.differs = group.acknowledgedDiffers
        return differsSentence(for: acknowledged)
    }

    /// The Agents tab's line under a server that differs, seen from one agent:
    /// the odd one out reads "Points at a different address than the others",
    /// everyone else "Grok has a different setup".
    static func differsLine(for group: ServerGroup, agent: String) -> String {
        let oddLabels = group.differs.map(\.label)
        // A note's label is the display label: the agent, plus " (Project)" for a
        // project-scoped declaration.
        let agentIsOdd = oddLabels.contains { $0 == agent || $0.hasPrefix(agent + " (") }
        let (one, _) = targetNouns(for: group)
        if agentIsOdd { return "Points at a different \(one) than the others" }
        let odd = unique(oddLabels.map { AgentBadge.displayLabel($0) })
        return odd.count == 1 ? "\(odd[0]) has a different setup" : "\(list(odd)) have a different setup"
    }

    /// Display labels grouped by what they launch, in first-seen order. Compares
    /// the target as written (the normalised compare is `Differs`' job; this only
    /// words a split `Differs` already found).
    private static func camps(_ sources: [GroupSource]) -> [[String]] {
        var order: [String] = []
        var byTarget: [String: [String]] = [:]
        for source in sources {
            let label = AgentBadge.displayLabel(source.label)
            if byTarget[source.target] == nil { order.append(source.target) }
            if !(byTarget[source.target] ?? []).contains(label) {
                byTarget[source.target, default: []].append(label)
            }
        }
        return order.compactMap { byTarget[$0] }
    }

    /// "address" for URLs, "command" for stdio, "server" when both are in play.
    /// The sources `Differs` compares: aka's are left out (round 6).
    private static func comparedSources(_ group: ServerGroup) -> [GroupSource] {
        group.sources.filter { Differs.isCompared(agent: $0.agent) }
    }

    private static func targetNouns(for group: ServerGroup) -> (String, String) {
        let kinds = Set(comparedSources(group).map { $0.transport == .stdio ? "stdio" : "url" })
        if kinds == ["url"] { return ("address", "addresses") }
        if kinds == ["stdio"] { return ("command", "commands") }
        return ("server", "servers")
    }

    /// `~/.cursor/mcp.json` instead of `/Users/me/.cursor/mcp.json`.
    static func shortPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// A command line or URL with the home folder shortened to `~` wherever it
    /// appears (the command and every argument), for Compare.
    static func shortTarget(_ target: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty else { return target }
        return target.replacingOccurrences(of: home + "/", with: "~/")
    }

    /// Env names with their values masked: `API_KEY=••••`. The card never has the
    /// values to begin with (`GroupSource` carries names only); this is the look.
    static func maskedEnv(_ keys: [String]) -> [String] {
        keys.map { "\($0)=\u{2022}\u{2022}\u{2022}\u{2022}" }
    }

    /// Header names with their values masked: `Authorization: ••••`.
    static func maskedHeaders(_ keys: [String]) -> [String] {
        keys.map { "\($0): \u{2022}\u{2022}\u{2022}\u{2022}" }
    }

    /// "Used by · 3 agents": distinct agents, not declarations (two Claude Code
    /// projects are one agent).
    static func usedByTitle(for group: ServerGroup) -> String {
        let count = group.agents.count
        return "Used by \u{00B7} \(count) agent\(count == 1 ? "" : "s")"
    }

    /// "Used by" rows shown before the rest fold into "+n more" (Phase 7: a server
    /// used by nine agents made the card taller than the screen).
    static let usedByLimit = 4

    /// The "Used by" rows in the order the card lists them: the sources that
    /// differ first, then the failing ones, then the rest, each in discovery
    /// order. The first `usedByLimit` stay visible, so the rows that explain
    /// the problem must never be the ones folded away.
    static func usedByOrder(for group: ServerGroup) -> [GroupSource] {
        let odd = Set(group.differs.map(\.label))
        func rank(_ source: GroupSource) -> Int {
            if odd.contains(source.label) { return 0 }
            if source.state == .broken || source.state == .degraded { return 1 }
            return 2
        }
        return group.sources.enumerated()
            .sorted { a, b in
                let (ra, rb) = (rank(a.element), rank(b.element))
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// The rows the card shows: all of them when expanded, else at most
    /// `usedByLimit`. The second value is how many are folded into "+n more".
    static func usedByRows(for group: ServerGroup, expanded: Bool) -> (rows: [GroupSource], folded: Int) {
        let ordered = usedByOrder(for: group)
        guard !expanded, ordered.count > usedByLimit else { return (ordered, 0) }
        return (Array(ordered.prefix(usedByLimit)), ordered.count - usedByLimit)
    }

    /// Tools the card lists before "+N more" (1.5.3).
    static let toolsLimit = 5
    /// "+9 more", like "+n more" under "Used by" (2026-09-26: it said
    /// "Show more").
    static func showMoreTitle(folded: Int) -> String { "+\(folded) more" }
    static let showLessTitle = "Show less"

    /// "Show 9 more tools": the tooltip and accessibility label of "+N more".
    static func showMoreHelp(folded: Int) -> String {
        "Show \(folded) more tool\(folded == 1 ? "" : "s")"
    }

    /// The tools the card lists: all of them when expanded, else the first
    /// `toolsLimit` in the server's own order. The second value is how many
    /// "+N more" would add.
    static func toolRows(for group: ServerGroup, expanded: Bool) -> (rows: [MCPToolInfo], folded: Int) {
        guard !expanded, group.tools.count > toolsLimit else { return (group.tools, 0) }
        return (Array(group.tools.prefix(toolsLimit)), group.tools.count - toolsLimit)
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}

/// The card's icon-only actions (round 6): the symbol, and the words used as
/// tooltip and accessibility label. The right-click menu keeps its own texts
/// (`MenuText`).
enum CardAction: CaseIterable, Sendable {
    case checkAgain, resume, pin, unpin, hide

    var title: String {
        switch self {
        case .checkAgain: return "Check again"
        case .resume: return "Resume"
        case .pin: return "Pin"
        case .unpin: return "Unpin"
        case .hide: return "Hide"
        }
    }

    var systemImage: String {
        switch self {
        case .checkAgain: return "arrow.clockwise"
        case .resume: return "play"
        case .pin: return "pin"
        case .unpin: return "pin.slash"
        case .hide: return "eye.slash"
        }
    }
}
