import XCTest
@testable import mcpock

/// 1.16: agents ask the user (mcpock_ask). The helper only leaves a request
/// in mcpock's own folder; nothing else is written.
final class AgentAskTests: XCTestCase {
    private var folder: URL!
    private var statusFile: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("mcpock-asks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        folder = base.appendingPathComponent("asks")
        statusFile = base.appendingPathComponent("status.json")
        try Data(MCPStatusServerTests.fixtureJSON.utf8).write(to: statusFile)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    }

    private var now: Date { MCPockStatus.decoderDate("2027-01-15T08:02:00Z") }

    private func server(client: String? = "claude-code") throws -> MCPStatusServer {
        var s = MCPStatusServer(loadStatus: { StatusLoad.read(from: self.statusFile) }, now: { self.now },
                                isRunning: { _ in true }, version: "1.16.0")
        s.askFolder = folder
        if let client {
            let line = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"\#(client)","version":"1"}}}"#
            _ = s.handle(line: line)
        }
        return s
    }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func testTheToolIsListedAsNotReadOnlyButNeverDestructive() throws {
        let ask = try XCTUnwrap(MCPStatusServer.tools.first { $0["name"] as? String == "mcpock_ask" })
        let notes = try XCTUnwrap(ask["annotations"] as? [String: Bool])
        XCTAssertEqual(notes["readOnlyHint"], false)
        XCTAssertEqual(notes["destructiveHint"], false)
        let schema = try XCTUnwrap(ask["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["server", "action", "reason"])
        XCTAssertTrue(MCPStatusServer.instructions.contains("mcpock_ask"))
        XCTAssertTrue(MCPStatusServer.instructions.contains("only their Yes runs the switch"))
    }

    func testAskingLeavesOnePrivateRequestAndTellsTheAgentWhatToSay() throws {
        let s = try server()
        let text = try XCTUnwrap(s.callTool("mcpock_ask", arguments: [
            "server": "Wake", "tool": "wake_get_session", "action": "hide_tool", "reason": "never used\nin 30 days",
        ]))
        XCTAssertTrue(text.contains("Asked. mcpock shows the user your request to hide wake_get_session in wake"), text)
        XCTAssertTrue(text.contains("\"I asked mcpock to hide wake_get_session in wake (never used in 30 days). Open mcpock to say Yes or No.\""), text)
        XCTAssertEqual(files().count, 1)
        let file = folder.appendingPathComponent(files()[0])
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(folderMode?.intValue, 0o700)
        let read = AskBox.read(from: folder, now: now)
        XCTAssertEqual(read.asks.count, 1)
        XCTAssertEqual(read.asks[0].agent, "Claude Code")
        XCTAssertEqual(read.asks[0].server, "wake", "the name as mcpock lists it")
        XCTAssertEqual(read.asks[0].reason, "never used in 30 days")

        let again = try XCTUnwrap(s.callTool("mcpock_ask", arguments: [
            "server": "wake", "tool": "wake_get_session", "action": "hide_tool", "reason": "still never used",
        ]))
        XCTAssertTrue(again.hasPrefix("Already asked"), again)
        XCTAssertEqual(files().count, 1)
    }

    func testRefusalsWriteNothing() throws {
        let s = try server()
        let cases: [([String: Any], String)] = [
            (["server": "wake", "action": "delete", "reason": "x"], "Pass an action"),
            (["server": "nope", "action": "turn_off", "reason": "x"], "No server named \"nope\""),
            (["server": "wake", "action": "hide_tool", "reason": "x"], "Name the tool"),
            (["server": "wake", "tool": "rm_rf", "action": "hide_tool", "reason": "x"], "has no tool named"),
            (["server": "wake", "tool": "wake_search", "action": "show_tool", "reason": "x"], "is not hidden in any agent"),
            (["server": "wake", "action": "turn_on", "reason": "x"], "already on"),
            (["server": "wake", "action": "turn_off", "reason": " \n "], "Pass a short reason"),
        ]
        for (arguments, expected) in cases {
            let text = try XCTUnwrap(s.callTool("mcpock_ask", arguments: arguments))
            XCTAssertTrue(text.contains(expected), "\(arguments): \(text)")
        }
        XCTAssertEqual(files(), [])
    }

    func testAtMostTenWait() throws {
        let s = try server(client: nil)
        for index in 0..<AgentAsk.maxWaiting {
            let ask = AgentAsk(id: UUID().uuidString, server: "s\(index)", tool: nil, action: .turnOff, reason: "r",
                               agent: "x", asked: now)
            try AskBox.write(ask, to: folder)
        }
        let text = try XCTUnwrap(s.callTool("mcpock_ask", arguments: ["server": "wake", "action": "turn_off", "reason": "x"]))
        XCTAssertTrue(text.contains("10 requests already wait"), text)
        XCTAssertEqual(files().count, AgentAsk.maxWaiting)
    }

    func testTheFolderReaderTakesOnlyRealAsks() throws {
        let good = AgentAsk(id: UUID().uuidString, server: "wake", tool: nil, action: .turnOff, reason: "r", agent: "Cursor", asked: now)
        try AskBox.write(good, to: folder)
        let old = AgentAsk(id: UUID().uuidString, server: "wake", tool: nil, action: .turnOn, reason: "r", agent: "Cursor",
                           asked: now.addingTimeInterval(-AgentAsk.lifetime - 60))
        try AskBox.write(old, to: folder)
        // Not ours: wrong name, readable by others, extra keys, a symlink.
        try Data("{}".utf8).write(to: folder.appendingPathComponent("notes.json"))
        let open = UUID().uuidString + ".json"
        try Data(#"{"id":"x"}"#.utf8).write(to: folder.appendingPathComponent(open))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.appendingPathComponent(open).path)
        let extra = UUID().uuidString
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoder.encode(
            AgentAsk(id: extra, server: "wake", tool: nil, action: .turnOff, reason: "r", agent: "x", asked: now))) as? [String: Any])
        object["run"] = "rm -rf ~"
        let extraFile = folder.appendingPathComponent(extra + ".json")
        try JSONSerialization.data(withJSONObject: object).write(to: extraFile)
        _ = chmod(extraFile.path, 0o600)
        let link = UUID().uuidString + ".json"
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(link),
                                                   withDestinationURL: folder.appendingPathComponent(good.id + ".json"))

        let read = AskBox.read(from: folder, now: now)
        XCTAssertEqual(read.asks.map(\.id), [good.id])
        XCTAssertEqual(read.expired.map(\.id), [old.id])
        XCTAssertEqual(Set(read.rejected), ["notes.json", open, extra + ".json", link])
    }

    func testSwitchesSaysWhatBecameOfEachAsk() throws {
        guard case .loaded(var status) = StatusLoad.read(from: statusFile) else { return XCTFail("fixture") }
        status.asks = [
            AskRecord(id: "a1", server: "wake", tool: "wake_search", action: .hideTool, agent: "Claude Code",
                      asked: now.addingTimeInterval(-3600), state: .waiting, answered: nil),
            AskRecord(id: "a2", server: "figma", tool: nil, action: .turnOff, agent: "Cursor",
                      asked: now.addingTimeInterval(-90_000), state: .expired, answered: now.addingTimeInterval(-3000)),
        ]
        let text = StatusReport.switchesText(.loaded(status), now: now, isRunning: { _ in true })
        XCTAssertTrue(text.contains("- Claude Code asked to hide wake_search in wake (1 h ago): waiting for the user's answer. id a1"), text)
        XCTAssertTrue(text.contains("- Cursor asked to turn figma off (1 day ago): ended with no answer after a day; nothing changed"), text)
        XCTAssertTrue(text.contains("ask the user with mcpock_ask"), text)
    }

    func testAgentLabels() {
        XCTAssertEqual(AgentAsk.agentLabel("claude-code"), "Claude Code")
        XCTAssertEqual(AgentAsk.agentLabel("Cursor"), "Cursor")
        XCTAssertEqual(AgentAsk.agentLabel(nil), "An agent")
        XCTAssertEqual(AgentAsk.agentLabel("my\nbot"), "my bot")
    }
}
