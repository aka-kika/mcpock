import XCTest
@testable import mcpock

/// Round 7: the `mcpock-mcp` helper. Its answers from a fixture status file,
/// the JSON-RPC handler, and one end-to-end run of the real bundled binary.
final class MCPStatusServerTests: XCTestCase {
    /// A small status file as the app writes it: one broken, one sign-in,
    /// one differs, one fine, one hidden broken.
    static let fixtureJSON = """
    {
      "appVersion" : "1.5.0",
      "checkEverySeconds" : 300,
      "checking" : false,
      "counts" : { "broken" : 2, "checking" : 0, "differs" : 1, "fine" : 1, "hidden" : 1, "needsSignIn" : 1,
                   "paused" : 0, "selfManaged" : 0, "slow" : 0, "total" : 5 },
      "firstCheckDone" : true,
      "generated" : "2027-01-15T08:00:00Z",
      "pid" : 4242,
      "schema" : 1,
      "summary" : "4 servers · 1 broken · 1 needs sign-in · 1 set up differently",
      "servers" : [
        { "agents" : ["Cursor", "Claude Code"], "configPaths" : ["/Users/k/.cursor/mcp.json", "/Users/k/.claude.json"],
          "hidden" : false, "lastChecked" : "2027-01-15T07:59:00Z", "name" : "firecrawl", "needsAttention" : true,
          "pinned" : false, "reason" : "Quit on start (exit 1)", "state" : "broken", "status" : "broken",
          "toolCount" : 0, "tools" : [], "transports" : ["stdio"],
          "sources" : [
            { "agent" : "Cursor", "configPath" : "/Users/k/.cursor/mcp.json", "differs" : false,
              "envNames" : ["FIRECRAWL_API_KEY"], "failure" : "Non-zero exit (1) — Invalid key ••••",
              "headerNames" : [], "state" : "broken", "target" : "npx -y firecrawl-mcp", "transport" : "stdio" },
            { "agent" : "Claude Code", "configPath" : "/Users/k/.claude.json", "differs" : false,
              "envNames" : [], "headerNames" : [], "state" : "healthy", "target" : "npx -y firecrawl-mcp", "transport" : "stdio" }
          ] },
        { "agents" : ["Claude Code"], "configPaths" : ["/Users/k/.claude.json"], "hidden" : false, "name" : "figma",
          "needsAttention" : true, "pinned" : false, "reason" : "Needs sign-in", "state" : "degraded",
          "status" : "needs sign-in", "toolCount" : 0, "tools" : [], "transports" : ["http"],
          "sources" : [
            { "agent" : "Claude Code", "configPath" : "/Users/k/.claude.json", "differs" : false, "envNames" : [],
              "failure" : "Needs authentication (HTTP 401)", "headerNames" : ["Authorization"], "state" : "degraded",
              "target" : "https://figma.example.com/mcp", "transport" : "http" }
          ] },
        { "agents" : ["Cursor", "Grok"], "configPaths" : ["/Users/k/.cursor/mcp.json", "/Users/k/.grok/config.toml"],
          "differs" : "Grok points at a different command than Cursor.", "hidden" : false, "name" : "wake",
          "needsAttention" : true, "pinned" : true, "reason" : "Set up differently in Grok", "state" : "healthy",
          "status" : "set up differently", "toolCount" : 2, "tools" : ["wake_search", "wake_get_session"],
          "transports" : ["stdio"],
          "sources" : [
            { "agent" : "Cursor", "configPath" : "/Users/k/.cursor/mcp.json", "differs" : false, "envNames" : [],
              "headerNames" : [], "state" : "healthy", "target" : "/usr/local/bin/wake-mcp", "transport" : "stdio" },
            { "agent" : "Grok", "configPath" : "/Users/k/.grok/config.toml", "differs" : true, "envNames" : [],
              "headerNames" : [], "state" : "healthy", "target" : "/opt/old/wake-mcp", "transport" : "stdio" }
          ] },
        { "agents" : ["Cursor"], "configPaths" : ["/Users/k/.cursor/mcp.json"], "hidden" : false, "name" : "tinycast",
          "needsAttention" : false, "pinned" : false, "state" : "healthy", "status" : "fine", "toolCount" : 1,
          "tools" : ["add_note"], "transports" : ["stdio"], "sources" : [] },
        { "agents" : ["Cursor"], "configPaths" : ["/Users/k/.cursor/mcp.json"], "hidden" : true, "name" : "old-thing",
          "needsAttention" : true, "pinned" : false, "reason" : "Could not start: command not found", "state" : "broken",
          "status" : "broken", "toolCount" : 0, "tools" : [], "transports" : ["stdio"], "sources" : [] }
      ]
    }
    """

    private func fixtureFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-fixture-\(UUID().uuidString).json")
        try Data(Self.fixtureJSON.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func server(at url: URL, minutesLater: Double = 2, running: Bool = true) -> MCPStatusServer {
        let now = MCPockStatus.decoderDate("2027-01-15T08:00:00Z").addingTimeInterval(minutesLater * 60)
        return MCPStatusServer(loadStatus: { StatusLoad.read(from: url) }, now: { now }, isRunning: { _ in running }, version: "1.5.0")
    }

    // MARK: - Tool texts from the fixture

    func testProblemsListsWhatNeedsAttentionWorstFirst() throws {
        let text = try XCTUnwrap(server(at: fixtureFile()).callTool("mcpock_problems", arguments: [:]))
        XCTAssertTrue(text.hasPrefix("3 MCP servers need attention"), text)
        let firecrawl = try XCTUnwrap(text.range(of: "1. firecrawl — broken"))
        let figma = try XCTUnwrap(text.range(of: "2. figma — needs sign-in"))
        let wake = try XCTUnwrap(text.range(of: "3. wake — set up differently"))
        XCTAssertLessThan(firecrawl.lowerBound, figma.lowerBound)
        XCTAssertLessThan(figma.lowerBound, wake.lowerBound)
        XCTAssertTrue(text.contains("- /Users/k/.cursor/mcp.json"))
        XCTAssertTrue(text.contains("error: Non-zero exit (1) — Invalid key ••••"))
        XCTAssertTrue(text.contains("Set up differently: Grok points at a different command than Cursor."))
        XCTAssertTrue(text.contains("runs: /opt/old/wake-mcp"))
        XCTAssertFalse(text.contains("tinycast"), "fine servers are left out")
        XCTAssertTrue(text.contains("Hidden in mcpock and left out: old-thing."))
    }

    func testStatusCounts() throws {
        let text = try XCTUnwrap(server(at: fixtureFile()).callTool("mcpock_status", arguments: [:]))
        XCTAssertTrue(text.hasPrefix("mcpock 1.5.0: 4 servers"), text)
        XCTAssertTrue(text.contains("Updated 2 min ago · checks every 5 min"))
        XCTAssertTrue(text.contains("- broken: 2"))
        XCTAssertTrue(text.contains("- needs sign-in: 1"))
        XCTAssertTrue(text.contains("3 need attention: call mcpock_problems"))
    }

    func testServerDetailsMatchLooselyAndListEverything() throws {
        let text = try XCTUnwrap(server(at: fixtureFile()).callTool("mcpock_server", arguments: ["name": "Fire Crawl"]))
        XCTAssertTrue(text.hasPrefix("firecrawl — broken"), text)
        XCTAssertTrue(text.contains("env: FIRECRAWL_API_KEY (values not shown)"))
        XCTAssertTrue(text.contains("- Claude Code (stdio, healthy)"), "the full view lists every declaration")
        XCTAssertTrue(text.contains("Tools (0): none reported"))

        let missing = try XCTUnwrap(server(at: fixtureFile()).callTool("mcpock_server", arguments: ["name": "nope"]))
        XCTAssertTrue(missing.hasPrefix("No server named \"nope\""))
        XCTAssertTrue(missing.contains("firecrawl, figma, wake"))
    }

    func testMissingOldAndStoppedFilesSaySo() throws {
        let missing = MCPStatusServer(loadStatus: { .missing(path: "/x/status.json") })
        XCTAssertEqual(missing.callTool("mcpock_problems", arguments: [:]), StatusReport.notRunningYet)

        let url = try fixtureFile()
        let old = try XCTUnwrap(server(at: url, minutesLater: 90).callTool("mcpock_problems", arguments: [:]))
        XCTAssertTrue(old.hasPrefix("This snapshot is old (1 h ago)"), old)
        XCTAssertTrue(old.contains("1. firecrawl — broken"), "old results are still shown")

        let stopped = try XCTUnwrap(server(at: url, running: false).callTool("mcpock_status", arguments: [:]))
        XCTAssertTrue(stopped.hasPrefix("mcpock isn't running. This is what it saw last (2 min ago)"), stopped)

        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-bad-\(UUID().uuidString).json")
        try Data("{".utf8).write(to: broken)
        defer { try? FileManager.default.removeItem(at: broken) }
        let unreadable = try XCTUnwrap(server(at: broken).callTool("mcpock_status", arguments: [:]))
        XCTAssertTrue(unreadable.contains("couldn't be read"), unreadable)
    }

    func testFreshnessRules() throws {
        guard case .loaded(var status) = StatusLoad.read(from: try fixtureFile()) else { return XCTFail() }
        let at = status.generated
        XCTAssertNil(StatusReport.freshnessNote(status, now: at.addingTimeInterval(14 * 60), isRunning: true),
                     "5 min interval: fresh for 3 intervals")
        XCTAssertNotNil(StatusReport.freshnessNote(status, now: at.addingTimeInterval(16 * 60), isRunning: true))
        status.checkEverySeconds = 0
        XCTAssertNil(StatusReport.freshnessNote(status, now: at.addingTimeInterval(50 * 60), isRunning: true))
        XCTAssertTrue(StatusReport.freshnessNote(status, now: at.addingTimeInterval(2 * 3600), isRunning: true)?
            .hasPrefix("mcpock checks only when asked") ?? false)
        status.firstCheckDone = false
        XCTAssertTrue(StatusReport.freshnessNote(status, now: at, isRunning: true)?.contains("first check") ?? false)
    }

    // MARK: - JSON-RPC

    private func reply(_ server: MCPStatusServer, _ line: String) throws -> [String: Any] {
        let text = try XCTUnwrap(server.handle(line: line))
        XCTAssertFalse(text.contains("\n"), "one message per line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testInitializeListAndCall() throws {
        let s = server(at: try fixtureFile())
        let initialize = try reply(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        let result = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "mcpock")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])

        XCTAssertNil(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(s.handle(line: "   "))

        let list = try reply(s, #"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#)
        XCTAssertEqual(list["id"] as? String, "a")
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["mcpock_status", "mcpock_problems", "mcpock_server"])
        for tool in tools {
            XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
        }

        let call = try reply(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"mcpock_problems","arguments":{}}}"#)
        let content = try XCTUnwrap((call["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertTrue((content.first?["text"] as? String)?.hasPrefix("3 MCP servers need attention") ?? false)
    }

    func testErrors() throws {
        let s = server(at: try fixtureFile())
        let unknownTool = try reply(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"write_config"}}"#)
        XCTAssertEqual((unknownTool["error"] as? [String: Any])?["code"] as? Int, -32602)
        let unknownMethod = try reply(s, #"{"jsonrpc":"2.0","id":5,"method":"resources/read"}"#)
        XCTAssertEqual((unknownMethod["error"] as? [String: Any])?["code"] as? Int, -32601)
        let garbage = try reply(s, "not json")
        XCTAssertEqual((garbage["error"] as? [String: Any])?["code"] as? Int, -32700)
        let oldVersion = try reply(s, #"{"jsonrpc":"2.0","id":6,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual((oldVersion["result"] as? [String: Any])?["protocolVersion"] as? String,
                       MCPStatusServer.supportedVersions[0])
    }

    // MARK: - The real helper, end to end

    /// Runs the helper bundled in the test host (the app) over stdio against the
    /// fixture: initialize, tools/list, mcpock_problems.
    func testBundledHelperAnswersOverStdio() throws {
        let helper = ConnectSnippets.helperPath()
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            return XCTFail("mcpock-mcp missing from the app bundle at \(helper)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.environment = ["MCPOCK_STATUS_FILE": try fixtureFile().path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"mcpock_problems","arguments":{}}}"#,
        ]
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let replies = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(replies.count, 3, "one reply per request, none for the notification")
        XCTAssertTrue(replies[0].contains(#""protocolVersion":"2025-06-18""#))
        XCTAssertTrue(replies[1].contains("mcpock_problems"))
        XCTAssertTrue(replies[2].contains("firecrawl — broken"))
    }
}

extension MCPockStatus {
    /// Parse a fixture timestamp the way the file's decoder does.
    static func decoderDate(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? Date(timeIntervalSince1970: 0)
    }
}
