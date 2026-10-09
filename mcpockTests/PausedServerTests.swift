import XCTest
@testable import mcpock

/// Paused servers: the user's off-switch for spawn-to-probe side effects (e.g. an
/// X/Twitter MCP that opens an OAuth login page on every launch). A paused server
/// is never launched, shows a neutral gray dot, and never colors the menu-bar icon.
final class PausedServerTests: XCTestCase {
    func testPausedSortsAfterEverythingElse() {
        XCTAssertGreaterThan(HealthState.paused.sortRank, HealthState.selfManaged.sortRank)
        XCTAssertGreaterThan(HealthState.paused.sortRank, HealthState.healthy.sortRank)
    }

    func testPausedNeverColorsTheMenuBarIcon() {
        XCTAssertEqual(HealthMonitor.iconState([.healthy, .paused]), .allHealthy)
        XCTAssertEqual(HealthMonitor.iconState([.broken, .paused]), .broken,
                       "pausing one server must not mask another's failure")
        XCTAssertEqual(HealthMonitor.iconState([.paused]), .allHealthy,
                       "an all-paused set reads as healthy, like all-self-managed")
    }

    func testIconStateMatchesPreviousAggregateSemantics() {
        XCTAssertEqual(HealthMonitor.iconState([]), .degradedOrUnknown, "still discovering")
        XCTAssertEqual(HealthMonitor.iconState([.healthy, .unknown]), .degradedOrUnknown)
        XCTAssertEqual(HealthMonitor.iconState([.healthy, .selfManaged]), .allHealthy)
        XCTAssertEqual(HealthMonitor.iconState([.healthy, .degraded]), .degradedOrUnknown)
    }

    /// A newly discovered server whose name is in the paused set starts paused —
    /// the pause must survive a rescan, not just the session it was set in.
    func testNewlyDiscoveredServerHonorsPausedSet() {
        let cfg = ServerConfig(id: "Code:x", name: "X-Server", source: .code, projectPath: nil,
            transport: .stdio, command: "x-mcp", args: [], env: [:], url: nil, headers: [:])
        let merged = HealthMonitor.merged([cfg], into: [], pausedNames: [HealthMonitor.normalizedName("x-server")])
        XCTAssertEqual(merged.first?.state, .paused)
    }
}
