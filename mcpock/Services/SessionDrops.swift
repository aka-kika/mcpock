import Foundation

/// Reads Claude Code's own records, never writes them:
/// - `~/.claude/sessions/<pid>.json`: one file per running session (`pid`,
///   `sessionId`, `cwd`, `startedAt` in ms). A session is open while its
///   process runs and started no later than the file says (a reused pid is not).
/// - `~/Library/Caches/claude-cli-nodejs/<folder>/mcp-logs-<server>/*.jsonl`:
///   one JSON line per event, with `sessionId`. A server whose last connect
///   or failure line in an open session is a failure has dropped there.
enum SessionDrops {
    struct OpenSession: Hashable, Sendable {
        let id: String
        let folder: String
        let started: Date
    }

    /// Only the end of a big log is read.
    static let tailBytes = 256 * 1024

    /// Normalized server name -> the open sessions it dropped in.
    static func read(home: String = NSHomeDirectory()) -> [String: [SessionDrop]] {
        let sessions = openSessions(in: (home as NSString).appendingPathComponent(".claude/sessions"))
        guard !sessions.isEmpty else { return [:] }
        let caches = (home as NSString).appendingPathComponent("Library/Caches/claude-cli-nodejs")
        return drops(sessions: sessions, logsRoot: caches)
    }

    static func openSessions(
        in directory: String,
        isRunning: (Int32, Date) -> Bool = SessionDrops.isRunning(_:started:)
    ) -> [OpenSession] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            let path = (directory as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (object["pid"] as? NSNumber)?.int32Value,
                  let id = object["sessionId"] as? String, !id.isEmpty,
                  let folder = object["cwd"] as? String, !folder.isEmpty,
                  let startedMS = (object["startedAt"] as? NSNumber)?.doubleValue
            else { return nil }
            let started = Date(timeIntervalSince1970: startedMS / 1000)
            guard isRunning(pid, started) else { return nil }
            return OpenSession(id: id, folder: folder, started: started)
        }
    }

    /// The log folder Claude Code uses for a session folder: every character
    /// that is not a letter or digit becomes "-".
    static func logFolderName(for folder: String) -> String {
        String(folder.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
    }

    static func drops(sessions: [OpenSession], logsRoot: String) -> [String: [SessionDrop]] {
        let fm = FileManager.default
        var result: [String: [SessionDrop]] = [:]
        let byFolder = Dictionary(grouping: sessions, by: { logFolderName(for: $0.folder) })
        for (folderName, open) in byFolder {
            let projectLogs = (logsRoot as NSString).appendingPathComponent(folderName)
            guard let serverDirs = try? fm.contentsOfDirectory(atPath: projectLogs) else { continue }
            let ids = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let oldest = open.map(\.started).min() ?? .distantPast
            for dir in serverDirs where dir.hasPrefix("mcp-logs-") {
                let server = String(dir.dropFirst("mcp-logs-".count))
                let dirPath = (projectLogs as NSString).appendingPathComponent(dir)
                var last: [String: (at: Date, up: Bool)] = [:]
                for file in recentLogs(in: dirPath, since: oldest) {
                    for event in events(inLog: file) where ids[event.session] != nil {
                        if let known = last[event.session], known.at > event.at { continue }
                        last[event.session] = (event.at, event.up)
                    }
                }
                for (session, event) in last where !event.up {
                    guard let folder = ids[session]?.folder else { continue }
                    result[HealthMonitor.normalizedName(server), default: []].append(SessionDrop(folder: folder, at: event.at))
                }
            }
        }
        return result.mapValues { $0.sorted { $0.at > $1.at } }
    }

    /// Log files written since `since` (a minute's slack for clocks).
    private static func recentLogs(in directory: String, since: Date) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return names.filter { $0.hasSuffix(".jsonl") }.compactMap { name in
            let path = (directory as NSString).appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date,
                  modified >= since.addingTimeInterval(-60) else { return nil }
            return path
        }
    }

    struct Event: Equatable {
        let session: String
        let at: Date
        /// True for a connect or a tool call that worked, false for a failure.
        let up: Bool
    }

    static func events(inLog path: String) -> [Event] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() } // cut mid-line
        return lines.compactMap { event(fromLine: String($0)) }
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// One log line as a connection event, or nil for everything else
    /// (stderr, tool calls that failed on their own, shutdown).
    static func event(fromLine line: String) -> Event? {
        guard line.contains("\"sessionId\""),
              let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let session = object["sessionId"] as? String,
              let stamp = object["timestamp"] as? String,
              let at = dateFormatter.date(from: stamp) else { return nil }
        if let error = object["error"] as? String {
            let failed = error.hasPrefix("Failed to fetch tools") || error.hasPrefix("Connection failed")
            return failed ? Event(session: session, at: at, up: false) : nil
        }
        guard let debug = object["debug"] as? String else { return nil }
        if debug.hasPrefix("Successfully connected") || (debug.hasPrefix("Tool '") && debug.contains("completed successfully")) {
            return Event(session: session, at: at, up: true)
        }
        if debug.hasPrefix("Tool '") && debug.hasSuffix("Connection closed") {
            return Event(session: session, at: at, up: false)
        }
        return nil
    }

    /// The process runs and is not newer than the session it claims.
    static func isRunning(_ pid: Int32, started: Date) -> Bool {
        guard pid > 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return false }
        let tv = info.kp_proc.p_un.__p_starttime
        let processStart = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
        return processStart <= started.addingTimeInterval(60)
    }
}
