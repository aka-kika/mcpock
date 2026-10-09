import XCTest
@testable import mcpock

/// Round 5: aka's sidecar payload mapped onto configs, with no network. The
/// fixture mirrors the real shape (field names and kinds of values); the secret
/// values are made up.
final class AkaSourceTests: XCTestCase {
    private let secretKey = "sk-test-bearer-0000"
    private let secretEnv = "ghp_test_env_value_1111"
    private let secretOAuth = "oauth-client-secret-2222"

    private var fixture: Data {
        let json = """
        {"servers": [
          {"id": 22, "name": "recall", "transportType": "stdio", "enabled": true, "authType": "none",
           "path": "/Users/k/.local/bin/uv run /Users/k/Recall/src/recall_mcp.py",
           "apiKey": null, "env": {}, "oauthClientSecret": null, "connectionStatus": "connected", "lastError": null},
          {"id": 21, "name": "safari-mcp-stp", "transportType": "stdio", "enabled": true, "authType": "none",
           "path": "\\"/Applications/Safari Technology Preview.app/Contents/MacOS/safaridriver\\" --mcp", "env": {}},
          {"id": 27, "name": "playwright", "transportType": "stdio", "enabled": true, "authType": "none",
           "path": "@playwright/mcp@latest", "env": {}},
          {"id": 1, "name": "chrome-browser", "transportType": "stdio", "enabled": true, "authType": "none",
           "path": "chrome-devtools-mcp --autoConnect", "env": {}},
          {"id": 5, "name": "github", "transportType": "stdio", "enabled": true, "authType": "none",
           "path": "gh-mcp", "env": {"GITHUB_TOKEN": "\(secretEnv)"}},
          {"id": 19, "name": "reed-md", "transportType": "http", "enabled": true, "authType": "bearer",
           "path": "http://127.0.0.1:8742/mcp", "apiKey": "\(secretKey)", "env": {}},
          {"id": 104, "name": "cloudflare-docs", "transportType": "http", "enabled": true, "authType": "none",
           "path": "https://docs.mcp.cloudflare.com/mcp", "apiKey": null, "env": {}},
          {"id": 41, "name": "higgsfield", "transportType": "http", "enabled": false, "authType": "oauth",
           "path": "https://mcp.higgsfield.ai/mcp", "oauthClientSecret": "\(secretOAuth)", "env": {}},
          {"id": 42, "name": "remote-oauth", "transportType": "stdio", "enabled": true, "authType": "oauth",
           "path": "https://example.com/mcp", "apiKey": "\(secretKey)", "oauthClientSecret": "\(secretOAuth)", "env": {}},
          {"id": 50, "name": "helper-py", "transportType": "stdio", "enabled": true, "authType": "none",
           "path": "/Users/k/tools/helper.py --flag", "env": {}},
          {"id": 51, "name": "helper-js", "transportType": "stdio", "enabled": true, "authType": "none",
           "path": "/Users/k/tools/helper.mjs", "env": {}},
          {"id": 52, "name": "npx-line", "transportType": "stdio", "enabled": true, "authType": "none",
           "path": "npx -y some-server", "env": {}}
        ]}
        """
        return Data(json.utf8)
    }

    /// The bun aka runs packages with, as resolved on the test machine.
    private let bun = "/Users/k/.bun/bin/bun"

    private func configs() -> [String: ServerConfig] {
        let list = AkaSource.configs(fromJSON: fixture, bun: bun)
        return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
    }

    func testEveryEnabledServerIsAnAkaSource() {
        let byName = configs()
        XCTAssertEqual(Set(byName.keys), [
            "recall", "safari-mcp-stp", "playwright", "chrome-browser", "github", "reed-md",
            "cloudflare-docs", "remote-oauth", "helper-py", "helper-js", "npx-line",
        ], "disabled higgsfield is left out")
        for config in byName.values {
            XCTAssertEqual(config.source.label, "aka")
            XCTAssertEqual(config.source.path, AkaSource.dataFolder, "Open config opens aka's data folder")
        }
    }

    /// Round 6: aka's `parseStdioCommand`, read from its code.
    func testStdioCommandLinesMatchAkasLauncher() {
        let byName = configs()
        XCTAssertEqual(byName["recall"]?.command, "/Users/k/.local/bin/uv", "a path runs as is")
        XCTAssertEqual(byName["recall"]?.args, ["run", "/Users/k/Recall/src/recall_mcp.py"])
        XCTAssertEqual(byName["safari-mcp-stp"]?.command,
                       "/Applications/Safari Technology Preview.app/Contents/MacOS/safaridriver",
                       "a quoted path with spaces stays one word")
        XCTAssertEqual(byName["safari-mcp-stp"]?.args, ["--mcp"])
        XCTAssertEqual(byName["playwright"]?.command, bun, "a scoped package runs through bun x")
        XCTAssertEqual(byName["playwright"]?.args, ["x", "-y", "@playwright/mcp@latest"])
        XCTAssertEqual(byName["chrome-browser"]?.args, ["x", "-y", "chrome-devtools-mcp", "--autoConnect"])
        XCTAssertEqual(byName["github"]?.command, bun,
                       "any first word without a slash is a package to aka, installed or not")
        XCTAssertEqual(byName["github"]?.args, ["x", "-y", "gh-mcp"])
        XCTAssertEqual(byName["npx-line"]?.args, ["x", "-y", "npx", "-y", "some-server"],
                       "aka does not special-case npx either")
        XCTAssertEqual(byName["helper-py"]?.command, "python")
        XCTAssertEqual(byName["helper-py"]?.args, ["/Users/k/tools/helper.py", "--flag"])
        XCTAssertEqual(byName["helper-js"]?.command, bun)
        XCTAssertEqual(byName["helper-js"]?.args, ["run", "/Users/k/tools/helper.mjs"])
        XCTAssertEqual(byName["recall"]?.transport, .stdio)
    }

    /// aka finds bun on the login shell's PATH; mcpock's PATH is short, so it
    /// also looks where bun installs itself.
    func testBunIsFoundWhereBunInstallsItself() {
        let home = NSHomeDirectory()
        let notOnPath: (String) -> String = { $0 }
        XCTAssertEqual(AkaSource.bunCommand(environment: [:], lookUp: { _ in "/opt/homebrew/bin/bun" },
                                            isExecutable: { _ in true }), "/opt/homebrew/bin/bun")
        XCTAssertEqual(AkaSource.bunCommand(environment: ["BUN_INSTALL": "/opt/bun"], lookUp: notOnPath,
                                            isExecutable: { $0 == "/opt/bun/bin/bun" }), "/opt/bun/bin/bun")
        XCTAssertEqual(AkaSource.bunCommand(environment: [:], lookUp: notOnPath,
                                            isExecutable: { $0 == home + "/.bun/bin/bun" }), home + "/.bun/bin/bun")
        XCTAssertEqual(AkaSource.bunCommand(environment: [:], lookUp: notOnPath, isExecutable: { _ in false }), "bun")
    }

    func testHTTPServers() {
        let byName = configs()
        XCTAssertEqual(byName["reed-md"]?.transport, .http)
        XCTAssertEqual(byName["reed-md"]?.url, "http://127.0.0.1:8742/mcp")
        XCTAssertEqual(byName["reed-md"]?.headers["Authorization"], "Bearer \(secretKey)",
                       "a bearer key is what the probe needs, or it 401s")
        XCTAssertEqual(byName["cloudflare-docs"]?.headers, [:])
        XCTAssertEqual(byName["remote-oauth"]?.transport, .http,
                       "an http(s) path is Streamable HTTP whatever transportType says")
        XCTAssertEqual(byName["remote-oauth"]?.headers, [:], "OAuth tokens stay in aka")
        XCTAssertEqual(byName["remote-oauth"]?.env, [:])
    }

    /// Secrets stay where a probe needs them and nowhere else: never in the
    /// command line, the row's copy texts or the card's source list.
    func testSecretsGoNoFurtherThanTheProbe() {
        let list = AkaSource.configs(fromJSON: fixture, bun: bun)
        XCTAssertEqual(list.first { $0.name == "github" }?.env["GITHUB_TOKEN"], secretEnv, "the probe's env")
        for config in list {
            let everything = String(describing: config)
            XCTAssertFalse(everything.contains(secretOAuth), "OAuth secrets are never kept")
            XCTAssertFalse(config.commandLine.contains(secretKey))
            XCTAssertFalse(config.commandLine.contains(secretEnv))
        }
        let snapshots = list.map {
            ServerSnapshot(config: $0, state: .broken, failureReason: "Non-zero exit (1)")
        }
        let groups = HealthMonitor.groupByName(snapshots)
        for group in groups {
            let details = ServerReport.detailsText(ServerReport.entry(for: group, servers: snapshots), now: Date())
            for text in [group.copyText, details] + group.sources.map(\.target) {
                XCTAssertFalse(text.contains(secretKey), group.name)
                XCTAssertFalse(text.contains(secretEnv), group.name)
            }
            for source in group.sources {
                XCTAssertFalse(source.envKeys.contains(secretEnv))
                XCTAssertFalse(source.headerKeys.contains { $0.contains(secretKey) })
            }
        }
    }

    func testNoSidecarPayloadMeansNoServers() {
        XCTAssertTrue(AkaSource.configs(fromJSON: Data("not json".utf8), bun: bun).isEmpty)
        XCTAssertTrue(AkaSource.configs(fromJSON: Data("{\"error\":\"x\"}".utf8), bun: bun).isEmpty)
    }

    /// aka's `splitCommandLine`: no backslash escapes, empty words dropped.
    func testCommandLineSplitting() {
        XCTAssertEqual(AkaSource.splitCommandLine("a  b\tc"), ["a", "b", "c"])
        XCTAssertEqual(AkaSource.splitCommandLine("\"a b\" 'c d' e\\ f"), ["a b", "c d", "e\\", "f"])
        XCTAssertEqual(AkaSource.splitCommandLine("x \"\""), ["x"], "an empty quoted argument vanishes, as in aka")
        XCTAssertEqual(AkaSource.splitCommandLine("pre\"mid dle\"post"), ["premid dlepost"])
        XCTAssertEqual(AkaSource.splitCommandLine("   "), [])
    }

    /// Round 6: aka is never part of "set up differently", neither the odd one
    /// out nor the majority, and its real errors still show.
    func testAkaIsLeftOutOfTheDiffersCheck() throws {
        let aka = ServerSource(label: AkaSource.label, path: AkaSource.dataFolder)
        func cfg(_ source: ServerSource, _ command: String, _ args: [String]) -> ServerConfig {
            ServerConfig(id: "\(source.label):pw", name: "playwright", source: source, projectPath: nil,
                         transport: .stdio, command: command, args: args, env: [:], url: nil, headers: [:])
        }
        let npx = cfg(.code, "npx", ["-y", "@playwright/mcp@latest"])
        let cursor = cfg(.cursor, "npx", ["-y", "@playwright/mcp@latest"])
        let akaCopy = cfg(aka, bun, ["x", "-y", "@playwright/mcp@latest"])
        XCTAssertTrue(Differs.detect([npx, cursor, akaCopy]).isEmpty, "aka is never the odd one out")
        XCTAssertTrue(Differs.detect([npx, akaCopy]).isEmpty, "nor half of a 1-vs-1 split")

        let grok = cfg(.grok, "/old/playwright", [])
        let akaLikeGrok = cfg(aka, "/old/playwright", [])
        XCTAssertEqual(Differs.detect([npx, grok, akaLikeGrok]).map(\.label), ["Code", "Grok"],
                       "aka doesn't make Grok a majority: 1-vs-1 names both")

        let groups = HealthMonitor.groupByName([
            ServerSnapshot(config: npx, state: .healthy),
            ServerSnapshot(config: cursor, state: .healthy),
            ServerSnapshot(config: grok, state: .healthy),
            ServerSnapshot(config: akaCopy, state: .broken, failureReason: "Non-zero exit (1)"),
        ])
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.differs.map(\.label), ["Grok"])
        XCTAssertEqual(group.state, .broken, "aka's real error still shows")
        XCTAssertEqual(group.issues.map(\.label), ["aka"])
        let sentence = CardText.differsSentence(for: group)
        XCTAssertFalse(sentence.contains("aka"), sentence)
        XCTAssertEqual(sentence, "Grok points at a different command than Claude Code and Cursor.")

        let sections = AgentSections.build(groups: groups)
        let akaSection = try XCTUnwrap(sections.first { $0.agent == "aka" })
        XCTAssertEqual(akaSection.brokenCount, 1, "and under aka in the Agents tab")
        let healthyAka = AgentSections.build(groups: HealthMonitor.groupByName([
            ServerSnapshot(config: npx, state: .healthy),
            ServerSnapshot(config: grok, state: .healthy),
            ServerSnapshot(config: cursor, state: .healthy),
            ServerSnapshot(config: akaCopy, state: .healthy),
        ])).first { $0.agent == "aka" }
        XCTAssertEqual(healthyAka?.problems.count, 0, "a row that differs elsewhere is not flagged under aka")
    }
}
