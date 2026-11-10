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

    /// "Claude Code lost it in the open session in Recall 4 min ago. mcpock's
    /// own check reaches it, so run /mcp in that session to reconnect." (1.12)
    static func sessionDropNote(_ drops: [SessionDrop], now: Date) -> String? {
        guard let newest = drops.first else { return nil }
        let folders = list(drops.map { ($0.folder as NSString).lastPathComponent })
        let sessions = drops.count == 1 ? "the open session in \(folders)" : "open sessions in \(folders)"
        return "Claude Code lost it in \(sessions) \(PanelText.ago(newest.at, now: now)). "
            + "mcpock's own check reaches it, so run /mcp in that session to reconnect."
    }

    /// A row whose agents run their servers in the cloud (Grok Bot, 1.12).
    static func cloudNote(agents: [String], cloud: String) -> String {
        let host = list(agents.map(AgentBadge.displayLabel))
        return "Runs in \(cloud) for \(host), not on this Mac, so mcpock lists it and doesn't check it."
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
    /// Ask an agent only copies: the flash says so (r3 191b).
    static let askAgentCopied = "Prompt copied, paste it to your agent"
    static let copyErrorsButton = "Copy errors"
    static let markAsIntendedButton = "Mark as intended"
    static let markedLine = "Marked as intended"
    static let undoButton = "Undo"

    /// Title of the "why" box: broken, slow, or waiting for a sign-in.
    static func whyTitle(for group: ServerGroup) -> String {
        if group.needsSignIn { return "Why it needs sign-in" }
        if group.notCheckedHere || group.incompleteConfig { return "Why it is not checked" }
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
            let key = source.compareKey.isEmpty ? source.target : source.compareKey
            if byTarget[key] == nil { order.append(key) }
            if !(byTarget[key] ?? []).contains(label) {
                byTarget[key, default: []].append(label)
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
    /// A paused row whose servers come from a file only the scan found
    /// (review 2026-10-20, 5ae6), or nil.
    static func awaitingFileNote(for group: ServerGroup, home: String = NSHomeDirectory()) -> String? {
        var files: [String] = []
        for source in group.sources where source.awaitingFileOK && !files.contains(source.path) {
            files.append(source.path)
        }
        guard !files.isEmpty else { return nil }
        let list = list(files.map { shortPath($0, home: home) })
        return "Found in \(list), a file no agent mcpock knows reads. mcpock won't start it until you say so: "
            + "Allow this file (right-click the row) checks it from now on."
    }

    /// A source that sends keys over plain http to another machine, in its
    /// headers (r3 c5e8) or in the URL itself (`?token=`, `user:pass@`; review
    /// 2026-10-30, 7458): anyone on the network can read them. Nil when none does.
    static func plainHTTPWarning(for group: ServerGroup) -> String? {
        let exposed = group.sources.filter { source in
            guard source.transport != .stdio,
                  let url = URLComponents(string: source.target), url.scheme?.lowercased() == "http",
                  let host = url.host?.lowercased(),
                  !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else { return false }
            let keyInURL = url.user != nil || url.password != nil || url.queryItems?.contains { $0.value != nil } == true
            return !source.headerKeys.isEmpty || keyInURL
        }
        guard !exposed.isEmpty else { return nil }
        let labels = exposed.map { AgentBadge.displayLabel($0.label) }
        let agents = list(labels)
        return "\(agents) \(labels.count == 1 ? "sends its" : "send their") keys to this server over plain http, so anyone on the network can read them. "
            + "Use https if the server offers it."
    }

    /// The config file of the first failing source, for the Why box's
    /// Show in Finder link; nil when none is known.
    static func failingConfigPath(for group: ServerGroup) -> String? {
        group.sources.first { ($0.state == .broken || $0.state == .degraded) && !$0.path.isEmpty }?.path
    }

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
    // MARK: The server switch (1.14)

    struct EverywhereSwitch: Equatable {
        /// True when the switch turns every agent on (all of them are off).
        let turnOn: Bool
        /// The agents it covers: every one that has a switch.
        let count: Int
        /// Beside the switch: "All 5" (Kika's pick, Mocker 10 Nov).
        var label: String { "All \(count)" }
        /// What a click does: "Turn off in all 5" / "Turn on in all 5".
        var actionTitle: String { "Turn \(turnOn ? "on" : "off") in all \(count)" }
    }

    /// The switch above the agents' switches under "Used by": on while any
    /// agent with a switch has the server on, off when all of them have it
    /// off. Nil with fewer than two such agents (the row's own switch does
    /// it). It replaced the "Turn off everywhere" button (Kika, 10 Nov).
    static func everywhereSwitch(for group: ServerGroup) -> EverywhereSwitch? {
        let switchable = group.sources.filter(\.canSwitch)
        guard switchable.count > 1 else { return nil }
        return EverywhereSwitch(turnOn: !switchable.contains(where: { !$0.isOff }), count: switchable.count)
    }

    /// Under an agent's name in "Used by", in place of the file path: what
    /// the last flip said ("Off after Cursor reopens"), else "Turned off";
    /// nil for a row that is on and untouched.
    static func switchLine(isOff: Bool, note: String?) -> String? {
        if let note { return note }
        return isOff ? "Turned off" : nil
    }

    /// The sheet's small print: agents with no switch, files left alone.
    static func switchNotes(for plan: SwitchPlan) -> [String] {
        var lines = plan.problems
        if plan.tools != nil {
            // Agents with no way to hide tools are listed as rows of their own.
            if plan.isEmpty, lines.isEmpty, plan.skipped.isEmpty { lines.append("Nothing to change there.") }
            return lines
        }
        if !plan.skipped.isEmpty {
            let agents = list(plan.skipped)
            lines.append("No switch for \(agents) yet: turn it \(plan.turnOn ? "on" : "off") there by hand.")
        }
        if plan.isEmpty, lines.isEmpty {
            lines.append("It is already \(plan.turnOn ? "on" : "off") there.")
        }
        return lines
    }

    /// "Claude Code" back to the label its badge is stored under ("Code").
    static func agentLabel(forDisplay name: String) -> String {
        AgentBadge.displayNames.first { $0.value == name }?.key ?? name
    }

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

    /// The tool rows the card lists: all of them when expanded, else the
    /// first `toolsLimit`. The second value is how many "+N more" would add.
    static func toolRows<Row>(_ rows: [Row], expanded: Bool) -> (rows: [Row], folded: Int) {
        guard !expanded, rows.count > toolsLimit else { return (rows, 0) }
        return (Array(rows.prefix(toolsLimit)), rows.count - toolsLimit)
    }

    // MARK: - Tools on the card (Part 2, 2026-11-10)

    /// One tool on the card: its calls, and where it is hidden.
    struct ToolRow: Identifiable, Equatable {
        var id: String { tool.name }
        let tool: MCPToolInfo
        /// Calls in the Usage window; nil when counts are off or not read yet.
        let calls: Int?
        /// `UsageStore.dayIndex` of the last call on record.
        let lastDay: Int?
        /// Hidden in every agent that can hide tools.
        let hiddenEverywhere: Bool
        /// Agents (display names) that hide it, when only some do.
        let hiddenIn: [String]
    }

    struct ToolSections: Equatable {
        /// Used in the window, most calls first (or every tool, in the
        /// server's order, when there are no counts).
        var used: [ToolRow] = []
        /// No call in the window (only with counts).
        var unused: [ToolRow] = []
        var hidden: [ToolRow] = []
    }

    /// The card's tools in three groups. `hidden` is per declaration id;
    /// `labels` names each declaration's agent.
    static func toolSections(tools: [MCPToolInfo], usage: [String: ToolUsage]?, hidden: [String: Set<String>],
                             labels: [String: String]) -> ToolSections {
        var sections = ToolSections()
        for tool in tools {
            let hiders = hidden.filter { $0.value.contains(tool.name) }.map(\.key)
            let everywhere = !hidden.isEmpty && hiders.count == hidden.count
            let names = hiders.compactMap { labels[$0].map(AgentBadge.displayLabel) }
            let entry = usage?[UsageStore.toolKey(tool.name)]
            let row = ToolRow(tool: tool, calls: usage == nil ? nil : (entry?.calls ?? 0), lastDay: entry?.lastDay,
                              hiddenEverywhere: everywhere,
                              hiddenIn: everywhere ? [] : Array(Set(names)).sorted())
            if everywhere {
                sections.hidden.append(row)
            } else if let calls = row.calls, calls == 0 {
                sections.unused.append(row)
            } else {
                sections.used.append(row)
            }
        }
        if usage != nil {
            // Most calls first; ties keep the server's order (a stable sort).
            sections.used = sections.used.enumerated()
                .sorted { ($0.element.calls ?? 0, -$0.offset) > ($1.element.calls ?? 0, -$1.offset) }
                .map(\.element)
        }
        return sections
    }

    /// "Not used in 30 days" / "Not used in 7 days" / "Never used".
    static func unusedTitle(window: UsageWindow) -> String {
        guard let days = window.days else { return "Never used" }
        return "Not used in \(days) days"
    }

    /// "Calls in 30 days" beside "Tools · 26"; nil without counts.
    static func callsWindowTitle(window: UsageWindow) -> String? {
        switch window {
        case .off: return nil
        case .allTime: return "calls, all time"
        default: return "calls in \(window.days ?? 0) days"
        }
    }

    /// "today", "yesterday", "3 days ago", "Nov 2"; nil with no call on record.
    static func lastUsed(_ day: Int?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let day else { return nil }
        let ago = UsageStore.dayIndex(for: now, calendar: calendar) - day
        switch ago {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2..<7: return "\(ago) days ago"
        default:
            guard let date = calendar.date(byAdding: .day, value: -ago, to: now) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
            return formatter.string(from: date)
        }
    }

    /// Under an agent on the card: what is hidden there, or that it can't
    /// hide tools while another agent does. Nil when nothing is hidden.
    static func toolNote(canHide: Bool, hiddenHere: Int, anyHidden: Bool, toolCount: Int) -> String? {
        if canHide {
            guard hiddenHere > 0 else { return nil }
            return hiddenHere == 1 ? "1 tool hidden" : "\(hiddenHere) tools hidden"
        }
        guard anyHidden else { return nil }
        return "Sees all \(toolCount) tools: can't hide single tools"
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
    case checkAgain, resume, allowFile, pin, unpin, hide

    var title: String {
        switch self {
        case .checkAgain: return "Check again"
        case .resume: return "Resume"
        case .allowFile: return "Allow this file"
        case .pin: return "Pin"
        case .unpin: return "Unpin"
        case .hide: return "Hide"
        }
    }

    var systemImage: String {
        switch self {
        case .checkAgain: return "arrow.clockwise"
        case .resume: return "play"
        case .allowFile: return "checkmark.shield"
        case .pin: return "pin"
        case .unpin: return "pin.slash"
        case .hide: return "eye.slash"
        }
    }
}
