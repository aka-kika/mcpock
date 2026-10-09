import XCTest
@testable import mcpock

// MARK: - ClaudeCodeUsageReader

/// Fixtures under a throwaway temp folder, never the real `~/.claude/projects`.
final class ClaudeCodeUsageReaderTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock.tests.usage.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func write(_ lines: [String], to name: String = "session.jsonl", in subdirectory: String? = nil) -> URL {
        let directory = subdirectory.map { root.appendingPathComponent($0, isDirectory: true) } ?? root!
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let text = lines.map { $0 + "\n" }.joined()
        try! Data(text.utf8).write(to: url)
        return url
    }

    private func line(name: String, timestamp: String = "2026-01-01T10:00:00.000Z", role: String = "assistant") -> String {
        """
        {"timestamp":"\(timestamp)","message":{"role":"\(role)","content":[{"type":"tool_use","id":"t1","name":"\(name)","input":{}}]}}
        """
    }

    func testNormalCall() {
        _ = write([line(name: "mcp__skill-librarian__librarian_find")])
        let reader = ClaudeCodeUsageReader(root: root)
        let (events, cursor) = reader.read(since: .empty, knownServers: [])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.server, "skill-librarian")
        XCTAssertEqual(events.first?.agent, AgentRegistry.claudeCodeLabel)
        XCTAssertGreaterThan(cursor.values.values.first ?? 0, 0, "the offset advanced")
    }

    func testPluginName() {
        _ = write([line(name: "mcp__plugin_chrome-devtools-mcp_chrome-devtools__click")])
        let reader = ClaudeCodeUsageReader(root: root)
        let known: Set<String> = [HealthMonitor.normalizedName("chrome-devtools")]
        let (events, _) = reader.read(since: .empty, knownServers: known)
        XCTAssertEqual(events.first?.server, "chrome-devtools", "the part that matches a known server")
    }

    func testPluginNameFallsBackToRawWithNoKnownServerMatch() {
        _ = write([line(name: "mcp__plugin_remarc_remarc__remarc_get_comment")])
        let reader = ClaudeCodeUsageReader(root: root)
        let (events, _) = reader.read(since: .empty, knownServers: [])
        XCTAssertEqual(events.first?.server, "remarc_remarc", "no match: the raw <plugin>_<server> text")
    }

    func testNonMCPToolIgnored() {
        _ = write([line(name: "Bash")])
        let reader = ClaudeCodeUsageReader(root: root)
        let (events, _) = reader.read(since: .empty, knownServers: [])
        XCTAssertTrue(events.isEmpty)
    }

    func testUserRoleIgnored() {
        _ = write([line(name: "mcp__skill-librarian__librarian_find", role: "user")])
        let reader = ClaudeCodeUsageReader(root: root)
        let (events, _) = reader.read(since: .empty, knownServers: [])
        XCTAssertTrue(events.isEmpty, "only assistant tool_use blocks count")
    }

    func testIncrementalSecondReadReturnsOnlyNewLines() {
        let url = write([line(name: "mcp__skill-librarian__librarian_find")])
        let reader = ClaudeCodeUsageReader(root: root)
        let (firstEvents, cursor) = reader.read(since: .empty, knownServers: [])
        XCTAssertEqual(firstEvents.count, 1)

        // Append one more call.
        let handle = try! FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((line(name: "mcp__eventkit__list_reminders") + "\n").utf8))
        try? handle.close()

        let (secondEvents, secondCursor) = reader.read(since: cursor, knownServers: [])
        XCTAssertEqual(secondEvents.count, 1, "only the new line, not the first one again")
        XCTAssertEqual(secondEvents.first?.server, "eventkit")
        XCTAssertGreaterThan(secondCursor.values.values.first ?? 0, cursor.values.values.first ?? 0)
    }

    func testReplacedFileStartsOver() {
        let url = write([line(name: "mcp__skill-librarian__librarian_find"), line(name: "mcp__eventkit__list_reminders")])
        let reader = ClaudeCodeUsageReader(root: root)
        let (_, cursor) = reader.read(since: .empty, knownServers: [])
        XCTAssertGreaterThan(cursor.values.values.first ?? 0, 0)

        // Replaced with something shorter than the old offset.
        try! Data((line(name: "mcp__pieces__ask_pieces_ltm") + "\n").utf8).write(to: url)
        let (events, _) = reader.read(since: cursor, knownServers: [])
        XCTAssertEqual(events.count, 1, "the shrink is detected and the new content is read from the start")
        XCTAssertEqual(events.first?.server, "pieces")
    }

    func testIncompleteTrailingLineIsNotConsumedYet() {
        let directory = root!
        let url = directory.appendingPathComponent("live.jsonl")
        // No trailing newline: a line still being written.
        try! Data(line(name: "mcp__skill-librarian__librarian_find").utf8).write(to: url)
        let reader = ClaudeCodeUsageReader(root: root)
        let (events, cursor) = reader.read(since: .empty, knownServers: [])
        XCTAssertTrue(events.isEmpty, "an incomplete line is never parsed")
        // Keyed by whatever path the enumerator produced (macOS resolves
        // `/var` to `/private/var` under a temp root, so this isn't
        // necessarily `url.path` byte for byte) — what matters is the offset
        // it recorded, which must be 0: nothing was consumed.
        XCTAssertEqual(cursor.values.values.first ?? -1, 0, "and never counted as consumed")
    }

    func testSubagentTranscriptsAreFound() {
        _ = write([line(name: "mcp__skill-librarian__librarian_find")], to: "sub.jsonl", in: "session/subagents")
        let reader = ClaudeCodeUsageReader(root: root)
        let (events, _) = reader.read(since: .empty, knownServers: [])
        XCTAssertEqual(events.count, 1, "subagent transcripts, one folder deeper, are scanned too")
    }

    // MARK: - resolveServerName (pure)

    func testResolveServerName() {
        XCTAssertEqual(ClaudeCodeUsageReader.resolveServerName("mcp__reed-md__note_save", knownServers: []), "reed-md")
        XCTAssertNil(ClaudeCodeUsageReader.resolveServerName("Read", knownServers: []))
        XCTAssertNil(ClaudeCodeUsageReader.resolveServerName("mcp__onlyone", knownServers: []), "no tool separator")
        let known: Set<String> = [HealthMonitor.normalizedName("pdf")]
        XCTAssertEqual(
            ClaudeCodeUsageReader.resolveServerName("mcp__plugin_pdf-viewer_pdf__display_pdf", knownServers: known),
            "pdf"
        )
    }
}

// MARK: - UsageText

final class UsageTextTests: XCTestCase {
    func testBelowThousandIsPlain() {
        XCTAssertEqual(UsageText.compact(0), "0")
        XCTAssertEqual(UsageText.compact(42), "42")
        XCTAssertEqual(UsageText.compact(999), "999")
    }

    func testThousandsUseK() {
        XCTAssertEqual(UsageText.compact(1000), "1k")
        XCTAssertEqual(UsageText.compact(1240), "1.2k")
        XCTAssertEqual(UsageText.compact(2000), "2k", "a clean multiple drops the .0")
        XCTAssertEqual(UsageText.compact(999_499), "999.5k")
    }

    func testMillionsUseM() {
        XCTAssertEqual(UsageText.compact(1_000_000), "1M")
        XCTAssertEqual(UsageText.compact(3_400_000), "3.4M")
    }
}

// MARK: - UsageWindow / AppPreferences

final class UsageWindowPreferenceTests: XCTestCase {
    func testDefaultIsThirtyDays() {
        XCTAssertEqual(UsageWindow.default, .thirtyDays)
    }

    func testDaysForEachStop() {
        XCTAssertNil(UsageWindow.off.days)
        XCTAssertEqual(UsageWindow.sevenDays.days, 7)
        XCTAssertEqual(UsageWindow.thirtyDays.days, 30)
        XCTAssertNil(UsageWindow.allTime.days)
    }

    func testRoundTrip() {
        let suite = "mcpock.tests.usagewindow.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }

        XCTAssertEqual(AppPreferences.loadUsageWindow(from: defaults), .thirtyDays, "default when nothing saved")
        AppPreferences.saveUsageWindow(.off, to: defaults)
        XCTAssertEqual(AppPreferences.loadUsageWindow(from: defaults), .off)
        AppPreferences.saveUsageWindow(.allTime, to: defaults)
        XCTAssertEqual(AppPreferences.loadUsageWindow(from: defaults), .allTime)
    }

    func testKnownKeysListsUsageWindow() {
        XCTAssertTrue(SettingsMigration.knownKeys.contains(AppPreferences.usageWindowKey))
    }
}

// MARK: - UsageStore

@MainActor
final class UsageStoreTests: XCTestCase {
    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock.tests.usagestore.\(UUID().uuidString)", isDirectory: true)
        suite = "mcpock.tests.usagestore.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.retireSuite(named: suite)
        super.tearDown()
    }

    private struct FakeReader: UsageReader {
        let agent: String
        let events: [UsageEvent]
        func read(since cursor: UsageCursor, knownServers: Set<String>) -> (events: [UsageEvent], cursor: UsageCursor) {
            var next = cursor
            next.values["fake"] = (cursor.values["fake"] ?? 0) + 1
            return (events, next)
        }
    }

    func testDayIndexIsStableWithinADay() {
        // A fixed UTC calendar, so this test's day boundaries don't depend on
        // the machine's own time zone (production uses `.current` on purpose
        // — a local calendar day — this just needs an unambiguous one to test against).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let morning = ISO8601DateFormatter().date(from: "2026-01-05T01:00:00Z")!
        let evening = ISO8601DateFormatter().date(from: "2026-01-05T23:00:00Z")!
        XCTAssertEqual(UsageStore.dayIndex(for: morning, calendar: calendar), UsageStore.dayIndex(for: evening, calendar: calendar))
        let nextDay = ISO8601DateFormatter().date(from: "2026-01-06T01:00:00Z")!
        XCTAssertEqual(UsageStore.dayIndex(for: nextDay, calendar: calendar), UsageStore.dayIndex(for: morning, calendar: calendar) + 1)
    }

    func testNoReaderIsADash() async {
        let store = UsageStore(readers: [], directory: directory, isHostingTests: true, defaults: defaults)
        await store.start(knownServers: [])?.value
        XCTAssertNil(store.count(agent: "Grok", server: "anything", window: .thirtyDays), "no reader at all: dash")
        XCTAssertFalse(store.hasReader(for: "Grok"))
    }

    func testRealZeroIsNeverADash() async {
        let store = UsageStore(readers: [FakeReader(agent: "Code", events: [])], directory: directory, isHostingTests: true, defaults: defaults)
        await store.start(knownServers: [])?.value
        XCTAssertEqual(store.count(agent: "Code", server: "reed-md", window: .thirtyDays), 0,
                       "a reader that found nothing: a real 0, never nil")
    }

    func testWindowMath() async {
        let now = Date()
        let day: TimeInterval = 86400
        let events = [
            UsageEvent(agent: "Code", server: "reed-md", date: now), // today
            UsageEvent(agent: "Code", server: "reed-md", date: now.addingTimeInterval(-5 * day)), // 5 days ago
            UsageEvent(agent: "Code", server: "reed-md", date: now.addingTimeInterval(-20 * day)), // 20 days ago
            UsageEvent(agent: "Code", server: "reed-md", date: now.addingTimeInterval(-90 * day)), // 90 days ago
        ]
        let store = UsageStore(readers: [FakeReader(agent: "Code", events: events)], directory: directory, isHostingTests: true, defaults: defaults)
        await store.start(knownServers: [])?.value

        XCTAssertEqual(store.count(agent: "Code", server: "reed-md", window: .sevenDays, now: now), 2)
        XCTAssertEqual(store.count(agent: "Code", server: "reed-md", window: .thirtyDays, now: now), 3)
        XCTAssertEqual(store.count(agent: "Code", server: "reed-md", window: .allTime, now: now), 4)
    }

    /// A Hermes profile's calls are filed as "Hermes · scribe": its row counts
    /// those, not the main Hermes ones, while the reader check stays "Hermes".
    func testProfileCountsItsOwnCalls() async {
        let events = [
            UsageEvent(agent: "Hermes", server: "recall", date: Date()),
            UsageEvent(agent: "Hermes", server: "recall", date: Date()),
            UsageEvent(agent: "Hermes · scribe", server: "recall", date: Date()),
        ]
        let store = UsageStore(readers: [FakeReader(agent: "Hermes", events: events)], directory: directory, isHostingTests: true, defaults: defaults)
        await store.start(knownServers: [])?.value
        XCTAssertEqual(store.count(agent: "Hermes", server: "recall", window: .thirtyDays), 2)
        XCTAssertEqual(store.count(agent: "Hermes", server: "recall", window: .thirtyDays, recordedAs: "Hermes · scribe"), 1)
    }

    func testServerNameIsNormalized() async {
        let events = [UsageEvent(agent: "Code", server: "Chrome DevTools", date: Date())]
        let store = UsageStore(readers: [FakeReader(agent: "Code", events: events)], directory: directory, isHostingTests: true, defaults: defaults)
        await store.start(knownServers: [])?.value
        XCTAssertEqual(store.count(agent: "Code", server: "chrome-devtools", window: .allTime), 1,
                       "grouped like the Servers tab, via HealthMonitor.normalizedName")
    }

    func testPersistsAndReloads() async {
        let events = [UsageEvent(agent: "Code", server: "reed-md", date: Date())]
        let first = UsageStore(readers: [FakeReader(agent: "Code", events: events)], directory: directory, isHostingTests: false, defaults: defaults)
        await first.start(knownServers: [])?.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.fileURL.path))

        // A fresh store, same directory, no reader with anything new: what it
        // shows comes only from the file on disk.
        let second = UsageStore(readers: [FakeReader(agent: "Code", events: [])], directory: directory, isHostingTests: false, defaults: defaults)
        await second.start(knownServers: [])?.value
        XCTAssertEqual(second.count(agent: "Code", server: "reed-md", window: .allTime), 1)
    }

    func testHostingTestsNeverWritesTheFile() async {
        let events = [UsageEvent(agent: "Code", server: "reed-md", date: Date())]
        let store = UsageStore(readers: [FakeReader(agent: "Code", events: events)], directory: directory, isHostingTests: true, defaults: defaults)
        await store.start(knownServers: [])?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testOffStopsReadingEntirely() {
        let suite = "mcpock.tests.usagestore.off.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        AppPreferences.saveUsageWindow(.off, to: defaults)

        let store = UsageStore(
            readers: [FakeReader(agent: "Code", events: [])], directory: directory, isHostingTests: true, defaults: defaults
        )
        let task = store.start(knownServers: [])
        XCTAssertNil(task, "Off: never even starts a refresh")
    }
}

// MARK: - AgentSections.ServerFold (pure)

final class ServerFoldTests: XCTestCase {
    private func server(_ name: String, rank: Int? = nil) -> AgentServer {
        AgentServer(name: name, state: rank == nil ? .healthy : .broken, note: nil, rank: rank)
    }

    func testFewerThanLimitShowsEverything() {
        let servers = (1...3).map { server("s\($0)") }
        let result = AgentSections.ServerFold.shown(servers, expanded: false)
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertEqual(result.hiddenCount, 0)
    }

    func testProblemsAreNeverFoldedEvenPastTheLimit() {
        let problems = (1...7).map { server("broken\($0)", rank: 0) }
        let fine = (1...3).map { server("fine\($0)") }
        let servers = problems + fine
        let result = AgentSections.ServerFold.shown(servers, expanded: false, limit: 5)
        XCTAssertEqual(result.rows.count, 7, "all 7 problems show, past the limit of 5")
        XCTAssertTrue(result.rows.allSatisfy(\.needsYou))
        XCTAssertEqual(result.hiddenCount, 3, "all 3 fine ones fold away")
    }

    func testFineServersFillWhateverSlotsAreLeft() {
        let problems = (1...2).map { server("broken\($0)", rank: 0) }
        let fine = (1...10).map { server("fine\($0)") }
        let servers = problems + fine
        let result = AgentSections.ServerFold.shown(servers, expanded: false, limit: 5)
        XCTAssertEqual(result.rows.count, 5, "2 problems + 3 fine slots")
        XCTAssertEqual(result.rows.filter(\.needsYou).count, 2)
        XCTAssertEqual(result.rows.filter { !$0.needsYou }.count, 3)
        XCTAssertEqual(result.hiddenCount, 7)
    }

    func testOrderIsNeverChanged() {
        let servers = [server("broken", rank: 0), server("a"), server("b"), server("c"), server("d"), server("e"), server("f")]
        let result = AgentSections.ServerFold.shown(servers, expanded: false, limit: 5)
        XCTAssertEqual(result.rows.map(\.name), ["broken", "a", "b", "c", "d"])
    }

    func testExpandedShowsEverything() {
        let servers = (1...9).map { server("s\($0)") }
        let result = AgentSections.ServerFold.shown(servers, expanded: true)
        XCTAssertEqual(result.rows.count, 9)
        XCTAssertEqual(result.hiddenCount, 0)
    }

    func testProblemsOnlyModeDegeneratesToNoLink() {
        // What `section.listed` is with the attention filter on: problems only,
        // however many. The fold should never hide any of them.
        let problems = (1...9).map { server("broken\($0)", rank: 0) }
        let result = AgentSections.ServerFold.shown(problems, expanded: false, limit: 5)
        XCTAssertEqual(result.rows.count, 9)
        XCTAssertEqual(result.hiddenCount, 0, "nothing left to fold: no link shows")
    }
}

// MARK: - PanelState fold toggle

@MainActor
final class ServerFoldPanelStateTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "mcpock.tests.serverfold.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.retireSuite(named: suite)
        super.tearDown()
    }

    func testToggleServerFoldFlipsMembership() {
        let state = PanelState(monitor: HealthMonitor(defaults: defaults), defaults: defaults)
        XCTAssertFalse(state.expandedFoldAgents.contains("Code"))
        state.toggleServerFold(for: "Code")
        XCTAssertTrue(state.expandedFoldAgents.contains("Code"))
        state.toggleServerFold(for: "Code")
        XCTAssertFalse(state.expandedFoldAgents.contains("Code"))
    }
}
