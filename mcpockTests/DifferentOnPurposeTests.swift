import XCTest
@testable import mcpock

/// 1.5.2 "Mark as intended" (called "Different on purpose" until 1.5.3): the user's
/// `feed` is set up differently in every agent by design (each has its own key
/// and launcher script). Marking it
/// saves the SET of launch targets as fingerprints; while they still match, the
/// row stops counting as set up differently everywhere, but it is still probed
/// and its real errors still show. When a target is added, removed or changed,
/// the note comes back on its own. Each test uses its own defaults suite (the
/// test host is the app; `.standard` would be the real preferences).
@MainActor
final class DifferentOnPurposeTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "mcpock.tests.onpurpose.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.retireSuite(named: suite)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func feed(
        _ agent: String,
        script: String,
        env: [String: String] = [:],
        state: HealthState = .healthy,
        failure: String? = nil
    ) -> ServerSnapshot {
        let config = ServerConfig(
            id: "\(agent):feed", name: "feed", source: ServerSource(label: agent, path: "/Users/k/.\(agent.lowercased())"),
            projectPath: nil, transport: .stdio, command: "/bin/sh", args: [script],
            env: env, url: nil, headers: [:]
        )
        return ServerSnapshot(config: config, state: state, failureReason: failure, lastChecked: Self.now)
    }

    /// Three agents, three launcher scripts, three keys: set up differently.
    private func feedSetups() -> [ServerSnapshot] {
        [
            feed("Code", script: "/Users/k/feed/code.sh", env: ["FEED_KEY": "code-secret"]),
            feed("Cursor", script: "/Users/k/feed/cursor.sh", env: ["FEED_KEY": "cursor-secret"]),
            feed("Grok", script: "/Users/k/feed/grok.sh", env: ["FEED_KEY": "grok-secret"]),
        ]
    }

    private func other() -> ServerSnapshot {
        let config = ServerConfig(
            id: "Code:wake", name: "wake", source: .code, projectPath: nil, transport: .stdio,
            command: "wake-mcp", args: [], env: [:], url: nil, headers: [:]
        )
        return ServerSnapshot(config: config, state: .healthy, lastChecked: Self.now)
    }

    private func monitor(with servers: [ServerSnapshot]) async -> HealthMonitor {
        let monitor = HealthMonitor(defaults: defaults)
        let configs = servers.map(\.config)
        monitor.discover = { configs }   // never scans this Mac
        await monitor.reloadConfigs()
        return monitor
    }

    private func acknowledged(_ servers: [ServerSnapshot]) -> [String: [String]] {
        ["feed": Differs.acknowledgements(servers.map(\.config))]
    }

    // MARK: - Fingerprints

    func testFingerprintsAreTheSortedSetOfTargetsAndHoldNoCommandText() {
        let prints = Differs.fingerprints(feedSetups().map(\.config))
        XCTAssertEqual(prints.count, 3)
        XCTAssertEqual(prints, prints.sorted())
        for print in prints {
            XCTAssertEqual(print.count, 16)
            XCTAssertTrue(print.allSatisfy(\.isHexDigit))
        }
        let joined = prints.joined()
        XCTAssertFalse(joined.contains("feed") || joined.contains("sh"), "hashed, never the command line")
    }

    func testEnvAndHeaderValuesNeverChangeTheFingerprint() {
        let before = Differs.fingerprints(feedSetups().map(\.config))
        let rotated = [
            feed("Code", script: "/Users/k/feed/code.sh", env: ["FEED_KEY": "new-key"]),
            feed("Cursor", script: "/Users/k/feed/cursor.sh"),
            feed("Grok", script: "/Users/k/feed/grok.sh", env: ["OTHER": "x"]),
        ]
        XCTAssertEqual(Differs.fingerprints(rotated.map(\.config)), before, "a rotated key is not a new setup")

        let http = { (headers: [String: String]) in
            ServerConfig(id: "Code:r", name: "r", source: .code, projectPath: nil, transport: .http,
                         command: nil, args: [], env: [:], url: "https://x.example.com/mcp/", headers: headers)
        }
        XCTAssertEqual(Differs.fingerprints([http(["Authorization": "a"])]),
                       Differs.fingerprints([http(["Authorization": "b"])]))
    }

    func testAkaIsLeftOutLikeInDetect() {
        let aka = ServerSnapshot(config: ServerConfig(
            id: "aka:feed", name: "feed", source: ServerSource(label: AkaSource.label), projectPath: nil,
            transport: .stdio, command: "bun", args: ["x", "-y", "feed"], env: [:], url: nil, headers: [:]))
        XCTAssertEqual(Differs.fingerprints((feedSetups() + [aka]).map(\.config)),
                       Differs.fingerprints(feedSetups().map(\.config)))
    }

    // MARK: - Grouping

    func testAcknowledgedRowNoLongerDiffersButKeepsItsNotes() {
        let servers = feedSetups()
        let plain = HealthMonitor.groupByName(servers).first!
        XCTAssertTrue(plain.isDiffering)
        XCTAssertTrue(plain.differsNeedsAttention)

        let group = HealthMonitor.groupByName(servers, acknowledged: acknowledged(servers)).first!
        XCTAssertFalse(group.isDiffering)
        XCTAssertFalse(group.differsNeedsAttention)
        XCTAssertTrue(group.isDifferentOnPurpose)
        XCTAssertEqual(group.acknowledgedDiffers, plain.differs)
        XCTAssertNil(ShortReason.line(for: group), "no yellow note under the row")
        XCTAssertEqual(HealthMark.word(for: group), "Healthy")
        XCTAssertFalse(PanelSections.needsYou(group))
        XCTAssertNil(PanelSections.worstNeedsYouRank([group]))
        XCTAssertEqual(HealthMonitor.iconState(servers.map(\.state), anyDiffers: group.differsNeedsAttention),
                       .allHealthy, "no attention ring in the menu bar")
        XCTAssertFalse(PanelText.summary([group], firstPass: false).contains("differ"))
        let agents = AgentSections.build(groups: [group])
        XCTAssertTrue(agents.allSatisfy { $0.problems.isEmpty }, "no Agents-tab problem counts")
    }

    /// Per agent since 1.9.0: a changed or added setup brings the note back
    /// for that agent only; the agents she marked stay quiet.
    func testAChangedOrAddedSetupBringsTheNoteBackForThatAgentOnly() {
        let servers = feedSetups()
        let ack = acknowledged(servers)

        var changed = servers
        changed[2] = feed("Grok", script: "/Users/k/feed/grok-v2.sh")
        let changedGroup = HealthMonitor.groupByName(changed, acknowledged: ack).first!
        XCTAssertEqual(changedGroup.differs.map(\.label), ["Grok"], "changed")
        XCTAssertEqual(changedGroup.acknowledgedDiffers.map(\.label), ["Code", "Cursor"])

        let added = servers + [feed("Goose", script: "/Users/k/feed/goose.sh")]
        let addedGroup = HealthMonitor.groupByName(added, acknowledged: ack).first!
        XCTAssertEqual(addedGroup.differs.map(\.label), ["Goose"], "added")
    }

    /// A 1.5.2 mark fell off when one of a server's four wrappers went away.
    /// Since 1.9.0 an agent leaving keeps the mark.
    func testARemovedAgentKeepsTheMark() {
        let servers = feedSetups()
        let removed = Array(servers.prefix(2))
        let group = HealthMonitor.groupByName(removed, acknowledged: acknowledged(servers)).first!
        XCTAssertFalse(group.isDiffering, "removed")
        XCTAssertTrue(group.isDifferentOnPurpose)
    }

    /// A mark saved before 1.9.0 holds bare fingerprints (the SET of targets).
    /// It still reads, by target, even after a target went away.
    func testAMarkFromBefore190StillReads() {
        let servers = feedSetups()
        let legacy = ["feed": Differs.fingerprints(servers.map(\.config)) + ["0123456789abcdef"]]
        let group = HealthMonitor.groupByName(servers, acknowledged: legacy).first!
        XCTAssertFalse(group.isDiffering)
        XCTAssertTrue(group.isDifferentOnPurpose)

        var changed = servers
        changed[2] = feed("Grok", script: "/Users/k/feed/grok-v2.sh")
        XCTAssertEqual(HealthMonitor.groupByName(changed, acknowledged: legacy).first!.differs.map(\.label), ["Grok"])
    }

    /// A marked row where a new agent differs: the card shows the box with
    /// Mark, the menu offers Mark, and marking again quiets the new agent too.
    func testMarkingAgainAddsTheNewAgent() async {
        let monitor = await monitor(with: feedSetups())
        monitor.setDifferentOnPurpose(true, name: "feed")
        let withGoose = feedSetups() + [feed("Goose", script: "/Users/k/feed/goose.sh")]
        monitor.discover = { withGoose.map(\.config) }
        await monitor.reloadConfigs()

        let partial = monitor.groups.first { $0.name == "feed" }!
        XCTAssertEqual(partial.differs.map(\.label), ["Goose"])
        XCTAssertEqual(MenuText.intendedItem(for: partial), .mark)
        XCTAssertEqual(CardText.problems(for: partial), [.differs])
        XCTAssertFalse(monitor.isDifferentOnPurpose("feed"))

        monitor.setDifferentOnPurpose(true, name: "feed")
        let marked = monitor.groups.first { $0.name == "feed" }!
        XCTAssertFalse(marked.isDiffering)
        XCTAssertEqual(marked.acknowledgedDiffers.map(\.label).sorted(), ["Code", "Cursor", "Goose", "Grok"])
        XCTAssertTrue(monitor.isDifferentOnPurpose("feed"))
    }

    /// Marking keeps the marks of an agent that is away right now, and drops
    /// pre-1.9.0 bare fingerprints.
    func testMarkingKeepsAwayAgentsAndDropsLegacyEntries() {
        let servers = feedSetups()
        let grokOnly = Differs.acknowledgements([servers[2].config])
        let marks = Differs.marking(Array(servers.prefix(2)).map(\.config),
                                    over: grokOnly + ["0123456789abcdef"])
        XCTAssertEqual(marks, Differs.acknowledgements(servers.map(\.config)))
        XCTAssertTrue(marks.allSatisfy { $0.hasSuffix(":Code") || $0.hasSuffix(":Cursor") || $0.hasSuffix(":Grok") })
    }

    func testANewAgentCopyingAnAcknowledgedSetupKeepsIt() {
        let servers = feedSetups()
        let copied = servers + [feed("Goose", script: "/Users/k/feed/code.sh", env: ["FEED_KEY": "goose"])]
        let group = HealthMonitor.groupByName(copied, acknowledged: acknowledged(servers)).first!
        XCTAssertTrue(group.isDifferentOnPurpose, "the SET of targets is unchanged")
    }

    func testRealErrorsStillShow() {
        var servers = feedSetups()
        servers[1].state = .broken
        servers[1].failureReason = "Non-zero exit (1) — FEED_KEY missing"
        let group = HealthMonitor.groupByName(servers, acknowledged: acknowledged(servers)).first!
        XCTAssertEqual(group.state, .broken)
        XCTAssertTrue(PanelSections.needsYou(group))
        XCTAssertEqual(group.issues.count, 1)
        XCTAssertNotNil(ShortReason.line(for: group))
    }

    // MARK: - Monitor and preference

    func testMarkAndUndoPersistAsJSON() async throws {
        let monitor = await monitor(with: feedSetups() + [other()])
        XCTAssertFalse(monitor.isDifferentOnPurpose("feed"))

        monitor.setDifferentOnPurpose(true, name: "Feed")
        XCTAssertTrue(monitor.isDifferentOnPurpose("feed"))
        XCTAssertTrue(monitor.groups.first { $0.name == "feed" }!.isDifferentOnPurpose)
        XCTAssertFalse(monitor.groups.contains(where: \.differsNeedsAttention))

        let stored = try XCTUnwrap(defaults.string(forKey: AppPreferences.differsAcknowledgedKey))
        let decoded = try JSONDecoder().decode([String: [String]].self, from: Data(stored.utf8))
        XCTAssertEqual(decoded, ["feed": Differs.acknowledgements(feedSetups().map(\.config))])
        XCTAssertFalse(stored.contains("secret") || stored.contains(".sh"), "no command text, no env values")

        let relaunched = await self.monitor(with: feedSetups())
        XCTAssertTrue(relaunched.isDifferentOnPurpose("feed"), "survives a relaunch")

        monitor.setDifferentOnPurpose(false, name: "feed")
        XCTAssertFalse(monitor.isDifferentOnPurpose("feed"))
        XCTAssertTrue(monitor.groups.first { $0.name == "feed" }!.isDiffering)
        XCTAssertTrue(AppPreferences.loadDiffersAcknowledged(from: defaults).isEmpty)
    }

    func testMarkingARowThatAgreesDoesNothingVisible() async {
        let monitor = await monitor(with: [other()])
        monitor.setDifferentOnPurpose(true, name: "wake")
        XCTAssertFalse(monitor.isDifferentOnPurpose("wake"))
        XCTAssertNil(MenuText.intendedItem(for: monitor.groups[0]))
        XCTAssertEqual(CardText.problems(for: monitor.groups[0]), [])
    }

    func testPreferenceReadsALaunchArgumentShapedDictionary() {
        defaults.set(["feed": ["b", "a"]], forKey: AppPreferences.differsAcknowledgedKey)
        XCTAssertEqual(AppPreferences.loadDiffersAcknowledged(from: defaults), ["feed": ["a", "b"]])
        defaults.set("not json", forKey: AppPreferences.differsAcknowledgedKey)
        XCTAssertTrue(AppPreferences.loadDiffersAcknowledged(from: defaults).isEmpty)
    }

    func testMenuOffersTheRightItem() {
        let servers = feedSetups()
        let plain = MenuText.intendedItem(for: HealthMonitor.groupByName(servers)[0])
        XCTAssertEqual(plain, .mark)
        XCTAssertEqual(plain?.title, "Mark as Intended")
        XCTAssertEqual(plain?.marks, true)
        let marked = MenuText.intendedItem(
            for: HealthMonitor.groupByName(servers, acknowledged: acknowledged(servers))[0])
        XCTAssertEqual(marked, .unmark, "a marked row is never offered Mark again")
        XCTAssertEqual(marked?.title, "Unmark as Intended")
        XCTAssertEqual(marked?.marks, false)
    }

    // MARK: - The card (1.5.3, layout B)

    /// Set up differently: the two-by-two box, never the marked line. Marked:
    /// only the quiet line, never the box (so Mark is not offered twice).
    func testCardShowsTheBoxOrTheMarkedLineNeverBoth() {
        let servers = feedSetups()
        XCTAssertEqual(CardText.problems(for: HealthMonitor.groupByName(servers)[0]), [.differs])
        let marked = HealthMonitor.groupByName(servers, acknowledged: acknowledged(servers))[0]
        XCTAssertEqual(CardText.problems(for: marked), [.marked])
        XCTAssertFalse(ServerReport.canAskAgent(marked), "nothing left to ask about")
    }

    func testBrokenMarkedRowShowsWhyAndTheMarkedLine() {
        var servers = feedSetups()
        servers[1] = feed("Cursor", script: "/Users/k/feed/cursor.sh", state: .broken, failure: "Non-zero exit (1)")
        XCTAssertEqual(CardText.problems(for: HealthMonitor.groupByName(servers)[0]), [.why, .differs])
        let marked = HealthMonitor.groupByName(servers, acknowledged: acknowledged(servers))[0]
        XCTAssertEqual(CardText.problems(for: marked), [.why, .marked])
        XCTAssertEqual(MenuText.intendedItem(for: marked), .unmark)
    }

    func testCardButtonWording() {
        XCTAssertEqual(CardText.differsButtons, [["Compare", "Ask an agent"], ["Copy details", "Mark as intended"]])
        XCTAssertEqual(CardText.whyButtons, ["Ask an agent", "Copy errors"])
        XCTAssertEqual(CardText.markedLine, "Marked as intended")
        XCTAssertEqual(CardText.undoButton, "Undo")
    }

    /// The card's button and Undo set the mark explicitly: pressing "Mark as
    /// intended" twice never takes it back, Undo twice never re-marks.
    func testPanelSetsTheMarkExplicitly() async {
        let monitor = await monitor(with: feedSetups())
        let state = PanelState(monitor: monitor, defaults: defaults)
        state.setMarkedAsIntended(true, name: "feed")
        state.setMarkedAsIntended(true, name: "feed")
        XCTAssertTrue(monitor.isDifferentOnPurpose("feed"))
        XCTAssertEqual(MenuText.intendedItem(for: monitor.groups[0]), .unmark)
        XCTAssertEqual(CardText.problems(for: monitor.groups[0]), [.marked])

        state.rowActions(for: "feed").setIntended(false)
        state.setMarkedAsIntended(false, name: "feed")
        XCTAssertFalse(monitor.isDifferentOnPurpose("feed"))
        XCTAssertEqual(MenuText.intendedItem(for: monitor.groups[0]), .mark)
        XCTAssertEqual(CardText.problems(for: monitor.groups[0]), [.differs])
    }

    // MARK: - Status file and helper

    func testStatusFileAndHelperTreatItAsFine() throws {
        let servers = feedSetups()
        let status = StatusSnapshot.build(
            servers: servers, isHidden: { _ in false }, isPinned: { _ in false },
            acknowledged: acknowledged(servers), checking: false, firstCheckDone: true,
            interval: .fiveMinutes, now: Self.now, pid: 1, appVersion: "1.5.2"
        )
        let entry = try XCTUnwrap(status.servers.first)
        XCTAssertEqual(entry.status, "fine")
        XCTAssertFalse(entry.needsAttention)
        XCTAssertNil(entry.differs)
        XCTAssertEqual(status.counts.differs, 0)
        XCTAssertFalse(entry.sources.contains(where: \.differs))
        let onPurpose = try XCTUnwrap(entry.differsOnPurpose)
        XCTAssertFalse(onPurpose.contains("secret"))

        XCTAssertTrue(StatusReport.problems(in: status).isEmpty, "mcpock_problems leaves it out")
        let text = StatusReport.serverLines(entry, number: nil, full: true, now: Self.now).joined(separator: "\n")
        XCTAssertTrue(text.contains("Set up differently, marked as intended: "), text)
        let details = ServerReport.detailsText(entry, now: Self.now)
        XCTAssertTrue(details.contains("Set up differently, marked as intended: "), details)
        XCTAssertFalse(text.contains("on purpose") || details.contains("on purpose"))

        // Round trip, and a file from before 1.5.2 (no field) still reads.
        let data = try MCPockStatus.encoder().encode(status)
        XCTAssertEqual(try MCPockStatus.decoder().decode(MCPockStatus.self, from: data), status)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try XCTUnwrap(json["servers"] as? [[String: Any]])
        rows[0].removeValue(forKey: "differsOnPurpose")
        json["servers"] = rows
        let old = try MCPockStatus.decoder().decode(
            MCPockStatus.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.servers[0].differsOnPurpose)
    }

    func testMonitorSnapshotUsesTheAcknowledgement() async {
        let monitor = await monitor(with: feedSetups())
        XCTAssertNotNil(monitor.statusSnapshot().servers.first?.differs)
        monitor.setDifferentOnPurpose(true, name: "feed")
        XCTAssertNil(monitor.statusSnapshot().servers.first?.differs)
        XCTAssertNotNil(monitor.statusSnapshot().servers.first?.differsOnPurpose)
    }
}
