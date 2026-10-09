import Foundation

/// Every `UsageReader` `UsageStore` uses by default (1.7: Claude Code, Grok,
/// Cursor, Hermes). Where the other agents keep their calls:
/// `docs/USAGE-SOURCES.md`.
enum UsageReaders {
    static let all: [UsageReader] = [
        ClaudeCodeUsageReader(),
        GrokUsageReader(),
        CursorUsageReader(),
        HermesUsageReader(),
    ]
}
