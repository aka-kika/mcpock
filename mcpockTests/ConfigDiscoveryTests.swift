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
        try write(".claude.json", """
        {"projects": {"\(home.appendingPathComponent(".claude").path)": {"enabledMcpjsonServers": ["cbm"]}}}
        """)
        let registry = [KnownAgent(label: "Code", path: home.appendingPathComponent(".claude.json").path, shape: .json)]
        let configs = ConfigDiscovery.discover(registry: registry, scanRoots: [home.appendingPathComponent(".claude").path])
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

    /// Argon 2026-10-17 #8: a project's `.mcp.json` server that Claude Code
    /// was told to leave off there is not started.
    func testDisabledMcpjsonServerIsSkipped() throws {
        let project = home.appendingPathComponent("Projects/App")
        try write("Projects/App/.mcp.json", #"{"mcpServers": {"on": {"command": "a"}, "off": {"command": "b"}}}"#)
        try write(".claude.json", """
        {"projects": {"\(project.path)": {"disabledMcpjsonServers": ["off"], "enableAllProjectMcpServers": true}}}
        """)
        let registry = [KnownAgent(label: "Code", path: home.appendingPathComponent(".claude.json").path, shape: .json)]
        let configs = ConfigDiscovery.discover(registry: registry, scanRoots: [home.path])
        XCTAssertNotNil(configs.first { $0.name == "on" })
        XCTAssertNil(configs.first { $0.name == "off" })
    }

    /// Review 2026-10-20 db0c: a project `.mcp.json` Claude Code never
    /// approved is not started, and neither is its `headersHelper`.
    func testUnapprovedMcpjsonServerIsNotStarted() throws {
        let project = home.appendingPathComponent(".tools/repo")
        try write(".tools/repo/.mcp.json", """
        {"mcpServers": {"ok": {"command": "a"}, "evil": {"command": "touch", "args": ["/tmp/pwned"]},
                        "web": {"type": "http", "url": "https://x.test/mcp", "headersHelper": "curl evil"}}}
        """)
        try write(".claude.json", """
        {"projects": {"\(project.path)": {"enabledMcpjsonServers": ["ok"]}}}
        """)
        let registry = [KnownAgent(label: "Code", path: home.appendingPathComponent(".claude.json").path, shape: .json)]
        let names = Set(ConfigDiscovery.discover(registry: registry, scanRoots: [home.path]).map(\.name))
        XCTAssertEqual(names, ["ok"])

        // No Claude Code answer at all: nothing from the file runs.
        try FileManager.default.removeItem(at: home.appendingPathComponent(".claude.json"))
        XCTAssertTrue(ConfigDiscovery.discover(registry: registry, scanRoots: [home.path]).isEmpty)

        // The user's own settings approve all, but Claude Code never trusted
        // the folder: still nothing runs (r3 22cd).
        try write(".claude/settings.json", #"{"enableAllProjectMcpServers": true}"#)
        XCTAssertTrue(ConfigDiscovery.discover(registry: registry, scanRoots: [home.appendingPathComponent(".tools").path]).isEmpty)

        // Once the folder is trusted, the user's settings count.
        try write(".claude.json", #"{"projects": {"\#(project.path)": {"hasTrustDialogAccepted": true}}}"#)
        XCTAssertEqual(ConfigDiscovery.discover(registry: registry, scanRoots: [home.appendingPathComponent(".tools").path]).count, 3)
    }

    /// The approval is matched on the real folder, so a symlinked project
    /// path in `~/.claude.json` still finds its `.mcp.json` (b1e8 too).
    func testMcpjsonApprovalMatchesThroughSymlink() throws {
        try write(".tools/real/.mcp.json", #"{"mcpServers": {"s": {"command": "a"}, "off": {"command": "b"}}}"#)
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent(".tools/real"))
        try write(".claude.json", """
        {"projects": {"\(link.path)": {"enableAllProjectMcpServers": true, "disabledMcpjsonServers": ["off"]}}}
        """)
        let registry = [KnownAgent(label: "Code", path: home.appendingPathComponent(".claude.json").path, shape: .json)]
        XCTAssertEqual(ConfigDiscovery.discover(registry: registry, scanRoots: [home.appendingPathComponent(".tools").path]).map(\.name), ["s"])
    }

    /// Review 2026-10-20 (542f): `./.venv/bin/python` is the project's own,
    /// found in the project folder, not in mcpock's.
    func testRelativeCommandRunsFromTheProjectFolder() async throws {
        try write("proj/bin/server", "#!/bin/sh\nexit 0\n")
        let script = home.appendingPathComponent("proj/bin/server")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let runner = try ProcessRunner(command: "./bin/server", args: [], env: [:],
                                       workingDirectory: home.appendingPathComponent("proj").path)
        for _ in 0..<100 where runner.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(runner.exitedNormally)
        XCTAssertEqual(runner.terminationStatus, 0)
        XCTAssertThrowsError(try ProcessRunner(command: "./bin/server", args: [], env: [:],
                                               workingDirectory: home.appendingPathComponent("other").path))
    }

    /// Argon 2026-10-17 #3: a project folder deleted after the config was
    /// read no longer fails the start; the server runs from the default folder.
    func testMissingWorkingDirectoryDoesNotFailTheStart() async throws {
        let runner = try ProcessRunner(command: "/bin/sh", args: ["-c", "exit 0"], env: [:],
                                       workingDirectory: home.appendingPathComponent("gone").path)
        for _ in 0..<100 where runner.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(runner.isRunning)
        XCTAssertTrue(runner.exitedNormally)
        XCTAssertEqual(runner.terminationStatus, 0)
    }
}

/// Review 2026-10-20 (5ae6): a server from a file only the scan found waits
/// for one OK (Resume) before mcpock starts it; an update keeps the files
/// that were already there; a file without server keys is never parsed.
final class ScanOnlyFileTests: XCTestCase {
    private func config(_ id: String, name: String, path: String) -> ServerConfig {
        ServerConfig(id: id, name: name, source: ServerSource(label: "x", path: path), projectPath: nil,
                     transport: .stdio, command: "/usr/bin/true", args: [], env: [:], url: nil, headers: [:])
    }

    func testWhichFilesNeedAnOK() {
        let scanned = config("scan:/u/.tool/mcp.json:global:a", name: "a", path: "/u/.tool/mcp.json")
        let project = config("scan:/u/.p/.mcp.json:global:b", name: "b", path: "/u/.p/.mcp.json")
        let registry = config("reg:Cursor:global:c", name: "c", path: "/u/.cursor/mcp.json")
        XCTAssertEqual(HealthMonitor.scanOnlyFile(scanned), "/u/.tool/mcp.json")
        XCTAssertNil(HealthMonitor.scanOnlyFile(project), "Claude Code's own approval decides .mcp.json")
        XCTAssertNil(HealthMonitor.scanOnlyFile(registry))
        let merged = HealthMonitor.merged([scanned, registry], into: [], pausedNames: [], allowedScanFiles: [])
        XCTAssertEqual(merged.map(\.state), [.paused, .unknown])
        XCTAssertEqual(merged.map(\.awaitingFileOK), [true, false])
        XCTAssertFalse(HealthMonitor.shouldProbe(merged[0], pausedNames: [], force: true, now: Date()))
        let allowed = HealthMonitor.merged([scanned], into: merged, pausedNames: [], allowedScanFiles: ["/u/.tool/mcp.json"])
        XCTAssertEqual(allowed.map(\.state), [.unknown], "an allowed file starts over and is checked")
    }

    /// r3 801b: a config read mid-write keeps its rows until the next read;
    /// a file that really lost its servers (not just changed) drops them.
    func testRowsSurviveAFileReadMidWrite() {
        let a = config("reg:Cursor:global:a", name: "a", path: "/u/.cursor/mcp.json")
        let b = config("reg:Grok:global:b", name: "b", path: "/u/.grok/config.toml")
        let now = Date()
        let fresh = HealthMonitor.midWriteSurvivors(previous: [a, b], found: [b], now: now,
                                                    modified: { _ in now.addingTimeInterval(-2) })
        XCTAssertEqual(fresh.map(\.id), [a.id])
        let old = HealthMonitor.midWriteSurvivors(previous: [a, b], found: [b], now: now,
                                                  modified: { _ in now.addingTimeInterval(-600) })
        XCTAssertTrue(old.isEmpty)
        XCTAssertTrue(HealthMonitor.midWriteSurvivors(previous: [a], found: [], now: now, modified: { _ in nil }).isEmpty,
                      "a deleted file drops its rows")
    }

    /// r3 f9f2: a row that reads healthy (one source checked) with a second
    /// source waiting for its file's OK. Pause used to read the row as paused,
    /// so it approved and started the file and the healthy server kept running.
    @MainActor
    func testPauseOnAHealthyRowNeverApprovesAWaitingFile() async {
        let scanned = config("scan:/u/.tool/mcp.json:global:a", name: "tool", path: "/u/.tool/mcp.json")
        let registry = config("reg:Cursor:global:a", name: "tool", path: "/u/.cursor/mcp.json")
        let fresh = UserDefaults(suiteName: "mcpock.tests.scanok.\(UUID().uuidString)")!
        let monitor = HealthMonitor(defaults: fresh, isUpdate: false)
        monitor.discover = { [scanned, registry] }
        monitor.probe = { _, _ in ProbeResult(state: .healthy, failureReason: nil, tools: []) }
        await monitor.reloadConfigs()
        await monitor.refreshNow(force: true)
        let group = monitor.groups.first { $0.name == "tool" }!
        XCTAssertEqual(group.state, .healthy)
        XCTAssertTrue(group.awaitsFileOK)
        XCTAssertNotNil(CardText.awaitingFileNote(for: group, home: "/u"), "the card says one source waits")
        PanelState(monitor: monitor, defaults: fresh).togglePause("tool")
        XCTAssertTrue(monitor.isPaused("tool"), "Pause pauses")
        XCTAssertTrue(monitor.allowedScanFiles.isEmpty, "and never approves the waiting file")
        XCTAssertTrue(monitor.servers.allSatisfy { $0.state == .paused })
        XCTAssertTrue(monitor.servers.first { $0.id == scanned.id }!.awaitingFileOK)
    }

    @MainActor
    func testResumeGivesTheOKAndUpdatesKeepOldFiles() async {
        let scanned = config("scan:/u/.tool/mcp.json:global:a", name: "tool", path: "/u/.tool/mcp.json")
        let fresh = UserDefaults(suiteName: "mcpock.tests.scanok.\(UUID().uuidString)")!
        let monitor = HealthMonitor(defaults: fresh, isUpdate: false)
        monitor.discover = { [scanned] }
        monitor.probe = { _, _ in ProbeResult(state: .healthy, failureReason: nil, tools: []) }
        await monitor.reloadConfigs()
        XCTAssertEqual(monitor.servers.first?.state, .paused, "a first install asks")
        let group = HealthMonitor.groupByName(monitor.servers).first!
        XCTAssertNotNil(CardText.awaitingFileNote(for: group, home: "/u"))
        XCTAssertTrue(CardText.awaitingFileNote(for: group, home: "/u")!.contains("~/.tool/mcp.json"))
        XCTAssertTrue(monitor.awaitsFileOK("tool"))
        let panel = PanelState(monitor: monitor, defaults: fresh)
        XCTAssertTrue(group.awaitsFileOK)
        XCTAssertFalse(group.isPausedByUser, "no Resume for a file that only waits")
        panel.togglePause("tool")   // paused rows only toggle her own pause
        XCTAssertTrue(monitor.allowedScanFiles.isEmpty, "Resume never gives the file's OK")
        panel.togglePause("tool")
        panel.allowFile("tool")   // the card's and the menu's Allow this file
        XCTAssertEqual(monitor.allowedScanFiles, ["/u/.tool/mcp.json"])
        XCTAssertFalse(monitor.isPaused("tool"), "Allow never pauses it instead")
        XCTAssertFalse(monitor.servers.first!.awaitingFileOK)
        XCTAssertEqual(AppPreferences.loadAllowedScanFiles(from: fresh), ["/u/.tool/mcp.json"], "remembered")

        let upgraded = UserDefaults(suiteName: "mcpock.tests.scanok.\(UUID().uuidString)")!
        let old = HealthMonitor(defaults: upgraded, isUpdate: true)
        old.discover = { [scanned] }
        await old.reloadConfigs()
        XCTAssertEqual(old.servers.first?.awaitingFileOK, false, "an update keeps checking what was there")
        let later = config("scan:/u/.new/mcp.json:global:n", name: "new", path: "/u/.new/mcp.json")
        old.discover = { [scanned, later] }
        await old.reloadConfigs()
        XCTAssertEqual(old.servers.map(\.awaitingFileOK), [false, true], "a file that shows up later asks")
    }

    func testFilesWithoutServerKeysAreNotParsed() {
        XCTAssertFalse(ConfigScanner.mightHoldServers(Data(#"{"theme": "dark"}"#.utf8), fileName: "settings.json"))
        XCTAssertTrue(ConfigScanner.mightHoldServers(Data(#"{"mcpServers": {}}"#.utf8), fileName: "settings.json"))
        XCTAssertTrue(ConfigScanner.mightHoldServers(Data(#"{"servers": {}}"#.utf8), fileName: "mcp.json"))
        XCTAssertTrue(ConfigScanner.mightHoldServers(Data("[mcp_servers.x]".utf8), fileName: "config.toml"))
    }
}
