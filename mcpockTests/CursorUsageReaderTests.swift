import XCTest
import SQLite3
@testable import mcpock

/// Usage counts (1.7), Cursor: builds a temp SQLite db with the real
/// `cursorDiskKV` table shape and real-shaped (invented) JSON bubbles, since
/// `CursorUsageReader` takes its database path as an init parameter for
/// exactly this. No real Cursor data is ever touched here.
final class CursorUsageReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcpock-cursor-usage-test-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture database

    /// A tiny stand-in for `state.vscdb`: same table, same `key`/`value`
    /// shape, opened read-write only by the test so it can insert bubbles
    /// the way Cursor itself would (a plain `INSERT`, letting
    /// `ON CONFLICT REPLACE` simulate Cursor rewriting a bubble mid-stream).
    private final class Fixture {
        let path: String
        private var db: OpaquePointer?

        init(at path: String) {
            self.path = path
            XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
            exec("CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);")
        }

        deinit { sqlite3_close(db) }

        private func exec(_ sql: String) {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }

        /// Inserts (or, for a repeated `key`, replaces) one bubble row.
        func putBubble(key: String, name: String?, status: String?, createdAt: String) {
            let value = Self.bubbleJSON(name: name, status: status, createdAt: createdAt)
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(db, "INSERT INTO cursorDiskKV (key, value) VALUES (?, ?);", -1, &statement, nil),
                SQLITE_OK
            )
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, key, -1, transient)
            sqlite3_bind_text(statement, 2, value, -1, transient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }

        private static func bubbleJSON(name: String?, status: String?, createdAt: String) -> String {
            var toolFormerData = "null"
            if let name {
                let statusField = status.map { "\"\($0)\"" } ?? "null"
                toolFormerData = #"{"name":"\#(name)","status":\#(statusField),"toolCallId":"call-test"}"#
            }
            return #"{"bubbleId":"b","createdAt":"\#(createdAt)","toolFormerData":\#(toolFormerData)}"#
        }
    }

    // MARK: - Tests

    /// An MCP call whose server name itself has a dash splits against
    /// `knownServers`, not on the first dash.
    func testKnownServerDashedNameSplits() {
        let fixture = Fixture(at: root.appendingPathComponent("state.vscdb").path)
        fixture.putBubble(
            key: "bubbleId:composer-1:bubble-1",
            name: "mcp-cursor-ide-browser-browser_cdp",
            status: "completed",
            createdAt: "2026-09-20T10:00:00.000Z"
        )
        let reader = CursorUsageReader(databasePath: fixture.path)
        let knownServers: Set<String> = [HealthMonitor.normalizedName("cursor-ide-browser")]

        let result = reader.read(since: .empty, knownServers: knownServers)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.agent, "Cursor")
        XCTAssertEqual(result.events.first?.server, "cursor-ide-browser")
    }

    /// A name with no known server anywhere falls back to the first
    /// dash-separated segment, per TODO.md.
    func testUnknownServerFallsBackToFirstSegment() {
        let fixture = Fixture(at: root.appendingPathComponent("state.vscdb").path)
        fixture.putBubble(
            key: "bubbleId:composer-1:bubble-1",
            name: "mcp-neverconfigured-server-do_thing",
            status: "completed",
            createdAt: "2026-09-20T10:00:00.000Z"
        )
        let reader = CursorUsageReader(databasePath: fixture.path)

        let result = reader.read(since: .empty, knownServers: [])

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.server, "neverconfigured")
    }

    /// A bubble that isn't an MCP call (Cursor's own built-in tools) is
    /// never reported.
    func testNonMCPToolIsIgnored() {
        let fixture = Fixture(at: root.appendingPathComponent("state.vscdb").path)
        fixture.putBubble(
            key: "bubbleId:composer-1:bubble-1",
            name: "read_file_v2",
            status: "completed",
            createdAt: "2026-09-20T10:00:00.000Z"
        )
        fixture.putBubble(
            key: "bubbleId:composer-1:bubble-2",
            name: "mcp-testserver-do_thing",
            status: "completed",
            createdAt: "2026-09-20T10:00:01.000Z"
        )
        let reader = CursorUsageReader(databasePath: fixture.path)

        let result = reader.read(since: .empty, knownServers: [HealthMonitor.normalizedName("testserver")])

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.server, "testserver")
    }

    /// Cursor rewrites the same bubble key while a call streams in (a
    /// mid-stream `"loading"` write, then a settled `"completed"` write,
    /// same `key` — `ON CONFLICT REPLACE` means only the second physically
    /// remains). The call is counted exactly once.
    func testStreamedDuplicateIsCountedOnce() {
        let fixture = Fixture(at: root.appendingPathComponent("state.vscdb").path)
        let key = "bubbleId:composer-1:bubble-1"
        fixture.putBubble(key: key, name: "mcp-testserver-do_thing", status: "loading", createdAt: "2026-09-20T10:00:00.000Z")
        fixture.putBubble(key: key, name: "mcp-testserver-do_thing", status: "completed", createdAt: "2026-09-20T10:00:01.000Z")
        let reader = CursorUsageReader(databasePath: fixture.path)

        let result = reader.read(since: .empty, knownServers: [HealthMonitor.normalizedName("testserver")])

        XCTAssertEqual(result.events.count, 1)
    }

    /// A second read, using the cursor the first read returned, sees only
    /// calls written after it.
    func testIncrementalReadOnlyReturnsNewCalls() {
        let path = root.appendingPathComponent("state.vscdb").path
        let fixture = Fixture(at: path)
        fixture.putBubble(
            key: "bubbleId:composer-1:bubble-1",
            name: "mcp-serverone-do_thing",
            status: "completed",
            createdAt: "2026-09-20T10:00:00.000Z"
        )
        let reader = CursorUsageReader(databasePath: path)
        let knownServers: Set<String> = [
            HealthMonitor.normalizedName("serverone"), HealthMonitor.normalizedName("servertwo"),
        ]

        let first = reader.read(since: .empty, knownServers: knownServers)
        XCTAssertEqual(first.events.map(\.server), ["serverone"])

        fixture.putBubble(
            key: "bubbleId:composer-1:bubble-2",
            name: "mcp-servertwo-do_other_thing",
            status: "completed",
            createdAt: "2026-09-20T10:00:02.000Z"
        )
        let second = reader.read(since: first.cursor, knownServers: knownServers)
        XCTAssertEqual(second.events.map(\.server), ["servertwo"])

        // Reading again with the latest cursor and nothing new written
        // yields no events and the same cursor.
        let third = reader.read(since: second.cursor, knownServers: knownServers)
        XCTAssertTrue(third.events.isEmpty)
        XCTAssertEqual(third.cursor, second.cursor)
    }

    /// Cursor's database was reset (reinstall, history cleared): the stored
    /// cursor is past the table's end. The reader starts over instead of
    /// finding nothing forever (review, 2026-09-26).
    func testResetDatabaseStartsOver() {
        let path = root.appendingPathComponent("state.vscdb").path
        let fixture = Fixture(at: path)
        fixture.putBubble(
            key: "bubbleId:composer-1:bubble-1",
            name: "mcp-serverone-do_thing",
            status: "completed",
            createdAt: "2026-09-20T10:00:00.000Z"
        )
        let reader = CursorUsageReader(databasePath: path)
        let stale = UsageCursor(values: [CursorUsageReader.cursorKey: 5_000])
        let result = reader.read(since: stale, knownServers: [HealthMonitor.normalizedName("serverone")])
        XCTAssertEqual(result.events.map(\.server), ["serverone"])
        XCTAssertEqual(result.cursor.values[CursorUsageReader.cursorKey], 1)
    }

    /// Started over with calls already counted still in the table (a VACUUM
    /// renumbers rowids too): only the newer call counts (review, 2026-10-14,
    /// item 11).
    func testResetDatabaseNeverCountsOldCallsTwice() {
        let path = root.appendingPathComponent("state.vscdb").path
        let fixture = Fixture(at: path)
        fixture.putBubble(key: "bubbleId:c:old", name: "mcp-serverone-do_thing", status: "completed", createdAt: "2026-09-20T10:00:00.000Z")
        fixture.putBubble(key: "bubbleId:c:new", name: "mcp-servertwo-do_thing", status: "completed", createdAt: "2026-09-21T10:00:00.000Z")
        let counted = ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z")!
        let stale = UsageCursor(values: [CursorUsageReader.cursorKey: 5_000], newest: [CursorUsageReader.cursorKey: UsageCursor.millis(counted)])
        let result = CursorUsageReader(databasePath: path).read(since: stale, knownServers: [])
        XCTAssertEqual(result.events.map(\.server), ["servertwo"])
        XCTAssertEqual(result.cursor.values[CursorUsageReader.cursorKey], 2)
    }

    /// Argon 2026-10-17 #10: Cursor rewrites a finished bubble (same key,
    /// new rowid); the call was counted a second time.
    func testFinishedBubbleRewrittenLaterIsNotCountedAgain() {
        let path = root.appendingPathComponent("state.vscdb").path
        let fixture = Fixture(at: path)
        let key = "bubbleId:c:one"
        fixture.putBubble(key: key, name: "mcp-serverone-do_thing", status: "completed", createdAt: "2026-09-20T10:00:00.000Z")
        let reader = CursorUsageReader(databasePath: path)
        let first = reader.read(since: .empty, knownServers: [])
        XCTAssertEqual(first.events.count, 1)

        fixture.putBubble(key: key, name: "mcp-serverone-do_thing", status: "completed", createdAt: "2026-09-20T10:00:00.000Z")
        let second = reader.read(since: first.cursor, knownServers: [])
        XCTAssertTrue(second.events.isEmpty, "the rewrite is the same call")
        XCTAssertEqual(second.cursor.values[CursorUsageReader.cursorKey], 2, "and it is not read again")

        // Saved and loaded like usage.json does: the memory survives.
        let saved = try! JSONDecoder().decode(UsageCursor.self, from: JSONEncoder().encode(second.cursor))
        fixture.putBubble(key: key, name: "mcp-serverone-do_thing", status: "completed", createdAt: "2026-09-20T10:00:00.000Z")
        XCTAssertTrue(reader.read(since: saved, knownServers: []).events.isEmpty)
    }

    /// Two calls at once, the first one slower: it finishes after the
    /// second was counted and still counts.
    func testCallsFinishingOutOfOrderBothCount() {
        let path = root.appendingPathComponent("state.vscdb").path
        let fixture = Fixture(at: path)
        fixture.putBubble(key: "bubbleId:c:late", name: "mcp-serverone-a", status: "loading", createdAt: "2026-09-20T10:00:00.000Z")
        fixture.putBubble(key: "bubbleId:c:fast", name: "mcp-servertwo-b", status: "completed", createdAt: "2026-09-20T10:00:05.000Z")
        let reader = CursorUsageReader(databasePath: path)
        let first = reader.read(since: .empty, knownServers: [])
        XCTAssertEqual(first.events.map(\.server), ["servertwo"])

        fixture.putBubble(key: "bubbleId:c:late", name: "mcp-serverone-a", status: "completed", createdAt: "2026-09-20T10:00:00.000Z")
        XCTAssertEqual(reader.read(since: first.cursor, knownServers: []).events.map(\.server), ["serverone"])
    }

    /// A rewrite of a call older than the key memory is never new.
    func testRewriteOfAnOldCallIsNotCounted() {
        let path = root.appendingPathComponent("state.vscdb").path
        let fixture = Fixture(at: path)
        fixture.putBubble(key: "bubbleId:c:old", name: "mcp-serverone-a", status: "completed", createdAt: "2026-09-01T10:00:00.000Z")
        let newest = ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z")!
        let cursor = UsageCursor(values: [CursorUsageReader.cursorKey: 0], newest: [CursorUsageReader.cursorKey: UsageCursor.millis(newest)])
        XCTAssertTrue(CursorUsageReader(databasePath: path).read(since: cursor, knownServers: []).events.isEmpty)
    }

    /// A full read starts past the table's last row, other keys too, so
    /// they are not read again every time.
    func testCursorAdvancesPastOtherKeys() {
        let path = root.appendingPathComponent("state.vscdb").path
        let fixture = Fixture(at: path)
        fixture.putBubble(key: "bubbleId:c:one", name: "mcp-serverone-a", status: "completed", createdAt: "2026-09-20T10:00:00.000Z")
        fixture.putBubble(key: "composerData:c", name: nil, status: nil, createdAt: "2026-09-20T10:00:01.000Z")
        fixture.putBubble(key: "composerData:d", name: nil, status: nil, createdAt: "2026-09-20T10:00:02.000Z")
        let result = CursorUsageReader(databasePath: path).read(since: .empty, knownServers: [])
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.cursor.values[CursorUsageReader.cursorKey], 3)
    }

    /// A missing database is not an error: no events, same cursor back.
    func testMissingDatabaseReturnsNoEventsSameCursor() {
        let missingPath = root.appendingPathComponent("does-not-exist.vscdb").path
        let reader = CursorUsageReader(databasePath: missingPath)
        let startingCursor = UsageCursor(values: ["whatever": 42])

        let result = reader.read(since: startingCursor, knownServers: [])

        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.cursor, startingCursor)
    }

    /// The fallback open reads the database in place and copies nothing
    /// (review 2026-10-20, f3ee): no `mcpock-cursor-usage-*` entry appears in
    /// the temp folder, and the rows still read.
    func testFallbackOpenLeavesNoCopyInTempFolder() throws {
        let path = root.appendingPathComponent("state.vscdb").path
        let fixture = Fixture(at: path)
        fixture.putBubble(key: "bubbleId:a:1", name: "mcp-demo-run", status: "completed", createdAt: "2026-01-01T00:00:00.000Z")

        let tempFolder = FileManager.default.temporaryDirectory
        func copies() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: tempFolder.path)) ?? [])
                .filter { $0.hasPrefix("mcpock-cursor-usage-") && !$0.hasPrefix("mcpock-cursor-usage-test-") })
        }
        let before = copies()

        let count: Int32? = CursorUsageReader.withOpenDatabase(at: path, skipDirectOpen: true) { db in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM cursorDiskKV;", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else { return -1 }
            return sqlite3_column_int(statement, 0)
        }

        XCTAssertEqual(count, 1)
        XCTAssertEqual(copies(), before)
    }

    /// `agent` reports "Cursor", exactly as `UsageEvent.agent` expects.
    func testAgentLabelIsCursor() {
        let reader = CursorUsageReader(databasePath: root.appendingPathComponent("state.vscdb").path)
        XCTAssertEqual(reader.agent, "Cursor")
    }

    /// Argon 2026-10-17 #14: `memory`'s `search` is not the server `memory-search`.
    func testSplitLeavesTheToolAtLeastOneSegment() {
        let split = CursorUsageReader.split("mcp-memory-search", knownServers: ["memory", "memorysearch"])
        XCTAssertEqual(split?.server, "memory")
        XCTAssertEqual(split?.tool, "search")
        XCTAssertEqual(HermesUsageReader.serverName(from: "mcp_memory_search", knownServers: ["memory", "memorysearch"]),
                       "memory")
    }
}
