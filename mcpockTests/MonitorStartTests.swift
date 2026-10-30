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

    /// How many reads a test monitor did. A lock, since discovery is `@Sendable`.
    private final class ReadCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }

    /// A monitor that reads and probes nothing real: `HealthMonitor()` keeps
    /// the real discover, which scanned this Mac and started its servers
    /// (review 2026-10-30, 14a8).
    private func monitor(counting reads: ReadCount) -> HealthMonitor {
        let monitor = HealthMonitor(defaults: defaults, isUpdate: false)
        monitor.discover = {
            reads.add()
            return []
        }
        monitor.probe = { _, _ in ProbeResult(state: .healthy, failureReason: nil, tools: []) }
        return monitor
    }

    private func waitForFirstPass(_ monitor: HealthMonitor) async throws {
        for _ in 0..<300 where !monitor.hasCompletedFirstPass {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(monitor.hasCompletedFirstPass)
    }

    /// The actual fix: repeated `start()` calls — one per panel open — must not
    /// each kick off another discovery + probe pass.
    func testRepeatedStartDoesNotRestartWork() async throws {
        let reads = ReadCount()
        let monitor = monitor(counting: reads)
        monitor.start()
        monitor.start()
        try await waitForFirstPass(monitor)
        XCTAssertEqual(reads.value, 1)

        // Simulate the panel being opened several more times.
        monitor.start()
        monitor.start()
        monitor.start()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(reads.value, 1, "extra start() calls must be no-ops, not new probe passes")
        monitor.stop()
    }

    /// `stop()` clears the latch so a later `start()` works again.
    func testStopAllowsStartingAgain() async throws {
        let reads = ReadCount()
        let monitor = monitor(counting: reads)
        monitor.start()
        try await waitForFirstPass(monitor)
        XCTAssertEqual(reads.value, 1)
        monitor.stop()
        monitor.start()
        for _ in 0..<300 where reads.value < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reads.value, 2)
        monitor.stop()
    }
}
