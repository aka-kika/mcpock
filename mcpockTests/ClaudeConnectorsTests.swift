import XCTest
@testable import mcpock

/// The Claude account's connectors and the agents managed online (22 Nov,
/// Kika's picks). mcpock checks neither itself: it reads what Claude Code
/// lists, and links to the vendors' pages. The parsing is pure.
@MainActor
final class ClaudeConnectorsTests: XCTestCase {
    private let listing = """
        Checking MCP server health\u{2026}

        claude.ai Gmail: https://gmail.mcp.claude.com/mcp - \u{2714} Connected
        claude.ai Google Sheets: https://sheetsmcp.googleapis.com/mcp/v1 - \u{2714} Connected
        claude.ai Linear: https://mcp.linear.app/sse (SSE) - \u{2718} Failed to connect \u{2014} SSE error: ECONNREFUSED
        claude.ai Railway: https://mcp.railway.com/mcp - ! Needs authentication
        claude.ai Keyed: https://example.com/api/mcp/0123456789abcdef0123456789abcdef - \u{2714} Connected
        github: npx -y @modelcontextprotocol/server-github - \u{2714} Connected
        context7: https://mcp.context7.com/mcp (HTTP) - \u{2714} Connected
        plugin:design:figma: https://mcp.figma.com/mcp - ! Needs authentication
        """

    func testOnlyTheAccountsConnectorsAreListed() {
        let names = ClaudeConnectors.parse(listing).map(\.name)
        XCTAssertEqual(names, ["Gmail", "Google Sheets", "Linear", "Railway", "Keyed"],
                       "config servers and plugin servers are mcpock's own rows or nobody's")
    }

    func testStatesComeFromClaudeCodesWords() {
        let byName = Dictionary(uniqueKeysWithValues: ClaudeConnectors.parse(listing).map { ($0.name, $0.state) })
        XCTAssertEqual(byName["Gmail"], .connected)
        XCTAssertEqual(byName["Linear"], .failing)
        XCTAssertEqual(byName["Railway"], .needsSignIn)
    }

    /// A connector's URL can carry a key in its path: only the host is kept.
    func testOnlyTheHostIsKept() {
        let keyed = ClaudeConnectors.parse(listing).first { $0.name == "Keyed" }
        XCTAssertEqual(keyed?.host, "example.com")
        XCTAssertEqual(ClaudeConnectors.host(of: "https://user:secret@Host.Example.com:8443/a/b?token=1"), "host.example.com")
        XCTAssertEqual(ClaudeConnectors.host(of: "npx -y something"), "")
        XCTAssertEqual(ClaudeConnectors.host(of: "https://mcp.linear.app/sse (SSE)"), "mcp.linear.app")
        for connector in ClaudeConnectors.parse(listing) {
            XCTAssertFalse(connector.host.contains("/"), connector.name)
            XCTAssertFalse(connector.host.contains("0123456789abcdef"), connector.name)
        }
    }

    func testAStatusItDoesNotKnowIsUnknownNotFine() {
        XCTAssertEqual(ClaudeConnectors.state(of: "something new"), .unknown)
        XCTAssertEqual(ClaudeConnectors.state(of: ""), .unknown)
        XCTAssertEqual(ClaudeConnectors.parse("claude.ai Odd: https://odd.example.com/mcp").first?.state, .unknown)
    }

    func testNothingListedGivesNothing() {
        XCTAssertTrue(ClaudeConnectors.parse("").isEmpty)
        XCTAssertTrue(ClaudeConnectors.parse("Checking MCP server health\u{2026}\n\nNo MCP servers configured.").isEmpty)
        XCTAssertTrue(ClaudeConnectors.parse("claude.ai : https://x.example.com - Connected").isEmpty, "no name, no row")
    }

    func testAConnectorListedTwiceIsOneRow() {
        let twice = "claude.ai Gmail: https://a.example.com - \u{2714} Connected\nclaude.ai gmail: https://b.example.com - \u{2714} Connected"
        XCTAssertEqual(ClaudeConnectors.parse(twice).count, 1)
    }

    func testOffProjectsComeFromTheProjectsLists() {
        let json = """
            {"projects": {
              "/Users/me/code/shop": {"disabledMcpServers": ["claude.ai Gmail", "claude.ai Canva", "github"]},
              "/Users/me/code/blog": {"disabledMcpServers": ["claude.ai Gmail"]},
              "/Users/me/code/quiet": {"mcpServers": {}}
            }, "claudeAiMcpEverConnected": ["claude.ai Gmail"]}
            """
        let off = ClaudeConnectors.offProjects(claudeJSON: Data(json.utf8))
        XCTAssertEqual(off["gmail"], ["blog", "shop"])
        XCTAssertEqual(off["canva"], ["shop"])
        XCTAssertNil(off["github"], "only the account's connectors")
        XCTAssertTrue(ClaudeConnectors.offProjects(claudeJSON: Data("not json".utf8)).isEmpty)
    }

    func testTheWordSaysTheProblemFirstThenWhereItIsOff() {
        let off = ["gmail": ["blog", "shop"], "canva": ["shop"], "linear": ["shop"]]
        let merged = ClaudeConnectors.merged([
            ClaudeConnector(name: "Gmail", host: "", state: .connected),
            ClaudeConnector(name: "Canva", host: "", state: .connected),
            ClaudeConnector(name: "Linear", host: "", state: .failing),
            ClaudeConnector(name: "Zed", host: "", state: .connected),
            ClaudeConnector(name: "Railway", host: "", state: .needsSignIn),
        ], off: off)
        XCTAssertEqual(merged.map(\.name), ["Linear", "Railway", "Canva", "Gmail", "Zed"], "problems first, then by name")
        let word = Dictionary(uniqueKeysWithValues: merged.map { ($0.name, $0.word) })
        XCTAssertEqual(word["Linear"], "Not answering")
        XCTAssertEqual(word["Railway"], "Needs sign-in")
        XCTAssertEqual(word["Canva"], "Off in shop")
        XCTAssertEqual(word["Gmail"], "Off in 2 projects")
        XCTAssertEqual(word["Zed"], .some(nil))
        XCTAssertEqual(merged.first?.mark, .broken)
    }

    // MARK: - The panel only asks when she turned it on

    private func makePanel() -> (PanelState, UserDefaults) {
        let suite = "mcpock.tests.connectors.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let monitor = HealthMonitor(defaults: defaults)
        return (PanelState(monitor: monitor, defaults: defaults), defaults)
    }

    func testOffByDefaultAndNeverAsked() async {
        let (panel, _) = makePanel()
        var asked = 0
        panel.loadConnectors = { asked += 1; return .connectors([]) }
        panel.refreshConnectorsIfDue(force: true)
        await Task.yield()
        XCTAssertFalse(panel.includesConnectors)
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(panel.connectors.isEmpty)
        XCTAssertNil(panel.connectorsNote)
    }

    func testTurnedOnItAsksOnceAndNotAgainWhileFresh() async throws {
        let (panel, defaults) = makePanel()
        defaults.set(true, forKey: AppPreferences.includeConnectorsKey)
        var asked = 0
        panel.loadConnectors = {
            asked += 1
            return .connectors([ClaudeConnector(name: "Gmail", host: "gmail.mcp.claude.com", state: .connected)])
        }
        panel.refreshConnectorsIfDue()
        XCTAssertEqual(panel.connectorsNote, "Asking Claude Code\u{2026}")
        for _ in 0..<50 where panel.connectors.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(panel.connectors.map(\.name), ["Gmail"])
        XCTAssertNil(panel.connectorsNote)
        panel.refreshConnectorsIfDue()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(asked, 1, "a fresh list is not asked for again")
        panel.refreshConnectorsIfDue(force: true)
        for _ in 0..<50 where asked < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(asked, 2, "her Refresh asks again")
    }

    func testWhyThereIsNoListIsSaid() async throws {
        let (panel, defaults) = makePanel()
        defaults.set(true, forKey: AppPreferences.includeConnectorsKey)
        panel.loadConnectors = { .unavailable("Claude Code was not found on this Mac.") }
        panel.refreshConnectorsIfDue()
        for _ in 0..<50 where panel.connectorsNote == "Asking Claude Code\u{2026}" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(panel.connectorsNote, "Claude Code was not found on this Mac.")
        // Turned off again: the section is gone.
        defaults.set(false, forKey: AppPreferences.includeConnectorsKey)
        panel.refreshConnectorsIfDue()
        XCTAssertNil(panel.connectorsNote)
    }

    // MARK: - Managed online

    func testOnlyProductsWithAnAgentOnThisMacAreListed() {
        XCTAssertEqual(ManagedOnline.shown(localAgents: ["Cursor", "Code", "Codex"], enabled: true).map(\.id), ["chatgpt", "cursor"])
        XCTAssertEqual(ManagedOnline.shown(localAgents: ["Grok Bot", "Hermes \u{00B7} scribe"], enabled: true).map(\.id), ["grok"])
        XCTAssertEqual(ManagedOnline.shown(localAgents: ["gemini"], enabled: true).map(\.id), ["gemini"])
        XCTAssertTrue(ManagedOnline.shown(localAgents: ["Goose"], enabled: true).isEmpty)
        XCTAssertTrue(ManagedOnline.shown(localAgents: ["Cursor"], enabled: false).isEmpty, "turned off in Settings")
    }

    func testEveryManagedAgentHasARealWebAddress() {
        for agent in ManagedOnline.all {
            let url = URL(string: agent.url)
            XCTAssertEqual(url?.scheme, "https", agent.id)
            XCTAssertFalse(url?.host?.isEmpty ?? true, agent.id)
            XCTAssertFalse(agent.help.isEmpty, agent.id)
        }
        XCTAssertEqual(Set(ManagedOnline.all.map(\.id)).count, ManagedOnline.all.count)
    }

    func testTypedNamesAreTidied() {
        XCTAssertEqual(ManagedOnline.names("notion, canva ,  , Notion\nlinear"), ["notion", "canva", "linear"])
        XCTAssertTrue(ManagedOnline.names("  ").isEmpty)
    }

    func testTypedNamesAreSavedPerAgentAndBlanksDropped() {
        let (_, defaults) = makePanel()
        AppPreferences.saveManagedOnlineNames(["chatgpt": "notion, canva", "grok": "  "], to: defaults)
        XCTAssertEqual(AppPreferences.loadManagedOnlineNames(from: defaults), ["chatgpt": "notion, canva"])
        XCTAssertTrue(AppPreferences.loadShowManagedOnline(from: defaults), "on by default")
        XCTAssertFalse(AppPreferences.loadIncludeConnectors(from: defaults), "off by default")
    }

    func testTheDemoConnectorsShowEveryState() {
        XCTAssertEqual(DemoData.connectors.first?.name, "Linear", "the failing one first")
        XCTAssertEqual(DemoData.connectors.first { $0.name == "Canva" }?.word, "Off in shop")
        XCTAssertNil(DemoData.connectors.first { $0.name == "Gmail" }?.word)
    }
}
