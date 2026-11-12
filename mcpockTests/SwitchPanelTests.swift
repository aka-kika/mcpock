import XCTest
@testable import mcpock

/// The switch in the panel and on the card (1.14): the Turned off fold, the
/// quiet "Off in Cursor" note, the sheet's flow. The files live in a
/// temporary folder; nothing real is read or written.
@MainActor
final class SwitchPanelTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var home: URL!

    override func setUpWithError() throws {
        suite = "mcpock.tests.switch.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        home = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("mcpock-switch-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        ParsedFileCache.removeAll()
    }

    override func tearDown() {
        defaults.retireSuite(named: suite)
        try? FileManager.default.removeItem(at: home)
        ParsedFileCache.removeAll()
    }

    private func config(_ name: String, _ agent: String, off: Bool = false, reg: Bool = true) -> ServerConfig {
        var config = ServerConfig(id: "\(reg ? "reg" : "scan"):\(agent):global:\(name)", name: name,
                                  source: ServerSource(label: agent, path: "/x/\(agent)"), projectPath: nil,
                                  transport: .stdio, command: "run-\(name)", args: [], env: [:], url: nil, headers: [:])
        config.turnedOff = off
        return config
    }

    private func groups(_ configs: [ServerConfig]) -> [ServerGroup] {
        let snapshots = HealthMonitor.merged(configs, into: [], pausedNames: []).map { snapshot -> ServerSnapshot in
            var copy = snapshot
            if copy.state == .unknown { copy.state = .healthy }
            return copy
        }
        return HealthMonitor.groupByName(snapshots)
    }

    // MARK: Pure wording and sections

    func testOffEverywhereSitsInItsOwnSectionAndPartlyOffStaysPut() {
        let all = groups([
            config("linear", "Cursor", off: true),
            config("openrouter", "Code", off: true), config("openrouter", "Codex", off: true),
            config("stripe", "Cursor", off: true), config("stripe", "Claude Desktop"),
            config("figma", "Cursor"),
        ])
        let sections = PanelSections.build(groups: all, pinned: ["linear"], filter: .all, query: "")
        XCTAssertEqual(sections.map(\.kind), [.everythingElse, .turnedOff])
        XCTAssertEqual(sections[0].groups.map(\.name), ["figma", "stripe"])
        XCTAssertEqual(sections[1].groups.map(\.name), ["linear", "openrouter"], "off wins over a pin")
        XCTAssertEqual(sections[1].title, "Turned off")

        let stripe = all.first { $0.name == "stripe" }!
        XCTAssertEqual(stripe.state, .healthy)
        XCTAssertEqual(ShortReason.line(for: stripe), "Off in Cursor")
        XCTAssertFalse(PanelSections.needsYou(stripe))
        let many = groups([config("m", "Code", off: true), config("m", "Codex", off: true), config("m", "Cursor", off: true),
                           config("m", "Goose")])[0]
        XCTAssertEqual(ShortReason.line(for: many), "Off in 3 agents")
        XCTAssertNil(ShortReason.line(for: all.first { $0.name == "linear" }!))

        XCTAssertEqual(PanelText.compactSummary(all), "4 servers \u{00B7} 2 off")
        XCTAssertEqual(PanelText.summary(all), "4 servers \u{00B7} 2 turned off")
        XCTAssertEqual(PanelSections.build(groups: all, pinned: [], filter: .problems, query: "").count, 0)
    }

    func testAnOffDeclarationIsNeitherComparedNorAProblem() {
        var other = config("openrouter", "Cursor", off: true)
        other = ServerConfig(id: other.id, name: other.name, source: other.source, projectPath: nil, transport: .stdio,
                             command: "something-else", args: [], env: [:], url: nil, headers: [:])
        other.turnedOff = true
        let group = groups([config("openrouter", "Code"), config("openrouter", "Codex"), other])[0]
        XCTAssertFalse(group.isDiffering, "nothing starts the off one, so its setup is not compared")
        XCTAssertEqual(HealthMonitor.iconState([HealthMonitor.iconInput(group), .off]), .allHealthy)
        XCTAssertEqual(StatusSnapshot.statusWords(groups([config("a", "Cursor", off: true)])[0]), "turned off")
    }

    func testTheEverywhereSwitch() throws {
        let mixed = groups([config("s", "Code"), config("s", "Cursor", off: true), config("s", "VS Code")])[0]
        XCTAssertEqual(mixed.sources.map(\.canSwitch), [true, true, false])
        let on = try XCTUnwrap(CardText.everywhereSwitch(for: mixed))
        XCTAssertEqual(on.label, "All 2", "only the agents with a switch")
        XCTAssertEqual(on.actionTitle, "Turn off in all 2")
        XCTAssertFalse(on.turnOn, "on while any of them is on")
        let allOff = groups([config("s", "Code", off: true), config("s", "Cursor", off: true), config("s", "VS Code")])[0]
        XCTAssertEqual(CardText.everywhereSwitch(for: allOff)?.turnOn, true)
        XCTAssertEqual(CardText.everywhereSwitch(for: allOff)?.actionTitle, "Turn on in all 2")
        XCTAssertNil(CardText.everywhereSwitch(for: groups([config("s", "Cursor"), config("s", "VS Code")])[0]),
                     "one switch only: the row's own does it")
        XCTAssertEqual(CardText.switchLine(isOff: true, note: nil), "Turned off")
        XCTAssertEqual(CardText.switchLine(isOff: true, note: "Off after Cursor reopens"), "Off after Cursor reopens")
        XCTAssertNil(CardText.switchLine(isOff: false, note: nil))
    }

    func testAgentsTabCountsOffServersApart() {
        let sections = AgentSections.build(groups: groups([
            config("a", "Cursor", off: true), config("b", "Cursor"), config("c", "Codex", off: true),
        ]))
        let cursor = sections.first { $0.agent == "Cursor" }!
        XCTAssertEqual(cursor.offCount, 1)
        XCTAssertEqual(cursor.fineCount, 1)
        XCTAssertEqual(AgentSections.problemText(cursor), "", "the row's 1/2 says it (12 Nov)")
        XCTAssertEqual(RowCounts(tools: cursor.servers.count, hidden: cursor.offCount, unit: .servers).line, "1/2")
        XCTAssertEqual(cursor.servers.first { $0.name == "a" }?.note, "Off")
        let codex = sections.first { $0.agent == "Codex" }!
        XCTAssertEqual(AgentSections.problemText(codex), "")
        XCTAssertEqual(RowCounts(tools: codex.servers.count, hidden: codex.offCount, unit: .servers).line, "0/1")
        XCTAssertEqual(AgentSections.restText(codex), "Its only server is turned off")
        XCTAssertTrue(codex.problems.isEmpty)
    }

    // MARK: The flow, on files in a temporary folder

    private func path(_ rel: String) -> String { home.appendingPathComponent(rel).path }

    private func makeState() async throws -> PanelState {
        try FileManager.default.createDirectory(atPath: path(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: path(".cursor"), withIntermediateDirectories: true)
        try "[mcp_servers.openrouter]\ncommand = \"/usr/bin/true\"\n".write(toFile: path(".codex/config.toml"), atomically: true, encoding: .utf8)
        try #"{"mcpServers":{"openrouter":{"command":"/usr/bin/true"}}}"#.write(toFile: path(".cursor/mcp.json"), atomically: true, encoding: .utf8)
        let registry = [
            KnownAgent(label: "Codex", path: path(".codex/config.toml"), shape: .mcpServersTOML),
            KnownAgent(label: "Cursor", path: path(".cursor/mcp.json"), shape: .json),
        ]
        let monitor = HealthMonitor(defaults: defaults)
        let parked = home.appendingPathComponent("parked")
        monitor.discover = { ConfigDiscovery.discover(registry: registry, scanRoots: [], parkedDirectory: parked) }
        monitor.switchParked = parked
        monitor.probe = { _, _ in ProbeResult(state: .healthy, failureReason: nil, tools: []) }
        monitor.claudeSettingsPath = path(".claude/settings.json")
        monitor.switchBackups = home.appendingPathComponent("backups")
        await monitor.reloadConfigs()
        return PanelState(monitor: monitor, defaults: defaults)
    }

    /// 4b6a and 37f0 (11 Nov): a row says "2/3 tools" when tools are
    /// hidden: on the Servers tab those every agent that can hide tools
    /// hides, inside an agent that agent's own.
    func testRowsCountHiddenTools() async throws {
        let state = try await makeState()
        let monitor = state.monitor
        try "[mcp_servers.openrouter]\ncommand = \"/usr/bin/true\"\ndisabled_tools = [\"b\"]\n"
            .write(toFile: path(".codex/config.toml"), atomically: true, encoding: .utf8)
        ParsedFileCache.removeAll()
        monitor.probe = { _, _ in
            ProbeResult(state: .healthy, failureReason: nil,
                        tools: ["a", "b", "c"].map { MCPToolInfo(name: $0, description: "") })
        }
        await monitor.reloadConfigs()
        await monitor.refreshNow(force: true)
        await monitor.refreshHiddenTools()?.value
        let group = try XCTUnwrap(monitor.groups.first)
        let codex = Set(group.sources.filter { $0.agent == "Codex" }.map(\.configID))
        let cursor = Set(group.sources.filter { $0.agent == "Cursor" }.map(\.configID))
        XCTAssertEqual(monitor.hiddenToolCount(groupName: "openrouter"), 1, "Cursor can't hide tools: Codex decides")
        XCTAssertEqual(monitor.hiddenToolCount(groupName: "openrouter", configIDs: codex), 1)
        XCTAssertEqual(monitor.hiddenToolCount(groupName: "openrouter", configIDs: cursor), 0)
        XCTAssertEqual(RowCounts(tools: 3, hidden: monitor.hiddenToolCount(groupName: "openrouter"), calls: 130).line,
                       "2/3 \u{00B7} 130")

        monitor.switchesEnabled = false
        monitor.refreshHiddenTools()
        XCTAssertEqual(monitor.hiddenToolCount(groupName: "openrouter"), 0, "demo mode reads nothing")
    }

    func testFlippingASwitchOnlyOpensTheSheetAndEscapeClosesIt() async throws {
        let state = try await makeState()
        let group = try XCTUnwrap(state.monitor.groups.first)
        let cursor = try XCTUnwrap(group.sources.first { $0.agent == "Cursor" })
        let before = try String(contentsOfFile: path(".cursor/mcp.json"), encoding: .utf8)

        state.selectedName = "openrouter"
        state.askSwitch("openrouter", source: cursor, turnOn: false)
        XCTAssertEqual(state.pendingSwitch?.title, "Turn off openrouter in Cursor?")
        XCTAssertEqual(try String(contentsOfFile: path(".cursor/mcp.json"), encoding: .utf8), before, "nothing written yet")

        XCTAssertTrue(state.handleEscape())
        XCTAssertNil(state.pendingSwitch)
        XCTAssertEqual(try String(contentsOfFile: path(".cursor/mcp.json"), encoding: .utf8), before)
    }

    func testConfirmingWritesAndTheRowsFollow() async throws {
        let state = try await makeState()
        let monitor = state.monitor
        let outcome = await monitor.applySwitch(monitor.switchPlan(groupName: "openrouter", turnOn: false))
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.written.count, 2)
        XCTAssertEqual(monitor.groups.first?.state, .off)
        XCTAssertEqual(state.sections.map(\.kind), [.turnedOff])
        state.tab = .servers
        XCTAssertEqual(state.orderedNames, [], "the fold is closed: the arrow keys skip it")
        state.showsTurnedOff = true
        XCTAssertEqual(state.orderedNames, ["openrouter"])

        let on = monitor.switchPlan(groupName: "openrouter", turnOn: true)
        XCTAssertEqual(on.changes.count, 2)
        _ = await monitor.applySwitch(on)
        XCTAssertEqual(monitor.groups.first?.state, .healthy, "turned on: checked at once")
        XCTAssertEqual(monitor.groups.first?.offLabels, [])
    }

    /// fable-7 (review 10 Nov): turning a paused row on reads the configs
    /// again, so the card is not left saying "off" until Refresh.
    func testTurningAPausedRowOnReadsTheConfigsAgain() async throws {
        let state = try await makeState()
        let monitor = state.monitor
        _ = await monitor.applySwitch(monitor.switchPlan(groupName: "openrouter", turnOn: false))
        XCTAssertEqual(monitor.groups.first?.state, .off)
        monitor.setPaused(true, name: "openrouter")
        let outcome = await monitor.applySwitch(monitor.switchPlan(groupName: "openrouter", turnOn: true))
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.written.count, 2)
        XCTAssertNotEqual(monitor.groups.first?.state, .off)
        XCTAssertEqual(monitor.groups.first?.offLabels, [])
    }

    // MARK: Asks from agents (1.16)

    private func askCenter(now: Date = Date()) -> AskCenter {
        AskCenter(folder: home.appendingPathComponent("asks"), historyFile: home.appendingPathComponent("asks-answered.json"),
                  now: { now })
    }

    private func leaveAsk(_ action: AgentAsk.Action, server: String = "openrouter", tool: String? = nil,
                          asked: Date = Date()) throws -> AgentAsk {
        let ask = AgentAsk(id: UUID().uuidString, server: server, tool: tool, action: action, reason: "never used",
                           agent: "Claude Code", asked: asked)
        try AskBox.write(ask, to: home.appendingPathComponent("asks"))
        return ask
    }

    func testYesOpensTheUsualSheetAndOnlyTheConfirmWritesAndEndsTheAsk() async throws {
        let state = try await makeState()
        let asks = askCenter()
        state.asks = asks
        asks.start()
        defer { asks.stop() }
        var notified: [String] = []
        asks.onNew = { notified += $0.map(\.id) }
        let ask = try leaveAsk(.turnOff)
        asks.reload()
        XCTAssertEqual(asks.waiting.map(\.id), [ask.id])
        XCTAssertEqual(notified, [ask.id])
        asks.reload()
        XCTAssertEqual(notified, [ask.id], "one notification per ask")
        XCTAssertEqual(asks.asks(for: "OpenRouter").count, 1)
        let before = try String(contentsOfFile: path(".codex/config.toml"), encoding: .utf8)

        state.answerAsk(ask, yes: true)
        XCTAssertEqual(state.pendingSwitch?.changes.count, 2, "the usual sheet, every agent")
        XCTAssertEqual(state.pendingAsk?.id, ask.id)
        XCTAssertEqual(try String(contentsOfFile: path(".codex/config.toml"), encoding: .utf8), before, "nothing written by Yes")

        // Closing the sheet keeps the ask.
        state.cancelSwitch()
        XCTAssertNil(state.pendingAsk)
        XCTAssertEqual(asks.waiting.count, 1)

        state.answerAsk(ask, yes: true)
        state.confirmSwitch()
        for _ in 0..<100 where !asks.waiting.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(asks.waiting, [])
        XCTAssertEqual(asks.answered.first?.state, .done)
        XCTAssertTrue(try String(contentsOfFile: path(".codex/config.toml"), encoding: .utf8).contains("enabled = false"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("asks/\(ask.id).json").path))
        XCTAssertNil(state.monitor.statusSnapshot().asks, "no records source set in this test")
    }

    func testNoAndAnUnansweredDayChangeNothing() async throws {
        let state = try await makeState()
        let asks = askCenter()
        state.asks = asks
        let no = try leaveAsk(.turnOff)
        let old = try leaveAsk(.turnOff, server: "other", asked: Date().addingTimeInterval(-AgentAsk.lifetime - 60))
        var gone: [String] = []
        asks.onGone = { gone += $0 }
        asks.start()
        defer { asks.stop() }
        XCTAssertEqual(asks.waiting.map(\.id), [no.id])
        XCTAssertEqual(asks.answered.map(\.state), [.expired])
        state.answerAsk(no, yes: false)
        XCTAssertEqual(asks.answered.map(\.state), [.no, .expired])
        XCTAssertEqual(Set(gone), [no.id, old.id], "their notifications go")
        XCTAssertFalse(try String(contentsOfFile: path(".codex/config.toml"), encoding: .utf8).contains("enabled"))
        state.monitor.askRecords = { asks.records }
        XCTAssertEqual(state.monitor.statusSnapshot().asks?.map(\.state), [.no, .expired])

        // Kept across launches, and never notified again.
        let again = askCenter()
        var notified = 0
        again.onNew = { notified += $0.count }
        again.start()
        defer { again.stop() }
        XCTAssertEqual(again.answered.map(\.id), [no.id, old.id])
        XCTAssertEqual(notified, 0)
    }

    func testAskForWhatIsAlreadySoIsDoneWithoutASheet() async throws {
        let state = try await makeState()
        let asks = askCenter()
        state.asks = asks
        let ask = try leaveAsk(.turnOn)
        asks.start()
        defer { asks.stop() }
        state.answerAsk(ask, yes: true)
        XCTAssertNil(state.pendingSwitch)
        XCTAssertEqual(asks.answered.first?.state, .done)
    }

    func testDemoModeNeverPlansOrWrites() async throws {
        let state = try await makeState()
        state.monitor.switchesEnabled = false
        state.askSwitch("openrouter", turnOn: false)
        XCTAssertNil(state.pendingSwitch)
        let outcome = await state.monitor.applySwitch(state.monitor.switchPlan(groupName: "openrouter", turnOn: false))
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(outcome.written, [])
        XCTAssertFalse(try String(contentsOfFile: path(".codex/config.toml"), encoding: .utf8).contains("enabled"))
    }
}
