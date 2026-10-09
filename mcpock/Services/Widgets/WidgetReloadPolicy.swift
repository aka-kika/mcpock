import Foundation

/// Decides when a new widget snapshot is worth telling WidgetKit about (round
/// 8). Pure, so `WidgetReloadPolicyTests` can drive it without touching
/// WidgetCenter or a real clock. Two rules: only reload when what a widget
/// would actually draw changed (the `generated` timestamp alone doesn't
/// count — the widgets show that live via `Text(date:style:.relative)`), and
/// even then, at most once a minute (WidgetKit budgets reloads, and a probe
/// cycle can produce a burst of small changes).
enum WidgetReloadPolicy {
    static let minInterval: TimeInterval = 60

    static func shouldReload(
        previous: MCPockWidgetSnapshot?,
        next: MCPockWidgetSnapshot,
        lastReloadAt: Date?,
        now: Date
    ) -> Bool {
        guard displayDiffers(previous, next) else { return false }
        guard let lastReloadAt else { return true }
        return now.timeIntervalSince(lastReloadAt) >= minInterval
    }

    /// True when `next` would draw differently from `previous` — everything
    /// but `generated` and `schema`.
    static func displayDiffers(_ previous: MCPockWidgetSnapshot?, _ next: MCPockWidgetSnapshot) -> Bool {
        guard let previous else { return true }
        return previous.checking != next.checking
            || previous.firstCheckDone != next.firstCheckDone
            || previous.totalServers != next.totalServers
            || previous.problemCount != next.problemCount
            || previous.fineCount != next.fineCount
            || previous.problems != next.problems
            || previous.agents != next.agents
    }
}
