import XCTest
@testable import mcpock

final class ConfigDiscoveryTests: XCTestCase {
    private var home: URL!
    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcpock-home-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }
    private func write(_ rel: String, _ s: String) throws {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A scanned file inside a registry agent's own directory carries that agent's
    /// label — Hermes's per-profile configs are "Hermes · scribe", not "scribe".
    func testScannedFileUnderKnownAgentDirectoryInheritsItsLabel() {
        let home = NSHomeDirectory()
        let registry = [
            KnownAgent(label: "Hermes", path: home + "/.hermes/config.yaml", shape: .mcpServersYAML),
            KnownAgent(label: "Code", path: home + "/.claude.json", shape: .json),
        ]
        XCTAssertEqual(
            ConfigDiscovery.label(forScannedPath: home + "/.hermes/profiles/scribe/config.yaml", derived: "scribe", registry: registry),
            "Hermes · scribe")
        XCTAssertEqual(
            ConfigDiscovery.label(forScannedPath: home + "/.claude/mcp.json", derived: "claude", registry: registry),
            "claude", "a registry file directly in ~ must not claim every dotdir")
        XCTAssertEqual(
            ConfigDiscovery.label(forScannedPath: home + "/.hermesx/config.yaml", derived: "hermesx", registry: registry),
            "hermesx", "prefix match is on the directory, not the string")
    }

    /// `~/.claude/.mcp.json` showed up as an agent called "claude". A `.mcp.json`
    /// is Claude Code's project file: it belongs to Claude Code, with its folder
    /// as the project, so it reads "Claude Code (.claude)".
    func testScannedDotMCPJSONIsClaudeCodeProjectConfig() throws {
        try write(".claude/.mcp.json", #"{"mcpServers":{"cbm":{"command":"c"}}}"#)
        let configs = ConfigDiscovery.discover(registry: [], scanRoots: [home.appendingPathComponent(".claude").path])
        let cbm = try XCTUnwrap(configs.first { $0.name == "cbm" })
        XCTAssertEqual(cbm.source.label, "Code")
        let folder = ConfigScanner.canonicalPath(home.appendingPathComponent(".claude").path)
        XCTAssertEqual(cbm.projectPath, folder)
        XCTAssertEqual(cbm.displaySource, "Code (.claude)")
        XCTAssertEqual(AgentBadge.displayLabel(cbm.displaySource), "Claude Code (.claude)")
        XCTAssertEqual(AgentBadge.forLabel(cbm.source.label).monogram, "CC")

        XCTAssertNil(ConfigDiscovery.claudeProjectFolder(forScannedPath: "/x/.cursor/mcp.json"))
    }

    func testDiscoverMergesRegistryAndScanAndDedups() throws {
        // A registry-style file (Cursor) and a scanned unknown agent, plus a dup.
        try write(".cursor/mcp.json", #"{"mcpServers":{"cur":{"command":"c"}}}"#)
        try write(".config/newagent/mcp.json", #"{"mcpServers":{"na":{"command":"n"}}}"#)

        let registry = [KnownAgent(label: "Cursor", path: home.appendingPathComponent(".cursor/mcp.json").path, shape: .json)]
        let roots = [home.appendingPathComponent(".config").path, home.appendingPathComponent(".cursor").path]
        let configs = ConfigDiscovery.discover(registry: registry, scanRoots: roots)

        let byName = Dictionary(grouping: configs, by: { $0.name })
        XCTAssertEqual(byName["cur"]?.count, 1, "registry+scan must not double-count the same file")
        XCTAssertEqual(byName["cur"]?.first?.source.label, "Cursor", "registry label wins over derived")
        XCTAssertEqual(byName["na"]?.first?.source.label, "newagent")
    }

    /// v1.5's detail card lists each source's config file ("Used by"), so every
    /// discovered source carries the path it was read from: the registry path for
    /// registry agents, the scanned file's canonical path for everything else.
    func testDiscoveredSourcesCarryTheirConfigPath() throws {
        try write(".cursor/mcp.json", #"{"mcpServers":{"cur":{"command":"c"}}}"#)
        try write(".config/newagent/mcp.json", #"{"mcpServers":{"na":{"command":"n"}}}"#)

        let cursorPath = home.appendingPathComponent(".cursor/mcp.json").path
        let registry = [KnownAgent(label: "Cursor", path: cursorPath, shape: .json)]
        let configs = ConfigDiscovery.discover(registry: registry, scanRoots: [home.appendingPathComponent(".config").path])

        let byName = Dictionary(grouping: configs, by: { $0.name })
        XCTAssertEqual(byName["cur"]?.first?.source.path, cursorPath)
        let scanned = try XCTUnwrap(byName["na"]?.first?.source.path)
        XCTAssertEqual(scanned, ConfigScanner.canonicalPath(home.appendingPathComponent(".config/newagent/mcp.json").path))
        XCTAssertFalse(scanned.isEmpty)
    }

    /// Round 6: a Claude Code project entry whose folder is gone (xapi under the
    /// archived WeeklyContentCalendar) is skipped at discovery, so it can't show
    /// as "Could not start: The file WeeklyContentCalendar doesn't exist". The same
    /// server elsewhere only loses that source; global entries always stay.
    func testProjectEntriesWithAMissingFolderAreSkipped() throws {
        let live = home.appendingPathComponent("Projects/LiveApp")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let gone = home.appendingPathComponent("Projects/WeeklyContentCalendar").path
        let json = """
        {"mcpServers": {"xapi": {"command": "/usr/local/bin/xurl"}},
         "projects": {
           "\(gone)": {"mcpServers": {"xapi": {"command": "/usr/local/bin/xurl"}, "only-old": {"command": "o"}}},
           "\(live.path)": {"mcpServers": {"xapi": {"command": "/usr/local/bin/xurl"}, "live-only": {"command": "l"}}}
         }}
        """
        try write(".claude.json", json)
        let registry = [KnownAgent(label: "Code", path: home.appendingPathComponent(".claude.json").path, shape: .json)]
        let configs = ConfigDiscovery.discover(registry: registry, scanRoots: [])

        XCTAssertNil(configs.first { $0.name == "only-old" }, "a server only in the missing project is gone")
        XCTAssertNotNil(configs.first { $0.name == "live-only" }, "an existing project's server stays")
        let xapi = configs.filter { $0.name == "xapi" }
        XCTAssertEqual(Set(xapi.map { $0.projectPath ?? "global" }), ["global", live.path],
                       "xapi keeps its global and live-project sources, only the stale one is dropped")

        let entries = [
            DiscoveredEntry(name: "a", entry: ["command": "a"]),
            DiscoveredEntry(name: "b", entry: ["command": "b"], projectPath: "/nope"),
            DiscoveredEntry(name: "c", entry: ["command": "c"], projectPath: "/yes"),
        ]
        XCTAssertEqual(ConfigDiscovery.droppingStaleProjects(entries, folderExists: { $0 == "/yes" }).map(\.name),
                       ["a", "c"])
        XCTAssertFalse(ConfigDiscovery.isExistingFolder(gone))
        XCTAssertTrue(ConfigDiscovery.isExistingFolder(live.path))
        XCTAssertFalse(ConfigDiscovery.isExistingFolder(home.appendingPathComponent(".claude.json").path),
                       "a file is not a project folder")
    }
}
