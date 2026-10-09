import XCTest
@testable import mcpock

/// The Agents tab (v1.5 spec, Phase 4): every source label is an agent, each
/// server is judged by that agent's own declarations, and agents are sorted by
/// what needs you.
final class AgentSectionsTests: XCTestCase {
    private func src(
        _ agent: String,
        _ state: HealthState = .healthy,
        reason: String? = nil,
        target: String = "npx s",
        path: String? = nil,
        project: String? = nil
    ) -> GroupSource {
        let label = project.map { "\(agent) (\($0))" } ?? agent
        return GroupSource(
            configID: "\(label)-\(UUID().uuidString)", label: label, agent: agent,
            path: path ?? "/Users/k/.\(agent.lowercased()).json", transport: .stdio, target: target,
            envKeys: [], headerKeys: [], state: state, failureReason: reason
        )
    }

    private func group(_ name: String, _ sources: [GroupSource], differs: [String] = [], tools: [String] = []) -> ServerGroup {
        ServerGroup(
            name: name,
            state: HealthMonitor.aggregateState(sources.map(\.state)),
            sourceLabels: sources.map(\.label),
            tools: tools.map { MCPToolInfo(name: $0, description: "") },
            issues: sources.compactMap { s in s.failureReason.map { ServerIssue(label: s.label, reason: $0, command: s.target) } },
            variantCount: sources.count,
            differs: differs.map { DiffNote(label: $0, target: "x") },
            sources: sources
        )
    }

    func testEverySourceLabelIsAnAgentWithItsServers() {
        let sections = AgentSections.build(groups: [
            group("wake", [src("Code"), src("Cursor")]),
            group("feed", [src("Code")]),
        ])
        XCTAssertEqual(Set(sections.map(\.agent)), ["Code", "Cursor"])
        let code = sections.first { $0.agent == "Code" }!
        XCTAssertEqual(code.servers.map(\.name), ["feed", "wake"], "fine servers by name")
        XCTAssertEqual(code.displayName, "Claude Code")
        XCTAssertEqual(code.paths, ["/Users/k/.code.json"])
    }

    /// Broken in Cursor only: Claude Code's copy is fine.
    func testStateIsPerAgent() {
        let sections = AgentSections.build(groups: [
            group("tinycast", [src("Code"), src("Cursor", .broken, reason: "Spawn error: Command not found: tinycast")]),
        ])
        let code = sections.first { $0.agent == "Code" }!
        let cursor = sections.first { $0.agent == "Cursor" }!
        XCTAssertTrue(code.problems.isEmpty)
        XCTAssertEqual(cursor.problems.map(\.name), ["tinycast"])
        XCTAssertEqual(cursor.problems.first?.note, "Could not start: command not found")
        XCTAssertEqual(cursor.brokenCount, 1)
    }

    func testTwoProjectsInOneAgentAreOneServer() {
        let sections = AgentSections.build(groups: [
            group("xapi", [src("Code", project: "A"), src("Code", .broken, reason: "Non-zero exit (1)", project: "B")]),
        ])
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].servers.count, 1)
        XCTAssertEqual(sections[0].servers[0].state, .broken, "worst of the agent's own declarations")
    }

    func testSortedByProblemsThenName() {
        let sections = AgentSections.build(groups: [
            group("tinycast", [src("Code", .broken, reason: "Non-zero exit (127)"), src("Cursor", .broken, reason: "Non-zero exit (127)")]),
            group("n8n", [src("Code", .degraded, reason: "Timed out after 10s"), src("Grok", .degraded, reason: "Timed out after 10s")]),
            group("firecrawl", [src("Code", target: "a"), src("Cursor", target: "a"), src("Grok", target: "b")], differs: ["Grok"]),
            group("wake", [src("Goose"), src("OpenCode")]),
        ])
        // Code 2 (tinycast, n8n); Grok 2 (n8n, and firecrawl where it is the odd
        // one out); Cursor 1 (tinycast; it is in firecrawl's majority).
        XCTAssertEqual(sections.map(\.agent), ["Code", "Grok", "Cursor", "Goose", "OpenCode"],
                       "most problems first, ties and the fine ones by name")
        let code = sections[0]
        XCTAssertEqual(code.problems.map(\.name), ["tinycast", "n8n"], "broken, slow")
        XCTAssertEqual(code.problems.map(\.note), ["Quit on start (exit 127)", "Slow: no answer in 10 s"])
        XCTAssertEqual(sections[1].problems.last?.note, "Points at a different command than the others",
                       "Grok is the odd one out")
        XCTAssertEqual(code.brokenCount, 1)
        XCTAssertEqual(code.attentionCount, 1)
        XCTAssertEqual(code.fineCount, 1, "firecrawl is fine for Claude Code")
    }

    // MARK: - 1.5.3: per-agent attribution of "set up differently"

    /// A report: Claude Code read "2 need you" although all its servers
    /// were fine; the flags came from Goose, Cursor and Grok, set up
    /// differently from Claude Code (the majority).
    func testOnlyTheOddOnesOutCountADifferingServer() {
        let vault = group("notes-vault", [
            src("Code", target: "node /a/index.js"), src("Code", target: "node /a/index.js", project: "Vault"),
            src("Hermes", target: "node /a/index.js"),
            src("Goose", target: "uvx old"), src("Cursor", target: "node /b.js"), src("Grok", target: "bun /c.ts"),
        ], differs: ["Goose", "Cursor", "Grok"])
        let sections = AgentSections.build(groups: [vault, group("wake", [src("Code"), src("Goose")])])
        let byAgent = Dictionary(uniqueKeysWithValues: sections.map { ($0.agent, $0) })

        let code = byAgent["Code"]!
        XCTAssertTrue(code.problems.isEmpty, "Claude Code is in the majority")
        XCTAssertEqual(AgentSections.problemText(code), "All fine")
        XCTAssertEqual(code.fineCount, 2, "the health bar is all fine")
        XCTAssertEqual(code.servers.first { $0.name == "notes-vault" }?.note, nil, "a fine row, no note")
        XCTAssertTrue(byAgent["Hermes"]!.problems.isEmpty)
        for odd in ["Goose", "Cursor", "Grok"] {
            XCTAssertEqual(byAgent[odd]!.problems.map(\.name), ["notes-vault"], odd)
            XCTAssertEqual(byAgent[odd]!.problems.first?.rank, 2)
        }
        XCTAssertEqual(sections.suffix(2).map(\.agent), ["Code", "Hermes"], "agents with nothing wrong sort last")
        XCTAssertEqual(AgentSections.compactSummary(sections), "5 agents \u{00B7} 3 need you")
        XCTAssertEqual(AgentSections.worstRank(sections), 2)

        // With the attention toggle on, Claude Code stays in the list, dimmed
        // (round 9), rather than disappearing.
        let pressed = AgentSections.build(groups: [vault], filter: .problems)
        let dimmedCode = pressed.first { $0.agent == "Code" }
        XCTAssertNotNil(dimmedCode)
        XCTAssertTrue(AgentSections.isDimmed(dimmedCode!, filter: .problems))
    }

    /// No majority (a 1-vs-1 split): `Differs` names every compared source, so
    /// every agent involved counts.
    func testNoMajorityCountsEveryAgentInvolved() {
        let split = group("feed", [src("Code", target: "a"), src("Cursor", target: "b"), src("aka", target: "c")],
                          differs: ["Code", "Cursor"])
        let sections = AgentSections.build(groups: [split])
        let byAgent = Dictionary(uniqueKeysWithValues: sections.map { ($0.agent, $0) })
        XCTAssertEqual(byAgent["Code"]?.problems.count, 1)
        XCTAssertEqual(byAgent["Cursor"]?.problems.count, 1)
        XCTAssertEqual(byAgent["aka"]?.problems.count, 0, "aka is never compared")
    }

    /// A row marked as intended never counts, for any agent.
    func testDifferentOnPurposeNeverCounts() {
        var onPurpose = group("feed", [src("Code", target: "a"), src("Code", target: "a", project: "P"), src("Grok", target: "b")])
        onPurpose.acknowledgedDiffers = [DiffNote(label: "Grok", target: "b")]
        let sections = AgentSections.build(groups: [onPurpose])
        XCTAssertTrue(sections.allSatisfy { $0.problems.isEmpty })
        XCTAssertNil(AgentSections.worstRank(sections))
    }

    /// An agent's own failure still counts, whether or not the row also differs.
    func testOwnFailureCountsEvenInTheMajority() {
        let sections = AgentSections.build(groups: [
            group("wake", [src("Code", .broken, reason: "Non-zero exit (1)", target: "a"), src("Cursor", target: "a"),
                           src("Grok", target: "b")], differs: ["Grok"]),
        ])
        let byAgent = Dictionary(uniqueKeysWithValues: sections.map { ($0.agent, $0) })
        XCTAssertEqual(byAgent["Code"]?.problems.first?.rank, 0, "Claude Code's own copy is broken")
        XCTAssertEqual(byAgent["Cursor"]?.problems.count, 0)
        XCTAssertEqual(byAgent["Grok"]?.problems.first?.rank, 2)
        XCTAssertEqual(AgentSections.worstRank(sections), 0)
    }

    /// A project-scoped declaration named by the notes makes its agent odd.
    func testProjectScopedOddOneOut() {
        let sections = AgentSections.build(groups: [
            group("x", [src("Code", target: "b", project: "Old"), src("Cursor", target: "a"), src("Grok", target: "a")],
                  differs: ["Code (Old)"]),
        ])
        let code = sections.first { $0.agent == "Code" }!
        XCTAssertEqual(code.problems.first?.note, "Points at a different command than the others")
    }

    func testQuietServersAreFine() {
        let sections = AgentSections.build(groups: [
            group("matrix", [src("MiniMax", .selfManaged)]),
            group("oauth", [src("MiniMax", .paused)], differs: ["MiniMax"]),
        ])
        XCTAssertTrue(sections[0].problems.isEmpty)
        XCTAssertEqual(sections[0].fineCount, 2)
    }

    /// Right after launch nothing is checked yet; that is not a problem.
    func testUncheckedServersAreNotProblems() {
        let sections = AgentSections.build(groups: [
            group("wake", [src("Code", .unknown)]),
            group("feed", [src("Code", .unknown)]),
        ])
        XCTAssertTrue(sections[0].problems.isEmpty)
        XCTAssertEqual(sections[0].checkingCount, 2)
        XCTAssertEqual(sections[0].fineCount, 0, "not checked is not fine either")
        XCTAssertEqual(AgentSections.problemText(sections[0]), "Checking\u{2026}")
        XCTAssertEqual(AgentSections.restText(sections[0]), "2 not checked yet")
    }

    func testTwoConfigFilesForOneAgent() {
        let sections = AgentSections.build(groups: [
            group("a", [src("Agent", path: "/a/one/mcp.json")]),
            group("b", [src("Agent", path: "/a/mcp.json")]),
        ])
        XCTAssertEqual(sections[0].paths, ["/a/one/mcp.json", "/a/mcp.json"])
    }

    func testSearchMatchesAgentOrItsServers() {
        let groups = [
            group("wake", [src("Code"), src("Cursor")], tools: ["wake_search"]),
            group("feed", [src("Goose")]),
        ]
        XCTAssertEqual(AgentSections.build(groups: groups, query: "goo").map(\.agent), ["Goose"])
        XCTAssertEqual(AgentSections.build(groups: groups, query: "claude").map(\.agent), ["Code"],
                       "the display name counts")
        XCTAssertEqual(Set(AgentSections.build(groups: groups, query: "wake_s").map(\.agent)), ["Code", "Cursor"],
                       "tool names find the agents that declare them")
        XCTAssertTrue(AgentSections.build(groups: groups, query: "zzz").isEmpty)
    }

    func testWording() {
        let sections = AgentSections.build(groups: [
            group("a", [src("Code", .broken, reason: "x")]),
            group("b", [src("Code")]),
            group("c", [src("Code")]),
            group("d", [src("Grok")]),
        ])
        XCTAssertEqual(AgentSections.summary(sections), "2 agents \u{00B7} sorted by what needs you")
        XCTAssertEqual(AgentSections.summary([]), "No agents found")
        XCTAssertEqual(AgentSections.problemText(sections[0]), "1 needs you")
        XCTAssertEqual(AgentSections.restText(sections[0]), "2 more, all fine")
        XCTAssertEqual(AgentSections.problemText(sections[1]), "All fine")
        XCTAssertEqual(AgentSections.restText(sections[1]), "Its only server answers normally")
    }

    func testCompactSummaryForTheFooter() {
        let sections = AgentSections.build(groups: [
            group("a", [src("Code", .broken, reason: "x")]),
            group("d", [src("Grok")]),
        ])
        XCTAssertEqual(AgentSections.compactSummary(sections), "2 agents \u{00B7} 1 needs you")
        let calm = AgentSections.build(groups: [group("d", [src("Grok")])])
        XCTAssertEqual(AgentSections.compactSummary(calm), "1 agent, all fine")
        let allBad = AgentSections.build(groups: [
            group("a", [src("Code", .broken, reason: "x")]),
            group("b", [src("Grok", .broken, reason: "x")]),
        ])
        XCTAssertEqual(AgentSections.compactSummary(allBad), "2 agents, all need you")
        XCTAssertEqual(AgentSections.compactSummary([]), "No agents found")
        XCTAssertEqual(AgentSections.compactSummary([], checking: true), "Checking\u{2026}")
    }

    // MARK: - Round 5: the attention toggle on the Agents tab

    private var mixed: [ServerGroup] {
        [
            group("tinycast", [src("Code", .broken, reason: "Non-zero exit (127)")]),
            group("n8n", [src("Code", .degraded, reason: "Timed out after 10s")]),
            group("wake", [src("Code"), src("Grok")]),
            group("feed", [src("Code", .unknown), src("Grok")]),
            group("matrix", [src("Grok", .paused)]),
        ]
    }

    /// Unpressed: every agent, and an agent lists all its servers, problems
    /// first (broken, slow), then the rest by name, each with its short reason.
    func testAllListsEveryAgentAndEveryServer() {
        let sections = AgentSections.build(groups: mixed, filter: .all)
        XCTAssertEqual(sections.map(\.agent), ["Code", "Grok"], "an agent with nothing wrong stays in the list")
        let code = sections[0]
        XCTAssertEqual(code.listed.map(\.name), ["tinycast", "n8n", "feed", "wake"])
        XCTAssertEqual(code.listed.map(\.note), ["Quit on start (exit 127)", "Slow: no answer in 10 s", nil, nil])
        XCTAssertEqual(sections[1].listed.map(\.name), ["feed", "matrix", "wake"])
        XCTAssertEqual(code.listed, code.servers)
    }

    /// Pressed: agents with a problem list only the problems. Counts and
    /// wording still describe all of the agent's servers.
    func testProblemsKeepsOnlyAgentsAndServersThatNeedYou() {
        let sections = AgentSections.build(groups: mixed, filter: .problems)
        let code = sections[0]
        XCTAssertEqual(code.listed.map(\.name), ["tinycast", "n8n"])
        XCTAssertEqual(code.servers.count, 4, "the health bar and counts keep every server")
        XCTAssertEqual(AgentSections.problemText(code), "2 need you")
        XCTAssertEqual(AgentSections.restText(code), "2 more, 1 not checked yet")
    }

    /// Round 9 (2026-09-25): an agent with nothing wrong stays in the
    /// list under the attention toggle, sorted after the ones that need you,
    /// so the tab is never left looking half empty. `isDimmed` marks it for
    /// the view; its own servers aren't listed (there's nothing to flag).
    func testProblemsKeepsFineAgentsTooButDimmed() {
        let sections = AgentSections.build(groups: mixed, filter: .problems)
        XCTAssertEqual(sections.map(\.agent), ["Code", "Grok"], "Grok has nothing wrong but stays")
        let grok = sections[1]
        XCTAssertTrue(grok.problems.isEmpty)
        XCTAssertEqual(grok.listed, [], "nothing to flag, so nothing is listed")
        XCTAssertTrue(AgentSections.isDimmed(grok, filter: .problems))
        XCTAssertFalse(AgentSections.isDimmed(sections[0], filter: .problems), "Code needs you")
        XCTAssertFalse(AgentSections.isDimmed(grok, filter: .all), "the toggle off dims nobody")
    }

    func testProblemsWithNothingWrongListsEveryoneDimmed() {
        let calm = [group("wake", [src("Code"), src("Grok")])]
        let sections = AgentSections.build(groups: calm, filter: .problems)
        XCTAssertEqual(sections.count, 2, "nobody is dropped, just dimmed")
        XCTAssertTrue(sections.allSatisfy { AgentSections.isDimmed($0, filter: .problems) })
        XCTAssertEqual(AgentSections.build(groups: calm, filter: .all).count, 2)
    }

    func testProblemsAndSearchTogether() {
        XCTAssertEqual(AgentSections.build(groups: mixed, query: "matrix", filter: .problems).map(\.agent), ["Grok"],
                       "only Grok declares matrix; it stays (dimmed) because the search matched it")
        XCTAssertEqual(AgentSections.build(groups: mixed, query: "tiny", filter: .problems).map(\.agent), ["Code"])
    }

    /// The open agent and the servers the arrow keys walk through.
    func testOpenAgentAndItsServerNames() {
        let sections = AgentSections.build(groups: mixed, filter: .all)
        XCTAssertNil(PanelState.openAgent(in: sections, expanded: nil), "round 8: nothing starts open, not even the worst")
        XCTAssertEqual(PanelState.openAgent(in: sections, expanded: "Grok"), "Grok")
        XCTAssertNil(PanelState.openAgent(in: sections, expanded: "Gone"), "an agent that left the list")
        let pressedList = AgentSections.build(groups: mixed, filter: .problems)
        XCTAssertNil(PanelState.openAgent(in: pressedList, expanded: nil), "attention pressed: still all closed")
        // Round 9: Grok has nothing wrong but stays in the list dimmed, so it
        // can still be opened.
        XCTAssertEqual(PanelState.openAgent(in: pressedList, expanded: "Grok"), "Grok")
        XCTAssertEqual(PanelState.agentServerNames(in: sections, open: "Grok"), ["feed", "matrix", "wake"])
        XCTAssertEqual(PanelState.agentServerNames(in: sections, open: nil), [])
        let pressed = AgentSections.build(groups: mixed, filter: .problems)
        XCTAssertEqual(PanelState.agentServerNames(in: pressed, open: "Code"), ["tinycast", "n8n"])
        // A dimmed agent's own servers aren't listed: nothing of Grok's needs
        // flagging, so there's nothing to walk through with the arrow keys.
        XCTAssertEqual(PanelState.agentServerNames(in: pressed, open: "Grok"), [])
    }

    /// Round 6: aka is a desktop agent app and always sits at the bottom, even with
    /// the most problems; the rest stay sorted by what needs you.
    func testAkaIsAlwaysLast() {
        let sections = AgentSections.build(groups: [
            group("a", [src("aka", .broken, reason: "Non-zero exit (1)"), src("Code"), src("Cursor", .broken, reason: "Timed out after 10s")]),
            group("b", [src("aka", .broken, reason: "Non-zero exit (1)"), src("Zed")]),
            group("c", [src("aka", .degraded, reason: "Needs authentication (HTTP 401)")]),
        ])
        XCTAssertEqual(sections.map(\.agent), ["Cursor", "Code", "Zed", "aka"])
        XCTAssertEqual(sections.last?.problems.count, 3, "its real errors still count")

        let problemsOnly = AgentSections.build(groups: [
            group("a", [src("aka", .broken, reason: "x"), src("Cursor", .broken, reason: "y")]),
        ], filter: .problems)
        XCTAssertEqual(problemsOnly.map(\.agent), ["Cursor", "aka"])
    }
}
