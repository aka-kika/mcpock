import XCTest
@testable import mcpock

/// Round 8 (review of round 7): Copy for Claude, copy-icon rows, one
/// config path menu with Open Config… last and no double-click, icon segments
/// in Settings > Servers, the Status section's texts.
@MainActor
final class Round8SettingsTests: XCTestCase {
    private let path = "/Applications/mcpock.app/Contents/Helpers/mcpock-mcp"
    private let home = "/Users/k"

    private var agents: [KnownAgent] {
        [
            KnownAgent(label: "Code", path: "/Users/k/.claude.json", shape: .json),
            KnownAgent(label: "Claude Desktop",
                       path: "/Users/k/Library/Application Support/Claude/claude_desktop_config.json", shape: .json),
            KnownAgent(label: "VS Code", path: "/Users/k/Library/Application Support/Code/User/mcp.json", shape: .json),
            KnownAgent(label: "Grok", path: "/Users/k/.grok/config.toml", shape: .mcpServersTOML),
            KnownAgent(label: "MiniMax", path: "/Users/k/.minimax/mcp.json", shape: .json),
            KnownAgent(label: "Goose", path: "/Users/k/.config/goose/config.yaml", shape: .gooseYAML),
            KnownAgent(label: "Hermes", path: "/Users/k/.hermes/config.yaml", shape: .mcpServersYAML),
            KnownAgent(label: "OpenCode", path: "/Users/k/.config/opencode/opencode.json", shape: .json),
        ]
    }

    // MARK: - Copy for Claude

    func testClaudePromptHasEveryStep() {
        let prompt = ConnectSnippets.claudeSetupPrompt(path: path, agents: agents, home: home)
        XCTAssertTrue(prompt.hasPrefix("Please connect mcpock to the AI agents on this Mac."))
        for step in ["Step 1. Find the agent configs", "Step 2. Back up before editing",
                     "Step 3. Add mcpock where it's missing", "Step 4. Check it works", "Step 5. Report"] {
            XCTAssertTrue(prompt.contains(step), step)
        }
        XCTAssertTrue(prompt.contains("- command: \(path)"))
        XCTAssertTrue(prompt.contains("mcpock never edits agent configs itself"))
        XCTAssertTrue(prompt.contains("claude mcp add --scope user mcpock -- \(path)"))
        XCTAssertTrue(prompt.contains("claude mcp get mcpock"))
        XCTAssertTrue(prompt.contains("call mcpock_status"))
        XCTAssertTrue(prompt.contains("Agent | Config path | Result (added / already there / skipped: why)"))
        XCTAssertTrue(prompt.contains("leave it as it is (\"already there\")"))
        XCTAssertFalse(prompt.contains("/Users/k/"), "paths are shown with ~")
    }

    func testClaudePromptListsTheRegistryAgentsWithTheirFormats() {
        let lines = ConnectSnippets.agentLines(agents, home: home)
        XCTAssertEqual(lines, [
            "- Claude Code: ~/.claude.json (don't edit it by hand; use the claude command in step 3)",
            "- Claude Desktop: ~/Library/Application Support/Claude/claude_desktop_config.json (JSON, \"mcpServers\")",
            "- VS Code: ~/Library/Application Support/Code/User/mcp.json (JSON, \"servers\")",
            "- Grok: ~/.grok/config.toml (TOML)",
            "- MiniMax: ~/.minimax/mcp.json (JSON, \"mcpServers\")",
            "- Goose: ~/.config/goose/config.yaml (YAML, Goose \"extensions\")",
            "- Hermes: ~/.hermes/config.yaml (YAML, \"mcp_servers\")",
            "- OpenCode: ~/.config/opencode/opencode.json (JSON, \"mcp\")",
            "- aka: no file; it keeps its servers in its own settings",
        ])
        // The real registry: every known file is in the default prompt.
        let real = ConnectSnippets.claudeSetupPrompt(path: path)
        for agent in AgentRegistry.known {
            XCTAssertTrue(real.contains(CardText.shortPath(agent.path)), agent.path)
        }
    }

    /// The per-format entries in step 3 are the same texts the rows copy.
    func testClaudePromptEntriesMatchTheSnippets() {
        let prompt = ConnectSnippets.claudeSetupPrompt(path: path, agents: agents, home: home)
        XCTAssertTrue(prompt.contains("\"mcpock\": { \"command\": \"\(path)\", \"args\": [] }"))
        XCTAssertTrue(prompt.contains("  [mcp_servers.mcpock]\n  command = \"\(path)\"\n  args = []"))
        XCTAssertTrue(prompt.contains("      cmd: \(path)\n"))
        XCTAssertTrue(prompt.contains("\"mcpock\": { \"type\": \"local\", \"command\": [\"\(path)\"], \"enabled\": true }"))
        // The helper test line runs the helper, quoted for zsh when it has a space.
        let spaced = ConnectSnippets.claudeSetupPrompt(path: "/Users/k/My Apps/mcpock.app/x", agents: agents, home: home)
        XCTAssertTrue(spaced.contains(#""method":"tools/list"}' | '/Users/k/My Apps/mcpock.app/x'"#))
    }

    func testCopyIconHelp() {
        let byName = Dictionary(uniqueKeysWithValues: ConnectSnippets.targets.map { ($0.name, $0) })
        XCTAssertEqual(ConnectSnippets.copyHelp(try XCTUnwrap(byName["Cursor"])), "Copy JSON for Cursor")
        XCTAssertEqual(ConnectSnippets.copyHelp(try XCTUnwrap(byName["Claude Code"])), "Copy Terminal command for Claude Code")
        XCTAssertEqual(ConnectSnippets.copyHelp(try XCTUnwrap(byName["Grok"])), "Copy TOML for Grok")
        XCTAssertEqual(ConnectSnippets.copyHelp(try XCTUnwrap(byName["Hermes"])), "Copy YAML for Hermes")
        XCTAssertEqual(ConnectSnippets.copyHelp(try XCTUnwrap(byName["aka"])), "Copy setup note for aka")
    }

    // MARK: - Config path menu

    func testConfigPathMenuTexts() {
        XCTAssertEqual([MenuText.showInFinderTitle, MenuText.copyPathTitle, MenuText.openConfigTitle],
                       ["Show in Finder", "Copy Path", "Open Config\u{2026}"])
        XCTAssertEqual(MenuText.openFileTitle, "Open File\u{2026}")
        XCTAssertEqual(MenuText.configPathHelp(path: "/a/b.json"), "/a/b.json\nRight-click for options")
        XCTAssertFalse(MenuText.configPathHelp(path: "/a").contains("double-click"))
        XCTAssertEqual(MenuText.openConfigQuestion(path: "/Users/k/.cursor/mcp.json"), "Open mcp.json?")
        XCTAssertTrue(MenuText.openConfigWarning.contains("mcpock itself only reads it"))
    }

    // MARK: - Servers pane

    func testShowAsIsThreeIcons() {
        XCTAssertEqual(ServerVisibility.allCases.map(\.systemImage), ["pin", "eye", "eye.slash"])
        XCTAssertEqual(ServerVisibility.allCases.map(\.title), ["Pinned", "Shown", "Hidden"])
        for symbol in ServerVisibility.allCases.map(\.systemImage) {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    // MARK: - General > Status

    func testStatusTexts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let text = SettingsGeneralPane.lastCheckText(now.addingTimeInterval(-180), now: now)
        XCTAssertTrue(text.hasPrefix("3 min ago, at "), text)
        let entries = [
            SettingsAgentEntry(agent: "Cursor", paths: ["/a/mcp.json"], serverCount: 3),
            SettingsAgentEntry(agent: "MiniMax", paths: ["/b/1.json", "/b/2.json"], serverCount: 1),
        ]
        XCTAssertEqual(SettingsAgentsPane.countText(entries), "2 agents · 3 config files")
        XCTAssertEqual(SettingsAgentsPane.countText([]), "0 agents · 0 config files")
        XCTAssertTrue(SettingsGeneralPane(theme: ThemeColors.resolve(.dark)).statusFilePath.hasSuffix("Library/Application Support/mcpock/status.json"))
    }
}
