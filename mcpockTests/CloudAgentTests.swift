import XCTest
@testable import mcpock

/// 1.12: Grok Bot (its servers run in xAI's cloud: listed, never started) and
/// Antigravity (`~/.gemini/config/mcp_config.json`, `serverUrl` for remote).
final class CloudAgentTests: XCTestCase {
    private func discover(_ agents: [KnownAgent]) -> [ServerConfig] {
        ConfigDiscovery.discover(registry: agents, scanRoots: [], folderExists: { _ in true })
    }

    private func tempFile(_ name: String, _ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-cloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A made-up Grok Bot settings file: the names become rows, marked as
    /// managed elsewhere, with no command to start.
    func testGrokBotListsItsBoxServersAndStartsNone() throws {
        let file = try tempFile("settings.json", """
            {"version": 3, "themePreference": "dark", "mcpBoxServers": ["linear", "github", "linear", " ", ""],
             "mcpDisabledToolsByServerId": {"123": ["delete_issue"]}, "localToolPermission": "ask"}
            """)
        let configs = discover([KnownAgent(label: AgentRegistry.grokBotLabel, path: file.path, shape: .grokBotSettings)])
        XCTAssertEqual(configs.map(\.name), ["github", "linear"], "deduped, blanks dropped")
        XCTAssertTrue(configs.allSatisfy { $0.builtin && $0.command == nil && $0.url == nil })
        XCTAssertTrue(configs.allSatisfy { $0.source.label == "Grok Bot" })
    }

    func testGrokBotWithAnEmptyListAddsNothing() throws {
        let file = try tempFile("settings.json", #"{"mcpBoxServers": [], "version": 3}"#)
        XCTAssertTrue(discover([KnownAgent(label: AgentRegistry.grokBotLabel, path: file.path, shape: .grokBotSettings)]).isEmpty)
        XCTAssertNil(GrokBotConfig.parse(Data("not json".utf8)))
        XCTAssertNil(GrokBotConfig.parse(Data(#"{"mcpBoxServers": "linear"}"#.utf8)))
    }

    func testAGrokBotServerIsNeverProbed() async {
        let config = ServerConfig(id: "reg:Grok Bot:global:linear", name: "linear",
                                  source: ServerSource(label: "Grok Bot", path: "/u/.grokbot/settings.json"),
                                  projectPath: nil, transport: .stdio, command: nil, args: [], env: [:],
                                  url: nil, headers: [:], builtin: true)
        let result = await HealthMonitor.probeServer(config: config, fetchTools: true)
        XCTAssertEqual(result.state, .selfManaged)
    }

    func testRowsSayWhereItRuns() {
        XCTAssertEqual(AgentRegistry.cloudHost(forAgents: ["Grok Bot"]), "xAI's cloud")
        XCTAssertNil(AgentRegistry.cloudHost(forAgents: ["Grok Bot", "Cursor"]), "one source on this Mac: not a cloud row")
        XCTAssertNil(AgentRegistry.cloudHost(forAgents: ["Grok"]), "the grok CLI runs here")
        XCTAssertEqual(CardText.cloudNote(agents: ["Grok Bot"], cloud: "xAI's cloud"),
                       "Runs in xAI's cloud for Grok Bot, not on this Mac, so mcpock lists it and doesn't check it.")
        XCTAssertEqual(AgentBadge.forLabel("Grok Bot").monogram, "GB")
    }

    /// Seen in the VM: Grok Bot read "All fine" and "All 2 servers answer
    /// normally", though mcpock checks none of them.
    func testAGrokBotAgentNeverReadsAllFine() {
        let rows = ["linear", "github"].map {
            ServerSnapshot(config: ServerConfig(id: "reg:Grok Bot:global:\($0)", name: $0,
                                                source: ServerSource(label: "Grok Bot", path: "/u/.grokbot/settings.json"),
                                                projectPath: nil, transport: .stdio, command: nil, args: [], env: [:],
                                                url: nil, headers: [:], builtin: true),
                           state: .selfManaged)
        }
        let section = AgentSections.build(groups: HealthMonitor.groupByName(rows)).first { $0.agent == "Grok Bot" }!
        XCTAssertEqual(AgentSections.problemText(section), "In xAI's cloud")
        XCTAssertEqual(AgentSections.restText(section), "All 2 servers run in xAI's cloud, so mcpock doesn't check them")
        XCTAssertEqual(section.servers.first?.note, "Runs in xAI's cloud")
    }

    func testTheSetupPromptSkipsGrokBot() {
        let lines = ConnectSnippets.agentLines(AgentRegistry.known, home: NSHomeDirectory())
        XCTAssertTrue(lines.contains("- Grok Bot: skip it; its servers run in xAI's cloud, not on this Mac"))
        XCTAssertFalse(lines.joined().contains(".grokbot"))
    }

    // MARK: - Antigravity

    func testAntigravityIsKnownAtItsDocumentedPath() {
        XCTAssertTrue(AgentRegistry.known.contains {
            $0.label == "Antigravity" && $0.path.hasSuffix("/.gemini/config/mcp_config.json")
        })
        XCTAssertTrue(AgentHost.all.contains { $0.id == "antigravity" && $0.file == ".gemini/config/mcp_config.json" })
        XCTAssertEqual(AgentBadge.forLabel("Antigravity").monogram, "Ag")
    }

    /// The docs' own example: a stdio server and a remote one under `serverUrl`.
    func testAntigravityConfigReadsServerUrl() throws {
        let file = try tempFile("mcp_config.json", """
            {"mcpServers": {
              "sqlite-explorer": {"command": "node", "args": ["/usr/local/bin/sqlite-mcp-server.js"],
                                  "env": {"SQLITE_DB_PATH": "/var/data/app.db"}},
              "my-remote-server": {"serverUrl": "https://api.example.com/mcp/",
                                   "headers": {"Authorization": "Bearer YOUR_API_TOKEN"}},
              "off-one": {"serverUrl": "https://example.com/mcp/", "disabled": true}
            }}
            """)
        let configs = discover([KnownAgent(label: "Antigravity", path: file.path, shape: .json)])
        XCTAssertEqual(configs.map(\.name), ["my-remote-server", "sqlite-explorer"], "a disabled server is left out")
        let remote = try XCTUnwrap(configs.first { $0.name == "my-remote-server" })
        XCTAssertEqual(remote.transport, .http)
        XCTAssertEqual(remote.url, "https://api.example.com/mcp/")
        XCTAssertEqual(remote.headers["Authorization"], "Bearer YOUR_API_TOKEN")
        XCTAssertEqual(configs.first { $0.name == "sqlite-explorer" }?.command, "node")
    }

    /// A file with only remote servers under `serverUrl` still counts as a config.
    func testAServerUrlOnlyFileIsAConfig() throws {
        let file = try tempFile("mcp_config.json", #"{"mcpServers": {"r": {"serverUrl": "https://x.example/mcp"}}}"#)
        XCTAssertEqual(discover([KnownAgent(label: "Windsurf", path: file.path, shape: .json)]).first?.url,
                       "https://x.example/mcp")
    }
}
