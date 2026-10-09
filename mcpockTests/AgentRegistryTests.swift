import XCTest
@testable import mcpock

final class AgentRegistryTests: XCTestCase {
    func testRegistryCoversKnownAgentsWithAbsolutePaths() {
        let byLabel = Dictionary(AgentRegistry.known.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        for label in ["Code", "Claude Desktop", "Cursor", "Grok", "Goose", "Hermes", "Kimi Code", "OpenCode"] {
            XCTAssertNotNil(byLabel[label], "registry must include \(label)")
        }
        // 1.5.1: MiniMax loads only ~/.minimax/mcp.json; ~/.minimax/mcp/mcp.json is not its config.
        let minimax = AgentRegistry.known.filter { $0.label == "MiniMax" }
        XCTAssertEqual(minimax.map(\.path), [(NSHomeDirectory() as NSString).appendingPathComponent(".minimax/mcp.json")])
        XCTAssertFalse(AgentRegistry.known.contains { $0.path.hasSuffix("/.minimax/mcp/mcp.json") })
        for agent in AgentRegistry.known {
            XCTAssertTrue(agent.path.hasPrefix("/"), "paths must be absolute: \(agent.path)")
        }
        XCTAssertEqual(byLabel["Grok"]?.shape.id, "mcp-servers-toml")
        XCTAssertEqual(byLabel["Codex"]?.shape.id, "mcp-servers-toml")
        XCTAssertEqual(byLabel["Goose"]?.shape.id, "goose-yaml")
        XCTAssertEqual(byLabel["Hermes"]?.shape.id, "mcp-servers-yaml")
        XCTAssertEqual(byLabel["Cursor"]?.shape.id, "json")
        XCTAssertFalse(AgentRegistry.known.contains { $0.label == "Neve" || $0.path.contains("/neve/") },
                       "Neve is gone (round 5): a dead tool, removed from the registry")
    }
}
