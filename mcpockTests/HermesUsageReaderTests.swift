import XCTest
import SQLite3
@testable import mcpock

private let SQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class HermesUsageReaderTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcpock-hermes-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    /// One row as `state.db`'s `messages` table would hold it. `toolName` nil
    /// writes SQL NULL.
    private struct Row {
        let role: String
        let toolName: String?
        let timestamp: Double?
        init(role: String = "tool", toolName: String?, timestamp: Double? = 1_780_000_000) {
            self.role = role
            self.toolName = toolName
            self.timestamp = timestamp
        }
    }

    /// Writes a minimal `state.db` (just the `messages` shape this reader
    /// reads) at `path`, creating parent directories as needed.
    private func makeStateDB(at path: String, rows: [Row]) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT,
                role TEXT NOT NULL,
                tool_name TEXT,
                timestamp REAL
            )
            """, nil, nil, nil), SQLITE_OK)

        for row in rows {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(
                db, "INSERT INTO messages (session_id, role, tool_name, timestamp) VALUES ('s', ?, ?, ?)",
                -1, &stmt, nil
            ), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, row.role, -1, SQLiteTransient)
            if let toolName = row.toolName {
                sqlite3_bind_text(stmt, 2, toolName, -1, SQLiteTransient)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            if let timestamp = row.timestamp {
                sqlite3_bind_double(stmt, 3, timestamp)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        }
    }

    private func appendRow(to path: String, _ row: Row) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            db, "INSERT INTO messages (session_id, role, tool_name, timestamp) VALUES ('s', ?, ?, ?)",
            -1, &stmt, nil
        ), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, row.role, -1, SQLiteTransient)
        sqlite3_bind_text(stmt, 2, row.toolName!, -1, SQLiteTransient)
        sqlite3_bind_double(stmt, 3, row.timestamp!)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }

    // MARK: - Splitting

    /// Hermes joins the server and tool with underscores on both sides
    /// (`mcp_skill_librarian_librarian_find`), so the splitter must try the
    /// longest run of words first: "skill_librarian_librarian" isn't a known
    /// server, but "skill_librarian" is.
    func testMCPCallWithUnderscoreSplitServerNameIsReadAndNonMCPToolIsIgnored() throws {
        let dbPath = home.appendingPathComponent("state.db").path
        try makeStateDB(at: dbPath, rows: [
            Row(toolName: "mcp_skill_librarian_librarian_find", timestamp: 1_780_000_000),
            Row(toolName: "terminal"), // a native tool, never a call to report
        ])
        let reader = HermesUsageReader(hermesHome: home.path)
        let (events, _) = reader.read(since: .empty, knownServers: ["skilllibrarian"])

        XCTAssertEqual(events.count, 1, "the native 'terminal' row must not turn into an event")
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.agent, "Hermes")
        XCTAssertEqual(event.server, "skill_librarian")
        XCTAssertEqual(event.date, Date(timeIntervalSince1970: 1_780_000_000))
    }

    /// No known server is a prefix of the remainder: report the first word,
    /// per the contract's fallback.
    func testUnknownServerFallsBackToFirstSegment() throws {
        let dbPath = home.appendingPathComponent("state.db").path
        try makeStateDB(at: dbPath, rows: [Row(toolName: "mcp_widget_bar_thing")])
        let reader = HermesUsageReader(hermesHome: home.path)
        let (events, _) = reader.read(since: .empty, knownServers: ["skilllibrarian"])
        XCTAssertEqual(events.map(\.server), ["widget"])
    }

    // MARK: - Profiles

    /// A profile with its own `state.db` reports under "Hermes · <name>",
    /// same label mcpock already uses for a profile's scanned config.
    func testProfileSessionReportsUnderHermesDotName() throws {
        try makeStateDB(at: home.appendingPathComponent("state.db").path, rows: [])
        try makeStateDB(
            at: home.appendingPathComponent("profiles/scribe/state.db").path,
            rows: [Row(toolName: "mcp_higgsfield_transactions")]
        )
        let reader = HermesUsageReader(hermesHome: home.path)
        let (events, _) = reader.read(since: .empty, knownServers: ["higgsfield"])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.agent, "Hermes · scribe")
        XCTAssertEqual(events.first?.server, "higgsfield")
    }

    // MARK: - Incremental reads

    func testIncrementalSecondReadOnlyReturnsNewCalls() throws {
        let dbPath = home.appendingPathComponent("state.db").path
        try makeStateDB(at: dbPath, rows: [Row(toolName: "mcp_higgsfield_transactions", timestamp: 1_780_000_000)])
        let reader = HermesUsageReader(hermesHome: home.path)

        let (firstEvents, cursor) = reader.read(since: .empty, knownServers: ["higgsfield"])
        XCTAssertEqual(firstEvents.count, 1)

        // Same cursor again, nothing new yet.
        let (repeatEvents, sameCursor) = reader.read(since: cursor, knownServers: ["higgsfield"])
        XCTAssertEqual(repeatEvents.count, 0)
        XCTAssertEqual(sameCursor, cursor)

        try appendRow(to: dbPath, Row(toolName: "mcp_higgsfield_balance", timestamp: 1_780_000_100))
        let (secondEvents, _) = reader.read(since: cursor, knownServers: ["higgsfield"])
        XCTAssertEqual(secondEvents.count, 1, "only the new row, not the one already read")
        XCTAssertEqual(secondEvents.first?.date, Date(timeIntervalSince1970: 1_780_000_100))
    }

    // MARK: - Bad data

    /// A row that can't be turned into a server name (`mcp` with nothing
    /// after it) or has no usable timestamp is skipped, not a crash, and
    /// doesn't stop the rows around it from being read.
    func testBadLineIsSkipped() throws {
        try makeStateDB(at: home.appendingPathComponent("state.db").path, rows: [
            Row(toolName: "mcp_", timestamp: 1_780_000_000),
            Row(toolName: "mcp_higgsfield_transactions", timestamp: 0),
            Row(toolName: "mcp_higgsfield_balance", timestamp: 1_780_000_200),
        ])
        let reader = HermesUsageReader(hermesHome: home.path)
        let (events, _) = reader.read(since: .empty, knownServers: ["higgsfield"])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.server, "higgsfield")
    }

    // MARK: - Missing store

    func testMissingStoreReturnsNoEventsAndSameCursor() {
        let reader = HermesUsageReader(hermesHome: home.appendingPathComponent("nope").path)
        let (events, cursor) = reader.read(since: .empty, knownServers: [])
        XCTAssertEqual(events, [])
        XCTAssertEqual(cursor, .empty)
    }
}
