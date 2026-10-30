import XCTest
@testable import mcpock

/// 1.12.1 ("I don't see Grok Bot in agents in settings"): Grok Bot is listed
/// once installed, even with no servers, in the Agents tab and Settings.
final class ServerlessAgentTests: XCTestCase {
    private func grokBotRow(_ name: String) -> ServerSnapshot {
        ServerSnapshot(config: ServerConfig(id: "reg:Grok Bot:global:\(name)", name: name,
                                            source: ServerSource(label: "Grok Bot", path: "/u/.grokbot/settings.json"),
                                            projectPath: nil, transport: .stdio, command: nil, args: [], env: [:],
                                            url: nil, headers: [:], builtin: true),
                       state: .selfManaged)
    }

    private func cursorRow(_ name: String) -> ServerSnapshot {
        ServerSnapshot(config: ServerConfig(id: "reg:Cursor:global:\(name)", name: name,
                                            source: ServerSource(label: "Cursor", path: "/u/.cursor/mcp.json"),
                                            projectPath: nil, transport: .stdio, command: "npx", args: [], env: [:],
                                            url: nil, headers: [:]),
                       state: .healthy)
    }

    func testInstalledMeansItsAppOrItsFolder() {
        let markers = ["Grok Bot": ["/Applications/Grok Bot.app", "/u/.grokbot"]]
        XCTAssertEqual(AgentRegistry.installedEmptyAgents(markers: markers, exists: { $0 == "/u/.grokbot" }), ["Grok Bot"])
        XCTAssertEqual(AgentRegistry.installedEmptyAgents(markers: markers, exists: { $0.hasSuffix(".app") }), ["Grok Bot"])
        XCTAssertEqual(AgentRegistry.installedEmptyAgents(markers: markers, exists: { _ in false }), [])
        XCTAssertNotNil(AgentRegistry.installMarkers["Grok Bot"])
    }

    func testTheAgentsTabListsItWithNoServers() {
        let sections = AgentSections.build(groups: HealthMonitor.groupByName([cursorRow("docs")]),
                                           emptyAgents: ["Grok Bot"])
        let grokBot = sections.first { $0.agent == "Grok Bot" }
        XCTAssertNotNil(grokBot)
        XCTAssertEqual(grokBot?.servers.count, 0)
        XCTAssertEqual(grokBot.map(AgentSections.problemText), "Not visible here")
        XCTAssertEqual(grokBot?.emptyLine, "Grok Bot's servers live in your xAI account and run in xAI's cloud.")
        XCTAssertEqual(AgentSections.compactSummary(sections), "2 agents, all fine")
    }

    func testWithServersItIsListedOnceAsUsual() {
        let sections = AgentSections.build(groups: HealthMonitor.groupByName([grokBotRow("linear")]),
                                           emptyAgents: ["Grok Bot"])
        XCTAssertEqual(sections.map(\.agent), ["Grok Bot"])
        XCTAssertNil(sections.first?.emptyLine)
        XCTAssertEqual(sections.first.map(AgentSections.problemText), "In xAI's cloud")
    }

    func testSearchStillFiltersIt() {
        XCTAssertTrue(AgentSections.build(groups: [], query: "cursor", emptyAgents: ["Grok Bot"]).isEmpty)
        XCTAssertEqual(AgentSections.build(groups: [], query: "grok", emptyAgents: ["Grok Bot"]).map(\.agent), ["Grok Bot"])
    }

    func testSettingsListsItWithNoServers() {
        let entries = SettingsAgentsPane.entries(from: HealthMonitor.groupByName([cursorRow("docs")]),
                                                 emptyAgents: ["Grok Bot"])
        XCTAssertEqual(entries.map(\.agent), ["Cursor", "Grok Bot"])
        XCTAssertEqual(entries.last?.serverCount, 0)
        XCTAssertEqual(entries.last?.paths, [])
        XCTAssertEqual(SettingsAgentsPane.countText(entries), "2 agents · 1 config file")
    }

    @MainActor
    func testAMonitorWithNoFinderListsNone() {
        let suite = "mcpock.tests.serverless.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let monitor = HealthMonitor(defaults: defaults, isUpdate: false)
        XCTAssertEqual(monitor.serverlessAgents, [])
    }

    // MARK: - aka asks for access (1.12.2)

    func testA401Or403FromAkaMeansNeedsAccessNotNoServers() {
        XCTAssertNil(AkaSource.answer(statusCode: 401, data: nil, bun: "bun"))
        XCTAssertNil(AkaSource.answer(statusCode: 403, data: Data("{}".utf8), bun: "bun"))
        XCTAssertEqual(AkaSource.answer(statusCode: 500, data: nil, bun: "bun")?.count, 0)
        XCTAssertEqual(AkaSource.answer(statusCode: nil, data: nil, bun: "bun")?.count, 0, "aka not running: no row")
        let json = Data(#"{"servers": [{"name": "md", "path": "mcp-md", "enabled": true}]}"#.utf8)
        XCTAssertEqual(AkaSource.answer(statusCode: 200, data: json, bun: "bun")?.map(\.name), ["md"])
    }

    func testAkaNeedingAccessIsListedCalmly() {
        let sections = AgentSections.build(groups: HealthMonitor.groupByName([cursorRow("docs")]),
                                           emptyAgents: [AkaSource.label])
        let aka = sections.first { $0.agent == "aka" }
        XCTAssertNotNil(aka)
        XCTAssertEqual(aka.map(AgentSections.problemText), "Needs access")
        XCTAssertEqual(aka?.problems.count, 0, "calm, not red")
        XCTAssertEqual(aka?.emptyLine, "aka asked for access before listing its servers, so mcpock can't show them yet.")
        XCTAssertEqual(sections.last?.agent, "aka", "still last")
        XCTAssertEqual(AgentSections.compactSummary(sections), "2 agents, all fine")
        let entries = SettingsAgentsPane.entries(from: [], emptyAgents: [AkaSource.label])
        XCTAssertEqual(entries.map(\.agent), ["aka"])
        XCTAssertEqual(AgentRegistry.emptyStatus(for: "aka"), "Needs access")
        XCTAssertEqual(AgentRegistry.emptyStatus(for: "Grok Bot"), "Not visible here")
    }
}
