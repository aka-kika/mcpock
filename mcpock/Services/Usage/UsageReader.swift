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
    static let empty = UsageCursor(values: [:])
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
