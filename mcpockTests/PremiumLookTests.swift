import XCTest
@testable import mcpock

/// The premium look (22 Nov, Kika's picks on Mocker): three overview tiles,
/// one value per row in words, "No tools" for a broken server, the icon that
/// carries the state, and the widgets' rings. The wording and the counting
/// are pure, so they are checked here without a view.
final class PremiumLookTests: XCTestCase {
    private func group(
        _ name: String,
        _ state: HealthState = .healthy,
        tools: Int = 0,
        reason: String? = nil,
        differs: Bool = false
    ) -> ServerGroup {
        ServerGroup(
            name: name,
            state: state,
            sourceLabels: ["Code"],
            tools: (0..<tools).map { MCPToolInfo(name: "tool\($0)", description: "") },
            issues: reason.map { [ServerIssue(label: "Code", reason: $0, command: "x")] } ?? [],
            variantCount: 1,
            differs: differs ? [DiffNote(label: "Cursor", target: "x")] : []
        )
    }

    // MARK: - Counts in words

    func testToolsReadInWords() {
        XCTAssertEqual(RowCounts(tools: 7).words, "7 tools")
        XCTAssertEqual(RowCounts(tools: 7, hidden: 2).words, "5 of 7 tools")
        XCTAssertEqual(RowCounts(tools: 1).words, "1 tool")
        XCTAssertNil(RowCounts(tools: 0).words, "nothing to count yet: no value at all")
    }

    func testAnAgentsServersReadInWords() {
        XCTAssertEqual(RowCounts(tools: 29, hidden: 8, unit: .servers).words, "21 of 29 servers")
        XCTAssertEqual(RowCounts(tools: 19, unit: .servers).words, "19 servers")
        XCTAssertEqual(RowCounts(tools: 1, unit: .servers).words, "1 server")
    }

    /// The calls left the rows: the words never carry them, the tooltip does.
    func testCallsStayOutOfTheWordsAndInTheTooltip() {
        let counts = RowCounts(tools: 7, hidden: 2, calls: 160, window: .default)
        XCTAssertEqual(counts.words, "5 of 7 tools")
        XCTAssertTrue(counts.help.contains("160 calls"))
    }

    func testAnOpenAgentsCallsLine() {
        XCTAssertEqual(RowCounts(tools: 35, calls: 9214, window: .default, unit: .servers).callsLine?.hasPrefix("9,214 calls"), true)
        XCTAssertEqual(RowCounts(tools: 3, calls: 1, window: .default, unit: .servers).callsLine?.hasPrefix("1 call "), true)
        XCTAssertNil(RowCounts(tools: 3, unit: .servers).callsLine, "no record of calls: no line")
    }

    func testHiddenIsClampedInTheWords() {
        XCTAssertEqual(RowCounts(tools: 3, hidden: 9).words, "0 of 3 tools")
        XCTAssertEqual(RowCounts(tools: 3, hidden: -2).words, "3 tools")
    }

    // MARK: - "No tools"

    func testOnlyABrokenServerWithNoToolsReadsNoTools() {
        XCTAssertTrue(ServerRowView.showsNoTools(group("postgres", .broken)))
        XCTAssertFalse(ServerRowView.showsNoTools(group("postgres", .broken, tools: 4)), "it has tools from an earlier check")
        XCTAssertFalse(ServerRowView.showsNoTools(group("notion", .degraded)), "needs sign-in is not broken")
        XCTAssertFalse(ServerRowView.showsNoTools(group("new", .unknown)), "not checked yet")
    }

    // MARK: - The icon carries the state

    func testAFineServerHasNoBadge() {
        XCTAssertNil(ServerIconView.badgeState(for: .healthy))
    }

    func testEveryOtherStateIsBadged() {
        for state in [HealthState.degraded, .broken, .unknown, .paused, .selfManaged, .needsApp, .off] {
            XCTAssertEqual(ServerIconView.badgeState(for: state), state)
        }
    }

    func testTheFallbackIsTheMenuBarGlyph() {
        XCTAssertEqual(ServerIconView.fallbackSymbol, "server.rack")
    }

    func testUsedByNamesTheAgentsOnce() {
        func source(_ id: String, _ agent: String) -> GroupSource {
            GroupSource(configID: id, label: agent, agent: agent, path: "", transport: .stdio, target: "npx x",
                        envKeys: [], headerKeys: [], state: .healthy, failureReason: nil)
        }
        var github = group("github")
        XCTAssertNil(ServerRowView.usedBy(github), "no declaration known: no line")
        // Two Claude Code projects are still one Claude Code.
        github.sources = [source("a", "Code"), source("b", "Code"), source("c", "Cursor")]
        XCTAssertEqual(ServerRowView.usedBy(github),
                       "Used by \(AgentBadge.displayLabel("Code")), \(AgentBadge.displayLabel("Cursor"))")
    }

    // MARK: - The agent row's mark

    func testAnAgentsMarkIsTheWorstOfItsServers() {
        let fine = AgentServer(name: "a", state: .healthy, note: nil, rank: nil)
        let slow = AgentServer(name: "b", state: .degraded, note: "Slow", rank: 1)
        let broken = AgentServer(name: "c", state: .broken, note: "Quit", rank: 0)
        XCTAssertNil(AgentSections.mark(for: AgentSection(agent: "Code", paths: [], servers: [fine])))
        XCTAssertEqual(AgentSections.mark(for: AgentSection(agent: "Code", paths: [], servers: [fine, slow])), .degraded)
        XCTAssertEqual(AgentSections.mark(for: AgentSection(agent: "Code", paths: [], servers: [slow, broken])), .broken)
    }

    // MARK: - Overview tiles

    func testOverviewCountsWhatIsInUseOffAndNeedsHer() {
        let groups = [
            group("postgres", .broken),
            group("notion", .degraded, reason: "Needs authentication (HTTP 401)"),
            group("figma", .degraded, reason: "Needs authentication (HTTP 401)"),
            group("github", tools: 26),
            group("apple-docs", tools: 7),
            group("old", .off),
        ]
        let overview = PanelOverview.build(groups: groups, agentCount: 9) { $0.name == "apple-docs" ? 2 : 0 }
        XCTAssertEqual(overview.inUse, 5, "a server off in every agent is not in use")
        XCTAssertEqual(overview.inUseLine, "across 9 agents")
        XCTAssertEqual(overview.toolsOff, 2)
        XCTAssertEqual(overview.toolsOffLine, "in 1 server")
        XCTAssertEqual(overview.needYou, 3)
        XCTAssertTrue(overview.hasBroken)
        XCTAssertEqual(overview.needYouLine, "1 broken \u{00B7} 2 sign-in")
    }

    func testOverviewWithNothingWrong() {
        let overview = PanelOverview.build(groups: [group("github", tools: 3)], agentCount: 1) { _ in 0 }
        XCTAssertEqual(overview.needYou, 0)
        XCTAssertFalse(overview.hasBroken)
        XCTAssertEqual(overview.needYouLine, "")
        XCTAssertEqual(overview.toolsOffLine, "all tools on")
        XCTAssertEqual(overview.inUseLine, "in 1 agent")
    }

    func testOverviewNamesTwoKindsThenTheRest() {
        let needs = [
            group("a", .broken),
            group("b", .degraded, reason: "Needs authentication (HTTP 401)"),
            group("c", .degraded, reason: "No answer in 10 s"),
            group("d", differs: true),
        ]
        XCTAssertEqual(PanelOverview.needLine(needs), "1 broken \u{00B7} 3 more")
        XCTAssertEqual(PanelOverview.needLine(Array(needs.prefix(2))), "1 broken \u{00B7} 1 sign-in")
        XCTAssertEqual(PanelOverview.needLine([needs[2]]), "1 slow")
    }

    func testOverviewSaysHowFarTheCheckIs() {
        let groups = [group("a"), group("b", .unknown), group("c", .unknown)]
        let overview = PanelOverview.build(groups: groups, agentCount: 1, hiddenTools: { _ in 0 }, checking: true)
        XCTAssertEqual(overview.needYouLine, "Checking 1 of 3")
        let done = PanelOverview.build(groups: [group("a")], agentCount: 1, hiddenTools: { _ in 0 }, checking: true)
        XCTAssertEqual(done.needYouLine, "Checking\u{2026}")
    }

    func testTheRestOfTheListIsCalledAllServers() {
        XCTAssertEqual(PanelSection(kind: .everythingElse, groups: []).title, "All servers")
        XCTAssertEqual(PanelSection(kind: .needsYou, groups: []).title, "Needs you")
    }

    // MARK: - Rings

    func testAllFineIsOneClosedRing() {
        XCTAssertEqual(RingArcs.arcs(broken: 0, attention: 0, fine: 41), [RingArcs.Arc(kind: .fine, from: 0, to: 1)])
    }

    func testNothingToDrawWithNoServers() {
        XCTAssertTrue(RingArcs.arcs(broken: 0, attention: 0, fine: 0).isEmpty)
    }

    func testProblemsComeFirstAndCanBeSeen() {
        let arcs = RingArcs.arcs(broken: 1, attention: 2, fine: 38, minShare: 0.045, gap: 0.014)
        XCTAssertEqual(arcs.map(\.kind), [.broken, .attention, .fine])
        // One server of 41 is 2.4% of the circle; the sliver keeps its minimum.
        XCTAssertEqual(arcs[0].to - arcs[0].from, 0.045 - 0.014, accuracy: 0.0001)
        XCTAssertEqual(arcs[1].to - arcs[1].from, 2.0 / 41.0 - 0.014, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(arcs[2].to, 1)
        // Arcs never overlap.
        XCTAssertLessThan(arcs[0].to, arcs[1].from)
        XCTAssertLessThan(arcs[1].to, arcs[2].from)
    }

    func testWhatIsOffStaysTheBareTrack() {
        let arcs = RingArcs.arcs(broken: 0, attention: 0, fine: 21, off: 8, gap: 0)
        XCTAssertEqual(arcs.count, 1)
        XCTAssertEqual(arcs[0].to, 21.0 / 29.0, accuracy: 0.0001, "the last 8 of 29 are left open")
    }

    func testNegativeCountsAreTreatedAsNone() {
        XCTAssertEqual(RingArcs.arcs(broken: -1, attention: 0, fine: 3), [RingArcs.Arc(kind: .fine, from: 0, to: 1)])
    }

    // MARK: - Widget numbers

    func testWidgetInUseLine() {
        var s = MCPockWidgetSnapshot(generated: Date(timeIntervalSince1970: 1_800_000_000), checking: false,
                                     firstCheckDone: true, totalServers: 43, problemCount: 3, fineCount: 38,
                                     problems: [], agents: [], brokenCount: 1)
        XCTAssertEqual(s.inUseLine, "43 servers", "an older snapshot has neither number")
        s.inUse = 41
        XCTAssertEqual(s.inUseLine, "41 in use")
        s.toolsOff = 12
        XCTAssertEqual(s.inUseLine, "41 in use \u{00B7} 12 off")
        XCTAssertEqual(s.ringCounts.broken, 1)
        XCTAssertEqual(s.ringCounts.attention, 2)
        XCTAssertEqual(s.ringCounts.fine, 38)
        XCTAssertEqual(s.ringCounts.quiet, 2)
    }

    func testWidgetAgentWords() {
        var agent = MCPockWidgetSnapshot.Agent(name: "Goose", serverCount: 29, problemCount: 0, fineCount: 21)
        XCTAssertEqual(agent.countWords, "29")
        XCTAssertEqual(agent.quietCount, 8)
        agent.offCount = 8
        XCTAssertEqual(agent.countWords, "21 of 29")
    }

    func testWidgetAgentNamesFoldProjects() {
        XCTAssertEqual(MCPockWidgetSnapshot.agentNames(["Claude Code (MyApp)", "Claude Code", "Cursor"]), ["Claude Code", "Cursor"])
    }

    /// An older snapshot (no new fields) still decodes.
    func testAnOlderWidgetSnapshotStillDecodes() throws {
        let json = """
        {"schema":1,"generated":"2026-11-01T10:00:00Z","checking":false,"firstCheckDone":true,"totalServers":4,
         "problemCount":1,"fineCount":3,"problems":[{"name":"figma","status":"needs sign-in"}],
         "agents":[{"name":"Cursor","serverCount":4,"problemCount":1,"fineCount":3}]}
        """
        let snapshot = try MCPockWidgetSnapshot.decoder().decode(MCPockWidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.inUse)
        XCTAssertNil(snapshot.problems[0].agents)
        XCTAssertEqual(snapshot.agents[0].countWords, "4")
        XCTAssertEqual(snapshot.inUseLine, "4 servers")
    }
}
