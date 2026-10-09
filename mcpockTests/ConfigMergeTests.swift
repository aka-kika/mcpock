import XCTest
@testable import mcpock

/// `HealthMonitor.merged` — how a fresh discovery result folds into the snapshots
/// the app already holds. Runs at launch and on every "Refresh now".
final class ConfigMergeTests: XCTestCase {
    private func config(_ id: String, name: String = "srv", args: [String] = []) -> ServerConfig {
        ServerConfig(id: id, name: name, source: .code, projectPath: nil,
                     transport: .stdio, command: "x", args: args, env: [:], url: nil, headers: [:])
    }

    /// A server that is still there keeps its health, tools and backoff counter.
    func testUnchangedServerKeepsItsState() {
        let old = ServerSnapshot(config: config("a"), state: .healthy,
                                 tools: [MCPToolInfo(name: "t", description: "")], consecutiveFailures: 0)
        let merged = HealthMonitor.merged([config("a")], into: [old], pausedNames: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].state, .healthy)
        XCTAssertEqual(merged[0].tools.map(\.name), ["t"])
    }

    /// Regression: a server the user just fixed in its config used to inherit the
    /// hourly backoff its broken predecessor had earned, so the fix went unverified
    /// for up to an hour. A changed probe spec restarts from `.unknown`.
    func testChangedSpecResetsFailureStateAndBackoff() {
        let broken = ServerSnapshot(config: config("a", args: ["--old"]), state: .broken,
                                    failureReason: "Non-zero exit (1)", lastChecked: Date(), consecutiveFailures: 6)
        let merged = HealthMonitor.merged([config("a", args: ["--fixed"])], into: [broken], pausedNames: [])
        XCTAssertEqual(merged[0].state, .unknown)
        XCTAssertEqual(merged[0].consecutiveFailures, 0)
        XCTAssertNil(merged[0].failureReason)
        XCTAssertTrue(HealthMonitor.isDue(merged[0], now: Date()), "must be probed on the very next pass")
    }

    func testRemovedServerIsDropped() {
        let old = ServerSnapshot(config: config("gone"), state: .healthy)
        XCTAssertTrue(HealthMonitor.merged([], into: [old], pausedNames: []).isEmpty)
    }

    func testDuplicateIDsCollapseToOne() {
        let merged = HealthMonitor.merged([config("dup"), config("dup")], into: [], pausedNames: [])
        XCTAssertEqual(merged.count, 1)
    }

    /// A rescan that hits a half-written config must not wipe the user's hidden or
    /// paused choices — nothing is pruned on merge; the sets are left alone.
    func testPausedNameSurvivesDisappearingAndReappearing() {
        let paused: Set<String> = [HealthMonitor.normalizedName("srv")]
        let gone = HealthMonitor.merged([], into: [], pausedNames: paused)
        XCTAssertTrue(gone.isEmpty)
        let back = HealthMonitor.merged([config("a")], into: gone, pausedNames: paused)
        XCTAssertEqual(back[0].state, .paused, "the pause still applies once the server is readable again")
    }
}
