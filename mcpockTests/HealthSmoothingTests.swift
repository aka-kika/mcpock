import XCTest
@testable import mcpock

/// Failure smoothing: a transient failure (e.g. a slow cold-start timeout) should show
/// amber `degraded` before red `broken`, so a healthy/starting server doesn't blink red
/// on a single hiccup. Definitive failures (spawn error) go straight to broken.
final class HealthSmoothingTests: XCTestCase {
    private func smooth(_ probe: HealthState, transient: Bool, attention: Bool = false, failures: Int)
        -> (state: HealthState, failures: Int) {
        HealthMonitor.smoothedState(
            probe: probe, transientFailure: transient, needsAttention: attention, priorFailures: failures)
    }

    func testHealthyProbeIsHealthyImmediatelyAndResetsFailures() {
        let r = smooth(.healthy, transient: true, failures: 3)
        XCTAssertEqual(r.state, .healthy)
        XCTAssertEqual(r.failures, 0)
    }

    func testFirstTransientFailureFromHealthyIsDegradedNotBroken() {
        let r = smooth(.broken, transient: true, failures: 0)
        XCTAssertEqual(r.state, .degraded, "one transient failure should show amber, not red")
        XCTAssertEqual(r.failures, 1)
    }

    func testSecondConsecutiveTransientFailureIsBroken() {
        let r = smooth(.broken, transient: true, failures: 1)
        XCTAssertEqual(r.state, .broken)
        XCTAssertEqual(r.failures, 2)
    }

    func testColdStartTimeoutFromUnknownIsDegradedNotBroken() {
        // First-ever probe of a slow-starting server times out → amber, not red.
        let r = smooth(.broken, transient: true, failures: 0)
        XCTAssertEqual(r.state, .degraded)
        XCTAssertEqual(r.failures, 1)
    }

    func testDefinitiveFailureIsBrokenImmediately() {
        // e.g. spawn error / bad command — no point smoothing, it won't self-heal.
        let r = smooth(.broken, transient: false, failures: 0)
        XCTAssertEqual(r.state, .broken, "definitive failures should show red at once")
    }

    func testRecoveryResetsToHealthy() {
        let r = smooth(.healthy, transient: false, failures: 1)
        XCTAssertEqual(r.state, .healthy)
        XCTAssertEqual(r.failures, 0)
    }

    func testProbeErrorTransienceClassification() {
        XCTAssertTrue(ProbeError.timeout(.seconds(10)).isTransient, "a timeout may be a slow cold start")
        XCTAssertFalse(ProbeError.spawnFailed("x").isTransient, "spawn errors are definitive")
        XCTAssertFalse(ProbeError.nonZeroExit(1).isTransient)
        XCTAssertFalse(ProbeError.handshakeRejected("x").isTransient)
        XCTAssertFalse(ProbeError.protocolError("x").isTransient)
        XCTAssertFalse(ProbeError.noData.isTransient)
    }

    // MARK: - Auth = stable amber "needs attention"

    func testAuthFailureIsDegradedNotBroken() {
        // An unauthenticated server (HTTP 401) should read as amber "needs you",
        // not red "broken" — nothing is crashing, it just wants credentials.
        let r = smooth(.broken, transient: false, attention: true, failures: 0)
        XCTAssertEqual(r.state, .degraded)
    }

    func testAuthFailureNeverEscalatesToBroken() {
        // Even after many cycles it must stay amber — retrying won't fix auth, so
        // it must never blink red the way a repeated transient failure does.
        let r = smooth(.broken, transient: false, attention: true, failures: 99)
        XCTAssertEqual(r.state, .degraded, "auth must not escalate to broken")
        XCTAssertEqual(r.failures, 0, "the failure counter stays parked so it can't cross the threshold")
    }

    func testAuthTakesPrecedenceOverTransient() {
        let r = smooth(.broken, transient: true, attention: true, failures: 1)
        XCTAssertEqual(r.state, .degraded)
        XCTAssertEqual(r.failures, 0)
    }

    func testAuthCodeClassification() {
        XCTAssertTrue(ProbeError.httpError(401, "").needsAttention, "401 = needs auth")
        XCTAssertTrue(ProbeError.httpError(403, "").needsAttention, "403 = needs auth")
        XCTAssertFalse(ProbeError.httpError(404, "").needsAttention)
        XCTAssertFalse(ProbeError.httpError(500, "body").needsAttention, "a 500 is a real failure, not auth")
        XCTAssertFalse(ProbeError.timeout(.seconds(10)).needsAttention)
        XCTAssertFalse(ProbeError.spawnFailed("x").needsAttention)
    }

    func testAuthErrorMessageIsHumanReadable() {
        XCTAssertEqual(ProbeError.httpError(401, "Unauthorized").errorDescription,
                       "Needs authentication (HTTP 401)")
        XCTAssertEqual(ProbeError.httpError(403, "").errorDescription,
                       "Needs authentication (HTTP 403)")
        // Non-auth codes keep the raw HTTP message + body snippet.
        XCTAssertEqual(ProbeError.httpError(500, "boom").errorDescription, "HTTP 500: boom")
    }
}
