import XCTest
@testable import mcpock

/// The review of 22 Nov (two read-only reviews of 1.18.0 before release):
/// one test per finding that could lose a config, a file or a hidden tool.
/// Each failed before its fix.
final class ReviewNov22Tests: XCTestCase {
    private var home: URL!
    private var backups: URL { home.appendingPathComponent("backups") }
    private var parked: URL { home.appendingPathComponent("parked") }
    private var filters: URL { home.appendingPathComponent("filter") }
    private let helper = "/Applications/mcpock.app/Contents/Helpers/mcpock-mcp"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        ParsedFileCache.removeAll()
    }

    private func path(_ rel: String) -> String { home.appendingPathComponent(rel).path }

    private func put(_ rel: String, _ text: String) throws {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func text(_ rel: String) -> String? { try? String(contentsOfFile: path(rel), encoding: .utf8) }

    private func filteredEntry(command: String, hideFile: String) -> String {
        "{\n  \"mcpServers\": {\n    \"github\": {\n      \"command\": \"\(command)\",\n      \"args\": [\"filter\", \"--hide-file\", \"\(hideFile)\", \"--\", \"npx\", \"server-github\"]\n    }\n  }\n}\n"
    }

    // MARK: F1: a hide-file path from a config is never written

    /// A cloned project's `.cursor/mcp.json` names `~/.zshrc` as its hide
    /// file. Hiding a tool must not write there: the entry is not a filter.
    func testAHideFilePathFromAScannedFileIsNeverTrusted() throws {
        try put("zshrc", "export PATH=/usr/bin\n")
        try put("project/.cursor/mcp.json", filteredEntry(command: helper, hideFile: path("zshrc")))
        ParsedFileCache.removeAll()
        let configs = ConfigDiscovery.discover(registry: [], scanRoots: [], knownScanFiles: [path("project/.cursor/mcp.json")],
                                               parkedDirectory: parked)
        let config = try XCTUnwrap(configs.first { $0.name == "github" })
        XCTAssertNil(config.filterFile, "a scanned file is never read as filtered")
        XCTAssertNil(ToolPlanner.mechanism(for: config))
        let plan = ToolPlanner.plan(server: "github", configs: [config], hide: ["search_code"], show: [], allTools: ["search_code"],
                                    claudeSettingsPath: path(".claude/settings.json"))
        XCTAssertTrue(plan.changes.isEmpty)
        XCTAssertEqual(text("zshrc"), "export PATH=/usr/bin\n")
    }

    /// In an agent's own file too: a hide file outside mcpock's folder is not a filter.
    func testAHideFileOutsideMcpocksFolderIsNotAFilter() throws {
        try put("zshrc", "export PATH=/usr/bin\n")
        try put(".cursor/mcp.json", filteredEntry(command: helper, hideFile: path("zshrc")))
        ParsedFileCache.removeAll()
        let configs = ConfigDiscovery.discover(registry: [KnownAgent(label: "Cursor", path: path(".cursor/mcp.json"), shape: .json)],
                                               scanRoots: [], parkedDirectory: parked)
        let config = try XCTUnwrap(configs.first)
        XCTAssertNil(config.filterFile)
        XCTAssertEqual(config.command, helper, "shown as written, not as the command inside")
    }

    // MARK: F5: only mcpock's own helper is unwrapped

    func testAnotherProgramNamedLikeTheHelperIsShownAsWritten() throws {
        let inside = ToolFilter.defaultDirectory.appendingPathComponent("cursor--github.json").path
        try put(".cursor/mcp.json", filteredEntry(command: "./tools/mcpock-mcp", hideFile: inside))
        ParsedFileCache.removeAll()
        let configs = ConfigDiscovery.discover(registry: [KnownAgent(label: "Cursor", path: path(".cursor/mcp.json"), shape: .json)],
                                               scanRoots: [], parkedDirectory: parked)
        let config = try XCTUnwrap(configs.first)
        XCTAssertEqual(config.command, "./tools/mcpock-mcp", "the agent runs this, so mcpock shows and checks this")
        XCTAssertNil(config.filterFile)
    }

    // MARK: F2: no Set up from a disk image

    func testSetUpIsRefusedWhileMcpockRunsFromADiskImage() throws {
        try put(".cursor/mcp.json", "{\n  \"mcpServers\": {\n    \"github\": {\n      \"command\": \"npx\",\n      \"args\": [\"server-github\"]\n    }\n  }\n}\n")
        ParsedFileCache.removeAll()
        let configs = ConfigDiscovery.discover(registry: [KnownAgent(label: "Cursor", path: path(".cursor/mcp.json"), shape: .json)],
                                               scanRoots: [], parkedDirectory: parked)
        for temporary in ["/Volumes/mcpock/mcpock.app/Contents/Helpers/mcpock-mcp",
                          "/private/var/folders/x/AppTranslocation/ABC/d/mcpock.app/Contents/Helpers/mcpock-mcp"] {
            let plan = FilterPlanner.plan(server: "github", configs: configs, setUp: true, helper: temporary, directory: filters)
            XCTAssertTrue(plan.changes.isEmpty, "a path that stops working after eject is never written into a config")
            XCTAssertFalse(plan.problems.isEmpty)
        }
    }

    // MARK: F3: a comment above an entry stays

    func testTurningAServerOffKeepsTheCommentAboveIt() throws {
        let vscode = SwitchMechanism.parkOutside(key: "servers")
        let file = """
        {
          "servers": {
            "playwright": { "command": "npx", "args": ["@playwright/mcp@latest"] },
            // token from 1Password
            "github": { "type": "http", "url": "https://api.githubcopilot.com/mcp/" },
            /* the local one */
            "notes": { "command": "notes-mcp" }
          }
        }
        """
        let middle = try ServerSwitch.edited(file, mechanism: vscode, server: "github", turnOn: false)
        XCTAssertTrue(middle.contains("// token from 1Password"), "a middle entry: its comment stays in the file")
        XCTAssertTrue(middle.contains("/* the local one */"))
        let last = try ServerSwitch.edited(file, mechanism: vscode, server: "notes", turnOn: false)
        XCTAssertTrue(last.contains("/* the local one */"), "the last entry: its comment stays too")
        XCTAssertTrue(last.contains("// token from 1Password"))
        XCTAssertNotNil(ServerSwitch.jsonObject(last), "and the file still reads")
        XCTAssertNotNil(ServerSwitch.jsonObject(middle))
    }

    // MARK: F4: mcpock's own hide file never uses up the backups

    func testAToolSwitchThroughTheFilterMakesNoBackup() throws {
        var config = ServerConfig(id: "reg:Cursor:global:github", name: "github",
                                  source: ServerSource(label: "Cursor", path: path(".cursor/mcp.json")), projectPath: nil,
                                  transport: .stdio, command: "npx", args: ["server-github"], env: [:], url: nil, headers: [:])
        config.filterFile = filters.appendingPathComponent("cursor--github.json").path
        let all = ["a", "b", "c"]
        for tool in all {
            let plan = ToolPlanner.plan(server: "github", configs: [config], hide: [tool], show: [], allTools: all,
                                        claudeSettingsPath: path(".claude/settings.json"))
            XCTAssertNil(SwitchWriter.apply(plan, backups: backups, parked: parked).error)
        }
        XCTAssertEqual(ToolFilterCore.hidden(fromFileText: try String(contentsOfFile: config.filterFile!, encoding: .utf8)), ["a", "b", "c"])
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
        XCTAssertTrue(saved.isEmpty, "the backups are for the agents' configs: \(saved)")
    }

    // MARK: F6: a hidden tool's call never passes

    func testAnEscapedSlashDoesNotPassTheFilter() {
        let escaped = #"{"jsonrpc":"2.0","id":4,"method":"tools\/call","params":{"name":"delete_repository"}}"#
        guard case .answer = ToolFilterCore.fromClient(escaped, hidden: ["delete_repository"]) else {
            return XCTFail("\"tools\\/call\" is the same method as \"tools/call\"")
        }
    }

    // MARK: F18: the server never outlives the filter

    /// The server here starts a child of its own, as `npx` does. When the
    /// agent stops the filter, both must be gone.
    func testStoppingTheFilterStopsTheServersOwnChildrenToo() throws {
        let helperPath = ToolFilter.helperPath
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helperPath), "no helper in this build")
        try put("server.sh", """
            #!/bin/sh
            /bin/sleep 300 &
            echo $! > "\(path("grandchild.pid"))"
            while IFS= read -r line; do :; done
            wait
            """)
        try put("hide.json", ToolFilterCore.fileText(hidden: []))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = ToolFilterCore.wrappedArguments(hideFile: path("hide.json"), command: "/bin/sh", arguments: [path("server.sh")])
        process.environment = ["PATH": "/usr/bin:/bin"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        var grandchild: pid_t = 0
        addTeardownBlock {
            if process.isRunning { process.terminate() }
            if grandchild > 0 { kill(grandchild, SIGKILL) }
        }
        for _ in 0..<100 where grandchild == 0 {
            usleep(50_000)
            grandchild = pid_t((text("grandchild.pid") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        XCTAssertGreaterThan(grandchild, 0, "the stand-in server started its child")
        XCTAssertEqual(kill(grandchild, 0), 0, "and it runs")

        process.terminate()   // the agent stops the filter (SIGTERM)
        var gone = false
        for _ in 0..<100 where !gone {
            usleep(50_000)
            gone = kill(grandchild, 0) != 0
        }
        XCTAssertTrue(gone, "the server's own child must not be left running")
        _ = input
    }

    // MARK: DS5: demo mode and tests never read Claude Code's own files

    @MainActor
    func testDemoModeNeverReadsTheRealClaudeFile() async {
        XCTAssertNil(PanelState.standIns(isDemo: false, isHostingTests: false), "a normal run reads the real state")
        for standIns in [PanelState.standIns(isDemo: true, isHostingTests: false), PanelState.standIns(isDemo: false, isHostingTests: true)] {
            XCTAssertEqual(standIns?.projectOff(), [:], "no real project folder can reach a demo card")
        }
        let demo = await PanelState.standIns(isDemo: true, isHostingTests: false)?.connectors()
        XCTAssertEqual(demo, .connectors(DemoData.connectors))
        let suite = "mcpock.tests.standins.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let panel = PanelState(monitor: HealthMonitor(defaults: defaults), defaults: defaults)
        panel.loadClaudeProjectOff = { ["github": ["acme-confidential"]] }
        panel.useStandIns(PanelState.standIns(isDemo: true, isHostingTests: false))
        XCTAssertEqual(panel.loadClaudeProjectOff(), [:])
    }

    // MARK: F14 / DS2, F15 / DS12: the filter comes off a server that is turned off, and its list is emptied

    private let cursorConfig = "{\n  \"mcpServers\": {\n    \"github\": {\n      \"command\": \"npx\",\n      \"args\": [\"-y\", \"server-github\"],\n      \"env\": {\n        \"GITHUB_TOKEN\": \"ghp_abcdefabcdefabcdefabcdef\"\n      }\n    }\n  }\n}\n"

    private func cursor() -> [ServerConfig] {
        ParsedFileCache.removeAll()
        return ConfigDiscovery.discover(registry: [KnownAgent(label: "Cursor", path: path(".cursor/mcp.json"), shape: .json)],
                                        scanRoots: [], parkedDirectory: parked, filterDirectory: filters)
    }

    private func filterPlan(setUp: Bool) -> SwitchPlan {
        FilterPlanner.plan(server: "github", configs: cursor(), setUp: setUp, helper: helper, directory: filters,
                           parkedDirectory: parked, helperIsUsable: { _ in true })
    }

    private func switchPlan(on: Bool) -> SwitchPlan {
        SwitchPlanner.plan(server: "github", configs: cursor(), turnOn: on, claudeSettingsPath: path(".claude/settings.json"),
                           running: { _ in false }, parkedDirectory: parked)
    }

    func testTheFilterComesOffAServerThatIsTurnedOff() throws {
        try put(".cursor/mcp.json", cursorConfig)
        XCTAssertNil(SwitchWriter.apply(filterPlan(setUp: true), backups: backups, parked: parked).error)
        XCTAssertNil(SwitchWriter.apply(switchPlan(on: false), backups: backups, parked: parked).error)
        let off = try XCTUnwrap(cursor().first)
        XCTAssertTrue(off.turnedOff)
        XCTAssertNotNil(off.filterFile, "still filtered while it waits in mcpock's folder")

        let remove = filterPlan(setUp: false)
        XCTAssertTrue(remove.problems.isEmpty, "\(remove.problems)")
        XCTAssertEqual(remove.changes.count, 1)
        XCTAssertNil(SwitchWriter.apply(remove, backups: backups, parked: parked).error)
        XCTAssertNil(try XCTUnwrap(cursor().first).filterFile, "the waiting entry starts the server itself again")

        XCTAssertNil(SwitchWriter.apply(switchPlan(on: true), backups: backups, parked: parked).error)
        XCTAssertEqual(NSDictionary(dictionary: try XCTUnwrap(ServerSwitch.jsonObject(try XCTUnwrap(text(".cursor/mcp.json"))) as? [String: Any])),
                       NSDictionary(dictionary: try XCTUnwrap(ServerSwitch.jsonObject(cursorConfig) as? [String: Any])),
                       "turned on again it is the entry from before the filter, keys and all")
    }

    func testRemovingTheFilterEmptiesItsListOfHiddenTools() throws {
        try put(".cursor/mcp.json", cursorConfig)
        XCTAssertNil(SwitchWriter.apply(filterPlan(setUp: true), backups: backups, parked: parked).error)
        let filtered = try XCTUnwrap(cursor().first)
        let hideFile = try XCTUnwrap(filtered.filterFile)
        let hide = ToolPlanner.plan(server: "github", configs: [filtered], hide: ["delete_repository"], show: [],
                                    allTools: ["search_code", "delete_repository"], claudeSettingsPath: path(".claude/settings.json"))
        XCTAssertNil(SwitchWriter.apply(hide, backups: backups, parked: parked).error)
        XCTAssertEqual(ToolFilterCore.hidden(fromFileText: try String(contentsOfFile: hideFile, encoding: .utf8)), ["delete_repository"])

        XCTAssertNil(SwitchWriter.apply(filterPlan(setUp: false), backups: backups, parked: parked).error)
        XCTAssertEqual(ToolFilterCore.parsedHidden(fromFileText: try String(contentsOfFile: hideFile, encoding: .utf8)), [],
                       "a later Set up must not hide the old tools again")
        XCTAssertEqual(text(".cursor/mcp.json"), cursorConfig)
    }

    // MARK: DS11: no Set up for a command written as a list

    func testTheFilterIsNotOfferedForACommandWrittenAsAList() throws {
        try put(".cursor/mcp.json", #"{"mcpServers": {"github": {"command": ["npx", "server-github"]}, "plain": {"command": "npx", "args": ["x"]}}}"#)
        let configs = cursor()
        XCTAssertFalse(ToolFilter.canSetUp(try XCTUnwrap(configs.first { $0.name == "github" })))
        XCTAssertTrue(ToolFilter.canSetUp(try XCTUnwrap(configs.first { $0.name == "plain" })))
        let plan = FilterPlanner.plan(server: "github", configs: configs.filter { $0.name == "github" }, setUp: true, helper: helper,
                                      directory: filters, parkedDirectory: parked, helperIsUsable: { _ in true })
        XCTAssertTrue(plan.changes.isEmpty && plan.problems.isEmpty, "nothing offered, nothing to fail")
    }

    // MARK: F8 / DS6: a filtered server whose helper is gone is not shown as fine

    func testAFilteredServerWithoutItsHelperIsBroken() async throws {
        let gone = path("Gone.app") + ToolFilter.helperSuffix
        var config = ServerConfig(id: "reg:Cursor:global:github", name: "github",
                                  source: ServerSource(label: "Cursor", path: path(".cursor/mcp.json")), projectPath: nil,
                                  transport: .stdio, command: "/bin/echo", args: [], env: [:], url: nil, headers: [:])
        config.filterFile = filters.appendingPathComponent("cursor--github.json").path
        config.filterHelper = gone
        let result = await HealthMonitor.probeServer(config: config, fetchTools: false)
        XCTAssertEqual(result.state, .broken)
        XCTAssertEqual(result.failureReason, ToolFilter.helperMissingReason(gone))
        XCTAssertTrue(result.failureReason?.contains("Remove the filter") ?? false)
        // And it is read from the config: the helper path the agent will start.
        try put(".cursor/mcp.json", "{\"mcpServers\": {\"github\": {\"command\": \"\(gone)\", \"args\": [\"filter\", \"--hide-file\", \"\(filters.appendingPathComponent("cursor--github.json").path)\", \"--\", \"npx\", \"server-github\"]}}}")
        let read = try XCTUnwrap(cursor().first)
        XCTAssertEqual(read.filterHelper, gone)
        XCTAssertEqual(read.command, "npx")
    }

    // MARK: F6 / DS15, F7, F16: the filter's own rules

    func testABatchWithAHiddenCallIsAnsweredWholeAndABatchedListIsFiltered() throws {
        let hidden: Set<String> = ["delete_repository"]
        let batch = #"[{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search"}},{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"delete_repository"}},{"jsonrpc":"2.0","method":"notifications/x"}]"#
        guard case .answer(let reply) = ToolFilterCore.fromClient(batch, hidden: hidden) else { return XCTFail("the batch must not reach the server") }
        let replies = try XCTUnwrap(ServerSwitch.jsonObject(reply) as? [[String: Any]])
        XCTAssertEqual(Set(replies.compactMap { $0["id"] as? Int }), [1, 2], "every request of the batch is answered, the notification is not")
        XCTAssertTrue(replies.allSatisfy { $0["error"] != nil })
        let harmless = #"[{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search"}}]"#
        XCTAssertEqual(ToolFilterCore.fromClient(harmless, hidden: hidden), .forward)

        let list = #"[{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"search"},{"name":"delete_repository"}]}},{"jsonrpc":"2.0","id":2,"result":{"ok":true}}]"#
        let out = try XCTUnwrap(ServerSwitch.jsonObject(ToolFilterCore.fromServer(list, hidden: hidden)) as? [[String: Any]])
        XCTAssertEqual(((out[0]["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["search"])
        XCTAssertEqual((out[1]["result"] as? [String: Any])?["ok"] as? Bool, true)
    }

    func testARunningFilterKeepsItsLastGoodList() {
        var list = ToolFilterCore.HideList()
        list.update(fileText: nil)
        XCTAssertEqual(list.names, [], "no file yet: nothing was hidden")
        list.update(fileText: ToolFilterCore.fileText(hidden: ["delete_repository"]))
        XCTAssertEqual(list.names, ["delete_repository"])
        list.update(fileText: nil)
        XCTAssertEqual(list.names, ["delete_repository"], "the file was deleted: the tool stays hidden")
        list.update(fileText: "{ broken")
        XCTAssertEqual(list.names, ["delete_repository"])
        list.update(fileText: ToolFilterCore.fileText(hidden: []))
        XCTAssertEqual(list.names, [], "an emptied list is a good list")
    }

    func testALargeResultInSmallPiecesComesThroughWhole() {
        var splitter = FilterLineSplitter()
        let big = Data(String(repeating: "x", count: 600_000).utf8)
        var lines: [Data] = []
        var offset = 0
        while offset < big.count {
            let end = min(offset + 4096, big.count)
            lines += splitter.feed(big.subdata(in: offset..<end))
            offset = end
        }
        XCTAssertTrue(lines.isEmpty)
        lines += splitter.feed(Data("\nsecond\nthi".utf8))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], big)
        XCTAssertEqual(lines[1], Data("second".utf8))
        XCTAssertEqual(splitter.feed(Data("rd\n\n".utf8)), [Data("third".utf8), Data()])
        XCTAssertNil(splitter.finish())
    }

    // MARK: Connectors: DS3, F9, F13, DS8, DS9, DS13

    @MainActor
    private func makePanel(_ suite: String) -> (PanelState, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let panel = PanelState(monitor: HealthMonitor(defaults: defaults), defaults: defaults)
        panel.loadClaudeProjectOff = { [:] }
        return (panel, defaults)
    }

    /// "At most every 30 minutes" holds across a relaunch: the time of the
    /// last ask and the last list are saved.
    @MainActor
    func testARelaunchDoesNotAskClaudeCodeAgainWithinTheHalfHour() async throws {
        let suite = "mcpock.tests.connectors-saved.\(UUID().uuidString)"
        let (first, defaults) = makePanel(suite)
        defaults.set(true, forKey: AppPreferences.includeConnectorsKey)
        var asked = 0
        first.loadConnectors = {
            asked += 1
            return .connectors([ClaudeConnector(name: "Gmail", host: "gmail.mcp.claude.com", state: .connected)])
        }
        first.refreshConnectorsIfDue()
        for _ in 0..<100 where first.connectors.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(asked, 1)

        // The app starts again: a new panel on the same settings.
        let (second, _) = makePanel(suite)
        second.loadConnectors = { asked += 1; return .connectors([]) }
        second.refreshConnectorsIfDue()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(asked, 1, "not asked again")
        XCTAssertEqual(second.connectors.map(\.name), ["Gmail"], "the saved list shows at once")

        // Half an hour later it is asked again.
        second.refreshConnectorsIfDue(now: Date().addingTimeInterval(ClaudeConnectors.refreshEvery + 5))
        for _ in 0..<100 where asked < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(asked, 2)
    }

    /// A failed ask keeps the last list, and says why it is not newer and how old it is.
    @MainActor
    func testAFailedAskKeepsTheListAndSaysItsAge() async throws {
        let (panel, defaults) = makePanel("mcpock.tests.connectors-stale.\(UUID().uuidString)")
        defaults.set(true, forKey: AppPreferences.includeConnectorsKey)
        panel.loadConnectors = { .connectors([ClaudeConnector(name: "Gmail", host: "", state: .connected)]) }
        panel.refreshConnectorsIfDue()
        for _ in 0..<100 where panel.connectors.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(panel.connectorsNote)
        panel.loadConnectors = { .unavailable("Claude Code did not answer in time.") }
        panel.refreshConnectorsIfDue(force: true)
        for _ in 0..<100 where panel.connectorsNote == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(panel.connectors.map(\.name), ["Gmail"])
        let note = try XCTUnwrap(panel.connectorsNote)
        XCTAssertTrue(note.hasPrefix("Claude Code did not answer in time. This list is from "), note)
        // Turned off: the list, the note and what was saved are gone.
        defaults.set(false, forKey: AppPreferences.includeConnectorsKey)
        panel.refreshConnectorsIfDue()
        XCTAssertTrue(panel.connectors.isEmpty)
        XCTAssertNil(defaults.data(forKey: "claudeConnectorsList"))
    }

    func testOnlyKnownWordsMeanConnected() {
        XCTAssertEqual(ClaudeConnectors.state(of: "\u{2714} Connected"), .connected)
        XCTAssertEqual(ClaudeConnectors.state(of: "Disconnected"), .failing)
        XCTAssertEqual(ClaudeConnectors.state(of: "Not connected"), .failing)
        XCTAssertEqual(ClaudeConnectors.state(of: "Pending"), .unknown)
    }

    func testTwoProjectsWithTheSameFolderNameAreTwo() {
        let json = """
            {"projects": {
              "/Users/me/code/shop": {"disabledMcpServers": ["github", "claude.ai Gmail"]},
              "/Users/me/work/shop": {"disabledMcpServers": ["github", "claude.ai Gmail"]},
              "/Users/me/code/blog": {"disabledMcpServers": ["github"]}
            }}
            """
        let servers = ClaudeProjectOff.projects(claudeJSON: Data(json.utf8))
        XCTAssertEqual(servers["github"], ["blog", "code/shop", "work/shop"])
        XCTAssertEqual(ClaudeProjectOff.note(servers["github"] ?? []), "Off in 3 projects: blog, code/shop, work/shop")
        let connectors = ClaudeConnectors.offProjects(claudeJSON: Data(json.utf8))
        XCTAssertEqual(connectors["gmail"], ["code/shop", "work/shop"])
        XCTAssertEqual(ClaudeConnectors.merged([ClaudeConnector(name: "Gmail", host: "", state: .connected)], off: connectors).first?.word,
                       "Off in 2 projects")
    }

    func testAListPrintedWithAFailingExitStillCountsAndAnUnreadableOneIsAFailure() {
        let printed = "claude.ai Gmail: https://gmail.mcp.claude.com/mcp - \u{2714} Connected\nclaude.ai Linear: https://mcp.linear.app/sse - \u{2718} Failed to connect"
        guard case .connectors(let list) = ClaudeConnectors.result(output: printed, normalExit: false, off: [:]) else {
            return XCTFail("the lines were printed: they count, whatever the exit code")
        }
        XCTAssertEqual(list.map(\.name), ["Linear", "Gmail"])
        let changed = "claude.ai Gmail \u{2014} https://gmail.mcp.claude.com/mcp (connected)"
        XCTAssertEqual(ClaudeConnectors.result(output: changed, normalExit: true, off: [:]),
                       .unavailable("mcpock can't read Claude Code's list: its wording may have changed."),
                       "connector lines it can't read are never \"no connectors\"")
        XCTAssertEqual(ClaudeConnectors.result(output: "", normalExit: false, off: [:]), .unavailable("Claude Code could not list its servers."))
        XCTAssertEqual(ClaudeConnectors.result(output: "github: npx x - \u{2714} Connected", normalExit: true, off: [:]), .connectors([]))
    }

    func testAFailingConnectorIsNotUnderAllFine() {
        let fine = ServerGroup(name: "github", state: .healthy, sourceLabels: ["Code"], tools: [], issues: [], variantCount: 1)
        let connectors = [ClaudeConnector(name: "Gmail", host: "", state: .failing),
                          ClaudeConnector(name: "Canva", host: "", state: .needsSignIn),
                          ClaudeConnector(name: "Zed", host: "", state: .connected)]
        let overview = PanelOverview.build(groups: [fine], agentCount: 1, hiddenTools: { _ in 0 }, connectors: connectors)
        XCTAssertEqual(overview.needYou, 2)
        XCTAssertTrue(overview.hasBroken)
        XCTAssertEqual(overview.needYouLine, "2 connectors")
        XCTAssertEqual(PanelOverview.build(groups: [fine], agentCount: 1, hiddenTools: { _ in 0 }).needYou, 0)
        // With a server that needs her, the number stays the servers' own: it
        // is the count of the Needs you section, the icon and the widgets.
        let broken = ServerGroup(name: "postgres", state: .broken, sourceLabels: ["Code"], tools: [], issues: [], variantCount: 1)
        let both = PanelOverview.build(groups: [fine, broken], agentCount: 1, hiddenTools: { _ in 0 }, connectors: connectors)
        XCTAssertEqual(both.needYou, 1)
        XCTAssertEqual(both.needYouLine, "1 broken")
    }

    func testTheClaudeFileIsReadAgainOnlyWhenItChanged() throws {
        try put("claude.json", #"{"projects": {"/p/shop": {"disabledMcpServers": ["github"]}}}"#)
        XCTAssertEqual(ClaudeProjectOff.byPath(file: path("claude.json")), ["github": ["/p/shop"]])
        XCTAssertEqual(ClaudeProjectOff.byPath(file: path("claude.json")), ["github": ["/p/shop"]])
        // A change (another size) is seen.
        try put("claude.json", #"{"projects": {"/p/shop": {"disabledMcpServers": ["github", "notion"]}}}"#)
        XCTAssertEqual(ClaudeProjectOff.byPath(file: path("claude.json"))["notion"], ["/p/shop"])
        XCTAssertEqual(ClaudeProjectOff.byPath(file: path("not-there.json")), [:])
    }

    // MARK: Widgets: F11, F12, DS7

    func testTheWidgetsReloadWhenTheNewNumbersChange() {
        var a = MCPockWidgetSnapshot(generated: Date(timeIntervalSince1970: 1_800_000_000), checking: false, firstCheckDone: true,
                                     totalServers: 48, problemCount: 0, fineCount: 46, problems: [], agents: [], brokenCount: 0,
                                     inUse: 46, toolsOff: 0, agentCount: 7)
        let before = a
        XCTAssertFalse(WidgetReloadPolicy.displayDiffers(before, a))
        a.toolsOff = 1
        XCTAssertTrue(WidgetReloadPolicy.displayDiffers(before, a), "a tool was hidden: the widget says \"1 tool off\"")
        a = before; a.inUse = 45
        XCTAssertTrue(WidgetReloadPolicy.displayDiffers(before, a))
        a = before; a.agentCount = 8
        XCTAssertTrue(WidgetReloadPolicy.displayDiffers(before, a))
    }

    func testTheRingAndItsLineNameTheSameNumber() {
        var s = MCPockWidgetSnapshot(generated: Date(timeIntervalSince1970: 1_800_000_000), checking: false, firstCheckDone: true,
                                     totalServers: 48, problemCount: 0, fineCount: 46, problems: [], agents: [], brokenCount: 0,
                                     inUse: 46, toolsOff: 12, agentCount: 7)
        XCTAssertEqual(s.allFineNumber, 46, "the number in the ring is the in-use number the line names")
        XCTAssertEqual(s.inUseLine, "46 in use \u{00B7} 12 tools off")
        s.toolsOff = 1
        XCTAssertEqual(s.inUseLine, "46 in use \u{00B7} 1 tool off")
        s.inUse = nil
        XCTAssertEqual(s.allFineNumber, 48, "an older snapshot has only the total")
    }

    // MARK: F17: the icon lookup

    func testTheIconLookupIsTheSameThroughItsCache() {
        for (name, targets) in [("github", [String]()), ("GitHub_MCP", []), ("x", ["npx -y @upstash/context7-mcp@latest"]),
                                ("y", ["https://docs.mcp.cloudflare.com/sse"]), ("apple-notes", []), ("nothing-known", ["npx z"])] {
            XCTAssertEqual(ServerIcons.icon(name: name, targets: targets), ServerIcons.lookUp(name: name, targets: targets), name)
            XCTAssertEqual(ServerIcons.icon(name: name, targets: targets), ServerIcons.lookUp(name: name, targets: targets), name)
        }
    }

    // MARK: A connector's calls on its row (22 Nov, Kika's yes)

    func testAConnectorsCallsAreFiledUnderClaudeCodesNameForIt() {
        // Claude Code's tool is mcp__claude_ai_Google_Sheets__x; the section shows "Google Sheets".
        XCTAssertEqual(HealthMonitor.normalizedName(ClaudeConnectors.usageName("Google Sheets")),
                       HealthMonitor.normalizedName("claude_ai_Google_Sheets"))
        XCTAssertEqual(ClaudeConnectors.callsWord(642), "642 calls")
        XCTAssertEqual(ClaudeConnectors.callsWord(1), "1 call")
        XCTAssertEqual(ClaudeConnectors.callsWord(12_345), "12,345 calls")
        XCTAssertNil(ClaudeConnectors.callsWord(0), "a row never says 0 calls")
        XCTAssertNil(ClaudeConnectors.callsWord(nil))
    }

    // MARK: Turn On puts the entry back in its own place (22 Nov, seen with the real Claude Desktop)

    private let fiveServers = """
        {
          "globalShortcut": "",
          "mcpServers": {
            "alpha": { "command": "a" },
            "bravo": {
              "command": "npx",
              "args": ["-y", "bravo-mcp"],
              "env": { "KEY": "made-up" }
            },
            "charlie": { "command": "c" },
            "delta": { "command": "d" },
            "echo": { "command": "e" }
          },
          "preferences": { "x": 1 }
        }

        """

    private func desktop() -> [ServerConfig] {
        ParsedFileCache.removeAll()
        return ConfigDiscovery.discover(registry: [KnownAgent(label: "Claude Desktop", path: path("desktop.json"), shape: .json)],
                                        scanRoots: [], parkedDirectory: parked, filterDirectory: filters)
    }

    private func flip(_ server: String, on: Bool) throws {
        let plan = SwitchPlanner.plan(server: server, configs: desktop().filter { $0.name == server }, turnOn: on,
                                      claudeSettingsPath: path(".claude/settings.json"), running: { _ in false }, parkedDirectory: parked)
        XCTAssertTrue(plan.problems.isEmpty, "\(server) \(on): \(plan.problems)")
        XCTAssertEqual(plan.changes.count, 1, "\(server) \(on)")
        XCTAssertNil(SwitchWriter.apply(plan, backups: backups, parked: parked).error)
    }

    func testTurnedOnAgainTheEntryIsBackInItsOwnPlaceByteForByte() throws {
        for server in ["alpha", "bravo", "charlie", "echo"] {   // first, a long middle one, a middle one, last
            try put("desktop.json", fiveServers)
            try flip(server, on: false)
            XCTAssertNotEqual(text("desktop.json"), fiveServers)
            XCTAssertNil(ServerSwitch.jsonObject(text("desktop.json") ?? "").flatMap { ($0 as? [String: Any])?["mcpServers"] as? [String: Any] }?[server])
            try flip(server, on: true)
            XCTAssertEqual(text("desktop.json"), fiveServers, "\(server): the same place, the same bytes")
        }
    }

    func testTwoNeighboursOffAndOnInAnyOrderKeepTheListsOrder() throws {
        try put("desktop.json", fiveServers)
        try flip("bravo", on: false)
        try flip("charlie", on: false)   // its upper neighbour is already gone: it remembers alpha above, delta below
        try flip("bravo", on: true)      // charlie is still off: bravo goes back after alpha
        try flip("charlie", on: true)
        XCTAssertEqual(text("desktop.json"), fiveServers)

        try flip("delta", on: false)
        try flip("echo", on: false)
        try flip("delta", on: true)      // its lower neighbour is off: after charlie
        try flip("echo", on: true)
        XCTAssertEqual(text("desktop.json"), fiveServers)
    }

    /// The neighbours were renamed or removed meanwhile, or the entry was
    /// parked by an older build: it goes to the end, as before, never lost.
    func testWithItsNeighboursGoneTheEntryGoesLast() throws {
        try put("desktop.json", fiveServers)
        try flip("charlie", on: false)
        let without = try XCTUnwrap(text("desktop.json"))
        try put("desktop.json", without.replacingOccurrences(of: "\"bravo\"", with: "\"bravo2\"").replacingOccurrences(of: "\"delta\"", with: "\"delta2\""))
        try flip("charlie", on: true)
        let keys = JSONSpanEditor.memberKeys(in: try XCTUnwrap(text("desktop.json")), objectPath: ["mcpServers"])
        XCTAssertEqual(keys, ["alpha", "bravo2", "delta2", "echo", "charlie"])
        // Taking the filter off a waiting entry keeps where it sat.
        try ParkedStore.add(name: "zulu", raw: "{}", place: ParkedStore.Place(after: "alpha", before: nil), agent: "Claude Desktop",
                            configPath: path("desktop.json"), directory: parked)
        let store = try String(contentsOf: ParkedStore.fileURL(agent: "Claude Desktop", directory: parked), encoding: .utf8)
        let changed = try XCTUnwrap(ParkedStore.text(replacing: "zulu", raw: "{\"command\": \"z\"}", in: store))
        XCTAssertTrue(changed.contains("\"after\" : \"alpha\""), changed)
    }
}
