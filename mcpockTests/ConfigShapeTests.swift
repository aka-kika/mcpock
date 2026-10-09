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
}
