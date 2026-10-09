import XCTest
@testable import mcpock

/// Entries marked `"builtin": true` (e.g. MiniMax Code's cu/trash/matrix) run
/// inside their host app's own runtime — probing their on-disk command from
/// outside always fails, so they get the neutral `.selfManaged` state instead
/// of blinking red forever.
final class SelfManagedTests: XCTestCase {
    func testDiscoveryParsesBuiltinFlag() {
        let source = ServerSource(label: "MiniMax")
        let configs = ConfigDiscovery.configs(
            from: [
                DiscoveredEntry(name: "cu", entry: ["url": "http://127.0.0.1:15321/mavis/mcp/cu", "type": "streamable-http", "builtin": true]),
                DiscoveredEntry(name: "skill-librarian", entry: ["command": "/usr/bin/true"]),
            ],
            source: source,
            idPrefix: "test"
        )
        XCTAssertTrue(configs.first { $0.name == "cu" }!.builtin)
        XCTAssertFalse(configs.first { $0.name == "skill-librarian" }!.builtin)
    }

    func testSmoothingPassesSelfManagedThrough() {
        let smoothed = HealthMonitor.smoothedState(
            probe: .selfManaged, transientFailure: false, priorFailures: 3
        )
        XCTAssertEqual(smoothed.state, .selfManaged)
        XCTAssertEqual(smoothed.failures, 0, "self-managed never participates in failure smoothing")
    }

    func testSelfManagedNeverWorsensAGroupOrTheAggregate() {
        // A group mixing a healthy instance with a self-managed one reads healthy…
        XCTAssertEqual(HealthMonitor.aggregateState([.healthy, .selfManaged]), .healthy)
        // …a broken instance still wins…
        XCTAssertEqual(HealthMonitor.aggregateState([.broken, .selfManaged]), .broken)
        // …and an all-self-managed set stays self-managed (mapped to a calm icon).
        XCTAssertEqual(HealthMonitor.aggregateState([.selfManaged, .selfManaged]), .selfManaged)
    }

    func testSelfManagedSortsAfterHealthy() {
        XCTAssertGreaterThan(HealthState.selfManaged.sortRank, HealthState.healthy.sortRank)
    }
}
