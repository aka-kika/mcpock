import Foundation
import SQLite3

/// Reads Hermes' MCP tool-call history, read-only.
///
/// Investigated against a real `~/.hermes` (2026-09-26): the per-session
/// transcripts (`sessions/*.jsonl`) never carry the real tool name for an MCP
/// call — the model's own `tool_calls` name a generic wrapper (`execute_code`,
/// `terminal`) that runs the MCP call from inside; across all 339 real session
/// files, zero `tool_calls` or tool-result entries were ever named `mcp_...`.
/// The real, per-call name only shows up in `state.db`'s `messages` table
/// (`role = 'tool'`, `tool_name` set, one row per completed call, a real Unix
/// `timestamp`). So `state.db` — the main one and each profile's own copy —
/// is the complete, timestamped store this reader uses; the jsonl files are
/// not read.
///
/// Hermes has written that `tool_name` two ways over time: `mcp_<server>_<tool>`
/// and `mcp__<server>__<tool>`. Splitting on runs of `_` and dropping empty
/// pieces collapses both to the same word list, so one splitter handles both.
struct HermesUsageReader: UsageReader {
    let agent = "Hermes"

    /// `~/.hermes` by default; a param so tests point at a temp dir.
    private let hermesHome: String

    init(hermesHome: String = "~/.hermes") {
        self.hermesHome = (hermesHome as NSString).expandingTildeInPath
    }

    func read(since cursor: UsageCursor, knownServers: Set<String>) -> (events: [UsageEvent], cursor: UsageCursor) {
        var next = cursor
        var events: [UsageEvent] = []

        // The main state.db, then every profile that keeps its own: each
        // gets its own cursor entry, and a profile reports under
        // "Hermes · <name>" (the label mcpock already uses for a profile's
        // scanned config, `ConfigDiscovery.label`).
        var stores = [(key: "main", path: hermesHome + "/state.db", label: agent)]
        for name in Self.profileNames(hermesHome: hermesHome) {
            stores.append((key: "profile:\(name)", path: hermesHome + "/profiles/\(name)/state.db", label: "\(agent) · \(name)"))
        }
        for store in stores {
            var (found, lastID, restarted) = Self.readStore(
                path: store.path,
                agentLabel: store.label,
                knownServers: knownServers,
                since: next.values[store.key] ?? 0
            )
            // Its row ids went back (reset or replaced): count only calls
            // newer than the ones it already gave.
            if restarted { found = next.uncounted(found, from: store.key) }
            next.noteCounted(found, from: store.key)
            events.append(contentsOf: found)
            if let lastID { next.values[store.key] = lastID }
        }

        return (events, next)
    }

    /// Profile folder names under `hermesHome/profiles` that have their own
    /// `state.db` (an archived or otherwise empty profile folder without one
    /// contributes nothing and is skipped).
    private static func profileNames(hermesHome: String) -> [String] {
        let profilesDir = hermesHome + "/profiles"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) else { return [] }
        return names.filter { name in
            FileManager.default.fileExists(atPath: profilesDir + "/\(name)/state.db")
        }.sorted()
    }

    /// Reads new rows from one `state.db`. A missing file: no events, `nil`
    /// last (the caller leaves that cursor key untouched). A file that was
    /// reset or replaced with a smaller one (its highest id now below `since`)
    /// is read from the start and reported as `restarted`, same as a shrunk
    /// file would be. A row this reader can't make sense of (no server name
    /// to report) is skipped.
    private static func readStore(
        path: String,
        agentLabel: String,
        knownServers: Set<String>,
        since: Int64
    ) -> (events: [UsageEvent], lastID: Int64?, restarted: Bool) {
        guard FileManager.default.fileExists(atPath: path) else { return ([], nil, false) }

        var db: OpaquePointer?
        let uri = "file:\(path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return ([], nil, false)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)

        guard let maxID = queryMaxID(db) else { return ([], nil, false) }
        let restarted = since > maxID
        let startID = restarted ? 0 : since

        let sql = """
            SELECT id, tool_name, timestamp FROM messages
            WHERE role = 'tool' AND tool_name LIKE 'mcp%' AND id > ?
            ORDER BY id ASC
            """
        // A failed prepare or a step cut short (SQLITE_BUSY while Hermes
        // writes) moves the cursor only past the rows actually read, so the
        // rest is read next time instead of skipped for good (review,
        // 2026-10-14). Same as the Cursor reader.
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return ([], nil, false)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, startID)

        var events: [UsageEvent] = []
        var lastRead = startID
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(stmt) }
            lastRead = sqlite3_column_int64(stmt, 0)
            guard let namePtr = sqlite3_column_text(stmt, 1) else { continue } // bad line: no name, skip it
            let name = String(cString: namePtr)
            let time = sqlite3_column_double(stmt, 2)
            guard time > 0, let server = serverName(from: name, knownServers: knownServers) else { continue }
            events.append(UsageEvent(agent: agentLabel, server: server, date: Date(timeIntervalSince1970: time)))
        }
        // A restart cut short is not kept: next time starts over again, so
        // the old rows it didn't reach are never counted without the check.
        if restarted && step != SQLITE_DONE { return ([], nil, false) }
        return (events, step == SQLITE_DONE ? maxID : lastRead, restarted)
    }

    private static func queryMaxID(_ db: OpaquePointer) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(id), 0) FROM messages", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Splits `mcp_<server>_<tool>` (or `mcp__<server>__<tool>`) against
    /// `knownServers` (already normalized with `HealthMonitor.normalizedName`):
    /// tries the longest run of words after `mcp` as the server, then one
    /// shorter, and so on, returning the first that normalizes to a known
    /// server. Falls back to the first word when nothing matches. `nil` for a
    /// non-MCP name, or `mcp` with nothing after it.
    static func serverName(from toolName: String, knownServers: Set<String>) -> String? {
        let parts = toolName.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first, first.lowercased() == "mcp" else { return nil }
        let remainder = Array(parts.dropFirst())
        guard !remainder.isEmpty else { return nil }

        for count in stride(from: remainder.count, through: 1, by: -1) {
            let candidate = remainder[0..<count]
            let normalized = candidate.joined().lowercased().filter { $0.isLetter || $0.isNumber }
            if knownServers.contains(normalized) {
                return candidate.joined(separator: "_")
            }
        }
        return remainder[0]
    }
}
