import XCTest
@testable import mcpock

/// Round 5: what the right-click menus copy, in both tabs.
@MainActor
final class MenuTextTests: XCTestCase {
    private func group(_ state: HealthState, reason: String? = nil) -> ServerGroup {
        ServerGroup(
            name: "tinycast",
            state: state,
            sourceLabels: ["Code"],
            tools: [],
            issues: reason.map { [ServerIssue(label: "Code", reason: $0, command: "tinycast serve")] } ?? [],
            variantCount: 1
        )
    }

    func testCopyErrorIsTheSameReportAsTheCardAndCommandC() {
        let broken = group(.broken, reason: "Spawn error: Command not found: tinycast")
        XCTAssertEqual(MenuText.copyError(for: broken), broken.copyText)
        XCTAssertEqual(MenuText.copyError(for: broken), PanelState.copyText(for: broken))
        let slow = group(.degraded, reason: "Timed out after 10s")
        XCTAssertEqual(MenuText.copyError(for: slow), slow.copyText)
    }

    func testNoCopyErrorWithoutAnError() {
        for state in [HealthState.healthy, .unknown, .paused, .selfManaged] {
            XCTAssertNil(MenuText.copyError(for: group(state)), "\(state)")
        }
    }

    /// 1.5.3: exactly two copy items and Ask an Agent, as specified
    /// (title case in menus).
    func testServerMenuTitles() {
        XCTAssertEqual(MenuText.copyDetailsTitle, "Copy Details")
        XCTAssertEqual(MenuText.copyErrorsTitle, "Copy Errors")
        XCTAssertEqual(MenuText.askAgentTitle, "Ask an Agent")
        XCTAssertEqual(MenuText.markAsIntendedTitle, "Mark as Intended")
        XCTAssertEqual(MenuText.unmarkAsIntendedTitle, "Unmark as Intended")
    }

    func testConfigPaths() {
        XCTAssertEqual(MenuText.configPaths(["/Users/k/.hermes/config.yaml", "/Users/k/.hermes/profiles/scribe/config.yaml"]),
                       "/Users/k/.hermes/config.yaml\n/Users/k/.hermes/profiles/scribe/config.yaml")
        XCTAssertEqual(MenuText.configPaths(["/Users/k/.cursor/mcp.json"]), "/Users/k/.cursor/mcp.json")
        XCTAssertEqual(MenuText.copyPathsTitle(count: 1), "Copy Path")
        XCTAssertEqual(MenuText.copyPathsTitle(count: 2), "Copy Paths")
    }

    /// 2026-10-04 ("copy at once all the errors of an agent"): one block
    /// with every problem of that agent, its own errors only.
    func testAgentProblemsCopiesEveryProblemOfThatAgentOnly() throws {
        let board = ServerGroup(
            name: "the-board", state: .broken, sourceLabels: ["Code", "Grok"], tools: [],
            issues: [ServerIssue(label: "Code", reason: "No JSON in SSE stream", command: "http://myhost:4340/mcp"),
                     ServerIssue(label: "Grok", reason: "Grok's own error", command: "http://other")],
            variantCount: 2)
        let slow = ServerGroup(
            name: "postiz", state: .degraded, sourceLabels: ["Code (site)"], tools: [],
            issues: [ServerIssue(label: "Code (site)", reason: "Timed out after 10s", command: "postiz-mcp")],
            variantCount: 1)
        let section = AgentSection(agent: "Code", paths: ["/Users/k/.claude.json"], servers: [
            AgentServer(name: "the-board", state: .broken, note: "Protocol error", rank: 0),
            AgentServer(name: "postiz", state: .degraded, note: "Slow", rank: 1),
            AgentServer(name: "wigolo", state: .healthy, note: "Grok has a different setup", rank: 2),
            AgentServer(name: "fine", state: .healthy, note: nil, rank: nil),
        ])
        let text = try XCTUnwrap(MenuText.agentProblems(section, groups: ["the-board": board, "postiz": slow]))
        XCTAssertTrue(text.hasPrefix(ServerGroup.reportPreamble(plural: true)))
        XCTAssertTrue(text.contains("Config: /Users/k/.claude.json"))
        XCTAssertTrue(text.contains("- Code: No JSON in SSE stream\n  command: http://myhost:4340/mcp"))
        XCTAssertTrue(text.contains("- Code (site): Timed out after 10s"), "a project-scoped declaration is the agent's own")
        XCTAssertTrue(text.contains("MCP server: wigolo\nStatus: healthy\n- Grok has a different setup"))
        XCTAssertFalse(text.contains("Grok's own error"), "never another agent's error")
        XCTAssertFalse(text.contains("MCP server: fine"))
    }

    func testNoAgentProblemsWhenNothingNeedsYou() {
        let section = AgentSection(agent: "Code", paths: [], servers: [
            AgentServer(name: "fine", state: .healthy, note: nil, rank: nil),
        ])
        XCTAssertNil(MenuText.agentProblems(section, groups: [:]))
    }
}
