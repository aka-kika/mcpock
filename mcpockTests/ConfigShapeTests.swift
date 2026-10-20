import XCTest
@testable import mcpock

final class ConfigShapeTests: XCTestCase {
    func testJSONShapeParsesMcpServers() {
        let text = #"{"mcpServers":{"foo":{"command":"node","args":["s.js"]},"bar":{"url":"http://x/mcp"}}}"#
        let entries = JSONConfigShape.parse(text)
        XCTAssertNotNil(entries)
        let byName = Dictionary(uniqueKeysWithValues: entries!.map { ($0.name, $0) })
        XCTAssertEqual(byName["foo"]?.entry["command"] as? String, "node")
        XCTAssertEqual(byName["bar"]?.entry["url"] as? String, "http://x/mcp")
        XCTAssertNil(byName["foo"]?.projectPath)
    }

    func testJSONShapeParsesClaudeProjects() {
        let text = #"{"mcpServers":{"g":{"command":"g"}},"projects":{"/repo":{"mcpServers":{"p":{"command":"p"}}}}}"#
        let entries = JSONConfigShape.parse(text)!
        let p = entries.first { $0.name == "p" }
        XCTAssertEqual(p?.projectPath, "/repo")
    }

    func testJSONShapeRejectsNonMCPJSON() {
        XCTAssertNil(JSONConfigShape.parse(#"{"theme":"dark","keep_awake":true}"#))
        XCTAssertNil(JSONConfigShape.parse("not json at all"))
        XCTAssertNil(JSONConfigShape.parse(#"{"mcpServers":{}}"#), "empty mcpServers → not a source")
        XCTAssertNil(JSONConfigShape.parse(#"{"mcp":{"request_timeout":30}}"#), "an `mcp` settings block is not a server list")
        XCTAssertNil(JSONConfigShape.parse(#"{"servers":{"web":{"port":8080}}}"#), "servers without command/url are not MCP")
    }

    /// OpenCode: `{"mcp": {name: {type, command: [argv], environment}}}`.
    func testJSONShapeParsesOpenCode() {
        let text = #"{"$schema":"https://opencode.ai/config.json","mcp":{"cbm":{"enabled":true,"type":"local","command":["/usr/local/bin/cbm","--serve"],"environment":{"K":"v"}},"remote":{"type":"remote","url":"https://x/mcp"},"off":{"enabled":false,"type":"local","command":["nope"]}}}"#
        let entries = JSONConfigShape.parse(text)!
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertEqual(byName["cbm"]?.entry["command"] as? String, "/usr/local/bin/cbm", "argv[0] becomes the command")
        XCTAssertEqual(byName["cbm"]?.entry["args"] as? [String], ["--serve"])
        XCTAssertEqual((byName["cbm"]?.entry["env"] as? [String: String])?["K"], "v", "`environment` becomes `env`")
        XCTAssertEqual(byName["remote"]?.entry["url"] as? String, "https://x/mcp")
        XCTAssertNil(byName["off"], "enabled: false is dropped, as in the TOML/YAML readers")

        let configs = ConfigDiscovery.configs(from: entries, source: ServerSource(label: "OpenCode"), idPrefix: "oc")
        XCTAssertEqual(configs.first { $0.name == "cbm" }?.commandLine, "/usr/local/bin/cbm --serve")
        XCTAssertEqual(configs.first { $0.name == "remote" }?.transport, .http)
    }

    /// VS Code: `{"servers": {...}}` in mcp.json and `{"mcp": {"servers": {...}}}` in settings.json.
    func testJSONShapeParsesVSCodeServers() {
        let mcpJSON = JSONConfigShape.parse(#"{"servers":{"fs":{"type":"stdio","command":"npx","args":["-y","fs"]}}}"#)
        XCTAssertEqual(mcpJSON?.first?.name, "fs")
        XCTAssertEqual(mcpJSON?.first?.entry["command"] as? String, "npx")

        let settings = JSONConfigShape.parse(#"{"editor.fontSize":13,"mcp":{"servers":{"gh":{"url":"https://api.example/mcp"}}}}"#)
        XCTAssertEqual(settings?.first?.name, "gh")
        XCTAssertEqual(settings?.first?.entry["url"] as? String, "https://api.example/mcp")
    }

    func testJSONShapeDropsDisabledMcpServersEntries() {
        let entries = JSONConfigShape.parse(#"{"mcpServers":{"on":{"command":"a","enabled":true},"off":{"command":"b","enabled":false}}}"#)!
        XCTAssertEqual(entries.map(\.name), ["on"])
    }

    func testConfigsBuilderProducesServerConfigs() {
        let entries = JSONConfigShape.parse(#"{"mcpServers":{"foo":{"command":"node"}}}"#)!
        let configs = ConfigDiscovery.configs(from: entries, source: .cursor, idPrefix: "cursor")
        XCTAssertEqual(configs.first?.name, "foo")
        XCTAssertEqual(configs.first?.transport, .stdio)
        XCTAssertEqual(configs.first?.source.label, "Cursor")
    }

    func testConfigsBuilderDisambiguatesGlobalFromProjectNamedGlobal() {
        let entries = [
            DiscoveredEntry(name: "foo", entry: ["command": "node"], projectPath: nil),
            DiscoveredEntry(name: "foo", entry: ["command": "node"], projectPath: "global"),
        ]
        let configs = ConfigDiscovery.configs(from: entries, source: .cursor, idPrefix: "cursor")
        XCTAssertEqual(configs.count, 2)
        XCTAssertNotEqual(configs[0].id, configs[1].id,
                          "a project literally named 'global' must not collide with the global bucket")
    }

    func testGrokShapeEntries() {
        let toml = """
        [mcp_servers.foo]
        command = "node"
        args = ["s.js"]
        """
        let entries = MCPServersTOML.shapeEntries(toml)
        XCTAssertEqual(entries?.first?.name, "foo")
        XCTAssertEqual(entries?.first?.entry["command"] as? String, "node")
        XCTAssertNil(MCPServersTOML.shapeEntries(#"{"mcpServers":{}}"#), "JSON is not the TOML shape")
    }

    func testMCPServersYAMLShapeEntries() {
        let yaml = """
        mcp_servers:
          foo:
            command: node
            args:
              - s.js
        """
        let entries = MCPServersYAML.shapeEntries(yaml)
        XCTAssertEqual(entries?.first?.name, "foo")
        XCTAssertEqual(entries?.first?.entry["args"] as? [String], ["s.js"])
        XCTAssertNil(MCPServersYAML.shapeEntries("extensions:\n  foo:\n    cmd: x\n"), "Goose's block is not this shape")
        XCTAssertEqual(ConfigShape.all.map(\.id), ["json", "mcp-servers-toml", "goose-yaml", "mcp-servers-yaml"])
    }

    func testGooseShapeEntries() {
        let yaml = """
        extensions:
          foo:
            enabled: true
            type: stdio
            name: foo
            cmd: node
            args:
            - s.js
        """
        let entries = GooseConfig.shapeEntries(yaml)
        XCTAssertEqual(entries?.first?.name, "foo")
        XCTAssertNil(GooseConfig.shapeEntries("nothing here"), "no extensions: → nil")
    }

    /// Argon 2026-10-16 #15: `.jsonc` files (OpenCode, Zed, VS Code) have
    /// comments and trailing commas; they were found but never read.
    func testJSONCWithCommentsAndTrailingCommas() {
        let text = """
        {
          // OpenCode servers
          "mcp": {
            "docs": { "command": ["npx", "-y", "docs-mcp"], /* inline */ "url": "", },
            "web": { "url": "https://example.com/mcp//not-a-comment", },
          },
        }
        """
        let entries = JSONConfigShape.parse(text) ?? []
        XCTAssertEqual(Set(entries.map(\.name)), ["docs", "web"])
        XCTAssertEqual(entries.first { $0.name == "web" }?.entry["url"] as? String,
                       "https://example.com/mcp//not-a-comment", "// inside a string stays")
        XCTAssertEqual(entries.first { $0.name == "docs" }?.entry["args"] as? [String], ["-y", "docs-mcp"])
    }

    /// Argon 2026-10-17 #8: Cline, Roo Code and Windsurf switch a server off
    /// with `"disabled": true`; Claude Code with a project's `disabledMcpServers`.
    func testDisabledEntriesAreDropped() throws {
        let cline = #"{"mcpServers":{"on":{"command":"a"},"off":{"command":"b","disabled":true},"kept":{"command":"c","disabled":false}}}"#
        XCTAssertEqual(Set(try XCTUnwrap(JSONConfigShape.parse(cline)).map(\.name)), ["on", "kept"])

        let claude = #"{"mcpServers":{"vera":{"command":"v"}},"projects":{"/repo":{"mcpServers":{"local":{"command":"l"},"quiet":{"command":"q"}},"disabledMcpServers":["quiet","vera"]}}}"#
        let entries = try XCTUnwrap(JSONConfigShape.parse(claude))
        XCTAssertEqual(Set(entries.map(\.name)), ["vera", "local"],
                       "the project's own server is dropped; a global one it names stays for other projects")
    }

    func testClaudeProjectApprovalByFolder() {
        let text = #"{"projects":{"/repo/./app":{"disabledMcpjsonServers":["a"],"enabledMcpjsonServers":["b"],"hasTrustDialogAccepted":true},"/all":{"enableAllProjectMcpServers":true}}}"#
        let projects = ClaudeProjectApproval.projects(claudeJSON: text)
        let app = ClaudeProjectApproval.forFolder("/repo/app", projects: projects, userSettings: nil, readFile: { _ in nil })
        XCTAssertEqual(app.enabled, ["b"])
        XCTAssertEqual(app.disabled, ["a"])
        XCTAssertTrue(app.trusted)
        XCTAssertTrue(app.allows("b"))
        XCTAssertFalse(app.allows("a"))
        XCTAssertFalse(app.allows("c"), "not approved yet")
        let all = ClaudeProjectApproval.forFolder("/all", projects: projects, userSettings: nil, readFile: { _ in nil })
        XCTAssertTrue(all.allows("anything"))
        XCTAssertEqual(ClaudeProjectApproval.projects(claudeJSON: "nope"), [:])
    }

    /// Project settings count only in a trusted folder; a disabled name wins.
    func testClaudeProjectApprovalSettingsFiles() {
        let files = ["/p/.claude/settings.json": #"{"enableAllProjectMcpServers": true}"#,
                     "/p/.claude/settings.local.json": #"{"disabledMcpjsonServers": ["bad"]}"#]
        let untrusted = ClaudeProjectApproval.forFolder("/p", projects: [:], userSettings: nil, readFile: { files[$0] })
        XCTAssertFalse(untrusted.allows("x"), "a repo cannot approve itself")
        var trusted = ClaudeProjectApproval(); trusted.trusted = true
        let approval = ClaudeProjectApproval.forFolder("/p", projects: [ConfigScanner.canonicalPath("/p"): trusted],
                                                       userSettings: nil, readFile: { files[$0] })
        XCTAssertTrue(approval.allows("x"))
        XCTAssertFalse(approval.allows("bad"))
        let user = ClaudeProjectApproval.forFolder("/q", projects: [:], userSettings: ["enabledMcpjsonServers": ["u"]],
                                                   readFile: { _ in nil })
        XCTAssertTrue(user.allows("u"), "the user's own settings count everywhere")
    }
}
