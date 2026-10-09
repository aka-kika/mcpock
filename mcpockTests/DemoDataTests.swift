import XCTest
@testable import mcpock

final class DemoDataTests: XCTestCase {
    // MARK: - On/off

    func testIsActiveDetectsTheFlagOrTheEnvVariable() {
        XCTAssertFalse(DemoData.isActive(arguments: ["mcpock"], environment: [:]))
        XCTAssertTrue(DemoData.isActive(arguments: ["mcpock", "--demo"], environment: [:]))
        XCTAssertTrue(DemoData.isActive(arguments: ["mcpock"], environment: ["MCPOCK_DEMO": "1"]))
        XCTAssertFalse(DemoData.isActive(arguments: ["mcpock"], environment: ["MCPOCK_DEMO": "0"]))
        XCTAssertFalse(DemoData.isActive(arguments: ["mcpock"], environment: ["MCPOCK_DEMO": "true"]),
                        "only the exact \"1\" turns it on, same spirit as a plain feature flag")
    }

    // MARK: - The sample set is fixed

    func testConfigsAreDeterministic() {
        XCTAssertEqual(DemoData.configs, DemoData.configs, "the sample set is fixed, never randomized")
    }

    func testConfigsCoverTheCuratedFourteenServers() {
        let configs = DemoData.configs
        XCTAssertEqual(configs.count, 15, "14 servers, one (stripe) declared twice on purpose")
        let names = Set(configs.map(\.name))
        let expected: Set<String> = [
            "github", "filesystem", "playwright", "context7", "linear", "sentry",
            "postgres", "slack", "brave-search", "memory", "notion", "figma",
            "stripe", "cloudflare-docs",
        ]
        XCTAssertEqual(names, expected)
        let agents = Set(configs.map(\.source.label))
        XCTAssertEqual(agents, ["Code", "Cursor", "Grok", "Goose", "Hermes", "Claude Desktop", "Codex"])
    }

    func testConfigIdsAreUnique() {
        let ids = DemoData.configs.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "HealthMonitor.merged dedupes on id and would drop a collision")
    }

    /// Screenshots for the website and README must never show real
    /// machine, username or handle.
    func testConfigsCarryNoRealPathsOrNames() {
        let forbidden = [NSUserName(), NSHomeDirectory(), "/Users/", "akakika"]
        for config in DemoData.configs {
            for needle in forbidden {
                XCTAssertFalse(config.source.path.contains(needle), "path: \(config.source.path)")
                XCTAssertFalse((config.command ?? "").contains(needle))
                for arg in config.args {
                    XCTAssertFalse(arg.contains(needle), "arg: \(arg) in \(config.name)")
                }
                for value in config.env.values {
                    XCTAssertFalse(value.contains(needle))
                }
            }
            // Every path is the generic, un-expanded form ("~/.claude.json"),
            // never a real absolute one.
            if !config.source.path.isEmpty {
                XCTAssertTrue(config.source.path.hasPrefix("~/"), config.source.path)
            }
        }
    }

    // MARK: - Every health state the panel can draw

    /// Runs the sample set through the real `HealthMonitor` machinery
    /// (`discover` and `probe` swapped for `DemoData`'s closures, exactly as
    /// `MCPockApp.init` wires them in demo mode) and checks every health
    /// state shows up, with plausible counts. Also the regression test for
    /// the new injectable `probe` hook itself.
    @MainActor
    func testHealthMonitorWithDemoClosuresCoversEveryState() async {
        let suite = "mcpock.tests.demo.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        DemoData.seedPreferences(defaults)

        let monitor = HealthMonitor(defaults: defaults)
        monitor.discover = { DemoData.configs }
        monitor.probe = { config, _ in DemoData.probeResult(for: config) }
        XCTAssertNil(monitor.statusWriter, "demo mode never gets a status writer wired up")
        XCTAssertNil(monitor.widgetSnapshotWriter, "demo mode never gets a widget writer wired up")

        await monitor.reloadConfigs()
        await monitor.refreshNow(force: true)

        let groups = monitor.groups
        XCTAssertEqual(groups.count, 14)

        let healthyAndAgreeing = groups.filter { $0.state == .healthy && !$0.differsNeedsAttention }
        XCTAssertEqual(healthyAndAgreeing.count, 9, "nine plain healthy rows")
        for group in healthyAndAgreeing {
            XCTAssertFalse(group.tools.isEmpty, "\(group.name) should show a plausible tool list")
        }

        let byName = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0) })

        XCTAssertEqual(byName["notion"]?.state, .degraded)
        XCTAssertEqual(byName["notion"]?.needsSignIn, true, "the exact \"Needs authentication\" wording")

        XCTAssertEqual(byName["figma"]?.state, .degraded)
        XCTAssertEqual(byName["figma"]?.needsSignIn, false, "a timeout, not an auth failure")

        XCTAssertEqual(byName["postgres"]?.state, .broken)

        XCTAssertEqual(byName["cloudflare-docs"]?.state, .paused, "never probed at all")

        XCTAssertEqual(byName["stripe"]?.state, .healthy)
        XCTAssertEqual(byName["stripe"]?.differsNeedsAttention, true, "Cursor and Claude Desktop disagree")
        XCTAssertEqual(byName["stripe"]?.differs.count, 2, "no majority in a 1-vs-1 split — both named")
    }

    // MARK: - Isolation

    func testSeedPreferencesPausesOnlyCloudflareDocs() {
        let suite = "mcpock.tests.demo.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        DemoData.seedPreferences(defaults)
        XCTAssertEqual(AppPreferences.loadPausedServers(from: defaults), [HealthMonitor.normalizedName("cloudflare-docs")])
        XCTAssertTrue(AppPreferences.loadHiddenServers(from: defaults).isEmpty)
        XCTAssertTrue(AppPreferences.loadPinnedServers(from: defaults).isEmpty)
    }

    func testThrowawayDefaultsStartClean() {
        let defaults = DemoData.makeThrowawayDefaults()
        defaults.set(["stray"], forKey: AppPreferences.hiddenServersKey)
        let again = DemoData.makeThrowawayDefaults()
        XCTAssertTrue(AppPreferences.loadHiddenServers(from: again).isEmpty,
                       "every demo launch wipes the suite, so nothing from an earlier run carries over")
    }

    // MARK: - Usage counts

    func testUsageReadersReturnPlausibleCallsOnceThenStopDeterministically() {
        let readers = DemoData.usageReaders
        XCTAssertEqual(readers.count, 7, "one per demo agent")
        for reader in readers {
            let (first, cursor) = reader.read(since: .empty, knownServers: [])
            XCTAssertFalse(first.isEmpty, "\(reader.agent) has plausible sample calls")
            XCTAssertTrue(first.allSatisfy { $0.agent == reader.agent })
            let (second, _) = reader.read(since: cursor, knownServers: [])
            XCTAssertTrue(second.isEmpty, "a reader that already caught up returns nothing new, never doubling counts")
        }
    }
}
