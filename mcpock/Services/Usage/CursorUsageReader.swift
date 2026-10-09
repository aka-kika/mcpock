import Foundation
import SQLite3

/// Usage counts (1.7) for Cursor: reads MCP tool calls out of Cursor's own
/// IDE chat database, read-only. Checked against a real Cursor install on
/// 2026-09-26 (see TODO.md "Usage counts per server" and
/// `docs/OBSERVABILITY.md`).
///
/// **Where the data lives.** Cursor's IDE keeps every chat "bubble" as one
/// row in a single key-value table, `cursorDiskKV` in
/// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
/// (`key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB`, plain SQLite, no
/// other schema). A tool-call bubble's JSON `value` has a `toolFormerData`
/// object: `name` is `mcp-<server>-<tool>` for an MCP call — anything else
/// is one of Cursor's own built-in tools (`read_file_v2`, `ripgrep_raw_search`,
/// and so on) and is not ours to count. The bubble's own top-level `createdAt`
/// (ISO-8601 with milliseconds) is this call's time; every `mcp-` bubble
/// checked had one, so there is no need to fall back to the composer's own
/// timestamps.
///
/// **Splitting the name.** Both the server half and the tool half can
/// contain dashes (`mcp-cursor-ide-browser-browser_cdp`), so `name` alone
/// doesn't say where one ends and the other begins. `split(_:knownServers:)`
/// tries the longest dash-joined prefix (after `mcp-`) whose normalized form
/// (`HealthMonitor.normalizedName`) is in `knownServers` first, then shorter
/// ones; a server nothing configured recognizes falls back to the first
/// segment up to the next dash, per TODO.md.
///
/// **Counting once.** `cursorDiskKV.key` is `UNIQUE ON CONFLICT REPLACE`,
/// which SQLite implements as delete-then-insert, so a bubble Cursor
/// rewrites while it streams keeps the same `key` but gets a *new* rowid
/// each time — the old row is gone, not updated in place. That makes a
/// `rowid`-only cursor safe on its own for any one bubble (the mid-stream
/// row physically no longer exists by the time it's queried again), but it
/// still leaves one real risk: reading mid-stream, before the call has
/// settled. Checked statuses on a real db: `"loading"` while still
/// streaming (never carries an `mcp-` name yet, so it wouldn't be counted
/// anyway), and `"completed"`, `"error"`, `"cancelled"` once settled. Only
/// those three terminal statuses are counted — the server was genuinely
/// called in all three, only the outcome differs — and `"loading"` (or a
/// future status this file doesn't know about) is skipped so the same call
/// is never counted before its result is in and never counted twice across
/// a status change. A `name` of exactly `mcp--` (seen a handful of times,
/// always on an early `"error"` row) has no real server or tool in it and
/// is skipped rather than reported as an empty server.
///
/// **Opening the database.** Cursor keeps this file open continuously in
/// WAL mode. Opening it `SQLITE_OPEN_READONLY` and never issuing a
/// checkpoint is safe for a second reader to do while Cursor runs — that is
/// exactly what a read replica does — so that is the first thing tried,
/// with a busy timeout so a momentary lock clears instead of failing the
/// read. Only if that open itself fails (for example because the `-shm`
/// index doesn't exist yet and this process can't create one) does this
/// reader fall back to copying `state.vscdb` and its `-wal` sidecar to a
/// scratch directory and reading the copy instead; the copy is always
/// removed afterwards. Nothing here ever opens the file for writing and
/// nothing here ever runs `PRAGMA wal_checkpoint`.
struct CursorUsageReader: UsageReader {
    let agent = "Cursor"

    /// The `state.vscdb` path to read. A parameter (not a constant) so tests
    /// point this at a temp file built with the real table shape instead.
    private let databasePath: String

    init(databasePath: String = CursorUsageReader.defaultDatabasePath) {
        self.databasePath = databasePath
    }

    static var defaultDatabasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
    }

    /// This reader's own key into `UsageCursor.values`: the highest rowid of
    /// `cursorDiskKV` seen so far (across every key, not only `bubbleId:`
    /// ones, so it only ever grows).
    static let cursorKey = "cursorRowid"

    private static let rowLikePattern = "bubbleId:%"
    private static let mcpPrefix = "mcp-"

    /// Terminal `toolFormerData.status` values: the call genuinely reached
    /// the MCP server, whatever the outcome. `"loading"` (mid-stream, no
    /// real name attached yet) is the only other status seen and is never
    /// in this set.
    private static let terminalStatuses: Set<String> = ["completed", "error", "cancelled"]

    func read(since cursor: UsageCursor, knownServers: Set<String>) -> (events: [UsageEvent], cursor: UsageCursor) {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            return ([], cursor)
        }

        let storedRowid = cursor.values[Self.cursorKey] ?? 0
        // A cursor past the table's end means Cursor's database was reset
        // (reinstall, history cleared): rowids start low again, and without
        // this the scan found nothing forever (review, 2026-09-26). Start over,
        // as the Hermes reader does.
        guard let (scan, sinceRowid) = Self.withOpenDatabase(at: databasePath, body: { db -> (ScanResult, Int64) in
            let tableMax = Self.queryMaxRowid(db) ?? storedRowid
            let since = storedRowid > tableMax ? 0 : storedRowid
            return (Self.scan(db, sinceRowid: since, knownServers: knownServers), since)
        }) else {
            // Neither the direct open nor the copy-and-read fallback worked
            // (e.g. the file vanished between the exists check and here).
            // Not an error: same cursor, no events, try again next time.
            return ([], cursor)
        }

        guard scan.maxRowid > sinceRowid else {
            // Nothing new. After a reset to an empty table, remember the
            // restart so the stale high cursor isn't kept.
            guard sinceRowid != storedRowid else { return ([], cursor) }
            var reset = cursor.values
            reset[Self.cursorKey] = sinceRowid
            return ([], UsageCursor(values: reset))
        }
        var nextValues = cursor.values
        nextValues[Self.cursorKey] = scan.maxRowid
        return (scan.events, UsageCursor(values: nextValues))
    }

    // MARK: - Scanning

    private static func queryMaxRowid(_ db: OpaquePointer) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(rowid), 0) FROM cursorDiskKV", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private struct ScanResult {
        var events: [UsageEvent]
        var maxRowid: Int64
    }

    /// Reads every `bubbleId:` row past `sinceRowid`, in rowid order, and
    /// turns the terminal MCP-call ones into events. `maxRowid` is the
    /// highest rowid seen among *all* matching rows (even ones that were
    /// skipped), so a run of non-MCP or mid-stream bubbles still advances
    /// the cursor and is never rescanned.
    private static func scan(
        _ db: OpaquePointer, sinceRowid: Int64, knownServers: Set<String>
    ) -> ScanResult {
        let sql = """
        SELECT rowid,
               json_extract(value, '$.toolFormerData.name'),
               json_extract(value, '$.toolFormerData.status'),
               json_extract(value, '$.createdAt')
        FROM cursorDiskKV
        WHERE key LIKE ? AND rowid > ?
        ORDER BY rowid ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return ScanResult(events: [], maxRowid: sinceRowid)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, rowLikePattern, -1, Self.sqliteTransient)
        sqlite3_bind_int64(statement, 2, sinceRowid)

        var events: [UsageEvent] = []
        var maxRowid = sinceRowid
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFraction = ISO8601DateFormatter()

        while true {
            let step = sqlite3_step(statement)
            guard step == SQLITE_ROW else {
                // SQLITE_DONE ends the scan; SQLITE_BUSY (or any other
                // error) stops here rather than looping forever — whatever
                // rows were already read still count, and the cursor only
                // advances to the last one actually seen.
                break
            }
            let rowid = sqlite3_column_int64(statement, 0)
            if rowid > maxRowid { maxRowid = rowid }

            guard let name = Self.columnText(statement, 1),
                  name.hasPrefix(mcpPrefix), name != "mcp--" else { continue }
            guard let status = Self.columnText(statement, 2), terminalStatuses.contains(status) else { continue }
            guard let split = split(name, knownServers: knownServers) else { continue }
            guard let createdAt = Self.columnText(statement, 3) else { continue }
            guard let date = isoFormatter.date(from: createdAt) ?? isoFormatterNoFraction.date(from: createdAt) else {
                continue
            }

            events.append(UsageEvent(agent: "Cursor", server: split.server, date: date))
        }

        return ScanResult(events: events, maxRowid: maxRowid)
    }

    private static func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    /// `SQLITE_TRANSIENT`: tells SQLite to copy the bound string, since ours
    /// is a short-lived Swift value.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Splitting `mcp-<server>-<tool>`

    /// Splits an MCP tool-call name into its server and tool halves. Tries
    /// the longest dash-joined prefix (after `mcp-`) whose normalized form
    /// is a known server first, then shorter ones, and falls back to the
    /// first segment up to the next dash when nothing matches. Returns nil
    /// for a name that isn't `mcp-` at all, or whose server half would be
    /// empty.
    static func split(_ name: String, knownServers: Set<String>) -> (server: String, tool: String)? {
        guard name.hasPrefix(mcpPrefix) else { return nil }
        let rest = String(name.dropFirst(mcpPrefix.count))
        let parts = rest.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, !first.isEmpty else { return nil }

        var matchLength = 1
        if parts.count > 1 {
            for length in stride(from: parts.count, through: 1, by: -1) {
                let candidate = parts[0..<length].joined(separator: "-")
                if knownServers.contains(HealthMonitor.normalizedName(candidate)) {
                    matchLength = length
                    break
                }
            }
        }
        let server = parts[0..<matchLength].joined(separator: "-")
        let tool = parts[matchLength...].joined(separator: "-")
        return (server, tool)
    }

    // MARK: - Opening the database safely

    /// Opens `path` read-only and runs `body`, closing the connection
    /// afterwards either way. Tries the file directly first (safe to do
    /// against Cursor's live, WAL-mode database — this never checkpoints
    /// and never writes); if that open itself fails, copies the database
    /// and its `-wal` sidecar to a scratch directory and retries against the
    /// copy, which is always removed before returning. Returns nil if
    /// neither attempt could open a database.
    private static func withOpenDatabase<T>(at path: String, body: (OpaquePointer) -> T) -> T? {
        if let result = openAndRun(path, body: body) {
            return result
        }
        guard let snapshotDirectory = try? makeSnapshot(of: path) else { return nil }
        defer { try? FileManager.default.removeItem(at: snapshotDirectory) }
        let snapshotPath = snapshotDirectory.appendingPathComponent("state.vscdb").path
        return openAndRun(snapshotPath, body: body)
    }

    private static func openAndRun<T>(_ path: String, body: (OpaquePointer) -> T) -> T? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        // A generous timeout: Cursor's writer holding a brief lock should
        // clear well within this, and this reader would rather wait a
        // moment than skip a whole scan.
        sqlite3_busy_timeout(db, 5_000)
        return body(db)
    }

    /// Copies `path` (and its `-wal` sidecar, if present — the bubbles
    /// Cursor hasn't checkpointed into the main file yet live there) into a
    /// fresh temp directory. Read-only against the source: `copyItem` never
    /// opens it for writing. The caller removes the returned directory.
    private static func makeSnapshot(of path: String) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("mcpock-cursor-usage-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("state.vscdb")
        try fileManager.copyItem(atPath: path, toPath: destination.path)
        let walSource = path + "-wal"
        if fileManager.fileExists(atPath: walSource) {
            try? fileManager.copyItem(atPath: walSource, toPath: destination.path + "-wal")
        }
        return directory
    }
}
