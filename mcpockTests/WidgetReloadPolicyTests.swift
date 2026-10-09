import XCTest
@testable import mcpock

/// Round 8: when a new widget snapshot is worth telling WidgetKit about —
/// only on a real display change, and at most once a minute even then.
final class WidgetReloadPolicyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(problemCount: Int = 0, problems: [MCPockWidgetSnapshot.Problem] = [], generated: Date? = nil) -> MCPockWidgetSnapshot {
        MCPockWidgetSnapshot(
            generated: generated ?? base, checking: false, firstCheckDone: true,
            totalServers: 10, problemCount: problemCount, fineCount: 10 - problemCount,
            problems: problems, agents: []
        )
    }

    func testFirstSnapshotAlwaysReloads() {
        XCTAssertTrue(WidgetReloadPolicy.shouldReload(previous: nil, next: snapshot(), lastReloadAt: nil, now: base))
    }

    func testGeneratedTimestampAloneDoesNotReload() {
        let a = snapshot(generated: base)
        let b = snapshot(generated: base.addingTimeInterval(900))
        XCTAssertFalse(WidgetReloadPolicy.displayDiffers(a, b), "only the checked-at time changed")
        XCTAssertFalse(WidgetReloadPolicy.shouldReload(previous: a, next: b, lastReloadAt: base, now: base.addingTimeInterval(900)))
    }

    func testAProblemChangeReloadsWhenThrottleAllows() {
        let a = snapshot(problemCount: 0)
        let b = snapshot(problemCount: 1, problems: [.init(name: "wake", status: "not answering")])
        XCTAssertTrue(WidgetReloadPolicy.displayDiffers(a, b))
        // No prior reload recorded: nothing to throttle against.
        XCTAssertTrue(WidgetReloadPolicy.shouldReload(previous: a, next: b, lastReloadAt: nil, now: base))
    }

    func testWithinTheMinuteAChangeIsThrottled() {
        let a = snapshot(problemCount: 0)
        let b = snapshot(problemCount: 1, problems: [.init(name: "wake", status: "not answering")])
        let lastReload = base
        XCTAssertFalse(WidgetReloadPolicy.shouldReload(
            previous: a, next: b, lastReloadAt: lastReload, now: base.addingTimeInterval(30)
        ), "30s after the last reload, inside the 60s window")
    }

    func testAfterTheMinuteAChangeReloadsAgain() {
        let a = snapshot(problemCount: 0)
        let b = snapshot(problemCount: 1, problems: [.init(name: "wake", status: "not answering")])
        let lastReload = base
        XCTAssertTrue(WidgetReloadPolicy.shouldReload(
            previous: a, next: b, lastReloadAt: lastReload, now: base.addingTimeInterval(61)
        ))
    }

    /// 1.9.1: a change inside the minute is not dropped, it is sent when the
    /// minute is up. Found after installing 1.9.0: the first reload went out
    /// while checks were still running, the results came in seconds later,
    /// and the widgets showed old data for over ten minutes.
    func testAThrottledChangeIsSentWhenTheMinuteIsUp() {
        let drawn = snapshot(problemCount: 0)
        let next = snapshot(problemCount: 1, problems: [.init(name: "wake", status: "not answering")])
        XCTAssertEqual(WidgetReloadPolicy.nextReload(lastDrawn: drawn, next: next, lastReloadAt: base,
                                                     now: base.addingTimeInterval(20)), .after(40))
        XCTAssertEqual(WidgetReloadPolicy.nextReload(lastDrawn: drawn, next: next, lastReloadAt: base,
                                                     now: base.addingTimeInterval(61)), .now)
        XCTAssertEqual(WidgetReloadPolicy.nextReload(lastDrawn: nil, next: next, lastReloadAt: nil, now: base), .now)
    }

    /// Compared with what the widgets last drew, not with the last file
    /// written: a throttled change stays pending through identical writes.
    func testNothingToSendWhenTheWidgetsAlreadyShowIt() {
        let drawn = snapshot(problemCount: 1, problems: [.init(name: "wake", status: "not answering")])
        XCTAssertEqual(WidgetReloadPolicy.nextReload(lastDrawn: drawn, next: drawn, lastReloadAt: base,
                                                     now: base.addingTimeInterval(5)), .none)
    }

    func testIdenticalSnapshotNeverReloads() {
        let a = snapshot(problemCount: 2, problems: [.init(name: "x", status: "slow")])
        let b = a
        XCTAssertFalse(WidgetReloadPolicy.displayDiffers(a, b))
        XCTAssertFalse(WidgetReloadPolicy.shouldReload(previous: a, next: b, lastReloadAt: nil, now: base))
    }
}
