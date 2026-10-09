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

    /// What to do with a new snapshot (1.9.1).
    enum Action: Equatable {
        case none
        case now
        /// Send it once the interval since the last reload is up.
        case after(TimeInterval)
    }

    /// Compared with what the widgets last drew (`lastDrawn`), not with the
    /// last file written, so a change held back by the once-a-minute limit
    /// stays pending until it is sent. Before 1.9.1 it was dropped: after a
    /// fresh launch the first reload went out mid-check, the results came in
    /// seconds later, and the widgets showed old data for up to 15 minutes.
    static func nextReload(
        lastDrawn: MCPockWidgetSnapshot?,
        next: MCPockWidgetSnapshot,
        lastReloadAt: Date?,
        now: Date,
        interval: TimeInterval = minInterval
    ) -> Action {
        guard displayDiffers(lastDrawn, next) else { return .none }
        guard let lastReloadAt else { return .now }
        let elapsed = now.timeIntervalSince(lastReloadAt)
        return elapsed >= interval ? .now : .after(interval - elapsed)
    }

    /// True when `next` should be sent right now (the `.now` case above).
    static func shouldReload(
        previous: MCPockWidgetSnapshot?,
        next: MCPockWidgetSnapshot,
        lastReloadAt: Date?,
        now: Date
    ) -> Bool {
        nextReload(lastDrawn: previous, next: next, lastReloadAt: lastReloadAt, now: now) == .now
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
            || previous.brokenCount != next.brokenCount
    }
}
