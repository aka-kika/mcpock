import XCTest
@testable import mcpock

/// 1.5.3: the server menu's "Copy Details" and "Ask an Agent" texts. Same
/// masking as the status file, the right words, and a prompt that asks for
/// advice, never for a fix.
@MainActor
final class ServerReportTests: XCTestCase {
    private let secrets = ["sk-live-SUPERSECRET-0001", "hdr-SECRET-token-0002", "argSECRET0004xyzargSECRET0004xyz"]
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

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

    private var broken: [ServerSnapshot] {
        [
            ServerSnapshot(
                config: config("firecrawl", agent: "Cursor", path: "/Users/k/.cursor/mcp.json",
                               args: ["-y", "firecrawl-mcp", "--api-key", secrets[2]],
                               env: ["FIRECRAWL_API_KEY": secrets[0]]),
                state: .broken,
                failureReason: "Non-zero exit (1) — Invalid key \(secrets[0])",
                lastChecked: now.addingTimeInterval(-180)
            ),
            ServerSnapshot(
                config: config("firecrawl", agent: "Code", path: "/Users/k/.claude.json", transport: .http,
                               url: "https://api.firecrawl.dev/mcp", headers: ["Authorization": "Bearer \(secrets[1])"]),
                state: .healthy,
                tools: (1...7).map { MCPToolInfo(name: "tool\($0)", description: "") },
                lastChecked: now.addingTimeInterval(-60)
            ),
        ]
    }

    private func entry(_ servers: [ServerSnapshot], name: String) -> MCPockStatus.Server {
        let group = HealthMonitor.groupByName(servers).first { $0.name == name }!
        return ServerReport.entry(for: group, servers: servers)
    }

    func testDetailsCarryTheFactsAndNoSecret() {
        let text = ServerReport.detailsText(entry(broken, name: "firecrawl"), now: now)
        for secret in secrets {
            XCTAssertFalse(text.contains(secret), "masked like the status file: \(secret)")
        }
        XCTAssertTrue(text.hasPrefix("MCP server: firecrawl\nStatus: broken"))
        XCTAssertTrue(text.contains("Transport: stdio / http"))
        XCTAssertTrue(text.contains("Tools: 7"))
        XCTAssertTrue(text.contains("Last checked: "))
        XCTAssertTrue(text.contains("(1 min ago)"), "the newest check, with its age")
        XCTAssertTrue(text.contains("- Cursor (stdio, broken, set up differently)\n  config: /Users/k/.cursor/mcp.json"))
        XCTAssertTrue(text.contains("  runs: npx -y firecrawl-mcp --api-key \(SecretMask.dots)"))
        XCTAssertTrue(text.contains("  env: FIRECRAWL_API_KEY (values not shown)"))
        XCTAssertTrue(text.contains("- Claude Code (http, fine, set up differently)\n  config: /Users/k/.claude.json\n  runs: https://api.firecrawl.dev/mcp"))
        XCTAssertTrue(text.contains("  headers: Authorization (values not shown)"))
        XCTAssertTrue(text.contains("Set up differently: "), "a 1-vs-1 split names both")
        XCTAssertFalse(text.contains("Invalid key"), "errors are Copy Errors' job")
    }

    func testCheckedTextHasClockTimeAndAge() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(ServerReport.checkedText(now.addingTimeInterval(-180), now: now, timeZone: utc),
                       "2027-01-15 07:57 (3 min ago)")
    }

    func testDetailsOfADifferingRowNameTheOddOneOut() {
        let servers = [
            ServerSnapshot(config: config("wake", agent: "Code", path: "/c", command: "/a/wake"), state: .healthy),
            ServerSnapshot(config: config("wake", agent: "Cursor", path: "/u", command: "/a/wake"), state: .healthy),
            ServerSnapshot(config: config("wake", agent: "Grok", path: "/g", command: "/old/wake"), state: .healthy),
        ]
        let text = ServerReport.detailsText(entry(servers, name: "wake"), now: now)
        XCTAssertTrue(text.contains("Status: set up differently"))
        XCTAssertTrue(text.contains("Set up differently: Grok points at a different command than Claude Code and Cursor."))
        XCTAssertTrue(text.contains("- Grok (stdio, fine, set up differently)"))
        XCTAssertTrue(text.contains("Last checked: not yet"))
    }

    func testAskAgentAsksForAdviceNotAFix() {
        let prompt = ServerReport.askAgentPrompt(entry(broken, name: "firecrawl"), mcpockAgents: [], now: now)
        for secret in secrets {
            XCTAssertFalse(prompt.contains(secret), "masked: \(secret)")
        }
        XCTAssertTrue(prompt.contains("Investigate and advise only"))
        XCTAssertTrue(prompt.contains("don't change any file, config or setting"))
        XCTAssertTrue(prompt.contains("reports that \"firecrawl\" is broken ("))
        for ask in ["What the problem is", "likely causes", "options to fix it, each with its trade-offs",
                    "Which option you recommend", "ask me before you change anything"] {
            XCTAssertTrue(prompt.contains(ask), ask)
        }
        XCTAssertTrue(prompt.contains("Server details\nMCP server: firecrawl"))
        XCTAssertTrue(prompt.contains("Error\n- Cursor: Non-zero exit (1) — Invalid key \(SecretMask.dots)"),
                      "the error, masked")
        XCTAssertFalse(prompt.contains("mcpock_server"), "no mcpock server set up: not mentioned")
    }

    func testAskAgentMentionsMcpocksServerWhenItIsSetUp() {
        let servers = broken + [
            ServerSnapshot(config: config("mcpock", agent: "Code", path: "/c",
                                          command: "/Applications/mcpock.app/Contents/Helpers/mcpock-mcp")),
            ServerSnapshot(config: config("status", agent: "Cursor", path: "/u",
                                          command: "/Applications/mcpock.app/Contents/Helpers/mcpock-mcp")),
            ServerSnapshot(config: config("mcpock", agent: "Code", path: "/c2", command: "x")),
        ]
        let agents = ServerReport.mcpockAgents(in: servers)
        XCTAssertEqual(agents, ["Claude Code", "Cursor"], "by name or by the helper it runs, each agent once")
        let prompt = ServerReport.askAgentPrompt(entry(servers, name: "firecrawl"), mcpockAgents: agents, now: now)
        XCTAssertTrue(prompt.contains("\"mcpock\" (set up in Claude Code and Cursor)"))
        XCTAssertTrue(prompt.contains("call mcpock_server with name \"firecrawl\""))
    }

    func testAskAgentOnlyWhereThereIsSomethingToAsk() {
        let groups = HealthMonitor.groupByName(broken + [
            ServerSnapshot(config: config("wake", agent: "Code", path: "/c"), state: .healthy),
            ServerSnapshot(config: config("paused", agent: "Code", path: "/c"), state: .paused),
            ServerSnapshot(config: config("new", agent: "Code", path: "/c"), state: .unknown),
        ])
        let asks = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, ServerReport.canAskAgent($0)) })
        XCTAssertEqual(asks, ["firecrawl": true, "wake": false, "paused": false, "new": false])
    }

    func testProblemClauses() {
        var server = entry(broken, name: "firecrawl")
        server.status = "needs sign-in"
        server.reason = nil
        XCTAssertEqual(ServerReport.problemClause(server), "needs sign-in")
        server.status = "set up differently"
        server.differs = "Grok points at a different address than Cursor."
        XCTAssertEqual(ServerReport.problemClause(server),
                       "is set up differently across my agents: Grok points at a different address than Cursor.")
    }

    /// ⌘C on a fine row copies the same masked details as the menu.
    func testCommandCOnAFineRowCopiesTheDetails() {
        let servers = [ServerSnapshot(config: config("wake", agent: "Code", path: "/c",
                                                     args: ["--token", secrets[2]]), state: .healthy)]
        let group = HealthMonitor.groupByName(servers)[0]
        let text = PanelState.copyText(for: group, servers: servers, now: now)
        XCTAssertEqual(text, ServerReport.detailsText(ServerReport.entry(for: group, servers: servers), now: now))
        XCTAssertFalse(text.contains(secrets[2]))
    }
}

final class CopyErrorsMaskingTests: XCTestCase {
    /// Copy Errors / Export must never carry a token that sits on a command line
    /// or in an error text (2026-09-24: reed-md's bridge passes a bearer token).
    func testIssuesMaskTokensInCommandAndReason() {
        let token = "a653e30384f21c475b9e2d1f0c8a7b6e5d4c3b2a"
        let config = ServerConfig(
            id: "t", name: "reed-md", source: ServerSource(label: "Code"), projectPath: nil,
            transport: .stdio, command: "npx",
            args: ["mcp-remote", "http://127.0.0.1:8742/mcp", "--header", "Authorization: Bearer \(token)"],
            env: [:], url: nil, headers: [:])
        let snapshot = ServerSnapshot(config: config, state: .broken,
                                      failureReason: "HTTP 401 with Bearer \(token)")
        let groups = HealthMonitor.groupByName([snapshot])
        let text = groups[0].copyText
        XCTAssertFalse(text.contains(token), text)
        XCTAssertTrue(text.contains("mcp-remote"))
    }
}
