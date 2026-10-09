import XCTest
@testable import mcpock

/// Grok (`config.toml`) and Goose (`config.yaml`) store MCP servers in TOML and
/// YAML, not JSON. These tests pin the minimal parsers that normalize both into the
/// same `name → entry` shape the JSON sources already flow through.
final class ConfigFormatTests: XCTestCase {

    // MARK: - Grok / TOML

    private let grokSample = """
    [cli]
    installer = "internal"

    [plugins]
    enabled = ["user/abc/feature-dev"]

    [mcp_servers.skill-librarian]
    command = "/opt/py/bin/python"
    args = ["/opt/the_librarian/server.py"]
    enabled = true

    [mcp_servers.skill-librarian.env]
    OLLAMA_HOST = "http://localhost:11434"
    LIBRARIAN_EMBED_MODEL = "nomic-embed-text"

    [mcp_servers.desktop-commander]
    command = "npx"
    args = [
        "-y",
        "@wonderwhy-er/desktop-commander@latest",
    ]
    enabled = true

    [mcp_servers.pieces]
    url = "http://localhost:39300/mcp"
    enabled = true

    [mcp_servers.hig]
    command = "/usr/local/bin/hig-mcp"
    args = []
    enabled = true

    [mcp_servers.legacy]
    command = "old-server"
    enabled = false

    [models]
    default = "grok-build"
    """

    func testGrokParsesStdioServerWithArgsAndEnv() {
        let servers = MCPServersTOML.servers(fromTOML: grokSample)
        let sl = servers["skill-librarian"]
        XCTAssertNotNil(sl)
        XCTAssertEqual(sl?["command"] as? String, "/opt/py/bin/python")
        XCTAssertEqual(sl?["args"] as? [String], ["/opt/the_librarian/server.py"])
        let env = sl?["env"] as? [String: String]
        XCTAssertEqual(env?["OLLAMA_HOST"], "http://localhost:11434")
        XCTAssertEqual(env?["LIBRARIAN_EMBED_MODEL"], "nomic-embed-text")
    }

    func testGrokParsesMultiLineArray() {
        let servers = MCPServersTOML.servers(fromTOML: grokSample)
        XCTAssertEqual(servers["desktop-commander"]?["args"] as? [String],
                       ["-y", "@wonderwhy-er/desktop-commander@latest"])
    }

    func testGrokParsesEmptyArray() {
        let servers = MCPServersTOML.servers(fromTOML: grokSample)
        XCTAssertEqual(servers["hig"]?["args"] as? [String], [])
    }

    func testGrokParsesHTTPServer() {
        let servers = MCPServersTOML.servers(fromTOML: grokSample)
        XCTAssertEqual(servers["pieces"]?["url"] as? String, "http://localhost:39300/mcp")
        XCTAssertNil(servers["pieces"]?["command"])
    }

    /// Regression: `[mcp_servers.<name>.headers]` used to be ignored, so Grok's
    /// authenticated HTTP servers were probed with no Authorization header and
    /// reported a false 401 (reed-md).
    func testGrokParsesHeadersSubtable() {
        let toml = """
        [mcp_servers.reed-md]
        url = "http://127.0.0.1:8742/mcp"
        enabled = true

        [mcp_servers.reed-md.headers]
        Authorization = "Bearer abc123def456"
        X-Trace-Url = "https://example.com:8443/t"
        """
        let servers = MCPServersTOML.servers(fromTOML: toml)
        XCTAssertNil(servers["headers"], "the headers sub-table is not its own server")
        let headers = servers["reed-md"]?["headers"] as? [String: String]
        XCTAssertEqual(headers?["Authorization"], "Bearer abc123def456",
                       "auth header must survive parsing or the probe 401s")
        XCTAssertEqual(headers?["X-Trace-Url"], "https://example.com:8443/t",
                       "header values keep embedded colons")

        let configs = ConfigDiscovery.configs(
            from: MCPServersTOML.shapeEntries(toml)!, source: .grok, idPrefix: "grok")
        XCTAssertEqual(configs.first?.transport, .http)
        XCTAssertEqual(configs.first?.headers["Authorization"], "Bearer abc123def456")
        XCTAssertEqual(configs.first?.headers["X-Trace-Url"], "https://example.com:8443/t")
    }

    func testGrokSkipsDisabledServer() {
        let servers = MCPServersTOML.servers(fromTOML: grokSample)
        XCTAssertNil(servers["legacy"], "enabled = false servers must be dropped")
    }

    func testGrokIgnoresNonMCPSections() {
        let servers = MCPServersTOML.servers(fromTOML: grokSample)
        XCTAssertNil(servers["cli"])
        XCTAssertNil(servers["plugins"])
        XCTAssertNil(servers["models"])
        // Real MCP servers: skill-librarian, desktop-commander, pieces, hig (legacy dropped).
        XCTAssertEqual(Set(servers.keys), ["skill-librarian", "desktop-commander", "pieces", "hig"])
    }

    func testTOMLInlineCommentsDoNotDisableOrCorrupt() {
        // Inline `#` comments are legal TOML anywhere outside a string. Regression:
        // an unstripped comment made `enabled = true  # note` read as disabled and
        // leaked the comment into command/arg values.
        let toml = """
        [mcp_servers.commented]  # server managed by hand
        command = "npx"  # runs via npx
        args = ["-y", "server"]  # keep in sync with package.json
        enabled = true  # do not disable
        # full-line comment between tables
        [mcp_servers.commented.env]
        TOKEN = "abc#not-a-comment"  # hash inside quotes is data
        """
        let servers = MCPServersTOML.servers(fromTOML: toml)
        let entry = servers["commented"]
        XCTAssertNotNil(entry, "enabled = true with a trailing comment must not drop the server")
        XCTAssertEqual(entry?["command"] as? String, "npx")
        XCTAssertEqual(entry?["args"] as? [String], ["-y", "server"])
        XCTAssertEqual((entry?["env"] as? [String: String])?["TOKEN"], "abc#not-a-comment")
    }

    func testTOMLDisabledWithCommentStaysDropped() {
        let toml = """
        [mcp_servers.off]
        command = "x"
        enabled = false  # switched off on purpose
        """
        XCTAssertNil(MCPServersTOML.servers(fromTOML: toml)["off"])
    }

    func testTOMLMultiLineArraySurvivesBracketInComment() {
        // A `]` inside a comment used to flush the array accumulator early.
        let toml = """
        [mcp_servers.multi]
        command = "npx"
        args = [
            "-y",  # first element ]
            "pkg",
        ]
        enabled = true
        """
        XCTAssertEqual(
            MCPServersTOML.servers(fromTOML: toml)["multi"]?["args"] as? [String],
            ["-y", "pkg"]
        )
    }

    func testGrokDiscoveryEndToEnd() {
        // The parsed entries must flow through the shared ConfigDiscovery pipeline.
        let servers = ConfigDiscovery.configs(
            from: MCPServersTOML.shapeEntries(grokSample)!, source: .grok, idPrefix: "grok")
        let byName = Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0) })
        XCTAssertEqual(byName["pieces"]?.transport, .http)
        XCTAssertEqual(byName["skill-librarian"]?.transport, .stdio)
        XCTAssertEqual(byName["skill-librarian"]?.source, .grok)
        XCTAssertEqual(byName["skill-librarian"]?.commandLine,
                       "/opt/py/bin/python /opt/the_librarian/server.py")
    }

    // MARK: - Goose / YAML

    private let gooseSample = """
    extensions:
      xcodebuildmcp:
        enabled: true
        type: stdio
        name: xcodebuildmcp
        description: Apple platform build/test/run/debug via XcodeBuildMCP - iOS/macOS
          build, test, simulator + device run, log capture, and UI automation.
        cmd: xcodebuildmcp
        args:
        - mcp
        envs: {}
        timeout: 300
        bundled: null
      notes_vault:
        enabled: true
        type: stdio
        name: notes-vault
        description: Reads and writes vault markdown
          directly on disk.
        cmd: /opt/py/bin/python
        args:
        - -u
        - /opt/notes-vault/server.py
        envs:
          VAULT_VAULT_PATH: /Users/k/Vault
          VAULT_READ_ONLY: 'false'
        timeout: 300
      pieces:
        enabled: true
        type: stdio
        name: Pieces
        description: Long-term memory.
        cmd: uvx
        args:
        - --from
        - pieces-cli
        - pieces
        - mcp
        - start
        envs: {}
      supabase:
        enabled: false
        type: streamable_http
        name: Supabase
        uri: https://mcp.supabase.com/mcp
        envs: {}
      dev_to:
        enabled: true
        type: streamable_http
        name: Dev.to
        uri: http://localhost:3000/mcp
        envs: {}
      reed_md:
        enabled: true
        type: streamable_http
        name: reed-md
        uri: http://127.0.0.1:8742/mcp
        headers:
          Authorization: Bearer abc123def456
          X-Trace-Url: https://example.com:8443/t
        envs: {}
        env_keys: []
        timeout: 300
        description: reed.md notes app MCP
      todo:
        enabled: true
        type: platform
        name: todo
        display_name: Todo
        bundled: true
      memory:
        enabled: true
        type: builtin
        name: memory
        display_name: Memory
        timeout: 300
      playwright:
        enabled: true
        type: stdio
        name: Playwright
        cmd: npx
        args:
        - '@playwright/mcp@latest'
        envs: {}
    GOOSE_TELEMETRY_ENABLED: false
    providers:
      ollama:
        enabled: true
    """

    func testGooseParsesStdioServerUsingItsKey() {
        let servers = GooseConfig.servers(fromYAML: gooseSample)
        // Keyed by the YAML key, not the `name:` title (`notes-vault`); the two
        // spellings still group, `HealthMonitor.normalizedName` drops separators.
        let ko = servers["notes_vault"]
        XCTAssertNotNil(ko)
        XCTAssertNil(servers["notes-vault"])
        XCTAssertEqual(ko?["command"] as? String, "/opt/py/bin/python")
        XCTAssertEqual(ko?["args"] as? [String], ["-u", "/opt/notes-vault/server.py"])
        let env = ko?["env"] as? [String: String]
        XCTAssertEqual(env?["VAULT_VAULT_PATH"], "/Users/k/Vault")
        XCTAssertEqual(env?["VAULT_READ_ONLY"], "false", "quoted YAML scalar must be unquoted")
    }

    func testGooseParsesSingleItemArgList() {
        let servers = GooseConfig.servers(fromYAML: gooseSample)
        XCTAssertEqual(servers["xcodebuildmcp"]?["args"] as? [String], ["mcp"])
    }

    func testGooseParsesQuotedArgItem() {
        let servers = GooseConfig.servers(fromYAML: gooseSample)
        XCTAssertEqual(servers["playwright"]?["args"] as? [String], ["@playwright/mcp@latest"])
    }

    /// Regression: `headers:` used to fall into the catch-all `default:` branch and be
    /// skipped along with its children, so authenticated Goose HTTP extensions probed
    /// with no Authorization header and reported a false 401 (reed.md, 2026-08-03).
    func testGooseParsesHeadersForHTTPExtension() {
        let servers = GooseConfig.servers(fromYAML: gooseSample)
        let reed = servers["reed_md"]
        XCTAssertNotNil(reed)
        XCTAssertEqual(reed?["url"] as? String, "http://127.0.0.1:8742/mcp")
        XCTAssertEqual(reed?["type"] as? String, "http")
        let headers = reed?["headers"] as? [String: String]
        XCTAssertEqual(headers?["Authorization"], "Bearer abc123def456",
                       "auth header must survive parsing or the probe 401s")
    }

    /// Header values legitimately contain colons — split on the first one only.
    func testGooseHeaderValueKeepsEmbeddedColons() {
        let servers = GooseConfig.servers(fromYAML: gooseSample)
        let headers = servers["reed_md"]?["headers"] as? [String: String]
        XCTAssertEqual(headers?["X-Trace-Url"], "https://example.com:8443/t")
    }

    /// stdio extensions have no headers; parsing must not invent an empty map.
    func testGooseStdioExtensionHasNoHeaders() {
        let servers = GooseConfig.servers(fromYAML: gooseSample)
        XCTAssertNil(servers["notes_vault"]?["headers"])
    }

    /// An HTTP extension without a `headers:` block stays header-free.
    func testGooseHTTPExtensionWithoutHeadersOmitsKey() {
        let servers = GooseConfig.servers(fromYAML: gooseSample)
        XCTAssertNotNil(servers["dev_to"])
        XCTAssertNil(servers["dev_to"]?["headers"])
    }

    func testGooseParsesHTTPServer() {
        let servers = GooseConfig.servers(fromYAML: gooseSample)
        XCTAssertEqual(servers["dev_to"]?["url"] as? String, "http://localhost:3000/mcp")
        XCTAssertEqual(servers["dev_to"]?["type"] as? String, "http")
    }

    func testGooseSkipsPlatformAndBuiltinTypes() {
        let servers = GooseConfig.servers(fromYAML: gooseSample)
        XCTAssertNil(servers["todo"], "type: platform is a Goose built-in, not an MCP subprocess")
        XCTAssertNil(servers["memory"], "type: builtin is internal")
    }

    func testGooseSkipsDisabledServer() {
        let servers = GooseConfig.servers(fromYAML: gooseSample)
        XCTAssertNil(servers["supabase"], "enabled: false servers must be dropped")
    }

    func testGooseIgnoresContentOutsideExtensionsBlock() {
        let servers = GooseConfig.servers(fromYAML: gooseSample)
        XCTAssertNil(servers["providers"])
        XCTAssertNil(servers["ollama"])
        XCTAssertEqual(Set(servers.keys),
                       ["xcodebuildmcp", "notes_vault", "pieces", "dev_to", "reed_md", "playwright"])
    }

    func testGooseDiscoveryEndToEnd() {
        let servers = ConfigDiscovery.configs(
            from: GooseConfig.shapeEntries(gooseSample)!, source: .goose, idPrefix: "goose")
        let byName = Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0) })
        XCTAssertEqual(byName["pieces"]?.transport, .stdio)
        XCTAssertEqual(byName["pieces"]?.source, .goose)
        XCTAssertEqual(byName["pieces"]?.commandLine, "uvx --from pieces-cli pieces mcp start")
        XCTAssertEqual(byName["dev_to"]?.transport, .http)
    }

    /// Round 5: Goose's `name:` is a display title. Wake declared as `wake:` with
    /// `name: Wake (agent session history)` must be the server `wake`, and group
    /// with the `wake` every other agent declares.
    func testGooseKeyNotDisplayNameIsTheServerName() {
        let yaml = """
        extensions:
          wake:
            enabled: true
            type: stdio
            name: Wake (agent session history)
            description: 'Read-only search: every coding-agent session on this Mac.'
            cmd: /Applications/Wake.app/Contents/MacOS/wake-mcp
            args: []
            envs: {}
          extensionmanager:
            enabled: true
            type: stdio
            name: Extension Manager
            cmd: em
            args: []
        """
        let servers = GooseConfig.servers(fromYAML: yaml)
        XCTAssertEqual(Set(servers.keys), ["wake", "extensionmanager"])
        XCTAssertNil(servers["Wake (agent session history)"])
        XCTAssertEqual(servers["wake"]?["command"] as? String, "/Applications/Wake.app/Contents/MacOS/wake-mcp")

        let goose = ConfigDiscovery.configs(from: GooseConfig.shapeEntries(yaml)!, source: .goose, idPrefix: "goose")
        let cursor = ConfigDiscovery.configs(
            from: [DiscoveredEntry(name: "wake", entry: ["command": "/Applications/Wake.app/Contents/MacOS/wake-mcp"])],
            source: .cursor, idPrefix: "cursor")
        let groups = HealthMonitor.groupByName((goose + cursor).map { ServerSnapshot(config: $0) })
        let wake = groups.first { HealthMonitor.normalizedName($0.name) == "wake" }
        XCTAssertEqual(wake?.sourceLabels.count, 2, "Goose's wake groups with Cursor's")
        XCTAssertEqual(groups.count, 2, "wake + extensionmanager, no separate display-name row")
    }

    /// Hermes keys its `mcp_servers:` entries the same way: the key is the name,
    /// and a `name:` field inside an entry never renames it.
    func testHermesKeyIsTheServerName() {
        let yaml = """
        mcp_servers:
          wake:
            name: Wake (agent session history)
            command: /Applications/Wake.app/Contents/MacOS/wake-mcp
        """
        XCTAssertEqual(Set(MCPServersYAML.servers(fromYAML: yaml).keys), ["wake"])
    }

    // MARK: - Hermes / YAML `mcp_servers:`

    /// Hermes writes the JSON field names in YAML, with list items indented one level
    /// deeper than their key (unlike Goose, which writes them level with it).
    private let hermesSample = """
    model:
      default: some-model
    mcp_servers:
      firecrawl:
        command: /Users/k/.local/bin/firecrawl-mcp
        args: []
        env:
          FIRECRAWL_API_URL: https://firecrawl.example.com
          FIRECRAWL_API_KEY: fc-secret
      desktop-commander:
        args:
          - -y
          - '@wonderwhy-er/desktop-commander@latest'
        command: npx
      reed-md:
        headers:
          Authorization: Bearer abc:def
        type: http
        url: http://127.0.0.1:8742/mcp
      shared-agent-memory:
        args: []
        command: /Users/k/run-memory-mcp.sh
        connect_timeout: 60
        timeout: 120
      working-agents:
        args:
          - mcp
        command: /Users/k/.local/bin/agent-session
        enabled: false
    platform_toolsets:
      cli:
        - browser
    """

    func testHermesParsesStdioServerWithEnv() {
        let servers = MCPServersYAML.servers(fromYAML: hermesSample)
        let fc = servers["firecrawl"]
        XCTAssertEqual(fc?["command"] as? String, "/Users/k/.local/bin/firecrawl-mcp")
        XCTAssertEqual(fc?["args"] as? [String], [])
        XCTAssertEqual((fc?["env"] as? [String: String])?["FIRECRAWL_API_URL"], "https://firecrawl.example.com")
    }

    func testHermesParsesIndentedArgListRegardlessOfKeyOrder() {
        let servers = MCPServersYAML.servers(fromYAML: hermesSample)
        XCTAssertEqual(servers["desktop-commander"]?["command"] as? String, "npx")
        XCTAssertEqual(servers["desktop-commander"]?["args"] as? [String],
                       ["-y", "@wonderwhy-er/desktop-commander@latest"])
    }

    func testHermesParsesHTTPServerWithHeaders() {
        let servers = MCPServersYAML.servers(fromYAML: hermesSample)
        let reed = servers["reed-md"]
        XCTAssertEqual(reed?["url"] as? String, "http://127.0.0.1:8742/mcp")
        XCTAssertEqual(reed?["type"] as? String, "http")
        XCTAssertEqual((reed?["headers"] as? [String: String])?["Authorization"], "Bearer abc:def",
                       "header values keep their embedded colons")
    }

    func testHermesIgnoresUnknownFieldsAndOtherBlocks() {
        let servers = MCPServersYAML.servers(fromYAML: hermesSample)
        XCTAssertNotNil(servers["shared-agent-memory"])
        XCTAssertNil(servers["shared-agent-memory"]?["timeout"])
        XCTAssertNil(servers["cli"])
        XCTAssertNil(servers["default"])
    }

    func testHermesSkipsDisabledServer() {
        XCTAssertNil(MCPServersYAML.servers(fromYAML: hermesSample)["working-agents"])
    }

    func testHermesDiscoveryEndToEnd() {
        let servers = ConfigDiscovery.configs(
            from: MCPServersYAML.shapeEntries(hermesSample)!, source: ServerSource(label: "Hermes"), idPrefix: "hermes")
        let byName = Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0) })
        XCTAssertEqual(byName["reed-md"]?.transport, .http)
        XCTAssertEqual(byName["reed-md"]?.headers["Authorization"], "Bearer abc:def")
        XCTAssertEqual(byName["desktop-commander"]?.commandLine, "npx -y @wonderwhy-er/desktop-commander@latest")
        XCTAssertNil(byName["working-agents"])
    }

    /// The Goose shape and the Hermes shape must not claim each other's files.
    func testYAMLShapesAreMutuallyExclusive() {
        XCTAssertNil(MCPServersYAML.shapeEntries(gooseSample))
        XCTAssertNil(GooseConfig.shapeEntries(hermesSample))
    }
}
