import WidgetKit

/// One entry: the widgets show one moment in time, not a schedule of future
/// states (mcpock can't predict what a server will do next). `snapshot` is
/// `nil` when the app hasn't written one yet — first install, or before its
/// first check finishes.
struct MCPockWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: MCPockWidgetSnapshot?
}

/// Shared by all three widgets: read the App Group snapshot, show it, and
/// come back in about 15 minutes even if nothing prompted a sooner reload
/// (`WidgetReloadPolicy` in the app calls `WidgetCenter.reloadAllTimelines()`
/// on a real change; this is just the fallback so a widget never goes stale
/// for good if that call is missed).
struct MCPockTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> MCPockWidgetEntry {
        MCPockWidgetEntry(date: .now, snapshot: .placeholderSample)
    }

    func getSnapshot(in context: Context, completion: @escaping (MCPockWidgetEntry) -> Void) {
        let snapshot = context.isPreview ? .placeholderSample : currentSnapshot()
        completion(MCPockWidgetEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MCPockWidgetEntry>) -> Void) {
        let entry = MCPockWidgetEntry(date: .now, snapshot: currentSnapshot())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func currentSnapshot() -> MCPockWidgetSnapshot? {
        guard let container = AppGroup.containerURL else { return nil }
        return WidgetSnapshotStore.read(from: container)
    }
}

extension MCPockWidgetSnapshot {
    /// Sample data for the widget gallery and Xcode previews — never written
    /// anywhere, never read from a real file.
    static let placeholderSample = MCPockWidgetSnapshot(
        generated: .now.addingTimeInterval(-120),
        checking: false,
        firstCheckDone: true,
        totalServers: 48,
        problemCount: 2,
        fineCount: 46,
        problems: [
            .init(name: "firecrawl", status: "not answering"),
            .init(name: "figma", status: "needs sign-in"),
        ],
        agents: [
            .init(name: "Claude Code", serverCount: 14, problemCount: 1, fineCount: 13),
            .init(name: "Grok", serverCount: 10, problemCount: 0, fineCount: 10),
            .init(name: "Cursor", serverCount: 9, problemCount: 1, fineCount: 8),
            .init(name: "Hermes", serverCount: 15, problemCount: 0, fineCount: 15),
        ]
    )
}
