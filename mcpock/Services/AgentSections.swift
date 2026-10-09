import Foundation

/// One server as one agent sees it: that agent's own declarations decide the
/// state, so a server broken only in Cursor doesn't show broken under Claude Code.
struct AgentServer: Identifiable, Hashable, Sendable {
    let name: String
    let state: HealthState
    /// The short line under a problem server ("Could not start: command not
    /// found", "Grok has a different setup"); nil when it's fine.
    let note: String?
    /// Rank inside the agent's problems (broken, slow, differs), as in
    /// the panel's Needs you. nil when the server doesn't need you.
    let rank: Int?

    var id: String { name }
    var needsYou: Bool { rank != nil }
}

/// One agent in the Agents tab: its config file(s) and every server it declares.
struct AgentSection: Identifiable, Hashable, Sendable {
    /// The source label (`ServerSource.label`): "Code", "Cursor", "Hermes · scribe".
    let agent: String
    /// Config files behind it, in discovery order (usually one).
    let paths: [String]
    /// Problems first (by rank, then name), then the rest by name.
    let servers: [AgentServer]
    /// What the open agent lists (round 5): every server with the attention
    /// toggle off, only its problems with it on. The counts, the health bar and
    /// the wording always describe all of `servers`.
    let listed: [AgentServer]

    init(agent: String, paths: [String], servers: [AgentServer], listed: [AgentServer]? = nil) {
        self.agent = agent
        self.paths = paths
        self.servers = servers
        self.listed = listed ?? servers
    }

    var id: String { agent }
    var displayName: String { AgentBadge.displayLabel(agent) }
    var problems: [AgentServer] { servers.filter(\.needsYou) }
    var brokenCount: Int { servers.filter { $0.state == .broken }.count }
    /// Needs you, but not broken: slow, sign-in, differs.
    var attentionCount: Int { problems.count - brokenCount }
    /// Not checked yet (right after launch). Neither a problem nor fine.
    var checkingCount: Int { servers.filter { $0.state == .unknown }.count }
    var fineCount: Int { servers.count - problems.count - checkingCount }
}

/// Builds the Agents tab (v1.5 spec, Phase 4) from the same `ServerGroup`s as the
/// Servers tab: every source label is an agent. Pure, so `AgentSectionsTests`
/// covers grouping, per-agent state and the sort.
enum AgentSections {
    /// Agents sorted by what needs you: most problems first, then by name; aka
    /// always last (round 6).
    /// `query` keeps an agent whose name matches, or that declares a server whose
    /// name, source labels or tools match (the panel's search, `PanelSections.matches`).
    /// `filter` is the footer's attention toggle, shared with the Servers tab
    /// (round 5): `.all` keeps every agent and lists all its servers, problems
    /// first; `.problems` lists only the problems of agents that have one, but
    /// keeps agents with nothing wrong too, sorted after them, so the tab is
    /// never left looking half empty (2026-09-25). `isDimmed` tells the
    /// view which sections those are.
    static func build(groups: [ServerGroup], query: String = "", filter: PanelFilter = .all) -> [AgentSection] {
        var order: [String] = []
        var paths: [String: [String]] = [:]
        var servers: [String: [AgentServer]] = [:]
        var matched: [String: Bool] = [:]

        for group in groups {
            let byAgent = Dictionary(grouping: group.sources, by: \.agent)
            let groupMatches = PanelSections.matches(group, query: query)
            for source in group.sources {
                let agent = source.agent
                if paths[agent] == nil {
                    order.append(agent)
                    paths[agent] = []
                    servers[agent] = []
                }
                if !source.path.isEmpty && !(paths[agent] ?? []).contains(source.path) {
                    paths[agent, default: []].append(source.path)
                }
                if groupMatches { matched[agent] = true }
            }
            for (agent, own) in byAgent {
                servers[agent, default: []].append(server(group, agent: agent, sources: own))
            }
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return order
            .filter { agent in
                needle.isEmpty
                    || matched[agent] == true
                    || agent.localizedStandardContains(needle)
                    || AgentBadge.displayLabel(agent).localizedStandardContains(needle)
            }
            .map { agent in
                let all = sortServers(servers[agent] ?? [])
                return AgentSection(
                    agent: agent,
                    paths: paths[agent] ?? [],
                    servers: all,
                    listed: filter == .problems ? all.filter(\.needsYou) : all
                )
            }
            .sorted { a, b in
                // aka is a desktop agent app: always at the bottom (round 6).
                let (lastA, lastB) = (isAlwaysLast(a.agent), isAlwaysLast(b.agent))
                if lastA != lastB { return lastB }
                if a.problems.count != b.problems.count { return a.problems.count > b.problems.count }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
    }

    /// True when one of this agent's own declarations is named by the row's
    /// differs notes. aka is never compared (round 6), so it is never named.
    static func isOddOneOut(_ group: ServerGroup, sources: [GroupSource]) -> Bool {
        guard group.isDiffering else { return false }
        let odd = Set(group.differs.map(\.label))
        return sources.contains { odd.contains($0.label) && Differs.isCompared(agent: $0.agent) }
    }

    /// The worst problem rank across the agents (0 broken, 1 slow or sign-in,
    /// 2 set up differently), or nil when no agent needs you. Tints the
    /// attention toggle on the Agents tab.
    static func worstRank(_ sections: [AgentSection]) -> Int? {
        sections.flatMap(\.servers).compactMap(\.rank).min()
    }

    /// Agents listed after every other one, whatever their problem count.
    static func isAlwaysLast(_ agent: String) -> Bool {
        agent == AkaSource.label
    }

    /// True when the attention toggle is on and this agent has nothing wrong:
    /// it stays in the list (below the agents that need you) but the view
    /// dims it, so the tab is never left looking half empty (2026-09-25).
    static func isDimmed(_ section: AgentSection, filter: PanelFilter) -> Bool {
        filter == .problems && section.problems.isEmpty
    }

    /// The server as `agent` declares it. 1.5.3 ("Claude Code shows 2
    /// need you although all its servers are fine"): a server is this agent's
    /// problem only when (a) the agent's OWN declaration is broken, slow or
    /// needs sign-in, or (b) the server is set up differently AND this agent is
    /// an odd one out named by the differs notes (with no majority `Differs`
    /// names every compared source, so they all count). An agent in the
    /// majority sees a fine row; a row marked as intended never counts (its
    /// `differs` is empty).
    static func server(_ group: ServerGroup, agent: String, sources: [GroupSource]) -> AgentServer {
        let state = HealthMonitor.aggregateState(sources.map(\.state))
        let differs = state != .paused && state != .selfManaged
            && isOddOneOut(group, sources: sources)
        let rank: Int?
        let note: String?
        switch state {
        case .broken, .degraded:
            rank = state == .broken ? 0 : 1
            let reason = sources.first { $0.state == state && $0.failureReason != nil }?.failureReason
            note = reason.map { ShortReason.from($0, state: state) } ?? (state == .broken ? "Broken" : "Slow")
        case .healthy:
            rank = differs ? 2 : nil
            note = differs ? CardText.differsLine(for: group, agent: agent) : nil
        // Not checked yet is not a problem (same rule as the Servers tab's Needs
        // you): right after launch every agent would otherwise read "19 need you".
        case .unknown, .selfManaged, .paused:
            rank = nil
            note = nil
        }
        return AgentServer(name: group.name, state: state, note: note, rank: rank)
    }

    private static func sortServers(_ servers: [AgentServer]) -> [AgentServer] {
        servers.sorted { a, b in
            let (ra, rb) = (a.rank ?? .max, b.rank ?? .max)
            if ra != rb { return ra < rb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// "5 agents · sorted by what needs you".
    static func summary(_ sections: [AgentSection]) -> String {
        guard !sections.isEmpty else { return "No agents found" }
        let count = sections.count
        return "\(count) agent\(count == 1 ? "" : "s") \u{00B7} sorted by what needs you"
    }

    /// The footer on the Agents tab (round 2): "13 agents · 3 need you",
    /// "13 agents, all need you" or "13 agents, all fine"; "Checking…" while a
    /// check runs.
    static func compactSummary(_ sections: [AgentSection], checking: Bool = false) -> String {
        if checking { return "Checking\u{2026}" }
        guard !sections.isEmpty else { return "No agents found" }
        let count = sections.count
        let agents = "\(count) agent\(count == 1 ? "" : "s")"
        let needing = sections.filter { !$0.problems.isEmpty }.count
        if needing == 0 { return agents + ", all fine" }
        if needing == count && count > 1 { return agents + ", all need you" }
        return agents + " \u{00B7} \(needing) \(needing == 1 ? "needs" : "need") you"
    }

    /// "3 need you", "1 needs you", "Checking…" (nothing wrong so far, but not
    /// every server answered yet), or "All fine".
    static func problemText(_ section: AgentSection) -> String {
        let count = section.problems.count
        if count == 0 { return section.checkingCount > 0 ? "Checking\u{2026}" : "All fine" }
        return "\(count) \(count == 1 ? "needs" : "need") you"
    }

    /// "+N more / Show less" for an open agent's server list: only
    /// the first `limit` show by default, but a server that needs attention
    /// is never folded away, however many there are — fine servers fill
    /// whatever's left up to `limit`, in `AgentSection.servers`'s own order
    /// (problems by rank, then everyone by name), so a fold never reorders
    /// anything. With the attention filter on, `section.listed` already holds
    /// only problems, so this degenerates to "show everything, nothing
    /// folded" on its own — no special case needed.
    enum ServerFold {
        static let limit = 5

        /// The rows to show, and how many are folded away. `expanded` (or
        /// `limit` or fewer servers, so nothing to fold) shows everything.
        static func shown(
            _ servers: [AgentServer], expanded: Bool, limit: Int = Self.limit
        ) -> (rows: [AgentServer], hiddenCount: Int) {
            guard !expanded, servers.count > limit else { return (servers, 0) }
            let problemCount = servers.filter(\.needsYou).count
            let fineSlots = max(limit - problemCount, 0)
            var rows: [AgentServer] = []
            var fineShown = 0
            for server in servers {
                if server.needsYou {
                    rows.append(server)
                } else if fineShown < fineSlots {
                    rows.append(server)
                    fineShown += 1
                }
            }
            return (rows, servers.count - rows.count)
        }

        /// The tooltip and accessibility label of "+N more": "Show 3 more".
        static func showMoreHelp(folded: Int) -> String {
            "Show \(folded) more"
        }
    }

    /// Under the listed problems while the attention toggle is on (with it off
    /// every server is listed, so there is nothing to sum up): "16 more, all
    /// fine"; with no problems, "All 19
    /// servers answer normally". Servers not checked yet are named as such.
    static func restText(_ section: AgentSection) -> String {
        let rest = section.fineCount
        let checking = section.checkingCount
        if checking > 0 {
            let more = section.problems.isEmpty ? "" : "\(rest + checking) more, "
            return more + "\(checking) not checked yet"
        }
        if section.problems.isEmpty {
            return rest == 1 ? "Its only server answers normally" : "All \(rest) servers answer normally"
        }
        if rest == 0 { return "Nothing else here" }
        return "\(rest) more, all fine"
    }
}
