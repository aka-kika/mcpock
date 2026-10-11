import XCTest
@testable import mcpock

/// 1.10.1: Tinycast keeps its MCP servers in its preferences plist, as JSON
/// bytes under `mcpServers`; secrets stay in Tinycast's own Keychain items.
final class TinycastConfigTests: XCTestCase {
    private func plist(enabled: Bool? = true, servers: [[String: Any]]) throws -> Data {
        var root: [String: Any] = [
            "mcpServers": try JSONSerialization.data(withJSONObject: servers),
            "otherSetting": "x",
        ]
        if let enabled { root["mcpEnabled"] = enabled }
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    private let stdio: [String: Any] = [
        "id": "1", "slug": "tinycast", "name": "Tinycast", "isEnabled": true, "trust": "always",
        "transport": ["stdio": ["command": "/usr/local/bin/tc", "arguments": ["mcp", "serve"], "environmentKeys": []]],
    ]

    func testStdioServerWithoutSecretsIsChecked() throws {
        let entries = try XCTUnwrap(TinycastConfig.parse(plist(servers: [stdio])))
        XCTAssertEqual(entries.count, 1)
        let e = entries[0]
        XCTAssertEqual(e.name, "Tinycast")
        XCTAssertEqual(e.entry["command"] as? String, "/usr/local/bin/tc")
        XCTAssertEqual(e.entry["args"] as? [String], ["mcp", "serve"])
        XCTAssertNil(e.entry["builtin"], "no secret: mcpock starts it like any other")
    }

    func testSecretsHeldByTinycastShowAsManagedByItsApp() throws {
        var withEnv = stdio
        withEnv["name"] = "github"
        withEnv["transport"] = ["stdio": ["command": "npx", "arguments": ["gh-mcp"], "environmentKeys": ["GITHUB_TOKEN"]]]
        let http: [String: Any] = ["name": "linear", "isEnabled": true,
                                   "transport": ["http": ["url": "https://mcp.linear.app/mcp", "headerName": "Authorization"]]]
        let oauth: [String: Any] = ["name": "notion", "isEnabled": true, "oauth": true,
                                    "transport": ["http": ["url": "https://mcp.notion.com/mcp"]]]
        let open: [String: Any] = ["name": "docs", "isEnabled": true,
                                   "transport": ["http": ["url": "https://example.com/mcp"]]]
        let entries = try XCTUnwrap(TinycastConfig.parse(plist(servers: [withEnv, http, oauth, open])))
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.entry) })
        XCTAssertEqual(byName["github"]?["builtin"] as? Bool, true)
        XCTAssertEqual(byName["linear"]?["builtin"] as? Bool, true)
        XCTAssertEqual(byName["notion"]?["builtin"] as? Bool, true)
        XCTAssertNil(byName["docs"]?["builtin"])
        XCTAssertEqual(byName["docs"]?["type"] as? String, "http")
        XCTAssertEqual(byName["docs"]?["url"] as? String, "https://example.com/mcp")
    }

    func testDisabledServersAndSwitchedOffMCPAreSkipped() throws {
        var off = stdio
        off["isEnabled"] = false
        XCTAssertNil(TinycastConfig.parse(try plist(servers: [off])), "only a disabled server: no source")
        XCTAssertNil(TinycastConfig.parse(try plist(enabled: false, servers: [stdio])), "MCP off in Tinycast")
        XCTAssertNotNil(TinycastConfig.parse(try plist(enabled: nil, servers: [stdio])), "no switch saved yet: on")
    }

    func testGarbageIsNotASource() {
        XCTAssertNil(TinycastConfig.parse(Data("not a plist".utf8)))
        XCTAssertNil(TinycastConfig.parse(Data()))
    }

    /// The registry reads the plist bytes (the text path would fail on a binary
    /// plist) and labels the servers "Tinycast".
    func testDiscoveryReadsTheBinaryPlist() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcpock-tinycast-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("com.tinycast.app.plist")
        try plist(servers: [stdio]).write(to: file)
        let registry = [KnownAgent(label: "Tinycast", path: file.path, shape: .tinycastDefaults)]
        let configs = ConfigDiscovery.discover(registry: registry, scanRoots: [])
        let tc = try XCTUnwrap(configs.first)
        XCTAssertEqual(tc.source.label, "Tinycast")
        XCTAssertEqual(tc.command, "/usr/local/bin/tc")
        XCTAssertEqual(tc.transport, .stdio)
        XCTAssertFalse(tc.builtin)
        XCTAssertEqual(AgentBadge.forLabel("Tinycast").monogram, "Tc")
    }

    func testTinycastIsKnownButNeverScanned() {
        XCTAssertTrue(AgentRegistry.known.contains {
            $0.label == "Tinycast" && $0.path.hasSuffix("/Library/Preferences/com.tinycast.app.plist") && $0.shape.isAppSettings
        })
        XCTAssertFalse(ConfigShape.all.contains { $0.isAppSettings })
    }

    /// The Claude setup prompt must never ask an agent to edit a preferences plist.
    func testSetupPromptSendsTinycastToItsOwnSettings() {
        let lines = ConnectSnippets.agentLines(AgentRegistry.known, home: NSHomeDirectory())
        XCTAssertTrue(lines.contains("- Tinycast: no file; add mcpock in its own MCP settings"))
        XCTAssertFalse(lines.joined().contains("com.tinycast.app.plist"))
    }
}
