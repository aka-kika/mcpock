import Foundation

// Usage counts (1.7): how often each agent called each MCP server, read from
// the agent's own on-disk records. This file is the shared contract between
// the store and the per-agent readers.

/// One MCP tool call found in an agent's own records. Only these three facts
/// are ever kept: never arguments, results or any chat text.
struct UsageEvent: Hashable, Sendable {
    /// The agent's source label as `AgentRegistry` uses it
    /// (`AgentRegistry.claudeCodeLabel`, "Grok", "Cursor", "Hermes").
    let agent: String
    /// The server name as the call named it, before `HealthMonitor.normalizedName`.
    let server: String
    let date: Date
}

/// Where a reader stopped last time, so the next read only looks at what is
/// new (file offsets, a last rowid, a last timestamp). Only the reader that
/// wrote a cursor reads its values.
struct UsageCursor: Codable, Equatable, Sendable {
    var values: [String: Int64]
    /// Per source (a transcript file, a database; same key the reader uses in
    /// `values`): the newest call time counted from it, in milliseconds since
    /// 1970. A source that starts over (shrank, was replaced, its row ids
    /// reset) is read again from the start, and only calls newer than this
    /// are counted, so the store never adds old calls twice (review,
    /// 2026-10-14, item 11).
    var newest: [String: Int64] = [:]
    /// Set by `UsageStore` on counts saved before 1.10.6, which have no
    /// `newest`: when that file was last saved, so every source read back
    /// then counts as read up to that time.
    var countedBefore: Int64?
    /// Per file that started over: the cutoff from that moment, kept. A
    /// rewritten file can be written (and read) in several pieces, and only
    /// the first read sees it shrink; the later pieces still hold old calls,
    /// so every later read of it filters by this too (Argon 2026-10-17 #13).
    var restartCutoff: [String: Int64] = [:]
    /// Per source whose records get rewritten under a new row id (Cursor's
    /// chat bubbles): record key -> call time (ms) of each call counted in
    /// the last couple of days, so a rewrite is never counted again
    /// (Argon 2026-10-17 #10).
    var countedKeys: [String: [String: Int64]] = [:]

    static let empty = UsageCursor(values: [:])

    private enum CodingKeys: String, CodingKey {
        case values, newest, countedBefore, restartCutoff, countedKeys
    }

    /// A call's time as `newest` stores it.
    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// After `source` started over: only the events newer than anything
    /// already counted from it.
    func uncounted(_ events: [UsageEvent], from source: String) -> [UsageEvent] {
        let cutoff = [newest[source], countedBefore].compactMap { $0 }.max()
        guard let cutoff else { return events }
        return events.filter { Self.millis($0.date) > cutoff }
    }

    /// A file `source` starts over: from now on only calls newer than
    /// everything already counted from it count, on this read and every later
    /// one (`uncountedAfterRestart`).
    mutating func startOver(_ source: String) {
        guard let cutoff = [newest[source], countedBefore, restartCutoff[source]].compactMap({ $0 }).max() else { return }
        restartCutoff[source] = cutoff
    }

    /// The events of a file that are newer than its cutoff from when it
    /// started over; all of them for a file that never did.
    func uncountedAfterRestart(_ events: [UsageEvent], from source: String) -> [UsageEvent] {
        guard let cutoff = restartCutoff[source] else { return events }
        return events.filter { Self.millis($0.date) > cutoff }
    }

    /// Remembers the newest of `events` as counted from `source`.
    mutating func noteCounted(_ events: [UsageEvent], from source: String) {
        guard let latest = events.lazy.map({ Self.millis($0.date) }).max() else { return }
        newest[source] = max(newest[source] ?? latest, latest)
    }
}

extension UsageCursor {
    /// Cursors saved before 1.10.6 carry only `values`. In an extension so
    /// the memberwise `UsageCursor(values:)` stays.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        values = try container.decode([String: Int64].self, forKey: .values)
        newest = try container.decodeIfPresent([String: Int64].self, forKey: .newest) ?? [:]
        countedBefore = try container.decodeIfPresent(Int64.self, forKey: .countedBefore)
        restartCutoff = try container.decodeIfPresent([String: Int64].self, forKey: .restartCutoff) ?? [:]
        countedKeys = try container.decodeIfPresent([String: [String: Int64]].self, forKey: .countedKeys) ?? [:]
    }
}

/// Reads one agent's MCP calls from its own files, read-only. A missing or
/// unreadable store is not an error: it returns no events and the same cursor.
protocol UsageReader: Sendable {
    /// The `UsageEvent.agent` this reader reports.
    var agent: String { get }
    /// Every call recorded after `cursor`, and the cursor to pass next time.
    /// `knownServers` holds every server name found in configs, normalized with
    /// `HealthMonitor.normalizedName`, for call names that can't be split on
    /// their own (Cursor's `mcp-cursor-ide-browser-browser_cdp`).
    func read(since cursor: UsageCursor, knownServers: Set<String>) -> (events: [UsageEvent], cursor: UsageCursor)
}
