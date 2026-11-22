import XCTest
@testable import mcpock

/// mcpock's tool filter (22 Nov, Kika's pick): for agents that can't hide
/// single tools. The message rules and the config edits are pure; one test
/// runs the real helper in front of a stand-in server made of a shell script.
final class ToolFilterTests: XCTestCase {
    private var home: URL!
    private var backups: URL { home.appendingPathComponent("backups") }
    private var parked: URL { home.appendingPathComponent("parked") }
    private var filters: URL { home.appendingPathComponent("filter") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-filter-\(UUID().uuidString)")
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

    // MARK: - How the helper is invoked

    func testTheServersOwnCommandStaysInsideWordForWord() {
        let args = ToolFilterCore.wrappedArguments(hideFile: "/tmp/a b/hide.json", command: "npx",
                                                   arguments: ["-y", "@scope/server", "--flag", "--", "x y"])
        XCTAssertEqual(args, ["filter", "--hide-file", "/tmp/a b/hide.json", "--", "npx", "-y", "@scope/server", "--flag", "--", "x y"])
        XCTAssertEqual(ToolFilterCore.invocation(arguments: args),
                       .init(hideFile: "/tmp/a b/hide.json", command: "npx", arguments: ["-y", "@scope/server", "--flag", "--", "x y"]))
    }

    func testAnythingElseIsNotAFilterInvocation() {
        XCTAssertNil(ToolFilterCore.invocation(arguments: []))
        XCTAssertNil(ToolFilterCore.invocation(arguments: ["filter", "--hide-file", "/x", "--"]), "no server command")
        XCTAssertNil(ToolFilterCore.invocation(arguments: ["serve", "--hide-file", "/x", "--", "npx"]))
        XCTAssertNil(ToolFilterCore.invocation(arguments: ["filter", "--hide-file", "", "--", "npx"]))
        XCTAssertNil(ToolFilterCore.invocation(arguments: ["filter", "/x", "--", "npx", "a"]))
        XCTAssertTrue(ToolFilterCore.isHelper("/Applications/mcpock.app/Contents/Helpers/mcpock-mcp"))
        XCTAssertFalse(ToolFilterCore.isHelper("/usr/local/bin/mcpock-mcp-old"))
    }

    // MARK: - The hide file

    func testTheHideFileRoundTripsAndABrokenOneHidesNothing() {
        let text = ToolFilterCore.fileText(hidden: ["fork_repository", "delete_repository", "say \"hi\""])
        XCTAssertEqual(ToolFilterCore.hidden(fromFileText: text), ["fork_repository", "delete_repository", "say \"hi\""])
        XCTAssertTrue(text.hasPrefix("{\n  \"hide\": [\n    \"delete_repository\",\n"), "sorted, one per line")
        XCTAssertEqual(ToolFilterCore.hidden(fromFileText: ToolFilterCore.fileText(hidden: [])), [])
        for broken in [nil, "", "not json", "[]", "{\"hide\": \"all\"}", "{\"other\": []}"] as [String?] {
            XCTAssertEqual(ToolFilterCore.hidden(fromFileText: broken), [], "a broken file must never take tools away")
        }
        XCTAssertEqual(ToolFilterCore.hidden(fromFileText: "{\"hide\": [\"a\", 3, \"\", null]}"), ["a"])
    }

    // MARK: - One message

    private let toolList = #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search","description":"s"},{"name":"delete_repository","description":"d"},{"name":"read_file","description":"r"}],"nextCursor":"c1"}}"#

    func testAToolListLosesOnlyTheHiddenTools() throws {
        let out = ToolFilterCore.fromServer(toolList, hidden: ["delete_repository"])
        let result = try XCTUnwrap((ServerSwitch.jsonObject(out) as? [String: Any])?["result"] as? [String: Any])
        XCTAssertEqual((result["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["search", "read_file"])
        XCTAssertEqual(result["nextCursor"] as? String, "c1", "everything else in the answer stays")
        XCTAssertFalse(out.contains("\n"), "one line, as MCP's stdio wants")
    }

    func testEverythingElseComesBackByteForByte() {
        let untouched = [
            toolList.replacingOccurrences(of: "delete_repository", with: "other_tool"),
            #"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"the \"tools\" word in a result"}]}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#,
            #"{"jsonrpc":"2.0","id":4,"result":{"tools":"not a list"}}"#,
            "not json at all, with \"tools\" in it",
            #"{ "jsonrpc" : "2.0",   "id":5, "result" : { "resources": [] } }"#,
        ]
        for line in untouched {
            XCTAssertEqual(ToolFilterCore.fromServer(line, hidden: ["delete_repository"]), line)
        }
        XCTAssertEqual(ToolFilterCore.fromServer(toolList, hidden: []), toolList, "nothing hidden: nothing parsed")
    }

    func testACallToAHiddenToolIsAnsweredAndNeverReachesTheServer() throws {
        let call = #"{"jsonrpc":"2.0","id":"x4","method":"tools/call","params":{"name":"delete_repository","arguments":{}}}"#
        guard case .answer(let reply) = ToolFilterCore.fromClient(call, hidden: ["delete_repository"]) else {
            return XCTFail("a hidden tool's call must be answered by the filter")
        }
        let message = try XCTUnwrap(ServerSwitch.jsonObject(reply) as? [String: Any])
        XCTAssertEqual(message["id"] as? String, "x4", "the same id, a string as it came")
        XCTAssertEqual((message["error"] as? [String: Any])?["message"] as? String, "The tool delete_repository is turned off in mcpock.")
        XCTAssertNil(message["result"])
        // A numeric id stays a number.
        guard case .answer(let numbered) = ToolFilterCore.fromClient(call.replacingOccurrences(of: "\"x4\"", with: "7"),
                                                                     hidden: ["delete_repository"]) else { return XCTFail("answered") }
        XCTAssertEqual((ServerSwitch.jsonObject(numbered) as? [String: Any])?["id"] as? Int, 7)
        // Without an id there is nobody to answer.
        XCTAssertEqual(ToolFilterCore.fromClient(#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"delete_repository"}}"#,
                                                 hidden: ["delete_repository"]), .drop)
    }

    func testEveryOtherRequestIsPassedOn() {
        let hidden: Set<String> = ["delete_repository"]
        XCTAssertEqual(ToolFilterCore.fromClient(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search"}}"#, hidden: hidden), .forward)
        XCTAssertEqual(ToolFilterCore.fromClient(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, hidden: hidden), .forward)
        XCTAssertEqual(ToolFilterCore.fromClient(#"{"jsonrpc":"2.0","id":9,"method":"prompts/get","params":{"name":"delete_repository"}}"#, hidden: hidden), .forward)
        XCTAssertEqual(ToolFilterCore.fromClient("tools/call but not json delete_repository", hidden: hidden), .forward)
        XCTAssertEqual(ToolFilterCore.fromClient(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_repository"}}"#, hidden: []), .forward)
    }

    func testLinesAreSplitWithNoSizeLimit() {
        var splitter = FilterLineSplitter()
        let big = String(repeating: "x", count: 2_500_000)
        XCTAssertEqual(splitter.feed(Data("ab".utf8)), [])
        XCTAssertEqual(splitter.feed(Data("c\n\(big)".utf8)), [Data("abc".utf8)])
        let lines = splitter.feed(Data("\nlast".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.count, big.utf8.count, "a large tool result passes whole")
        XCTAssertEqual(splitter.finish(), Data("last".utf8))
        XCTAssertNil(splitter.finish())
    }

    // MARK: - The entry in the agent's file

    private let cursorConfig = "{\n  \"mcpServers\": {\n    \"github\": {\n      \"command\": \"npx\",\n      \"args\": [\"-y\", \"@modelcontextprotocol/server-github\"],\n      \"env\": {\n        \"GITHUB_TOKEN\": \"ghp_abcdefabcdefabcdefabcdef\"\n      }\n    },\n    \"notion\": {\n      \"url\": \"https://mcp.notion.com/mcp\"\n    }\n  }\n}\n"
    private let helper = "/Applications/mcpock.app/Contents/Helpers/mcpock-mcp"

    func testSettingUpChangesOnlyTheCommandAndArgumentsAndRemovingPutsThemBack() throws {
        let hide = "/Users/me/Library/Application Support/mcpock/filter/cursor--github.json"
        let wrapped = try ToolFilter.wrapped(cursorConfig, key: "mcpServers", server: "github", helper: helper, hideFile: hide)
        let entry = try XCTUnwrap(((ServerSwitch.jsonObject(wrapped) as? [String: Any])?["mcpServers"] as? [String: Any])?["github"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, helper)
        XCTAssertEqual(entry["args"] as? [String], ["filter", "--hide-file", hide, "--", "npx", "-y", "@modelcontextprotocol/server-github"])
        XCTAssertEqual((entry["env"] as? [String: String])?["GITHUB_TOKEN"], "ghp_abcdefabcdefabcdefabcdef", "its keys stay where they are")
        XCTAssertTrue(wrapped.contains("\"notion\""))
        XCTAssertEqual(try ToolFilter.unwrapped(wrapped, key: "mcpServers", server: "github"), cursorConfig, "exactly as it was")
    }

    func testEntriesItCanNotChangeSafelyAreLeftAlone() {
        let hide = "/x/hide.json"
        XCTAssertThrowsError(try ToolFilter.wrapped(cursorConfig, key: "mcpServers", server: "notion", helper: helper, hideFile: hide),
                             "a remote server has no command to put the filter in front of")
        XCTAssertThrowsError(try ToolFilter.wrapped(cursorConfig, key: "mcpServers", server: "nope", helper: helper, hideFile: hide))
        XCTAssertThrowsError(try ToolFilter.wrapped(cursorConfig, key: "servers", server: "github", helper: helper, hideFile: hide))
        let listed = #"{"mcpServers": {"a": {"command": ["npx", "a"]}, "b": {"command": "npx", "args": ["a", 3]}}}"#
        XCTAssertThrowsError(try ToolFilter.wrapped(listed, key: "mcpServers", server: "a", helper: helper, hideFile: hide))
        XCTAssertThrowsError(try ToolFilter.wrapped(listed, key: "mcpServers", server: "b", helper: helper, hideFile: hide))
        XCTAssertThrowsError(try ToolFilter.unwrapped(cursorConfig, key: "mcpServers", server: "github"), "not filtered")
        // Never a filter around a filter.
        let once = try? ToolFilter.wrapped(cursorConfig, key: "mcpServers", server: "github", helper: helper, hideFile: hide)
        XCTAssertThrowsError(try ToolFilter.wrapped(XCTUnwrap(once), key: "mcpServers", server: "github", helper: helper, hideFile: hide))
    }

    func testTheCheckRefusesAnyOtherChange() {
        let tampered = cursorConfig.replacingOccurrences(of: "ghp_abcdefabcdefabcdefabcdef", with: "ghp_other")
        XCTAssertFalse(ToolFilter.verify(before: cursorConfig, after: tampered, key: "mcpServers", server: "github",
                                         command: "npx", arguments: ["-y", "@modelcontextprotocol/server-github"]))
        XCTAssertTrue(ToolFilter.verify(before: cursorConfig, after: cursorConfig, key: "mcpServers", server: "github",
                                        command: "npx", arguments: ["-y", "@modelcontextprotocol/server-github"]))
    }

    func testOnlyAgentsWithNoSettingOfTheirOwnGetTheFilter() {
        XCTAssertEqual(ToolFilter.serversKey(agent: "Cursor", configID: "reg:Cursor:global:a", builtin: false), "mcpServers")
        XCTAssertEqual(ToolFilter.serversKey(agent: "Claude Desktop", configID: "reg:Claude Desktop:global:a", builtin: false), "mcpServers")
        XCTAssertEqual(ToolFilter.serversKey(agent: "VS Code", configID: "reg:VS Code:global:a", builtin: false), "servers")
        XCTAssertEqual(ToolFilter.serversKey(agent: "Cline", configID: "reg:Cline:global:a", builtin: false), "mcpServers")
        XCTAssertNil(ToolFilter.serversKey(agent: "Codex", configID: "reg:Codex:global:a", builtin: false), "Codex hides tools its own way")
        XCTAssertNil(ToolFilter.serversKey(agent: "Code", configID: "reg:Code:global:a", builtin: false))
        XCTAssertNil(ToolFilter.serversKey(agent: "Cursor", configID: "scan:/x/mcp.json:global:a", builtin: false), "never a file the scan found")
        XCTAssertNil(ToolFilter.serversKey(agent: "Cursor", configID: "reg:Cursor:global:a", builtin: true))
        XCTAssertNotEqual(ToolFilter.hideFile(agent: "Cursor", server: "a.b", directory: filters),
                          ToolFilter.hideFile(agent: "Cursor", server: "a-b", directory: filters))
        XCTAssertTrue(ToolFilter.hideFile(agent: "VS Code", server: "github", directory: filters).contains("/filter/vs-code--github-"))
    }

    // MARK: - End to end on made-up files

    private func discover() -> [ServerConfig] {
        ParsedFileCache.removeAll()
        return ConfigDiscovery.discover(registry: [KnownAgent(label: "Cursor", path: path(".cursor/mcp.json"), shape: .json)],
                                        scanRoots: [], parkedDirectory: parked)
    }

    func testSetUpThenHideAToolThenRemove() throws {
        try put(".cursor/mcp.json", cursorConfig)
        let before = try XCTUnwrap(discover().first { $0.name == "github" })
        XCTAssertTrue(ToolFilter.canSetUp(before))
        XCTAssertFalse(ToolFilter.canSetUp(try XCTUnwrap(discover().first { $0.name == "notion" })), "a remote server")
        XCTAssertNil(ToolPlanner.mechanism(for: before), "Cursor has no setting of its own")

        // Set up.
        let setUp = FilterPlanner.plan(server: "github", configs: discover(), setUp: true, helper: helper, directory: filters)
        XCTAssertEqual(setUp.changes.map(\.agents), [["Cursor"]])
        XCTAssertEqual(setUp.title, "Let mcpock filter github for Cursor?")
        XCTAssertEqual(setUp.confirmTitle, "Use the Filter")
        XCTAssertEqual(setUp.changes[0].when, "Filtered the next time Cursor opens")
        XCTAssertFalse(setUp.changes[0].diff.joined().contains("ghp_abcdef"), "the diff never shows a key")
        XCTAssertNil(SwitchWriter.apply(setUp, backups: backups, parked: parked).error)

        // Read through the filter: the row is still the server itself.
        let filtered = try XCTUnwrap(discover().first { $0.name == "github" })
        XCTAssertEqual(filtered.command, "npx")
        XCTAssertEqual(filtered.args, ["-y", "@modelcontextprotocol/server-github"])
        XCTAssertEqual(filtered.commandLine, before.commandLine, "the check and 'set up differently' go by the server's own command")
        let hideFile = try XCTUnwrap(filtered.filterFile)
        XCTAssertTrue(hideFile.hasPrefix(filters.path))
        XCTAssertEqual(ToolPlanner.mechanism(for: filtered), .filter)
        XCTAssertFalse(ToolFilter.canSetUp(filtered), "never twice")
        XCTAssertTrue(FilterPlanner.plan(server: "github", configs: discover(), setUp: true, helper: helper, directory: filters).isEmpty)

        // Hide a tool: only mcpock's own file changes.
        let all = ["search_code", "delete_repository", "fork_repository"]
        let configFile = try XCTUnwrap(text(".cursor/mcp.json"))
        let hide = ToolPlanner.plan(server: "github", configs: [filtered], hide: ["delete_repository"], show: [], allTools: all,
                                    claudeSettingsPath: path(".claude/settings.json"))
        XCTAssertEqual(hide.changes.map(\.path), [hideFile])
        XCTAssertNil(hide.changes[0].before, "the list does not exist until the first tool is hidden")
        XCTAssertEqual(hide.changes[0].what, "Goes on the list mcpock's filter leaves out.")
        XCTAssertEqual(hide.changes[0].when, "Hidden the next time Cursor lists its tools")
        XCTAssertTrue(hide.skipped.isEmpty)
        XCTAssertNil(SwitchWriter.apply(hide, backups: backups, parked: parked).error)
        XCTAssertEqual(text(".cursor/mcp.json"), configFile, "Cursor's own file is not touched by a tool switch")
        XCTAssertEqual(ToolPlanner.hiddenTools(configs: [filtered], allTools: all, claudeSettingsPath: path(".claude/settings.json")),
                       [filtered.id: ["delete_repository"]])

        // Show it again.
        let show = ToolPlanner.plan(server: "github", configs: [filtered], hide: [], show: ["delete_repository"], allTools: all,
                                    claudeSettingsPath: path(".claude/settings.json"))
        XCTAssertNil(SwitchWriter.apply(show, backups: backups, parked: parked).error)
        XCTAssertEqual(ToolPlanner.hiddenTools(configs: [filtered], allTools: all, claudeSettingsPath: path(".claude/settings.json")),
                       [filtered.id: []])

        // Remove the filter: Cursor's file is as it was.
        let remove = FilterPlanner.plan(server: "github", configs: discover(), setUp: false, helper: helper, directory: filters)
        XCTAssertEqual(remove.confirmTitle, "Remove the Filter")
        XCTAssertNil(SwitchWriter.apply(remove, backups: backups, parked: parked).error)
        XCTAssertEqual(text(".cursor/mcp.json"), cursorConfig)
        XCTAssertNil(try XCTUnwrap(discover().first { $0.name == "github" }).filterFile)
    }

    // MARK: - The card's words

    func testTheCardOffersTheFilterAndSaysWhenItIsOn() {
        func source(_ agent: String, _ state: GroupSource.FilterState) -> GroupSource {
            GroupSource(configID: agent, label: agent, agent: agent, path: "", transport: .stdio, target: "npx x",
                        envKeys: [], headerKeys: [], state: .healthy, failureReason: nil, filter: state)
        }
        var group = ServerGroup(name: "github", state: .healthy, sourceLabels: [], tools: [], issues: [], variantCount: 1)
        XCTAssertNil(CardText.filterNotice(for: group))
        XCTAssertNil(CardText.filteredLine(for: group))
        group.sources = [source("Code", .none), source("Cursor", .available), source("VS Code", .available), source("Cline", .on)]
        XCTAssertEqual(CardText.filterNotice(for: group), "Cursor and VS Code can't hide single tools. mcpock's filter can.")
        XCTAssertEqual(CardText.filteredLine(for: group), "Cline's tools go through mcpock's filter.")
        XCTAssertEqual(CardText.filteredToolNote("2 tools hidden"), "2 tools hidden through mcpock's filter")
        XCTAssertEqual(CardText.filteredToolNote(nil), "Through mcpock's filter")
    }

    // MARK: - The real helper in front of a stand-in server

    /// Starts the built helper from the app that hosts the tests, in filter
    /// mode, in front of a shell script that answers like a server. Skipped
    /// when the helper is not in the bundle.
    func testTheHelperFiltersARealStdioServer() throws {
        let helperPath = ToolFilter.helperPath
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helperPath), "no helper in this build")
        try put("server.sh", """
            #!/bin/sh
            while IFS= read -r line; do
              case "$line" in
                *tools/list*) printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search"},{"name":"delete_repository"}]}}' ;;
                *tools/call*) printf '%s\\n' "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":3,\\"result\\":{\\"ran\\":\\"$FAKE_KEY\\"}}" ;;
              esac
            done
            """)
        try put("hide.json", ToolFilterCore.fileText(hidden: ["delete_repository"]))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = ToolFilterCore.wrappedArguments(hideFile: path("hide.json"), command: "/bin/sh", arguments: [path("server.sh")])
        process.environment = ["PATH": "/usr/bin:/bin", "FAKE_KEY": "k1"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate() } }

        let requests = [
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search"}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"delete_repository"}}"#,
        ]
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()

        // Read to the end on another thread, so a hang fails the test instead of blocking it.
        let done = expectation(description: "the filter ends when its input does")
        var collected = Data()
        DispatchQueue.global().async {
            collected = output.fileHandleForReading.readDataToEndOfFile()
            done.fulfill()
        }
        wait(for: [done], timeout: 15)
        let lines = String(decoding: collected, as: UTF8.self).split(separator: "\n").map(String.init)
        let byID = Dictionary(lines.compactMap { line -> (Int, [String: Any])? in
            guard let message = ServerSwitch.jsonObject(line) as? [String: Any], let id = message["id"] as? Int else { return nil }
            return (id, message)
        }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(((byID[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["search"])
        XCTAssertEqual((byID[3]?["result"] as? [String: Any])?["ran"] as? String, "k1", "an allowed call reaches the server, with its environment")
        XCTAssertNotNil(byID[4]?["error"], "a hidden tool's call is answered by the filter")
        XCTAssertNil(byID[4]?["result"])
    }
}
