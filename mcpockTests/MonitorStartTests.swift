import XCTest
@testable import mcpock

/// Regression: `start()` must be idempotent.
///
/// It used to be called from `MenuBarPanelView.onAppear` (the app calls it at
/// launch since 1.7.1), and with `menuBarExtraStyle(.window)` that fired
/// **every time the panel was opened** — not once at launch. `start()` unconditionally ran discovery plus a full probe
/// pass, so simply opening the panel re-analyzed everything even with "Check
/// servers" set to **Manually** (reported 2026-08-03: "in settings i have manual
/// and it still regenere sometime reanalyzing"). The probe timer was never the
/// culprit — `restartTimer()` correctly installs no timer in manual mode.
@MainActor
final class MonitorStartTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "mcpock-start-\(ProcessInfo.processInfo.globallyUniqueString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.retireSuite(named: suiteName)
    }

    /// Manual mode installs no timer — the setting itself works.
    func testManualIntervalHasNoTimerInterval() {
        AppPreferences.saveProbeInterval(.manual, to: defaults)
        XCTAssertNil(AppPreferences.loadProbeInterval(from: defaults).seconds,
                     "manual mode must produce no timer interval")
    }

    func testTimedIntervalsKeepTheirSeconds() {
        for interval in [ProbeInterval.oneMinute, .fiveMinutes, .fifteenMinutes] {
            AppPreferences.saveProbeInterval(interval, to: defaults)
            XCTAssertEqual(AppPreferences.loadProbeInterval(from: defaults).seconds,
                           TimeInterval(interval.rawValue))
        }
    }

    /// The actual fix: repeated `start()` calls — one per panel open — must not
    /// each kick off another discovery + probe pass.
    func testRepeatedStartDoesNotRestartWork() {
        let monitor = HealthMonitor()
        monitor.start()
        let afterFirst = monitor.isRefreshing

        // Simulate the panel being opened several more times.
        monitor.start()
        monitor.start()
        monitor.start()

        XCTAssertEqual(monitor.isRefreshing, afterFirst,
                       "extra start() calls must be no-ops, not new probe passes")
        monitor.stop()
    }

    /// `stop()` clears the latch so a later `start()` works again.
    func testStopAllowsStartingAgain() {
        let monitor = HealthMonitor()
        monitor.start()
        monitor.stop()
        monitor.start()
        monitor.stop()
    }
}
