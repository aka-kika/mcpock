import XCTest
@testable import mcpock

final class RefreshTests: XCTestCase {
    private func snap(_ name: String, _ source: ServerSource) -> ServerSnapshot {
        let cfg = ServerConfig(id: "\(source.label):\(name)", name: name, source: source, projectPath: nil,
            transport: .stdio, command: "x", args: [], env: [:], url: nil, headers: [:])
        return ServerSnapshot(config: cfg)
    }

    func testInstanceIDsMatchGroupByNormalizedName() {
        let servers = [snap("Chrome DevTools", .goose), snap("chrome-devtools", .cursor), snap("other", .code)]
        let ids = HealthMonitor.instanceIDs(forGroup: "chrome-devtools", in: servers)
        XCTAssertEqual(Set(ids), ["Goose:Chrome DevTools", "Cursor:chrome-devtools"])
    }

    /// Regression (v1.4.0, "app stuck"): a forced refresh that waited for an
    /// in-flight cycle spun the main actor forever once that cycle finished,
    /// because awaiting a completed task returns without suspending and the
    /// finished task was still in `probeTask`. Every mix of overlapping refreshes
    /// must complete. Uses `refreshNow` / `refresh(groupName:)` only — never
    /// `refreshAll`, which would launch the real servers on this Mac.
    /// `refresh(groupName:)` reads the configs again (1.10), so discovery is
    /// stubbed out: the test never scans this Mac.
    /// If the spin comes back this test pins the main actor and the run hangs,
    /// which is the loudest possible failure.
    @MainActor
    func testOverlappingRefreshesAlwaysComplete() async {
        let monitor = HealthMonitor()   // no servers: a cycle finishes at once
        monitor.discover = { [] }
        for _ in 0..<50 {
            async let a: () = monitor.refreshNow()
            async let b: () = monitor.refreshNow(force: true)
            async let c: () = monitor.refresh(groupName: "nothing")
            async let d: () = monitor.refreshNow(force: true)
            async let e: () = monitor.refreshNow()
            _ = await (a, b, c, d, e)
        }
        XCTAssertFalse(monitor.isRefreshing, "no cycle may be left running")
    }

    /// 1.5.1 ("it takes a second until it starts spinning"): Refresh must
    /// turn `isRefreshing` on in the tap's own turn, before the Task hop and
    /// before discovery, and keep it on until the whole pass has ended.
    @MainActor
    func testRefreshSpinsBeforeAnyAsyncWork() async {
        let suite = "mcpock.tests.refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        let monitor = HealthMonitor(defaults: defaults)
        let spinningDuringDiscovery = LockedFlag()
        monitor.discover = {   // stands in for the scan: never touches this Mac
            let on = await MainActor.run { monitor.isRefreshing }
            spinningDuringDiscovery.set(on)
            return []
        }

        XCTAssertFalse(monitor.isRefreshing)
        let task = monitor.startRefreshAll()
        XCTAssertTrue(monitor.isRefreshing, "on synchronously, before discovery or probing runs")
        XCTAssertTrue(monitor.startRefreshAll() == task, "a second tap rides the pending Refresh")

        await task.value
        XCTAssertTrue(spinningDuringDiscovery.value, "still on while discovery runs")
        XCTAssertFalse(monitor.isRefreshing, "off once the pass has ended")
        XCTAssertTrue(monitor.hasCompletedFirstPass)

        // A new Refresh after the first one starts fresh (the pending task was cleared).
        let again = monitor.startRefreshAll()
        XCTAssertTrue(monitor.isRefreshing)
        XCTAssertFalse(again == task)
        await again.value
        XCTAssertFalse(monitor.isRefreshing)
    }

    /// Refresh overlapping timer ticks and per-row checks still always finishes
    /// and leaves nothing spinning (the v1.4.0 single-flight hang must not return).
    @MainActor
    func testRefreshOverlappingOtherChecksAlwaysCompletes() async {
        let suite = "mcpock.tests.refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        let monitor = HealthMonitor(defaults: defaults)
        monitor.discover = { [] }
        for _ in 0..<50 {
            let refresh = monitor.startRefreshAll()
            async let a: () = monitor.refreshNow()
            async let b: () = monitor.refresh(groupName: "nothing")
            async let c: () = monitor.refreshNow(force: true)
            _ = await (a, b, c)
            await refresh.value
        }
        XCTAssertFalse(monitor.isRefreshing, "no hold may be left behind")
    }

    /// 1.7.1: the app starts usage counts from this hook, not from the panel,
    /// so it must fire once per finished Refresh and never for a row's Check.
    @MainActor
    func testCycleFinishedFiresOncePerRefreshNotForARowCheck() async {
        let suite = "mcpock.tests.refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        let monitor = HealthMonitor(defaults: defaults)
        monitor.discover = { [] }
        var finished = 0
        monitor.onCycleFinished = { finished += 1 }
        await monitor.refresh(groupName: "nothing")
        XCTAssertEqual(finished, 0, "a row's Check is not a full cycle")
        await monitor.startRefreshAll().value
        XCTAssertEqual(finished, 1)
        await monitor.startRefreshAll().value
        XCTAssertEqual(finished, 2)
    }

    /// `groups` is built once per change (review, 2026-09-26): a new server
    /// list must show up at once, never a stale cached one.
    @MainActor
    func testGroupsFollowTheServerList() async {
        let suite = "mcpock.tests.refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        let monitor = HealthMonitor(defaults: defaults)
        let one = snap("alpha", .code).config
        let two = snap("beta", .cursor).config
        monitor.discover = { [one] }
        await monitor.reloadConfigs()
        XCTAssertEqual(monitor.groups.map(\.name), ["alpha"])
        XCTAssertEqual(monitor.groups.map(\.name), ["alpha"], "a second read reuses the result")
        monitor.discover = { [one, two] }
        await monitor.reloadConfigs()
        XCTAssertEqual(Set(monitor.groups.map(\.name)), ["alpha", "beta"])
        monitor.setHidden(true, name: "beta")
        XCTAssertEqual(monitor.visibleGroups.map(\.name), ["alpha"])
        XCTAssertEqual(monitor.hiddenGroups.map(\.name), ["beta"])
    }

    /// The card's Check again spins in the tap's own turn too.
    @MainActor
    func testCheckAgainSpinsAtOnce() async {
        let suite = "mcpock.tests.refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        let monitor = HealthMonitor(defaults: defaults)
        monitor.discover = { [] }   // Check again reads the configs again (1.10)
        let state = PanelState(monitor: monitor, defaults: defaults)
        state.checkAgain("nothing")
        XCTAssertTrue(state.isChecking("nothing"), "on before the re-probe runs")
        for _ in 0..<200 where state.isChecking("nothing") { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.isChecking("nothing"), "off once the re-probe is done")
    }

    /// 1.5.3: the row's health mark spins while its own check runs. The set is
    /// filled in the tap's turn, from the right-click menu too (the row actions),
    /// and emptied only after that server's probe has finished.
    @MainActor
    func testCheckingNamesFollowTheRowsOwnProbe() async throws {
        let suite = "mcpock.tests.refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        let monitor = HealthMonitor(defaults: defaults)
        // One server that exits at once: a real probe, nothing of this Mac's.
        let config = ServerConfig(id: "Test:quits", name: "quits", source: ServerSource(label: "Test"), projectPath: nil,
                                  transport: .stdio, command: "/usr/bin/false", args: [], env: [:], url: nil, headers: [:])
        monitor.discover = { [config] }
        await monitor.startRefreshAll().value
        let first = try XCTUnwrap(monitor.servers.first?.lastChecked)

        let state = PanelState(monitor: monitor, defaults: defaults)
        XCTAssertTrue(state.checkingNames.isEmpty)
        state.rowActions(for: "quits").checkAgain()
        XCTAssertEqual(state.checkingNames, ["quits"], "filled synchronously, before the probe runs")
        XCTAssertFalse(state.isChecking("wake"), "only that row")
        state.checkAgain("quits")
        XCTAssertEqual(state.checkingNames, ["quits"], "a second tap rides the running check")

        for _ in 0..<500 where state.isChecking("quits") { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(state.checkingNames.isEmpty, "cleared on completion")
        let second = try XCTUnwrap(monitor.servers.first?.lastChecked)
        XCTAssertGreaterThan(second, first, "cleared only after this server's probe finished")
    }

    /// 1.10 (the Wasdy note: "paste the fix, hit test, see green"): Check
    /// again reads the config files again before it probes. Before, it
    /// re-ran the command from before the fix, and the row stayed red until
    /// the next timer round or a full Refresh.
    @MainActor
    func testCheckAgainUsesTheFixedConfig() async throws {
        let suite = "mcpock.tests.refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        let monitor = HealthMonitor(defaults: defaults)
        func cfg(_ command: String) -> ServerConfig {
            ServerConfig(id: "Test:postiz", name: "postiz", source: ServerSource(label: "Test"), projectPath: nil,
                         transport: .stdio, command: command, args: [], env: [:], url: nil, headers: [:])
        }
        let probed = LockedList()
        monitor.probe = { config, _ in
            probed.append(config.command ?? "")
            return config.command == "fixed"
                ? ProbeResult(state: .healthy, failureReason: nil, tools: [])
                : ProbeResult(state: .broken, failureReason: "not found", tools: nil)
        }
        let typo = cfg("typo"), fixed = cfg("fixed")
        monitor.discover = { [typo] }
        await monitor.startRefreshAll().value
        XCTAssertEqual(monitor.servers.first?.state, .broken)

        // She fixes the config file, then presses Check again on the row.
        monitor.discover = { [fixed] }
        let state = PanelState(monitor: monitor, defaults: defaults)
        state.checkAgain("postiz")
        for _ in 0..<500 where state.isChecking("postiz") { try? await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(probed.items.last, "fixed", "probes the command from the file as it is now")
        XCTAssertEqual(monitor.servers.count, 1)
        XCTAssertEqual(monitor.servers.first?.state, .healthy, "green right away, not at the next timer round")
    }

    /// Stale-row bug (stress run, 2026-09-26): a config changed or removed between
    /// timer rounds kept its old row until Refresh or a relaunch. A timer round
    /// now rediscovers: the changed server comes back with its new config and a
    /// fresh check (not the old failure in backoff), and a removed one is gone.
    @MainActor
    func testTimerRoundPicksUpConfigChanges() async throws {
        let suite = "mcpock.tests.refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        let monitor = HealthMonitor(defaults: defaults)
        func cfg(_ id: String, _ command: String) -> ServerConfig {
            ServerConfig(id: id, name: String(id.split(separator: ":").last!), source: ServerSource(label: "Test"),
                         projectPath: nil, transport: .stdio, command: command, args: [], env: [:], url: nil, headers: [:])
        }
        let probed = LockedList()
        monitor.probe = { config, _ in
            probed.append(config.command ?? "")
            return ProbeResult(state: .broken, failureReason: "failed: \(config.command ?? "")", tools: nil)
        }
        let before = [cfg("Test:postiz", "old-launcher"), cfg("Test:gone", "x")]
        let after = [cfg("Test:postiz", "new-launcher")]
        monitor.discover = { before }
        await monitor.startRefreshAll().value
        XCTAssertEqual(monitor.servers.count, 2)

        // The user edits one config and deletes the other; only the timer runs.
        monitor.discover = { after }
        await monitor.timerTick()

        let postiz = try XCTUnwrap(monitor.servers.first)
        XCTAssertEqual(monitor.servers.count, 1, "the removed server's row is gone")
        XCTAssertEqual(postiz.config.command, "new-launcher", "the row shows the new config")
        XCTAssertEqual(postiz.failureReason, "failed: new-launcher", "checked again, not the old failure")
        XCTAssertEqual(probed.items.last, "new-launcher")
    }
}

/// A Bool that a `@Sendable` closure can set.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set(_ on: Bool) { lock.withLock { flag = on } }
}

/// A list that a `@Sendable` closure can append to.
private final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var items: [String] { lock.withLock { list } }
    func append(_ item: String) { lock.withLock { list.append(item) } }
}
