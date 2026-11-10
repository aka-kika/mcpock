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

    func testTheEverywhereButton() {
        let mixed = groups([config("s", "Code"), config("s", "Cursor", off: true), config("s", "VS Code")])[0]
        XCTAssertEqual(mixed.sources.map(\.canSwitch), [true, true, false])
        XCTAssertEqual(CardText.everywhereSwitch(for: mixed)?.title, "Turn off everywhere")
        let allOff = groups([config("s", "Code", off: true), config("s", "Cursor", off: true), config("s", "VS Code")])[0]
        XCTAssertEqual(CardText.everywhereSwitch(for: allOff)?.turnOn, true)
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
        XCTAssertEqual(AgentSections.problemText(cursor), "1 off")
        XCTAssertEqual(cursor.servers.first { $0.name == "a" }?.note, "Off")
        let codex = sections.first { $0.agent == "Codex" }!
        XCTAssertEqual(AgentSections.problemText(codex), "All off")
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
