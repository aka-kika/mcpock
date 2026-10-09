import XCTest
@testable import mcpock

/// Probe backoff: a server that keeps failing must NOT be re-spawned at full
/// cadence forever — spawning is side-effectful (an unauthenticated OAuth server
/// opens a browser login page on every launch). After the failure threshold the
/// retry interval escalates 5 min → 15 min → hourly. A user-initiated refresh
/// always bypasses backoff.
final class ProbeBackoffTests: XCTestCase {
    private func snap(failures: Int, lastChecked: Date?, state: HealthState = .broken) -> ServerSnapshot {
        let cfg = ServerConfig(id: "Code:x", name: "x", source: .code, projectPath: nil,
            transport: .stdio, command: "x-mcp", args: [], env: [:], url: nil, headers: [:])
        return ServerSnapshot(config: cfg, state: state, lastChecked: lastChecked, consecutiveFailures: failures)
    }

    func testNoBackoffBelowFailureThreshold() {
        XCTAssertNil(HealthMonitor.backoffSeconds(consecutiveFailures: 0))
        XCTAssertNil(HealthMonitor.backoffSeconds(consecutiveFailures: 1),
                     "one transient hiccup must not slow the next probe")
    }

    func testBackoffEscalatesFiveThenFifteenThenHourly() {
        XCTAssertEqual(HealthMonitor.backoffSeconds(consecutiveFailures: 2), 300)
        XCTAssertEqual(HealthMonitor.backoffSeconds(consecutiveFailures: 3), 900)
        XCTAssertEqual(HealthMonitor.backoffSeconds(consecutiveFailures: 4), 3600)
        XCTAssertEqual(HealthMonitor.backoffSeconds(consecutiveFailures: 10), 3600,
                       "backoff caps at hourly — never stops entirely")
    }

    func testHealthyServerIsAlwaysDue() {
        let s = snap(failures: 0, lastChecked: Date(), state: .healthy)
        XCTAssertTrue(HealthMonitor.isDue(s, now: Date()))
    }

    func testBackedOffServerIsNotDueUntilIntervalElapses() {
        let now = Date()
        let recent = snap(failures: 2, lastChecked: now.addingTimeInterval(-60))
        XCTAssertFalse(HealthMonitor.isDue(recent, now: now),
                       "2 failures = 5 min backoff; 60s ago is too soon")
        let stale = snap(failures: 2, lastChecked: now.addingTimeInterval(-301))
        XCTAssertTrue(HealthMonitor.isDue(stale, now: now))
    }

    func testNeverCheckedServerIsDueRegardlessOfFailures() {
        let s = snap(failures: 5, lastChecked: nil)
        XCTAssertTrue(HealthMonitor.isDue(s, now: Date()))
    }

    func testDefinitiveFailuresEscalateTheCounterSoBackoffGrows() {
        // A spawn error / non-zero exit every cycle must climb the backoff ladder
        // too, not sit at the threshold forever.
        let r = HealthMonitor.smoothedState(
            probe: .broken, transientFailure: false, priorFailures: 2)
        XCTAssertEqual(r.state, .broken)
        XCTAssertEqual(r.failures, 3, "repeated definitive failures keep counting up")
    }

    func testFirstDefinitiveFailureStillJumpsStraightToThreshold() {
        let r = HealthMonitor.smoothedState(
            probe: .broken, transientFailure: false, priorFailures: 0)
        XCTAssertEqual(r.state, .broken)
        XCTAssertEqual(r.failures, HealthMonitor.failureThreshold)
    }

    // MARK: - shouldProbe: pause beats force, backoff yields to force

    func testForcedRefreshBypassesBackoffButNeverPause() {
        let now = Date()
        let backedOff = snap(failures: 4, lastChecked: now.addingTimeInterval(-60))
        XCTAssertFalse(HealthMonitor.shouldProbe(backedOff, pausedNames: [], force: false, now: now))
        XCTAssertTrue(HealthMonitor.shouldProbe(backedOff, pausedNames: [], force: true, now: now),
                      "Refresh now is an explicit user ask — it skips backoff")
        XCTAssertFalse(HealthMonitor.shouldProbe(backedOff, pausedNames: ["x"], force: true, now: now),
                       "a paused server is never launched, even by Refresh now")
    }

    func testPauseMatchesOnNormalizedName() {
        let now = Date()
        let s = snap(failures: 0, lastChecked: nil, state: .unknown)
        XCTAssertFalse(HealthMonitor.shouldProbe(s, pausedNames: ["x"], force: false, now: now),
                       "config name 'x' normalizes to the paused key 'x'")
        XCTAssertTrue(HealthMonitor.shouldProbe(s, pausedNames: ["other"], force: false, now: now))
    }
}
