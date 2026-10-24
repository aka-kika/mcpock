import XCTest
@testable import mcpock

/// Inbox 2026-10-17: xapi dropped inside an open Claude Code session while
/// mcpock's own check read it fine. mcpock now reads the open sessions' logs
/// and says so on the row.
final class SessionDropsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-drops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func line(_ session: String, _ time: String, debug: String? = nil, error: String? = nil) -> String {
        var object: [String: Any] = ["timestamp": time, "sessionId": session, "cwd": "/u/Recall"]
        if let debug { object["debug"] = debug }
        if let error { object["error"] = error }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private func writeLog(server: String, folder: String, _ lines: [String]) throws {
        let dir = root.appendingPathComponent("logs").appendingPathComponent(SessionDrops.logFolderName(for: folder))
            .appendingPathComponent("mcp-logs-\(server)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("2026-10-17T11-00-00-000Z.jsonl"),
                                               atomically: true, encoding: .utf8)
    }

    private let open = SessionDrops.OpenSession(id: "s1", folder: "/u/_KIKA/Recall", started: .distantPast)

    func testLogFolderNameMatchesClaudeCodes() {
        XCTAssertEqual(SessionDrops.logFolderName(for: "/Users/kika_hub/_KIKA_MAIN/_INFRA/apps/Recall"),
                       "-Users-kika-hub--KIKA-MAIN--INFRA-apps-Recall")
    }

    func testTheCaseFromTheNote() throws {
        try writeLog(server: "xapi", folder: open.folder, [
            line("s1", "2026-10-17T11:00:01.000Z", debug: "Successfully connected (transport: stdio) in 900ms"),
            line("s1", "2026-10-17T11:58:00.000Z", error: "Connection failed (-1): xurl mcp: could not reach the MCP server (transport error)"),
            line("s1", "2026-10-17T11:58:00.100Z", error: "Failed to fetch tools: xurl mcp: could not reach the MCP server (transport error)"),
            line("s1", "2026-10-17T11:58:01.000Z", error: "Server stderr: [xurl mcp] bridging stdio"),
        ])
        let drops = SessionDrops.drops(sessions: [open], logsRoot: root.appendingPathComponent("logs").path)
        XCTAssertEqual(drops["xapi"]?.count, 1)
        XCTAssertEqual(drops["xapi"]?.first?.folder, "/u/_KIKA/Recall")
    }

    func testReconnectingClearsIt() throws {
        try writeLog(server: "xapi", folder: open.folder, [
            line("s1", "2026-10-17T11:58:00.100Z", error: "Failed to fetch tools: transport error"),
            line("s1", "2026-10-17T12:10:00.000Z", debug: "Successfully connected (transport: stdio) in 800ms"),
        ])
        XCTAssertTrue(SessionDrops.drops(sessions: [open], logsRoot: root.appendingPathComponent("logs").path).isEmpty)
    }

    func testAClosedSessionAndOtherLinesCountForNothing() throws {
        try writeLog(server: "xapi", folder: open.folder, [
            line("s1", "2026-10-17T11:00:01.000Z", debug: "Successfully connected (transport: stdio) in 900ms"),
            line("s1", "2026-10-17T11:30:00.000Z", error: "Tool error: Command failed: No active tab"),
            line("s1", "2026-10-17T11:31:00.000Z", debug: "STDIO connection closed after 30s (cleanly)"),
            line("gone", "2026-10-17T11:40:00.000Z", error: "Failed to fetch tools: Connection closed"),
            "not json",
        ])
        XCTAssertTrue(SessionDrops.drops(sessions: [open], logsRoot: root.appendingPathComponent("logs").path).isEmpty,
                      "a tool's own error is not a drop, and the session that failed is not open")
    }

    func testAToolCallThatLostTheConnectionIsADrop() {
        let event = SessionDrops.event(fromLine: line("s1", "2026-10-17T11:58:00.000Z",
                                                      debug: "Tool 'create_tab' failed after 3s: Connection closed"))
        XCTAssertEqual(event?.up, false)
        XCTAssertEqual(SessionDrops.event(fromLine: line("s1", "2026-10-17T11:58:00.000Z",
                                                         debug: "Tool 'x' completed successfully in 20ms"))?.up, true)
    }

    func testOnlyRunningSessionsAreOpen() throws {
        let dir = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"pid": 111, "sessionId": "s1", "cwd": "/u/a", "startedAt": 1792841420186}"#
            .write(to: dir.appendingPathComponent("111.json"), atomically: true, encoding: .utf8)
        try #"{"pid": 222, "sessionId": "s2", "cwd": "/u/b", "startedAt": 1792841420186}"#
            .write(to: dir.appendingPathComponent("222.json"), atomically: true, encoding: .utf8)
        try "secret".write(to: dir.appendingPathComponent("111.abc.key"), atomically: true, encoding: .utf8)
        let open = SessionDrops.openSessions(in: dir.path) { pid, _ in pid == 111 }
        XCTAssertEqual(open.map(\.id), ["s1"])
        XCTAssertTrue(SessionDrops.isRunning(getpid(), started: Date()), "this test's own process runs")
        XCTAssertFalse(SessionDrops.isRunning(getpid(), started: .distantPast), "a pid newer than its session is reused")
    }

    // MARK: - The row

    private func snapshot(_ label: String, name: String = "xapi") -> ServerSnapshot {
        let config = ServerConfig(id: "reg:\(label):global:\(name)", name: name,
                                  source: ServerSource(label: label, path: "/u/.x"), projectPath: nil,
                                  transport: .stdio, command: "/bin/echo", args: [], env: [:], url: nil, headers: [:])
        return ServerSnapshot(config: config, state: .healthy)
    }

    func testAHealthyClaudeCodeRowSaysItWasLost() {
        let drop = SessionDrop(folder: "/u/_KIKA/Recall", at: Date(timeIntervalSince1970: 0))
        let group = HealthMonitor.groupByName([snapshot("Code"), snapshot("Cursor")], sessionDrops: ["xapi": [drop]]).first!
        XCTAssertTrue(group.droppedInSession)
        XCTAssertEqual(ShortReason.line(for: group), "Lost in 1 open Claude Code session: run /mcp there")
        XCTAssertEqual(PanelSections.needsYouRank(group), 2)
        XCTAssertEqual(StatusSnapshot.statusWords(group), "lost in an open Claude Code session")
        XCTAssertEqual(HealthMark.word(for: group), "Lost in a session")
        XCTAssertTrue(PanelText.summary([group]).contains("1 lost in a session"))
        XCTAssertEqual(CardText.sessionDropNote([drop], now: Date(timeIntervalSince1970: 240)),
                       "Claude Code lost it in the open session in Recall 4 min ago. "
                       + "mcpock's own check reaches it, so run /mcp in that session to reconnect.")
        XCTAssertEqual(HealthMonitor.iconState([.healthy], anyDiffers: group.attentionWhileHealthy), .attention)

        let code = AgentSections.server(group, agent: "Code", sources: group.sources)
        XCTAssertEqual(code.note, "Lost in 1 open Claude Code session: run /mcp there")
        XCTAssertNil(AgentSections.server(group, agent: "Cursor", sources: group.sources).note, "Cursor's own row is fine")
    }

    func testOnlyRowsClaudeCodeDeclaresAndOnlyWhileHealthy() {
        let drop = SessionDrop(folder: "/u/a", at: Date())
        XCTAssertFalse(HealthMonitor.groupByName([snapshot("Cursor")], sessionDrops: ["xapi": [drop]]).first!.droppedInSession)
        var broken = snapshot("Code")
        broken.state = .broken
        XCTAssertFalse(HealthMonitor.groupByName([broken], sessionDrops: ["xapi": [drop]]).first!.droppedInSession,
                       "a broken row already says so")
    }

    @MainActor
    func testTheMonitorReadsDropsAfterACheck() async {
        let suite = "mcpock.tests.drops.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        let monitor = HealthMonitor(defaults: defaults, isUpdate: true)
        let config = snapshot("Code").config
        monitor.discover = { [config] }
        monitor.probe = { _, _ in ProbeResult(state: .healthy, failureReason: nil, tools: []) }
        monitor.readSessionDrops = { ["xapi": [SessionDrop(folder: "/u/a", at: Date())]] }
        await monitor.refreshAll()
        XCTAssertTrue(monitor.groups.first?.droppedInSession == true)
        monitor.readSessionDrops = { [:] }
        await monitor.refreshSessionDrops()
        XCTAssertFalse(monitor.groups.first?.droppedInSession == true, "gone once the session reconnects")
    }
}
