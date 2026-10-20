import Foundation
import SQLite3

/// Usage counts (1.7) for Cursor: reads MCP tool calls out of Cursor's own
/// IDE chat database, read-only. Checked against a real Cursor install on
/// 2026-09-26 (see `docs/OBSERVABILITY.md`).
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
/// segment up to the next dash.
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
/// Cursor can also rewrite a bubble after its call finished, which brings
/// the same call back under a new rowid: the keys of calls counted in the
/// last two days are kept in the cursor (`UsageCursor.countedKeys`), and a
/// call older than that behind the newest one counted is a rewrite, never
/// new (Argon 2026-10-17 #10).
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
        guard let (scan, sinceRowid, tableMax) = Self.withOpenDatabase(at: databasePath, body: { db -> (ScanResult, Int64, Int64) in
            let tableMax = Self.queryMaxRowid(db) ?? storedRowid
            let since = storedRowid > tableMax ? 0 : storedRowid
            return (Self.scan(db, sinceRowid: since, knownServers: knownServers), since, tableMax)
        }) else {
            // Neither the direct open nor the copy-and-read fallback worked
            // (e.g. the file vanished between the exists check and here).
            // Not an error: same cursor, no events, try again next time.
            return ([], cursor)
        }

        // Started over (the rowids went back, e.g. a reset or a VACUUM that
        // renumbered them): count only calls newer than the ones already
        // counted, never the old ones a second time. A restart cut short
        // (SQLITE_BUSY) is not kept, so the rows it didn't reach are never
        // read later without that check.
        let restarted = sinceRowid != storedRowid
        guard !restarted || scan.isComplete else { return ([], cursor) }
        // A full scan read every row up to the table's end, other keys too:
        // start past them next time instead of reading them again.
        let reached = scan.isComplete ? max(scan.maxRowid, tableMax) : scan.maxRowid
        guard reached > sinceRowid else {
            // Nothing new. After a reset to an empty table, remember the
            // restart so the stale high cursor isn't kept.
            guard restarted else { return ([], cursor) }
            var reset = cursor
            reset.values[Self.cursorKey] = sinceRowid
            return ([], reset)
        }
        var next = cursor
        next.values[Self.cursorKey] = reached
        let fresh = Self.notYetCounted(scan.calls, cursor: cursor)
        let counted = restarted
            ? fresh.filter { !cursor.uncounted([$0.event], from: Self.cursorKey).isEmpty } : fresh
        let events = counted.map(\.event)
        next.noteCounted(events, from: Self.cursorKey)
        next.countedKeys[Self.cursorKey] = Self.keysToKeep(
            counted, cursor: cursor, newest: next.newest[Self.cursorKey])
        return (events, next)
    }

    /// How long a counted bubble's key is remembered: a bubble Cursor
    /// rewrites after its call finished comes back under a new rowid, so
    /// without its key it was counted again (Argon 2026-10-17 #10). Calls
    /// older than this behind the newest one are rewrites, never new.
    static let keyMemoryMillis: Int64 = 2 * 24 * 3600 * 1000

    /// The calls not counted before: their key is new, and they are not
    /// older than the key memory reaches. Calls that finish out of order
    /// (two at once, the first one slower) still count.
    private static func notYetCounted(_ calls: [Call], cursor: UsageCursor) -> [Call] {
        let seen = cursor.countedKeys[cursorKey] ?? [:]
        let floor = cursor.newest[cursorKey].map { $0 - keyMemoryMillis }
        return calls.filter { call in
            seen[call.key] == nil && floor.map { UsageCursor.millis(call.event.date) > $0 } ?? true
        }
    }

    /// The remembered keys plus this read's counted ones, without those
    /// past the key memory.
    private static func keysToKeep(_ counted: [Call], cursor: UsageCursor, newest: Int64?) -> [String: Int64] {
        var keys = cursor.countedKeys[cursorKey] ?? [:]
        for call in counted {
            keys[call.key] = UsageCursor.millis(call.event.date)
        }
        guard let newest else { return keys }
        return keys.filter { $0.value > newest - keyMemoryMillis }
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

    /// One counted-shape row: its bubble key and the call it records.
    private struct Call {
        let key: String
        let event: UsageEvent
    }

    private struct ScanResult {
        var calls: [Call]
        var maxRowid: Int64
        /// Read to the end (SQLITE_DONE), not stopped by SQLITE_BUSY or an error.
        var isComplete = false
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
               json_extract(value, '$.createdAt'),
               key
        FROM cursorDiskKV
        WHERE key LIKE ? AND rowid > ?
        ORDER BY rowid ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return ScanResult(calls: [], maxRowid: sinceRowid, isComplete: false)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, rowLikePattern, -1, Self.sqliteTransient)
        sqlite3_bind_int64(statement, 2, sinceRowid)

        var calls: [Call] = []
        var maxRowid = sinceRowid
        var isComplete = false
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
                isComplete = step == SQLITE_DONE
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

            let key = Self.columnText(statement, 4) ?? "rowid:\(rowid)"
            calls.append(Call(key: key, event: UsageEvent(agent: "Cursor", server: split.server, date: date)))
        }

        return ScanResult(calls: calls, maxRowid: maxRowid, isComplete: isComplete)
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
    /// the longest dash-joined prefix (after `mcp-`, leaving the tool at
    /// least one segment) whose normalized form is a known server first, then shorter ones, and falls back to the
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
            // At least one segment stays for the tool (Argon 2026-10-17 #14).
            for length in stride(from: parts.count - 1, through: 1, by: -1) {
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
    /// and never writes); if that open itself fails, retries once through
    /// SQLite's `mode=ro&immutable=1` URI form, which reads the file in
    /// place and creates nothing. It used to copy the whole database (chats
    /// included) into the temp folder here, and a crash left that copy
    /// behind (review 2026-10-20, f3ee); usage never keeps chats, so nothing
    /// is copied now. The one cost: an immutable open ignores the `-wal`
    /// sidecar, so bubbles Cursor has not checkpointed yet are missed until
    /// the next scan. Returns nil if neither attempt could open a database.
    /// `skipDirectOpen` lets a test reach the fallback.
    static func withOpenDatabase<T>(
        at path: String,
        skipDirectOpen: Bool = false,
        body: (OpaquePointer) -> T
    ) -> T? {
        if !skipDirectOpen, let result = openAndRun(path, body: body) {
            return result
        }
        var components = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)
        components?.query = "mode=ro&immutable=1"
        guard let uri = components?.string else { return nil }
        return openAndRun(uri, extraFlags: SQLITE_OPEN_URI, body: body)
    }

    private static func openAndRun<T>(
        _ path: String,
        extraFlags: Int32 = 0,
        body: (OpaquePointer) -> T
    ) -> T? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | extraFlags
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
}
