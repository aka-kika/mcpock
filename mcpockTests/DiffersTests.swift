import XCTest
@testable import mcpock

/// "Set up differently": one server name, several agents, and one of them launches
/// something else. Only the launch target counts (command + args, or URL); env,
/// headers and project folder never do, since API keys legitimately differ.
final class DiffersTests: XCTestCase {
    private func stdio(
        _ source: ServerSource,
        command: String = "npx",
        args: [String] = ["-y", "reed-md"],
        env: [String: String] = [:],
        projectPath: String? = nil
    ) -> ServerConfig {
        ServerConfig(
            id: "\(source.label):\(projectPath ?? "global"):reed", name: "reed", source: source,
            projectPath: projectPath, transport: .stdio, command: command, args: args,
            env: env, url: nil, headers: [:]
        )
    }

    private func http(
        _ source: ServerSource,
        url: String = "https://example.com/mcp",
        headers: [String: String] = [:],
        transport: TransportKind = .http
    ) -> ServerConfig {
        ServerConfig(
            id: "\(source.label):remote", name: "remote", source: source, projectPath: nil,
            transport: transport, command: nil, args: [], env: [:], url: url, headers: headers
        )
    }

    func testSameCommandInThreeAgentsGivesNoDiff() {
        XCTAssertTrue(Differs.detect([stdio(.code), stdio(.cursor), stdio(.grok)]).isEmpty)
    }

    func testOneAgentWithAnotherURLNamesThatAgent() {
        let notes = Differs.detect([
            http(.code),
            http(.cursor),
            http(.grok, url: "https://old.example.com/mcp"),
        ])
        XCTAssertEqual(notes.map(\.label), ["Grok"])
        XCTAssertEqual(notes.first?.target, "https://old.example.com/mcp")
    }

    func testEnvOnlyDifferencesGiveNoDiff() {
        let notes = Differs.detect([
            stdio(.code, env: ["API_KEY": "one"]),
            stdio(.cursor, env: ["API_KEY": "two"]),
            stdio(.grok),
        ])
        XCTAssertTrue(notes.isEmpty, "API keys legitimately differ per agent")
    }

    func testHeaderOnlyDifferencesGiveNoDiff() {
        let notes = Differs.detect([
            http(.code, headers: ["Authorization": "Bearer a"]),
            http(.cursor, headers: ["Authorization": "Bearer b"]),
        ])
        XCTAssertTrue(notes.isEmpty)
    }

    func testProjectPathIsIgnored() {
        let notes = Differs.detect([stdio(.code, projectPath: "/Users/k/app"), stdio(.code), stdio(.cursor)])
        XCTAssertTrue(notes.isEmpty, "a per-project working directory is not a different server")
    }

    func testOneVsOneSplitListsBoth() {
        let notes = Differs.detect([stdio(.code), stdio(.cursor, args: ["-y", "reed-md@2"])])
        XCTAssertEqual(notes.map(\.label), ["Code", "Cursor"])
    }

    func testTiedSplitWithMoreSourcesListsEveryone() {
        let notes = Differs.detect([
            stdio(.code), stdio(.desktop),
            stdio(.cursor, command: "/usr/local/bin/reed"), stdio(.grok, command: "/usr/local/bin/reed"),
        ])
        XCTAssertEqual(Set(notes.map(\.label)), ["Code", "Desktop", "Cursor", "Grok"],
                       "2-vs-2 has no majority to measure against")
    }

    func testTwoOddOnesOutAgainstAMajority() {
        let notes = Differs.detect([
            stdio(.code), stdio(.desktop), stdio(.goose),
            stdio(.cursor, args: ["a"]), stdio(.grok, args: ["b"]),
        ])
        XCTAssertEqual(notes.map(\.label), ["Cursor", "Grok"])
    }

    func testDifferentArgsCount() {
        let notes = Differs.detect([stdio(.code), stdio(.desktop), stdio(.cursor, args: ["-y", "reed-md", "--debug"])])
        XCTAssertEqual(notes.map(\.label), ["Cursor"])
    }

    /// `npx` and `/opt/homebrew/bin/npx` are the same launch in practice; so are
    /// `~/bin/x` and its expanded form.
    func testPathNormalisationBeforeComparing() {
        XCTAssertTrue(Differs.detect([stdio(.code, command: "npx"), stdio(.cursor, command: "/opt/homebrew/bin/npx")]).isEmpty)
        let home = NSHomeDirectory()
        XCTAssertTrue(Differs.detect([
            stdio(.code, command: "~/bin/reed", args: ["~/data"]),
            stdio(.cursor, command: "\(home)/bin/reed", args: ["\(home)/data"]),
        ]).isEmpty)
        XCTAssertEqual(
            Differs.detect([stdio(.code, command: "reed"), stdio(.cursor, command: "/Users/k/reed")]).count, 2,
            "a binary outside the common bin folders is a different target")
    }

    /// 1.9.0 (2026-10-03): one agent runs its servers with its own
    /// `~/.agent/node/bin/npx` and `.../node`, the other agents with plain
    /// `npx` / `node`. Same package, same flags: a launcher is the same
    /// launcher wherever it lives, and only the rest of the command counts.
    func testALauncherIsTheSameWhereverItLives() {
        let home = NSHomeDirectory()
        XCTAssertTrue(Differs.detect([
            stdio(.code, command: "npx", args: ["-y", "chrome-devtools-mcp@latest", "--isolated"]),
            stdio(.cursor, command: "npx", args: ["-y", "chrome-devtools-mcp@latest", "--isolated"]),
            stdio(ServerSource(label: "OpenCode"), command: "\(home)/.agent/node/bin/npx",
                  args: ["-y", "chrome-devtools-mcp@latest", "--isolated"]),
        ]).isEmpty)
        XCTAssertTrue(Differs.detect([
            stdio(.code, command: "node", args: ["/srv/macos-automator/dist/server.js"]),
            stdio(ServerSource(label: "OpenCode"), command: "~/.agent/node/bin/node",
                  args: ["/srv/macos-automator/dist/server.js"]),
        ]).isEmpty)
        for launcher in ["node", "npx", "bun", "bunx", "uv", "uvx", "python3", "python", "deno"] {
            XCTAssertTrue(Differs.detect([
                stdio(.code, command: launcher, args: ["x"]),
                stdio(.cursor, command: "/opt/tools/\(launcher)", args: ["x"]),
            ]).isEmpty, launcher)
        }
        XCTAssertEqual(Differs.detect([
            stdio(.code, command: "npx", args: ["-y", "reed-md"]),
            stdio(.cursor, command: "/opt/tools/npx", args: ["-y", "reed-md@2"]),
        ]).count, 2, "the rest of the command still counts")
        XCTAssertEqual(Differs.detect([
            stdio(.code, command: "/Users/k/feed/claude-mcp.sh"),
            stdio(.cursor, command: "/Users/k/feed/grok-mcp.sh"),
        ]).count, 2, "a script is not a launcher: its path is the target")
    }

    func testURLTrailingSlashAndTransportSpellingAreIgnored() {
        XCTAssertTrue(Differs.detect([
            http(.code, url: "https://example.com/mcp/"),
            http(.cursor, url: "https://example.com/mcp", transport: .sse),
        ]).isEmpty)
    }

    func testSingleSourceNeverDiffers() {
        XCTAssertTrue(Differs.detect([stdio(.code)]).isEmpty)
        XCTAssertTrue(Differs.detect([]).isEmpty)
    }

    /// The group carries the notes, and a differing row that is otherwise healthy
    /// lifts the menu-bar verdict to `.attention` (a ring, never the diamond).
    func testGroupCarriesDiffsAndIconGoesToAttention() {
        let snaps = [stdio(.code), stdio(.desktop), stdio(.grok, command: "/tmp/old/reed")]
            .map { ServerSnapshot(config: $0, state: .healthy) }
        let group = HealthMonitor.groupByName(snaps)[0]
        XCTAssertEqual(group.differs.map(\.label), ["Grok"])
        XCTAssertTrue(group.isDiffering)
        XCTAssertTrue(group.differsNeedsAttention)
        XCTAssertEqual(group.sources.count, 3)

        XCTAssertEqual(HealthMonitor.iconState([.healthy], anyDiffers: true), .attention)
        XCTAssertEqual(HealthMonitor.iconState([.healthy, .degraded], anyDiffers: true), .degradedOrUnknown)
        XCTAssertEqual(HealthMonitor.iconState([.broken], anyDiffers: true), .broken,
                       "a mismatch never masks a real failure")
        XCTAssertEqual(HealthMonitor.iconState([.healthy], anyDiffers: false), .allHealthy)
    }

    /// Env and header *names* travel with the source for the Compare sheet; values never do.
    func testGroupSourcesKeepKeyNamesNotValues() {
        let cfg = ServerConfig(
            id: "Code:remote", name: "remote", source: ServerSource(label: "Code", path: "/Users/k/.claude.json"),
            projectPath: nil, transport: .http, command: nil, args: [], env: ["Z": "1", "A": "secret"],
            url: "https://example.com/mcp", headers: ["Authorization": "Bearer secret"]
        )
        let source = HealthMonitor.groupByName([ServerSnapshot(config: cfg)])[0].sources[0]
        XCTAssertEqual(source.path, "/Users/k/.claude.json")
        XCTAssertEqual(source.envKeys, ["A", "Z"])
        XCTAssertEqual(source.headerKeys, ["Authorization"])
        XCTAssertEqual(source.target, "https://example.com/mcp")
        XCTAssertFalse(String(describing: source).contains("Bearer secret"))
    }
}
