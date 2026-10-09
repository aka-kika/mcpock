import XCTest
@testable import mcpock

/// The pure parts of the v1.5 Preferences panes: the "Show as" three-way
/// control's model, the Servers footer line, and the Agents pane's list.
/// Monitor-backed cases use a throwaway defaults suite, because the test host
/// is the app and `.standard` would be the real preferences.
@MainActor
final class SettingsPanesTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "mcpock.tests.settings-panes.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.retireSuite(named: suite)
        super.tearDown()
    }

    // MARK: - Show as

    func testResolveMapsTheTwoFlagsToOnePosition() {
        XCTAssertEqual(ServerVisibility.resolve(pinned: false, hidden: false), .shown)
        XCTAssertEqual(ServerVisibility.resolve(pinned: true, hidden: false), .pinned)
        XCTAssertEqual(ServerVisibility.resolve(pinned: false, hidden: true), .hidden)
        XCTAssertEqual(ServerVisibility.resolve(pinned: true, hidden: true), .pinned,
                       "pinned wins over a stale hidden flag: the panel shows a pinned row")
    }

    func testSetVisibilityMovesBetweenAllThreePositions() {
        let monitor = HealthMonitor(defaults: defaults)
        XCTAssertEqual(monitor.visibility(of: "reed-md"), .shown)

        monitor.setVisibility(.pinned, name: "reed-md")
        XCTAssertEqual(monitor.visibility(of: "reed-md"), .pinned)
        XCTAssertTrue(monitor.isPinned("reed-md"))
        XCTAssertFalse(monitor.isHidden("reed-md"))

        monitor.setVisibility(.hidden, name: "reed-md")
        XCTAssertEqual(monitor.visibility(of: "reed-md"), .hidden)
        XCTAssertFalse(monitor.isPinned("reed-md"), "hiding unpins")
        XCTAssertTrue(monitor.isHidden("reed-md"))

        monitor.setVisibility(.shown, name: "reed-md")
        XCTAssertEqual(monitor.visibility(of: "reed-md"), .shown)
        XCTAssertFalse(monitor.isPinned("reed-md"))
        XCTAssertFalse(monitor.isHidden("reed-md"))
        XCTAssertTrue(AppPreferences.loadHiddenServers(from: defaults).isEmpty)
        XCTAssertTrue(AppPreferences.loadPinnedServers(from: defaults).isEmpty)
    }

    func testShownFromPinnedClearsOnlyThePin() {
        let monitor = HealthMonitor(defaults: defaults)
        monitor.setVisibility(.pinned, name: "wake")
        monitor.setVisibility(.shown, name: "wake")
        XCTAssertEqual(monitor.visibility(of: "wake"), .shown)
        XCTAssertEqual(AppPreferences.loadPinnedServers(from: defaults), [])
    }

    func testSummaryLine() {
        XCTAssertEqual(ServerVisibility.summary(total: 19, pinned: 5, hidden: 1), "19 servers · 5 pinned · 1 hidden")
        XCTAssertEqual(ServerVisibility.summary(total: 1, pinned: 0, hidden: 0), "1 server · 0 pinned · 0 hidden")
    }

    // MARK: - Agents

    private func group(_ name: String, sources: [(agent: String, path: String)]) -> ServerGroup {
        var group = ServerGroup(
            name: name,
            state: .healthy,
            sourceLabels: sources.map(\.agent),
            tools: [],
            issues: [],
            variantCount: sources.count
        )
        group.sources = sources.enumerated().map { index, source in
            GroupSource(
                configID: "\(name)-\(index)",
                label: source.agent,
                agent: source.agent,
                path: source.path,
                transport: .stdio,
                target: "npx x",
                envKeys: [],
                headerKeys: [],
                state: .healthy,
                failureReason: nil
            )
        }
        return group
    }

    func testAgentsAreDeduplicatedAndSortedWithTheirPaths() {
        let groups = [
            group("reed-md", sources: [("Cursor", "/u/.cursor/mcp.json"), ("Code", "/u/.claude.json")]),
            group("wake", sources: [("Cursor", "/u/.cursor/mcp.json"), ("Hermes", "/u/.hermes/config.yaml")]),
            group("feed", sources: [("Hermes · scribe", "/u/.hermes/scribe/config.yaml")]),
        ]
        let entries = SettingsAgentsPane.entries(from: groups)
        XCTAssertEqual(entries.map(\.agent), ["Code", "Cursor", "Hermes"])
        XCTAssertEqual(entries.map(\.serverCount), [1, 2, 2])
        XCTAssertEqual(entries[1].paths, ["/u/.cursor/mcp.json"], "one path, however many servers use it")
        XCTAssertEqual(entries[2].paths, ["/u/.hermes/config.yaml", "/u/.hermes/scribe/config.yaml"],
                       "a scanned folder label folds into its agent, its file kept")
    }

    func testProjectScopedLabelsCountOncePerAgent() {
        let groups = [
            group("eventkit", sources: [("Code (AppA)", "/u/.claude.json"), ("Code (AppB)", "/u/.claude.json")]),
        ]
        let entries = SettingsAgentsPane.entries(from: groups)
        XCTAssertEqual(entries.map(\.agent), ["Code"])
        XCTAssertEqual(entries[0].serverCount, 1)
        XCTAssertEqual(entries[0].paths, ["/u/.claude.json"])
    }

    func testEmptyPathsAreLeftOut() {
        let groups = [group("x", sources: [("Goose", "")])]
        let entries = SettingsAgentsPane.entries(from: groups)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].paths, [])
        XCTAssertTrue(SettingsAgentsPane.entries(from: []).isEmpty)
    }

    /// Round 6: aka sits at the bottom here too.
    func testAkaIsListedLast() {
        let groups = [
            group("recall", sources: [("aka", "/u/pipali"), ("Cursor", "/u/.cursor/mcp.json"), ("Zed", "/u/zed.json")]),
        ]
        XCTAssertEqual(SettingsAgentsPane.entries(from: groups).map(\.agent), ["Cursor", "Zed", "aka"])
    }
}
