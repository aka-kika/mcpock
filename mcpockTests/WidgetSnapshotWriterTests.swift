import XCTest
@testable import mcpock

/// 1.9.1: the writer itself sends a throttled change once the reload
/// interval is up, so the widgets always end on the latest results.
@MainActor
final class WidgetSnapshotWriterTests: XCTestCase {
    private func snapshot(_ problems: Int) -> MCPockWidgetSnapshot {
        MCPockWidgetSnapshot(
            generated: Date(), checking: false, firstCheckDone: true,
            totalServers: 10, problemCount: problems, fineCount: 10 - problems,
            problems: (0..<problems).map { .init(name: "s\($0)", status: "slow") }, agents: []
        )
    }

    func testAChangeInsideTheIntervalIsSentLater() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = WidgetSnapshotWriter(containerURL: dir, reloadInterval: 2)
        var reloads = 0
        writer.reloadAllTimelines = { reloads += 1 }

        writer.schedule { self.snapshot(0) }
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(reloads, 1, "the first snapshot reloads right away")

        writer.schedule { self.snapshot(3) }
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(reloads, 1, "inside the interval: held back")

        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(reloads, 2, "sent once the interval is up")
        XCTAssertEqual(WidgetSnapshotStore.read(from: dir)?.problemCount, 3)
    }
}
