import Foundation

/// The three numbers at the top of the panel (premium look, 22 Nov, Kika's
/// pick "three tiles"): servers in use, tools turned off, and what needs her.
/// Pure, so `PremiumLookTests` covers the counting and the wording.
struct PanelOverview: Equatable, Sendable {
    /// Visible servers that are on in at least one agent.
    var inUse: Int
    /// Agents that declare any server.
    var agents: Int
    /// Tools hidden across those servers (hidden by every agent that can hide).
    var toolsOff: Int
    /// How many servers have a hidden tool.
    var toolsOffServers: Int
    /// Rows in Needs you.
    var needYou: Int
    /// Something is broken: the number takes the broken tone, else the amber one.
    var hasBroken: Bool
    /// "1 broken · 2 sign-in": at most two kinds, then "N more".
    var needLine: String
    /// A check runs and rows still wait for their first answer.
    var checkingLine: String?

    static func build(
        groups: [ServerGroup],
        agentCount: Int,
        hiddenTools: (ServerGroup) -> Int,
        checking: Bool = false,
        connectors: [ClaudeConnector] = []
    ) -> PanelOverview {
        let on = groups.filter { !$0.isOffEverywhere }
        let hidden = on.map(hiddenTools).filter { $0 > 0 }
        let needs = groups.filter(PanelSections.needsYou)

        var checkingLine: String?
        if checking {
            let done = groups.filter { $0.state != .unknown }.count
            checkingLine = done < groups.count ? "Checking \(done) of \(groups.count)" : "Checking\u{2026}"
        }

        return PanelOverview(
            inUse: on.count,
            agents: agentCount,
            toolsOff: hidden.reduce(0, +),
            toolsOffServers: hidden.count,
            // The number is the servers that need her: the same count as the
            // Needs you section, the menu bar icon and the widgets. Only when
            // no server does, the account's connectors with a problem stand
            // here instead (review 22 Nov), so a failing one never sits under
            // "All fine".
            needYou: needs.isEmpty ? connectors.filter(\.needsYou).count : needs.count,
            hasBroken: needs.isEmpty ? connectors.contains { $0.state == .failing } : needs.contains { $0.state == .broken },
            needLine: needs.isEmpty ? needLine([], connectors: connectors.filter(\.needsYou).count) : needLine(needs),
            checkingLine: checkingLine
        )
    }

    /// One word per row, in the footer tooltip's order.
    static func needLine(_ needs: [ServerGroup], connectors: Int = 0) -> String {
        var kinds: [(count: Int, word: String)] = []
        func add(_ count: Int, _ word: String) { if count > 0 { kinds.append((count, word)) } }
        let degraded = needs.filter { $0.state == .degraded }
        let signIn = degraded.filter(\.needsSignIn).count
        let badConfig = degraded.filter { !$0.needsSignIn && $0.incompleteConfig }.count
        add(needs.filter { $0.state == .broken }.count, "broken")
        add(signIn, "sign-in")
        add(degraded.count - signIn - badConfig, "slow")
        add(badConfig, "bad config")
        let healthy = needs.filter { $0.state == .healthy }
        let lost = healthy.filter(\.droppedInSession).count
        add(healthy.count - lost, "set up differently")
        add(lost, "lost in a session")
        add(connectors, connectors == 1 ? "connector" : "connectors")

        guard kinds.count > 2 else {
            return kinds.map { "\($0.count) \($0.word)" }.joined(separator: " \u{00B7} ")
        }
        let rest = kinds.dropFirst().reduce(0) { $0 + $1.count }
        return "\(kinds[0].count) \(kinds[0].word) \u{00B7} \(rest) more"
    }

    var inUseLine: String {
        agents == 1 ? "in 1 agent" : "across \(agents) agents"
    }

    var toolsOffLine: String {
        guard toolsOff > 0 else { return "all tools on" }
        return toolsOffServers == 1 ? "in 1 server" : "in \(toolsOffServers) servers"
    }

    /// The third tile's grey line: how far the check is, else what kind of
    /// problems, else nothing.
    var needYouLine: String {
        checkingLine ?? needLine
    }
}
