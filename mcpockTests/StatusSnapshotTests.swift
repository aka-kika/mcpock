import XCTest
@testable import mcpock

/// Round 7: the status file agents read. What goes in, in what words, and
/// above all that no env value, header value or secret argument ever does.
@MainActor
final class StatusSnapshotTests: XCTestCase {
    private let secrets = ["sk-live-SUPERSECRET-0001", "hdr-SECRET-token-0002", "pa55-SECRET-0003", "argSECRET0004xyz"]

    private func config(
        _ name: String,
        agent: String,
        path: String,
        transport: TransportKind = .stdio,
        command: String? = "npx",
        args: [String] = [],
        env: [String: String] = [:],
        url: String? = nil,
        headers: [String: String] = [:]
    ) -> ServerConfig {
        ServerConfig(
            id: "\(agent):\(name)", name: name, source: ServerSource(label: agent, path: path), projectPath: nil,
            transport: transport, command: transport == .stdio ? command : nil, args: args, env: env,
            url: url, headers: headers
        )
    }

    private func fixture() -> [ServerSnapshot] {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return [
            ServerSnapshot(
                config: config("firecrawl", agent: "Cursor", path: "/Users/k/.cursor/mcp.json",
                               args: ["-y", "firecrawl-mcp", "--api-key", secrets[3]],
                               env: ["FIRECRAWL_API_KEY": secrets[0]]),
                state: .broken,
                failureReason: "Non-zero exit (1) — Invalid key \(secrets[0])",
                lastChecked: now
            ),
            ServerSnapshot(
                config: config("figma", agent: "Code", path: "/Users/k/.claude.json", transport: .http,
                               url: "https://figma.example.com/mcp?password=\(secrets[2])",
                               headers: ["Authorization": "Bearer \(secrets[1])"]),
                state: .degraded,
                failureReason: "Needs authentication (HTTP 401)",
                lastChecked: now
            ),
            ServerSnapshot(
                config: config("wake", agent: "Cursor", path: "/Users/k/.cursor/mcp.json", command: "/usr/local/bin/wake-mcp"),
                state: .healthy, tools: [MCPToolInfo(name: "wake_search", description: "")], lastChecked: now
            ),
            ServerSnapshot(
                config: config("wake", agent: "Grok", path: "/Users/k/.grok/config.toml", command: "/opt/wake-mcp"),
                state: .healthy, lastChecked: now
            ),
            ServerSnapshot(
                config: config("wake", agent: "Goose", path: "/Users/k/.config/goose/config.yaml", command: "/usr/local/bin/wake-mcp"),
                state: .healthy, lastChecked: now
            ),
            ServerSnapshot(
                config: config("old", agent: "Cursor", path: "/Users/k/.cursor/mcp.json", command: "old-mcp"),
                state: .broken, failureReason: "Spawn error: Command not found: old-mcp", lastChecked: now
            ),
            ServerSnapshot(config: config("quiet", agent: "Cursor", path: "/Users/k/.cursor/mcp.json"), state: .paused),
        ]
    }

    private func build(hidden: Set<String> = ["old"]) -> MCPockStatus {
        StatusSnapshot.build(
            servers: fixture(),
            isHidden: { hidden.contains($0) },
            isPinned: { $0 == "wake" },
            checking: false,
            firstCheckDone: true,
            interval: .fifteenMinutes,
            now: Date(timeIntervalSince1970: 1_800_000_060),
            pid: 4242,
            appVersion: "1.5.0"
        )
    }

    func testNoSecretEverReachesTheFile() throws {
        let status = build()
        let json = String(decoding: try MCPockStatus.encoder().encode(status), as: UTF8.self)
        let markdown = StatusWriter.markdown(status)
        for secret in secrets {
            XCTAssertFalse(json.contains(secret), "status.json leaked \(secret)")
            XCTAssertFalse(markdown.contains(secret), "status.md leaked \(secret)")
        }
        // Names stay, so an agent knows which variable to fix.
        XCTAssertTrue(json.contains("FIRECRAWL_API_KEY"))
        XCTAssertTrue(json.contains("Authorization"))
    }

    func testServersCarryWordsPathsAndAgents() throws {
        let status = build()
        let firecrawl = try XCTUnwrap(status.servers.first { $0.name == "firecrawl" })
        XCTAssertEqual(firecrawl.status, "broken")
        XCTAssertTrue(firecrawl.needsAttention)
        XCTAssertEqual(firecrawl.configPaths, ["/Users/k/.cursor/mcp.json"])
        XCTAssertEqual(firecrawl.agents, ["Cursor"])
        XCTAssertEqual(firecrawl.sources.first?.envNames, ["FIRECRAWL_API_KEY"])
        XCTAssertEqual(firecrawl.sources.first?.target, "npx -y firecrawl-mcp --api-key \(SecretMask.dots)")

        let figma = try XCTUnwrap(status.servers.first { $0.name == "figma" })
        XCTAssertEqual(figma.status, "needs sign-in")
        XCTAssertEqual(figma.agents, ["Claude Code"])
        XCTAssertEqual(figma.sources.first?.headerNames, ["Authorization"])

        let wake = try XCTUnwrap(status.servers.first { $0.name == "wake" })
        XCTAssertEqual(wake.status, "set up differently")
        XCTAssertTrue(wake.pinned)
        XCTAssertEqual(wake.sources.filter(\.differs).map(\.agent), ["Grok"])
        XCTAssertEqual(wake.differs, "Grok points at a different command than Cursor and Goose.")
        XCTAssertEqual(wake.tools, ["wake_search"])

        XCTAssertEqual(status.servers.first { $0.name == "quiet" }?.status, "paused")
        XCTAssertEqual(status.servers.first { $0.name == "old" }?.hidden, true)
    }

    func testCountsAndHeader() {
        let status = build()
        XCTAssertEqual(status.schema, MCPockStatus.currentSchema)
        XCTAssertEqual(status.pid, 4242)
        XCTAssertEqual(status.checkEverySeconds, 900)
        XCTAssertEqual(status.counts.total, 5)
        XCTAssertEqual(status.counts.broken, 2, "the hidden one still counts as broken")
        XCTAssertEqual(status.counts.needsSignIn, 1)
        XCTAssertEqual(status.counts.differs, 1)
        XCTAssertEqual(status.counts.paused, 1)
        XCTAssertEqual(status.counts.hidden, 1)
        XCTAssertEqual(status.summary, "4 servers \u{00B7} 1 broken \u{00B7} 1 needs sign-in \u{00B7} 1 set up differently",
                       "the summary is the panel's, over the rows she sees")
    }

    func testRoundTripsThroughJSON() throws {
        let status = build()
        let data = try MCPockStatus.encoder().encode(status)
        XCTAssertEqual(try MCPockStatus.decoder().decode(MCPockStatus.self, from: data), status)
    }

    func testWriterWritesBothFilesAtomically() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try StatusWriter.write(build(), to: dir)
        guard case .loaded(let read) = StatusLoad.read(from: dir.appendingPathComponent("status.json")) else {
            return XCTFail("status.json should read back")
        }
        XCTAssertEqual(read, build())
        let markdown = try String(contentsOf: dir.appendingPathComponent("status.md"), encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("# mcpock status"))
        XCTAssertTrue(markdown.contains("firecrawl — broken"))
    }

    func testTestMonitorHasNoWriter() {
        // The test host is the app: a monitor built here must never touch the real file.
        let suite = "status-tests"
        defer { UserDefaults(suiteName: suite)?.retireSuite(named: suite) }
        let monitor = HealthMonitor(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertNil(monitor.statusWriter)
        XCTAssertNil(monitor.widgetSnapshotWriter, "a test run must never touch the real App Group container either")
    }

    func testPerAgentRowsMatchTheAgentsTab() throws {
        // Round 8: the widgets read `perAgent`, and it must be exactly what
        // the Agents tab itself would build from the same groups.
        let status = build()
        let agents = try XCTUnwrap(status.perAgent)
        let cursor = try XCTUnwrap(agents.first { $0.name == "Cursor" })
        // Cursor declares firecrawl (broken), wake (fine), old (broken, hidden
        // in the panel — still counts here, same as the overall broken count)
        // and quiet (paused, not a problem, counted as fine like `AgentSection.fineCount` does).
        XCTAssertEqual(cursor.serverCount, 4)
        XCTAssertEqual(cursor.problemCount, 2)
        XCTAssertEqual(cursor.fineCount, 2)

        let code = try XCTUnwrap(agents.first { $0.name == "Claude Code" })
        XCTAssertEqual(code.serverCount, 1)
        XCTAssertEqual(code.problemCount, 1, "figma needs sign-in")

        let grok = try XCTUnwrap(agents.first { $0.name == "Grok" })
        XCTAssertEqual(grok.serverCount, 1)
        XCTAssertEqual(grok.problemCount, 1, "the odd one out on wake")
    }
}
