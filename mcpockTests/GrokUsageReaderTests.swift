import XCTest
@testable import mcpock

/// Fixture shapes are modelled on real `~/.grok/sessions/<encoded cwd>/<session
/// id>/events.jsonl` lines (checked 2026-09-26), with invented server/tool
/// names and timestamps.
final class GrokUsageReaderTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-grok-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// `~/.grok/sessions/<url-encoded cwd>/<session id>/events.jsonl`
    private func eventsPath(cwd: String = "%2FUsers%2Fdemo%2Fproject", session: String = "01a0test-0000-0000-0000-000000000001") -> URL {
        tempRoot
            .appendingPathComponent(cwd, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = lines.map { $0 + "\n" }.joined()
        try content.data(using: .utf8)!.write(to: url)
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        let content = lines.map { $0 + "\n" }.joined()
        handle.write(content.data(using: .utf8)!)
    }

    private func mcpCallStarted(server: String, tool: String, ts: String) -> String {
        """
        {"ts":"\(ts)","type":"mcp_tool_call_started","server_name":"\(server)","tool_name":"\(tool)","call_id":"\(server)__\(tool)","timeout_sec":6000}
        """
    }

    private func mcpCallCompleted(server: String, tool: String, ts: String) -> String {
        """
        {"ts":"\(ts)","type":"mcp_tool_call_completed","server_name":"\(server)","tool_name":"\(tool)","call_id":"\(server)__\(tool)","duration_ms":420,"success":true,"is_timeout":false,"reconnect_attempted":false,"auth_retry_attempted":false}
        """
    }

    // MARK: - Tests

    /// A real-shaped started+completed pair for the same call must be counted
    /// exactly once (the reader only looks at `mcp_tool_call_started`).
    func testRealShapedCallCountedOnce() throws {
        let path = eventsPath()
        try write([
            mcpCallStarted(server: "reed-md", tool: "note_get_active", ts: "2026-09-20T10:00:00.100Z"),
            mcpCallCompleted(server: "reed-md", tool: "note_get_active", ts: "2026-09-20T10:00:00.550Z"),
        ], to: path)

        let reader = GrokUsageReader(root: tempRoot)
        let (events, _) = reader.read(since: .empty, knownServers: [])

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.agent, "Grok")
        XCTAssertEqual(events.first?.server, "reed-md")
    }

    /// A non-MCP tool call (no `server_name`, generic `tool_started`) never
    /// produces a `UsageEvent`.
    func testNonMCPToolIgnored() throws {
        let path = eventsPath()
        try write([
            #"{"ts":"2026-09-20T10:00:00.000Z","type":"tool_started","tool_name":"search_tool"}"#,
            #"{"ts":"2026-09-20T10:00:00.050Z","type":"tool_completed","tool_name":"search_tool"}"#,
            mcpCallStarted(server: "wigolo", tool: "search", ts: "2026-09-20T10:00:01.000Z"),
        ], to: path)

        let reader = GrokUsageReader(root: tempRoot)
        let (events, _) = reader.read(since: .empty, knownServers: [])

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.server, "wigolo")
    }

    /// Two distinct calls to different servers both count.
    func testTwoCallsCounted() throws {
        let path = eventsPath()
        try write([
            mcpCallStarted(server: "wigolo", tool: "search", ts: "2026-09-20T10:00:00.000Z"),
            mcpCallStarted(server: "skill-librarian", tool: "librarian_find", ts: "2026-09-20T10:00:05.000Z"),
        ], to: path)

        let reader = GrokUsageReader(root: tempRoot)
        let (events, _) = reader.read(since: .empty, knownServers: [])

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.server)), ["wigolo", "skill-librarian"])
    }

    /// A second read with the cursor from the first only reports new lines.
    func testIncrementalSecondReadOnlyReturnsNewEvents() throws {
        let path = eventsPath()
        try write([
            mcpCallStarted(server: "wigolo", tool: "search", ts: "2026-09-20T10:00:00.000Z"),
        ], to: path)

        let reader = GrokUsageReader(root: tempRoot)
        let (firstEvents, cursor1) = reader.read(since: .empty, knownServers: [])
        XCTAssertEqual(firstEvents.count, 1)

        try append([
            mcpCallStarted(server: "skill-librarian", tool: "librarian_find", ts: "2026-09-20T10:00:10.000Z"),
        ], to: path)

        let (secondEvents, cursor2) = reader.read(since: cursor1, knownServers: [])
        XCTAssertEqual(secondEvents.count, 1)
        XCTAssertEqual(secondEvents.first?.server, "skill-librarian")

        // Reading again with the latest cursor and no new lines yields nothing.
        let (thirdEvents, _) = reader.read(since: cursor2, knownServers: [])
        XCTAssertEqual(thirdEvents.count, 0)
    }

    /// A file that gets replaced (new inode, e.g. deleted and rewritten) is
    /// read from the start rather than skipped as already-seen.
    func testReplacedFileIsReadFromStart() throws {
        let path = eventsPath()
        try write([
            mcpCallStarted(server: "wigolo", tool: "search", ts: "2026-09-20T10:00:00.000Z"),
        ], to: path)

        let reader = GrokUsageReader(root: tempRoot)
        let (firstEvents, cursor1) = reader.read(since: .empty, knownServers: [])
        XCTAssertEqual(firstEvents.count, 1)

        // Simulate the session file being replaced outright (new content,
        // new inode), the way a rotated or rewritten log would look.
        try FileManager.default.removeItem(at: path)
        try write([
            mcpCallStarted(server: "skill-librarian", tool: "librarian_find", ts: "2026-09-21T09:00:00.000Z"),
        ], to: path)

        let (secondEvents, _) = reader.read(since: cursor1, knownServers: [])
        XCTAssertEqual(secondEvents.count, 1)
        XCTAssertEqual(secondEvents.first?.server, "skill-librarian")
    }

    /// A malformed line is skipped, never crashes, and does not stop the
    /// valid lines around it from being read.
    func testBadJSONLineSkipped() throws {
        let path = eventsPath()
        try write([
            mcpCallStarted(server: "wigolo", tool: "search", ts: "2026-09-20T10:00:00.000Z"),
            "{not valid json at all",
            mcpCallStarted(server: "skill-librarian", tool: "librarian_find", ts: "2026-09-20T10:00:05.000Z"),
        ], to: path)

        let reader = GrokUsageReader(root: tempRoot)
        let (events, _) = reader.read(since: .empty, knownServers: [])

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.server)), ["wigolo", "skill-librarian"])
    }

    /// A missing sessions folder returns no events and hands back the same
    /// cursor unchanged, rather than throwing or crashing.
    func testMissingFolderReturnsNoEventsSameCursor() {
        let missingRoot = tempRoot.appendingPathComponent("does-not-exist", isDirectory: true)
        let reader = GrokUsageReader(root: missingRoot)
        let cursor = UsageCursor.empty
        let (events, returnedCursor) = reader.read(since: cursor, knownServers: [])

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(returnedCursor, cursor)
    }

    func testAgentLabelIsGrok() {
        XCTAssertEqual(GrokUsageReader(root: tempRoot).agent, "Grok")
    }
}
