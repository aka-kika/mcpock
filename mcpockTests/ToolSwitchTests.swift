import XCTest
@testable import mcpock

/// Hiding single tools (Part 2, 2026-11-10), one agent at a time, on text
/// shaped like the real files. Never a real config.
final class ToolSwitchTests: XCTestCase {
    private let tools = ["search_code", "get_file_contents", "create_issue", "delete_repository"]

    private func edit(_ text: String?, _ mechanism: ToolMechanism, server: String = "github",
                      hide: Set<String> = [], show: Set<String> = []) throws -> String {
        try ToolSwitch.edited(text, mechanism: mechanism, server: server, hide: hide, show: show, allTools: tools)
    }

    private func hidden(_ text: String?, _ mechanism: ToolMechanism, server: String = "github") -> Set<String>? {
        ToolSwitch.hidden(in: text, mechanism: mechanism, server: server, allTools: tools)
    }

    // MARK: Which agents

    func testMechanisms() {
        XCTAssertEqual(ToolSwitch.mechanism(agent: AgentRegistry.claudeCodeLabel, configID: "scan:x", builtin: false), .claudeDeny)
        XCTAssertEqual(ToolSwitch.mechanism(agent: "Codex", configID: "reg:codex", builtin: false), .codex)
        XCTAssertEqual(ToolSwitch.mechanism(agent: "Grok", configID: "reg:grok", builtin: false), .grok)
        XCTAssertEqual(ToolSwitch.mechanism(agent: "Hermes", configID: "reg:hermes", builtin: false), .hermes)
        XCTAssertEqual(ToolSwitch.mechanism(agent: "Goose", configID: "reg:goose", builtin: false), .goose)
        XCTAssertEqual(ToolSwitch.mechanism(agent: "OpenCode", configID: "reg:oc", builtin: false), .openCode)
        XCTAssertNil(ToolSwitch.mechanism(agent: "Cursor", configID: "reg:cursor", builtin: false), "Cursor has no setting for it")
        XCTAssertNil(ToolSwitch.mechanism(agent: "Claude Desktop", configID: "reg:cd", builtin: false))
        XCTAssertNil(ToolSwitch.mechanism(agent: "Codex", configID: "scan:x", builtin: false), "only the agent's own file")
        XCTAssertNil(ToolSwitch.mechanism(agent: "Codex", configID: "reg:codex", builtin: true))
    }

    func testNamesTheWayClaudeCodeAndOpenCodeWriteThem() {
        XCTAssertEqual(ToolSwitch.claudeRule(server: "my.server", tool: "get file"), "mcp__my_server__get_file")
        XCTAssertEqual(ToolSwitch.openCodeAction(server: "chrome-devtools", tool: "click"), "chrome-devtools_click")
    }

    // MARK: Claude Code

    private let claudeSettings = """
    {
      "permissions": {
        "allow": [
          "Bash(git status)"
        ],
        "deny": [
          "mcp__telegram__send"
        ]
      },
      "theme": "dark"
    }

    """

    func testClaudeCodeHideAddsADenyRuleAndShowTakesOnlyItOut() throws {
        let off = try edit(claudeSettings, .claudeDeny, hide: ["delete_repository"])
        XCTAssertEqual(off, """
        {
          "permissions": {
            "allow": [
              "Bash(git status)"
            ],
            "deny": [
              "mcp__telegram__send",
              "mcp__github__delete_repository"
            ]
          },
          "theme": "dark"
        }

        """)
        XCTAssertEqual(hidden(off, .claudeDeny), ["delete_repository"])
        XCTAssertEqual(try edit(off, .claudeDeny, show: ["delete_repository"]), claudeSettings)
    }

    func testClaudeCodeMakesTheListWhenThereIsNone() throws {
        let off = try edit("{\n  \"theme\": \"dark\"\n}\n", .claudeDeny, hide: ["create_issue"])
        let root = try XCTUnwrap(ServerSwitch.jsonObject(off) as? [String: Any])
        XCTAssertEqual((root["permissions"] as? [String: Any])?["deny"] as? [String], ["mcp__github__create_issue"])
        XCTAssertEqual(root["theme"] as? String, "dark")
        XCTAssertEqual(try edit(off, .claudeDeny, show: ["create_issue"]), "{\n  \"theme\": \"dark\"\n}\n",
                       "shown again: the empty list and permissions go")
        let made = try edit(nil, .claudeDeny, hide: ["create_issue"])
        XCTAssertEqual(hidden(made, .claudeDeny), ["create_issue"], "no settings file yet: one is made")
    }

    func testClaudeCodeHidingTwiceChangesNothing() throws {
        let off = try edit(claudeSettings, .claudeDeny, hide: ["create_issue"])
        XCTAssertEqual(try edit(off, .claudeDeny, hide: ["create_issue"]), off)
    }

    // MARK: Codex

    private let codexConfig = """
    model = "gpt-5"

    [mcp_servers.github]
    command = "npx"
    args = [
      "-y",
      "github-mcp",
    ]

    [mcp_servers.other]
    command = "other"

    """

    func testCodexWritesDisabledToolsInTheServersTable() throws {
        let off = try edit(codexConfig, .codex, hide: ["delete_repository", "create_issue"])
        XCTAssertTrue(off.contains("]\ndisabled_tools = [\"create_issue\", \"delete_repository\"]\n\n[mcp_servers.other]"), off)
        XCTAssertEqual(hidden(off, .codex), ["create_issue", "delete_repository"])
        let one = try edit(off, .codex, show: ["create_issue"])
        XCTAssertTrue(one.contains("disabled_tools = [\"delete_repository\"]"))
        XCTAssertEqual(try edit(one, .codex, show: ["delete_repository"]), codexConfig, "the last one shown: the line goes")
    }

    func testCodexLeavesAListOnSeveralLinesAlone() {
        let text = "[mcp_servers.github]\ncommand = \"x\"\ndisabled_tools = [\n  \"a\",\n]\n"
        XCTAssertThrowsError(try edit(text, .codex, hide: ["create_issue"]))
    }

    /// fable-4 (review 10 Nov): `[mcp_servers.x.env]` and `.http_headers`
    /// sub-tables are other keys; the list goes in the server's own table.
    func testCodexServerWithEnvAndHeadersSubTables() throws {
        let text = "[mcp_servers.github]\ncommand = \"x\"\n\n[mcp_servers.github.env]\nTOKEN = \"t\"\n\n[mcp_servers.github.http_headers]\nA = \"b\"\n"
        let off = try edit(text, .codex, hide: ["create_issue"])
        XCTAssertEqual(off, "[mcp_servers.github]\ncommand = \"x\"\ndisabled_tools = [\"create_issue\"]\n\n[mcp_servers.github.env]\nTOKEN = \"t\"\n\n[mcp_servers.github.http_headers]\nA = \"b\"\n")
        XCTAssertEqual(hidden(off, .codex), ["create_issue"])
        XCTAssertEqual(try edit(off, .codex, show: ["create_issue"]), text)
    }

    func testCodexListWrittenAsItsOwnTableIsNotGuessed() {
        let text = "[mcp_servers.github]\ncommand = \"x\"\n\n[mcp_servers.github.disabled_tools]\na = 1\n"
        XCTAssertThrowsError(try edit(text, .codex, hide: ["create_issue"]))
    }

    func testCodexServerWithNoTableIsNotGuessed() {
        XCTAssertThrowsError(try edit("[mcp_servers]\ngithub = { command = \"x\" }\n", .codex, hide: ["create_issue"]))
    }

    // MARK: Grok

    private let grokConfig = """
    model = "grok-5"

    [mcp_servers.github]
    command = "npx"

    [disabled_mcp_tools]
    __managed_gateway_connectors = ["gmail"]

    """

    func testGrokAddsTheServerToItsTableAndKeepsTheAppsOwnKey() throws {
        let off = try edit(grokConfig, .grok, hide: ["delete_repository"])
        XCTAssertTrue(off.contains("__managed_gateway_connectors = [\"gmail\"]\ngithub = [\"delete_repository\"]\n"), off)
        XCTAssertEqual(hidden(off, .grok), ["delete_repository"])
        XCTAssertEqual(try edit(off, .grok, show: ["delete_repository"]), grokConfig)
    }

    func testGrokMakesTheTableAtTheEnd() throws {
        let text = "[mcp_servers.github]\ncommand = \"npx\"\n"
        let off = try edit(text, .grok, hide: ["create_issue"])
        XCTAssertEqual(off, "[mcp_servers.github]\ncommand = \"npx\"\n\n[disabled_mcp_tools]\ngithub = [\"create_issue\"]\n")
    }

    func testGrokDottedFormIsNotGuessed() {
        XCTAssertThrowsError(try edit("[disabled_mcp_tools.github]\nx = 1\n", .grok, hide: ["create_issue"]))
    }

    // MARK: Hermes

    private let hermesConfig = """
    model: hermes-4
    mcp_servers:
      github:
        command: npx
        args:
          - github-mcp
      other:
        command: other

    """

    func testHermesAddsAnExcludeList() throws {
        let off = try edit(hermesConfig, .hermes, hide: ["create_issue"])
        XCTAssertEqual(off, """
        model: hermes-4
        mcp_servers:
          github:
            tools:
              exclude: [create_issue]
            command: npx
            args:
              - github-mcp
          other:
            command: other

        """)
        XCTAssertEqual(hidden(off, .hermes), ["create_issue"])
        let more = try edit(off, .hermes, hide: ["delete_repository"])
        XCTAssertTrue(more.contains("      exclude: [create_issue, delete_repository]\n"), more)
        let none = try edit(more, .hermes, show: ["create_issue", "delete_repository"])
        XCTAssertEqual(none, hermesConfig, "all shown: the lines mcpock added go again")
    }

    func testHermesWithAnIncludeListIsLeftAlone() {
        let text = hermesConfig.replacingOccurrences(of: "    command: npx\n", with: "    command: npx\n    tools:\n      include: [search_code]\n")
        XCTAssertEqual(hidden(text, .hermes), ["get_file_contents", "create_issue", "delete_repository"])
        XCTAssertThrowsError(try edit(text, .hermes, hide: ["search_code"]))
    }

    // MARK: Goose

    private let gooseConfig = """
    extensions:
      github:
        enabled: true
        name: github
        type: stdio
        available_tools: []
      other:
        enabled: true
        available_tools: []

    """

    func testGooseWritesTheToolsItMayStillUse() throws {
        let off = try edit(gooseConfig, .goose, hide: ["delete_repository"])
        XCTAssertTrue(off.contains("    available_tools: [search_code, get_file_contents, create_issue]\n  other:"), off)
        XCTAssertEqual(hidden(off, .goose), ["delete_repository"])
        XCTAssertEqual(try edit(off, .goose, show: ["delete_repository"]), gooseConfig, "all shown again: back to [] (all)")
    }

    func testGooseCantHideWithoutTheServersList() {
        XCTAssertThrowsError(try ToolSwitch.edited(gooseConfig, mechanism: .goose, server: "github",
                                                   hide: ["x"], show: [], allTools: []))
    }

    // MARK: OpenCode

    private let openCodeConfig = """
    {
      "$schema": "https://opencode.ai/config.json",
      "mcp": {
        "github": { "type": "local", "command": ["npx", "github-mcp"] }
      }
    }

    """

    func testOpenCodeAddsADenyRuleAndShowTakesItOut() throws {
        let off = try edit(openCodeConfig, .openCode, hide: ["create_issue"])
        let root = try XCTUnwrap(ServerSwitch.jsonObject(off) as? [String: Any])
        let rules = try XCTUnwrap(root["permissions"] as? [[String: String]])
        XCTAssertEqual(rules, [["action": "github_create_issue", "resource": "*", "effect": "deny"]])
        XCTAssertEqual(hidden(off, .openCode), ["create_issue"])
        let on = try edit(off, .openCode, show: ["create_issue"])
        XCTAssertEqual(on, openCodeConfig, "the empty list goes too")
    }

    func testOpenCodeKeepsOtherRulesInOrder() throws {
        let text = """
        {
          "permissions": [
            { "action": "shell", "resource": "*", "effect": "ask" }
          ]
        }
        """
        let off = try edit(text, .openCode, hide: ["create_issue"])
        let rules = try XCTUnwrap((ServerSwitch.jsonObject(off) as? [String: Any])?["permissions"] as? [[String: String]])
        XCTAssertEqual(rules.first?["action"], "shell")
        XCTAssertEqual(rules.last?["action"], "github_create_issue", "last match wins, so it goes at the end")
        XCTAssertEqual(try edit(off, .openCode, show: ["create_issue"]), text)
    }
}
