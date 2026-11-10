import XCTest
@testable import mcpock

/// The switch end to end on a made-up home folder in a temporary directory
/// (1.14): what discovery reads, what the plan says, what the writer writes.
/// Never a real config: `SwitchWriter` itself refuses anything outside the
/// temporary folder while tests run.
final class SwitchPlanTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("mcpock-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        ParsedFileCache.removeAll()
    }

    override func tearDownWithError() throws {
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

    private var registry: [KnownAgent] {
        [
            KnownAgent(label: AgentRegistry.claudeCodeLabel, path: path(".claude.json"), shape: .json),
            KnownAgent(label: "Cursor", path: path(".cursor/mcp.json"), shape: .json),
            KnownAgent(label: "Codex", path: path(".codex/config.toml"), shape: .mcpServersTOML),
            KnownAgent(label: "Goose", path: path(".config/goose/config.yaml"), shape: .gooseYAML),
            KnownAgent(label: "VS Code", path: path("vscode/mcp.json"), shape: .json),
        ]
    }

    private func seed() throws {
        try put(".claude.json", #"{"mcpServers": {"openrouter": {"command": "npx", "args": ["or"]}, "notion": {"command": "n"}}}"#)
        try put(".claude/settings.json", "{\n  \"theme\": \"dark\"\n}\n")
        try put(".cursor/mcp.json", "{\n  \"mcpServers\": {\n    \"openrouter\": {\n      \"command\": \"npx\",\n      \"env\": { \"OPENROUTER_API_KEY\": \"sk-or-v1-abcdefabcdefabcdefabcdef\" }\n    }\n  }\n}\n")
        try put(".codex/config.toml", "[mcp_servers.openrouter]\ncommand = \"npx\"\n")
        try put(".config/goose/config.yaml", "extensions:\n  openrouter:\n    enabled: true\n    type: stdio\n    cmd: npx\n    args: []\n")
        try put("vscode/mcp.json", #"{"servers": {"openrouter": {"command": "npx"}}}"#)
    }

    private func discover() -> [ServerConfig] {
        ParsedFileCache.removeAll()
        return ConfigDiscovery.discover(registry: registry, scanRoots: [], parkedDirectory: parked)
    }

    private func plan(_ configs: [ServerConfig], on: Bool, running: Bool = false) -> SwitchPlan {
        SwitchPlanner.plan(server: "openrouter", configs: configs.filter { $0.name == "openrouter" }, turnOn: on,
                           claudeSettingsPath: path(".claude/settings.json"), running: { _ in running },
                           parkedDirectory: parked)
    }

    private var backups: URL { home.appendingPathComponent("backups") }
    private var parked: URL { home.appendingPathComponent("parked") }

    func testOffEverywhereThenOnAgain() throws {
        try seed()
        let before = discover()
        XCTAssertEqual(before.filter(\.turnedOff).count, 0)

        let off = plan(before, on: false, running: true)
        XCTAssertEqual(off.title, "Turn off openrouter everywhere?")
        XCTAssertEqual(off.changes.map(\.agents), [["Claude Code"], ["Codex"], ["Cursor"], ["Goose"]])
        XCTAssertEqual(off.skipped, ["VS Code"])
        XCTAssertEqual(off.problems, [])
        XCTAssertEqual(off.changes.map(\.when), [
            "Off in new sessions", "Off from its next run", "Cursor is open: off after it reopens", "Off in new sessions",
        ])
        XCTAssertEqual(off.changes[0].what, "Goes on Claude Code's blocked list.")
        XCTAssertEqual(off.changes[1].diff, ["+ enabled = false"])
        XCTAssertEqual(off.changes[3].diff, ["- enabled: true", "+ enabled: false"])
        // The sheet never shows a key, even behind "Show the exact change".
        XCTAssertFalse(off.changes.flatMap(\.diff).joined().contains("sk-or"))

        // Nothing is written until she says so.
        XCTAssertEqual(discover().filter(\.turnedOff).count, 0)

        let outcome = SwitchWriter.apply(off, backups: backups, parked: parked, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.written.count, 4)

        let after = discover().filter { $0.name == "openrouter" }
        XCTAssertEqual(after.count, 5)
        XCTAssertEqual(Set(after.filter(\.turnedOff).map(\.source.label)), ["Code", "Codex", "Cursor", "Goose"])
        // Other servers are untouched. Cursor's entry left its file whole (nothing
        // a rewrite by Cursor could lose) and waits in mcpock's folder with its key.
        XCTAssertEqual(discover().first { $0.name == "notion" }?.turnedOff, false)
        XCTAssertEqual(text(".cursor/mcp.json"), "{\n  \"mcpServers\": {}\n}\n")
        XCTAssertEqual(after.first { $0.source.label == "Cursor" }?.env["OPENROUTER_API_KEY"], "sk-or-v1-abcdefabcdefabcdefabcdef")
        XCTAssertNil(text(".claude.json").flatMap { $0.contains("denied") ? $0 : nil })

        let on = plan(discover(), on: true)
        XCTAssertEqual(on.changes.count, 4)
        XCTAssertEqual(on.changes[2].when, "On the next time Cursor opens")
        XCTAssertNil(SwitchWriter.apply(on, backups: backups, parked: parked).error)
        XCTAssertEqual(discover().filter(\.turnedOff).count, 0)
        // The list mcpock added stays, empty: it never removes a key it may not own.
        XCTAssertEqual(text(".claude/settings.json"), "{\n  \"theme\": \"dark\",\n  \"deniedMcpServers\": []\n}\n")
        XCTAssertTrue(text(".cursor/mcp.json")?.contains("sk-or-v1-abcdefabcdefabcdefabcdef") == true, "back in Cursor's file, key and all")
        XCTAssertEqual(ParkedStore.entries(agent: "Cursor", configPath: path(".cursor/mcp.json"), directory: parked), [:])
        XCTAssertEqual(text(".config/goose/config.yaml"), "extensions:\n  openrouter:\n    enabled: true\n    type: stdio\n    cmd: npx\n    args: []\n")
    }

    func testOneAgentOnly() throws {
        try seed()
        let cursor = discover().filter { $0.source.label == "Cursor" }
        let off = plan(cursor, on: false)
        XCTAssertEqual(off.title, "Turn off openrouter in Cursor?")
        XCTAssertEqual(off.changes.count, 1)
        XCTAssertEqual(off.changes[0].diff, [
            "- \"mcpServers\": { \"openrouter\": {\u{2026}} }",
            "+ mcpock/parked/cursor.json: \"openrouter\"",
        ])
        XCTAssertEqual(off.changes[0].what,
                       "Moved out of its config into mcpock's own folder, keys and all, so the app can't lose it when it rewrites its file.")
    }

    func testEveryWriteIsBackedUpFirst() throws {
        try seed()
        let original = try XCTUnwrap(text(".codex/config.toml"))
        let codex = discover().filter { $0.source.label == "Codex" }
        XCTAssertNil(SwitchWriter.apply(plan(codex, on: false), backups: backups,
                                        now: Date(timeIntervalSince1970: 1_800_000_000)).error)
        let names = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].hasSuffix("-codex-config.toml"), names[0])
        let copy = backups.appendingPathComponent(names[0])
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), original)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue, 0o600)
    }

    func testAFileThatChangedSinceTheSheetIsNotWritten() throws {
        try seed()
        let codex = discover().filter { $0.source.label == "Codex" }
        let off = plan(codex, on: false)
        try put(".codex/config.toml", "[mcp_servers.openrouter]\ncommand = \"uvx\"\n")
        let outcome = SwitchWriter.apply(off, backups: backups)
        XCTAssertEqual(outcome.error, .fileChanged(path(".codex/config.toml")))
        XCTAssertEqual(outcome.written, [])
        XCTAssertEqual(text(".codex/config.toml"), "[mcp_servers.openrouter]\ncommand = \"uvx\"\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }

    func testPermissionsAndASymlinkedConfigSurvive() throws {
        try seed()
        let real = home.appendingPathComponent("dotfiles/codex.toml")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: path(".codex/config.toml"), toPath: real.path)
        try FileManager.default.createSymbolicLink(atPath: path(".codex/config.toml"), withDestinationPath: real.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: real.path)

        let codex = discover().filter { $0.source.label == "Codex" }
        XCTAssertNil(SwitchWriter.apply(plan(codex, on: false), backups: backups).error)

        let link = try FileManager.default.attributesOfItem(atPath: path(".codex/config.toml"))[.type] as? FileAttributeType
        XCTAssertEqual(link, .typeSymbolicLink)
        XCTAssertTrue(try String(contentsOf: real, encoding: .utf8).contains("enabled = false"))
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue, 0o640)
        // No temporary file is left beside it.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: real.deletingLastPathComponent().path), ["codex.toml"])
    }

    func testAFileMcpockCanNotChangeSafelyIsLeftAloneAndSaid() throws {
        try seed()
        try put(".config/goose/config.yaml", "extensions:\n  openrouter: {enabled: true, type: stdio, cmd: npx}\n")
        let goose = discover().filter { $0.source.label == "Goose" }
        XCTAssertEqual(goose.count, 1)
        let off = plan(goose, on: false)
        XCTAssertTrue(off.isEmpty)
        XCTAssertEqual(off.problems, ["Goose: mcpock can't change its file safely, so it is left alone."])
    }

    func testWhileTestsRunOnlyTheTemporaryFolderMayBeWritten() {
        XCTAssertFalse(SwitchWriter.allowed(URL(fileURLWithPath: NSHomeDirectory() + "/.cursor/mcp.json")))
        XCTAssertTrue(SwitchWriter.allowed(home.appendingPathComponent("x.json")))
        let change = SwitchChange(agents: ["Cursor"], path: NSHomeDirectory() + "/.mcpock-test-never-written.json",
                                  before: nil, after: "{}", what: "", when: "", diff: [])
        XCTAssertThrowsError(try SwitchWriter.write(change, backups: backups, now: Date()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: change.path))
    }

    // MARK: Claude Desktop: the entry waits in mcpock's own folder

    private let desktopConfig = """
    {
      "mcpServers": {
        "openrouter": {
          "command": "npx",
          "args": ["-y", "openrouter-mcp"],
          "env": {
            "OPENROUTER_API_KEY": "sk-or-v1-abcdefabcdefabcdefabcdef"
          }
        },
        "stripe": {
          "command": "stripe-mcp"
        }
      },
      "preferences": {
        "menuBarEnabled": false
      }
    }

    """

    private func desktop() -> [ServerConfig] {
        ParsedFileCache.removeAll()
        let registry = [KnownAgent(label: "Claude Desktop", path: path("Claude/claude_desktop_config.json"), shape: .json)]
        return ConfigDiscovery.discover(registry: registry, scanRoots: [], parkedDirectory: parked)
    }

    private func desktopPlan(on: Bool) -> SwitchPlan {
        SwitchPlanner.plan(server: "openrouter", configs: desktop().filter { $0.name == "openrouter" }, turnOn: on,
                           claudeSettingsPath: path(".claude/settings.json"), running: { _ in false }, parkedDirectory: parked)
    }

    /// The real Claude Desktop rewrites its config at launch and keeps only
    /// what it knows (seen 2026-11-10), so nothing may wait inside that file.
    func testClaudeDesktopServerWaitsInMcpocksFolderAndComesBack() throws {
        try put("Claude/claude_desktop_config.json", desktopConfig)
        let off = desktopPlan(on: false)
        XCTAssertEqual(off.changes.count, 1)
        XCTAssertTrue(off.changes[0].what.hasPrefix("Moved out of its config into mcpock's own folder"), off.changes[0].what)
        XCTAssertEqual(off.changes[0].diff, [
            "- \"mcpServers\": { \"openrouter\": {\u{2026}} }",
            "+ mcpock/parked/claude-desktop.json: \"openrouter\"",
        ])
        XCTAssertNil(SwitchWriter.apply(off, backups: backups, parked: parked).error)

        let file = try XCTUnwrap(text("Claude/claude_desktop_config.json"))
        XCTAssertFalse(file.contains("openrouter"))
        XCTAssertFalse(file.contains(ServerSwitch.parkedKey), "nothing Claude Desktop would drop is left in its file")
        XCTAssertTrue(file.contains("\"stripe\"") && file.contains("\"menuBarEnabled\": false"))
        let store = parked.appendingPathComponent("claude-desktop.json")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue, 0o600)

        // Claude Desktop rewrites its file its own way: the server is still listed as off.
        try put("Claude/claude_desktop_config.json", #"{"mcpServers":{"stripe":{"command":"stripe-mcp"}},"preferences":{"menuBarEnabled":true}}"#)
        let listed = try XCTUnwrap(desktop().first { $0.name == "openrouter" })
        XCTAssertTrue(listed.turnedOff)
        XCTAssertEqual(listed.source.label, "Claude Desktop")
        XCTAssertEqual(listed.commandLine, "npx -y openrouter-mcp")
        XCTAssertEqual(listed.env["OPENROUTER_API_KEY"], "sk-or-v1-abcdefabcdefabcdefabcdef")
        XCTAssertEqual(ServerSwitch.mechanism(agent: "Claude Desktop", configID: listed.id, builtin: false), .parkOutside)

        let on = desktopPlan(on: true)
        XCTAssertEqual(on.changes.map(\.what), ["Moved back into its config from mcpock's folder."])
        XCTAssertNil(SwitchWriter.apply(on, backups: backups, parked: parked).error)
        let back = try XCTUnwrap(ServerSwitch.jsonObject(try XCTUnwrap(text("Claude/claude_desktop_config.json"))) as? [String: Any])
        let original = try XCTUnwrap(ServerSwitch.jsonObject(desktopConfig) as? [String: Any])
        XCTAssertEqual((back["mcpServers"] as? NSDictionary)?["openrouter"] as? NSDictionary,
                       (original["mcpServers"] as? NSDictionary)?["openrouter"] as? NSDictionary)
        XCTAssertEqual((back["preferences"] as? [String: Any])?["menuBarEnabled"] as? Bool, true, "Claude Desktop's own change stays")
        XCTAssertEqual(ParkedStore.entries(agent: "Claude Desktop", configPath: path("Claude/claude_desktop_config.json"), directory: parked), [:])
        XCTAssertEqual(desktop().filter(\.turnedOff).count, 0)
    }

    func testClaudeDesktopFileWithNoServersLeftStillListsTheParkedOne() throws {
        try put("Claude/claude_desktop_config.json", #"{"mcpServers":{"only":{"command":"x"}}}"#)
        let plan = SwitchPlanner.plan(server: "only", configs: desktop(), turnOn: false,
                                      claudeSettingsPath: path(".claude/settings.json"), running: { _ in false }, parkedDirectory: parked)
        XCTAssertNil(SwitchWriter.apply(plan, backups: backups, parked: parked).error)
        XCTAssertEqual(text("Claude/claude_desktop_config.json"), #"{"mcpServers":{}}"#)
        XCTAssertEqual(desktop().map(\.turnedOff), [true])
        // The file is gone (the app was removed): the parked one is still listed, and on says why it can't.
        try FileManager.default.removeItem(atPath: path("Claude/claude_desktop_config.json"))
        XCTAssertEqual(desktop().map(\.name), ["only"])
        let on = SwitchPlanner.plan(server: "only", configs: desktop(), turnOn: true,
                                    claudeSettingsPath: path(".claude/settings.json"), running: { _ in false }, parkedDirectory: parked)
        XCTAssertTrue(on.isEmpty)
        XCTAssertEqual(on.problems.count, 1)
    }

    func testAFailedWriteLeavesNothingBehindInMcpocksFolder() throws {
        try put("Claude/claude_desktop_config.json", desktopConfig)
        let off = desktopPlan(on: false)
        try put("Claude/claude_desktop_config.json", desktopConfig + "\n")
        XCTAssertNotNil(SwitchWriter.apply(off, backups: backups, parked: parked).error)
        XCTAssertEqual(ParkedStore.entries(agent: "Claude Desktop", configPath: path("Claude/claude_desktop_config.json"), directory: parked), [:])
        XCTAssertEqual(desktop().filter(\.turnedOff).count, 0)
    }

    func testServersSwitchedOffInTheirFileAreListedAndNeverStarted() throws {
        try seed()
        try put(".codex/config.toml", "[mcp_servers.openrouter]\ncommand = \"npx\"\nenabled = false\n")
        let codex = try XCTUnwrap(discover().first { $0.source.label == "Codex" })
        XCTAssertTrue(codex.turnedOff)
        let snapshots = HealthMonitor.merged([codex], into: [], pausedNames: [])
        XCTAssertEqual(snapshots.map(\.state), [.off])
        XCTAssertFalse(HealthMonitor.shouldProbe(snapshots[0], pausedNames: [], force: true, now: Date()))

        // Turned on again in the file: checked like a new server.
        var on = codex
        on.turnedOff = false
        XCTAssertEqual(HealthMonitor.merged([on], into: snapshots, pausedNames: []).map(\.state), [.unknown])
    }

    // MARK: Hiding single tools (Part 2)

    private let orTools = ["chat_completion", "list_models", "delete_key"]

    private func toolPlan(_ configs: [ServerConfig], hide: [String] = [], show: [String] = []) -> SwitchPlan {
        ToolPlanner.plan(server: "openrouter", configs: configs.filter { $0.name == "openrouter" }, hide: hide, show: show,
                         allTools: orTools, claudeSettingsPath: path(".claude/settings.json"))
    }

    func testHidingAToolEverywhereWritesEachAgentsOwnSettingAndShowPutsItBack() throws {
        try seed()
        let configs = discover()
        let hide = toolPlan(configs, hide: ["delete_key"])
        XCTAssertEqual(hide.title, "Hide delete_key in openrouter?")
        XCTAssertEqual(hide.confirmTitle, "Hide")
        XCTAssertEqual(Set(hide.changes.flatMap(\.agents)), ["Claude Code", "Codex", "Goose"])
        XCTAssertEqual(Set(hide.skipped), ["Cursor", "VS Code"], "no setting for single tools there")
        XCTAssertTrue(CardText.switchNotes(for: hide).isEmpty, "they are rows of their own on the sheet")
        let before = [".claude/settings.json", ".cursor/mcp.json", ".codex/config.toml", ".config/goose/config.yaml"].map(text)

        let backups = home.appendingPathComponent("backups")
        XCTAssertNil(SwitchWriter.apply(hide, backups: backups, parked: parked).error)
        XCTAssertTrue(text(".claude/settings.json")?.contains("mcp__openrouter__delete_key") == true)
        XCTAssertTrue(text(".codex/config.toml")?.contains("disabled_tools = [\"delete_key\"]") == true)
        XCTAssertTrue(text(".config/goose/config.yaml")?.contains("available_tools: [chat_completion, list_models]") == true)
        XCTAssertEqual(text(".cursor/mcp.json"), before[1], "Cursor's file is never touched")

        let hidden = ToolPlanner.hiddenTools(configs: configs.filter { $0.name == "openrouter" }, allTools: orTools,
                                             claudeSettingsPath: path(".claude/settings.json"))
        XCTAssertEqual(Set(hidden.values), [["delete_key"]])
        XCTAssertEqual(hidden.count, 3)

        let show = toolPlan(discover(), show: ["delete_key"])
        XCTAssertEqual(show.confirmTitle, "Show")
        XCTAssertNil(SwitchWriter.apply(show, backups: backups, parked: parked).error)
        XCTAssertEqual(text(".codex/config.toml"), before[2])
        XCTAssertEqual(text(".config/goose/config.yaml"),
                       before[3]?.replacingOccurrences(of: "openrouter:\n", with: "openrouter:\n    available_tools: []\n"),
                       "all shown: the list is empty again, which Goose reads as every tool")
        XCTAssertEqual(text(".claude/settings.json"), before[0], "shown again: as it was")
    }

    func testHidingInOneAgentLeavesTheOthers() throws {
        try seed()
        let codexOnly = discover().filter { $0.source.label == "Codex" }
        let plan = toolPlan(codexOnly, hide: ["delete_key"])
        XCTAssertEqual(plan.changes.map(\.agents), [["Codex"]])
        XCTAssertTrue(plan.skipped.isEmpty)
    }

}
