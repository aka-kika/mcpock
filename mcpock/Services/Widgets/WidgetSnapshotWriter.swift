import Foundation
import WidgetKit

/// Writes the widgets' snapshot into the App Group container a moment after
/// `HealthMonitor`'s results change (round 8) — same coalesce-then-write
/// shape as `StatusWriter`, but a smaller shape of the data and a different
/// destination: the sandboxed widget extension can't reach `status.json` in
/// App Support at all, only files inside the group container
/// (`AppGroup.identifier`).
///
/// After writing, asks WidgetKit to redraw — throttled by `WidgetReloadPolicy`
/// so a burst of probe results in one cycle doesn't spend the whole refresh
/// budget. Without a reload call the widgets still catch up at their own
/// `.after(~15 min)` timeline refresh, so skipping one is never silent for long.
@MainActor
final class WidgetSnapshotWriter {
    private var pending: Task<Void, Never>?
    static let delay: Duration = .milliseconds(800)
    private let containerURL: URL?
    private var lastWritten: MCPockWidgetSnapshot?
    private var lastReloadAt: Date?
    /// Swapped in tests so a run never calls the real WidgetKit.
    var reloadAllTimelines: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    /// Swapped in tests for a fixed clock.
    var now: () -> Date = Date.init

    init(containerURL: URL? = AppGroup.containerURL) {
        self.containerURL = containerURL
    }

    /// Write soon. `make` runs on the main actor when the write happens, so it
    /// sees the latest state, not the state at the first change.
    func schedule(_ make: @escaping @MainActor () -> MCPockWidgetSnapshot?) {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard let self else { return }
            self.pending = nil
            guard let snapshot = make(), let containerURL = self.containerURL else { return }
            let shouldReload = WidgetReloadPolicy.shouldReload(
                previous: self.lastWritten, next: snapshot, lastReloadAt: self.lastReloadAt, now: self.now()
            )
            self.lastWritten = snapshot
            await Task.detached(priority: .utility) {
                try? WidgetSnapshotStore.write(snapshot, to: containerURL)
            }.value
            guard shouldReload else { return }
            self.lastReloadAt = self.now()
            self.reloadAllTimelines()
        }
    }
}
