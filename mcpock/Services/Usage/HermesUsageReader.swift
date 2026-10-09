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
        var values = cursor.values
        var events: [UsageEvent] = []

        let mainKey = "main"
        let (mainEvents, mainLast) = Self.readStore(
            path: hermesHome + "/state.db",
            agentLabel: agent,
            knownServers: knownServers,
            since: values[mainKey] ?? 0
        )
        events.append(contentsOf: mainEvents)
        if let mainLast { values[mainKey] = mainLast }

        // Every profile that keeps its own state.db gets its own cursor entry
        // and reports under "Hermes · <name>" (the label mcpock already uses
        // for a profile's scanned config, `ConfigDiscovery.label`).
        for name in Self.profileNames(hermesHome: hermesHome) {
            let key = "profile:\(name)"
            let (profileEvents, profileLast) = Self.readStore(
                path: hermesHome + "/profiles/\(name)/state.db",
                agentLabel: "\(agent) · \(name)",
                knownServers: knownServers,
                since: values[key] ?? 0
            )
            events.append(contentsOf: profileEvents)
            if let profileLast { values[key] = profileLast }
        }

        return (events, UsageCursor(values: values))
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
    /// is read from the start, same as a shrunk file would be. A row this
    /// reader can't make sense of (no server name to report) is skipped.
    private static func readStore(
        path: String,
        agentLabel: String,
        knownServers: Set<String>,
        since: Int64
    ) -> (events: [UsageEvent], lastID: Int64?) {
        guard FileManager.default.fileExists(atPath: path) else { return ([], nil) }

        var db: OpaquePointer?
        let uri = "file:\(path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return ([], nil)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)

        guard let maxID = queryMaxID(db) else { return ([], nil) }
        let startID = since > maxID ? 0 : since

        let sql = """
            SELECT id, tool_name, timestamp FROM messages
            WHERE role = 'tool' AND tool_name LIKE 'mcp%' AND id > ?
            ORDER BY id ASC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return ([], maxID)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, startID)

        var events: [UsageEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(stmt, 1) else { continue } // bad line: no name, skip it
            let name = String(cString: namePtr)
            let time = sqlite3_column_double(stmt, 2)
            guard time > 0, let server = serverName(from: name, knownServers: knownServers) else { continue }
            events.append(UsageEvent(agent: agentLabel, server: server, date: Date(timeIntervalSince1970: time)))
        }
        return (events, maxID)
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
