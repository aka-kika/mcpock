import XCTest
@testable import mcpock

/// Settings > Connect's agent rows (1.10.7): whether each agent already has mcpock, read on a
/// temporary home folder, and the line to paste. Read-only: nothing is ever written.
final class AgentConnectTests: XCTestCase {
    private var home: URL!
    private let helper = "/Applications/mcpock.app/Contents/Helpers/mcpock-mcp"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ text: String, _ rel: String) throws {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func host(_ id: String) throws -> AgentHost { try XCTUnwrap(AgentHost.all.first { $0.id == id }) }

    func testStatusReadsEachFormat() throws {
        try write(#"{"mcpServers": {"other": {"command": "x"}}}"#, ".cursor/mcp.json")
        XCTAssertEqual(try host("cursor").status(home: home), .notConnected)
        try write("// mine\n{ \"mcpServers\": { \"mcpock\": { \"command\": \"x\" }, } }\n", ".cursor/mcp.json")
        XCTAssertEqual(try host("cursor").status(home: home), .connected, "comments and trailing commas read too")

        try write(#"{"mcp": {"mcpock": {"type": "local", "command": ["x"], "enabled": true}}}"#, ".config/opencode/opencode.json")
        XCTAssertEqual(try host("opencode").status(home: home), .connected)
        try write(#"{"mcpServers": {"mcpock": {"command": "x"}}, "projects": {}}"#, ".claude.json")
        XCTAssertEqual(try host("claude-code").status(home: home), .connected)

        try write("[models]\ndefault = \"x\"\n\n[mcp_servers.mcpock]\ncommand = \"x\"\n", ".grok/config.toml")
        XCTAssertEqual(try host("grok").status(home: home), .connected)
        try write("model: x\nmcp_servers:\n  wake:\n    command: /w\n", ".hermes/config.yaml")
        XCTAssertEqual(try host("hermes").status(home: home), .notConnected)
        try write("extensions:\n  mcpock:\n    enabled: true\n    type: stdio\n    cmd: x\n", ".config/goose/config.yaml")
        XCTAssertEqual(try host("goose").status(home: home), .connected)

        XCTAssertEqual(try host("kimi-code").status(home: home), .notInstalled)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".kimi-code"), withIntermediateDirectories: true)
        XCTAssertEqual(try host("kimi-code").status(home: home), .notConnected, "the agent's folder is enough")
    }

    func testReadingNeverChangesAFile() throws {
        let text = "// mine\n{ \"mcpServers\": {} }\n"
        try write(text, ".cursor/mcp.json")
        _ = try host("cursor").status(home: home)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".cursor/mcp.json"), encoding: .utf8), text)
        let names = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".cursor").path)
        XCTAssertEqual(names, ["mcp.json"], "no copies, no new files")
    }

    /// Each line, pasted into an empty file, is read back by mcpock's own scan.
    func testEachLineIsWhatTheScanReads() throws {
        for agent in AgentHost.all {
            let line = agent.setup(helper: helper)
            switch agent.format {
            case .claudeCode:
                XCTAssertEqual(line, "claude mcp add --scope user mcpock -- \(helper)")
            case .json:
                let entries = try XCTUnwrap(JSONConfigShape.parse(line), agent.name)
                XCTAssertEqual(entries.first { $0.name == "mcpock" }?.entry["command"] as? String, helper, agent.name)
            case .toml:
                XCTAssertEqual(MCPServersTOML.servers(fromTOML: line)["mcpock"]?["command"] as? String, helper, agent.name)
            case .yaml(_, .goose):
                XCTAssertEqual(GooseConfig.servers(fromYAML: line)["mcpock"]?["command"] as? String, helper)
            case .yaml(_, .hermes):
                XCTAssertEqual(MCPServersYAML.servers(fromYAML: line)["mcpock"]?["command"] as? String, helper)
            }
            try write(line, agent.file)
            if !agent.format.isClaudeCode {
                XCTAssertEqual(agent.status(home: home), .connected, "\(agent.name): a pasted line reads connected")
            }
        }
    }

    func testOnlyAgentsWithoutARowKeepPlainCopyRows() {
        XCTAssertEqual(SettingsConnectPane.otherTargets.map(\.name), ["Cline", "aka", "Other agents"])
    }
}
