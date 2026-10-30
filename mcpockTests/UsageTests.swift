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
        try! Data((line(name: "mcp__pieces__ask_pieces_ltm", timestamp: "2026-01-02T10:00:00.000Z") + "\n").utf8).write(to: url)
        let (events, _) = reader.read(since: cursor, knownServers: [])
        XCTAssertEqual(events.count, 1, "the shrink is detected and the new content is read from the start")
        XCTAssertEqual(events.first?.server, "pieces")
    }

    /// A transcript rewritten shorter but still holding calls already counted
    /// (review, 2026-10-14, item 11): only the call newer than those counts.
    func testRewrittenFileNeverCountsOldCallsTwice() {
        let url = write([
            line(name: "mcp__skill-librarian__librarian_find", timestamp: "2026-01-01T10:00:00.000Z"),
            line(name: "mcp__eventkit__list_reminders", timestamp: "2026-01-01T11:00:00.000Z"),
            line(name: "mcp__eventkit__list_reminders", timestamp: "2026-01-01T12:00:00.000Z"),
        ])
        let reader = ClaudeCodeUsageReader(root: root)
        let (first, cursor) = reader.read(since: .empty, knownServers: [])
        XCTAssertEqual(first.count, 3)

        try! Data([
            line(name: "mcp__eventkit__list_reminders", timestamp: "2026-01-01T12:00:00.000Z"),
            line(name: "mcp__pieces__ask_pieces_ltm", timestamp: "2026-01-01T13:00:00.000Z"),
        ].map { $0 + "\n" }.joined().utf8).write(to: url)
        let (second, _) = reader.read(since: cursor, knownServers: [])
        XCTAssertEqual(second.map(\.server), ["pieces"], "the call counted before is not counted again")
    }

    /// Argon 2026-10-17 #13: a rewritten transcript written in pieces. Only
    /// the first read sees it shrink; the old calls in the later pieces are
    /// still never counted again.
    func testRewrittenFileReadInPiecesNeverCountsOldCallsTwice() {
        let old = [
            line(name: "mcp__skill-librarian__librarian_find", timestamp: "2026-01-01T10:00:00.000Z"),
            line(name: "mcp__eventkit__list_reminders", timestamp: "2026-01-01T11:00:00.000Z"),
            line(name: "mcp__eventkit__list_reminders", timestamp: "2026-01-01T12:00:00.000Z"),
        ]
        let url = write(old)
        let reader = ClaudeCodeUsageReader(root: root)
        let (first, cursor) = reader.read(since: .empty, knownServers: [])
        XCTAssertEqual(first.count, 3)

        // Rewritten: the first piece has no MCP call at all.
        try! Data((line(name: "Bash", timestamp: "2026-01-01T09:00:00.000Z") + "\n").utf8).write(to: url)
        let (second, afterFirstPiece) = reader.read(since: cursor, knownServers: [])
        XCTAssertTrue(second.isEmpty)

        // The rest arrives: the old calls again, then one new call.
        let handle = try! FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((old + [line(name: "mcp__pieces__ask_pieces_ltm", timestamp: "2026-01-01T13:00:00.000Z")])
            .map { $0 + "\n" }.joined().utf8))
        try? handle.close()
        let (third, afterRest) = reader.read(since: afterFirstPiece, knownServers: [])
        XCTAssertEqual(third.map(\.server), ["pieces"], "only the new call")

        // Kept across launches, and later calls still count.
        let saved = try! JSONDecoder().decode(UsageCursor.self, from: JSONEncoder().encode(afterRest))
        XCTAssertEqual(saved, afterRest)
        let more = try! FileHandle(forWritingTo: url)
        more.seekToEndOfFile()
        more.write(Data((line(name: "mcp__eventkit__list_reminders", timestamp: "2026-01-01T14:00:00.000Z") + "\n").utf8))
        try? more.close()
        XCTAssertEqual(reader.read(since: saved, knownServers: []).events.map(\.server), ["eventkit"])
    }

    /// r3 b935: cursor keys are hashes, never a path; an old full-path key
    /// moves to its hash once and its calls are not counted again.
    func testCursorKeysAreHashedAndOldPathKeysMigrate() {
        let url = write([line(name: "mcp__skill-librarian__librarian_find")])
        let reader = ClaudeCodeUsageReader(root: root)
        let (_, cursor) = reader.read(since: .empty, knownServers: [])
        for key in cursor.values.keys + Array(cursor.newest.keys) {
            XCTAssertTrue(key.hasPrefix("cc:"), "no path in the cursor")
            XCTAssertFalse(key.contains("mcpock.tests"))
        }
        XCTAssertFalse(cursor.values.isEmpty)

        // An old cursor, keyed by the full path the enumerator produced, plus
        // a leftover for a transcript that is gone.
        let hashed = cursor.values.keys.first!
        var old = UsageCursor.empty
        old.values["/gone/project/x.jsonl"] = 10
        old.newest["/gone/project/x.jsonl"] = 10
        for path in [url.path, url.resolvingSymlinksInPath().path, "/private" + url.path] {
            old.values[path] = cursor.values[hashed]
        }
        let (events, migrated) = reader.read(since: old, knownServers: [])
        XCTAssertTrue(events.isEmpty, "already read: not counted twice")
        XCTAssertEqual(migrated.values[hashed], cursor.values[hashed])
        XCTAssertTrue(migrated.values.keys.allSatisfy { $0.hasPrefix("cc:") })
        XCTAssertTrue(migrated.newest.keys.allSatisfy { $0.hasPrefix("cc:") })
    }

    /// r3 394d: a damaged cursor with a negative offset must not trap.
    func testNegativeStoredOffsetIsClampedToStart() {
        let url = write([line(name: "mcp__skill-librarian__librarian_find")])
        let reader = ClaudeCodeUsageReader(root: root)
        let key = url.resolvingSymlinksInPath().path
        var damaged = UsageCursor.empty
        damaged.values[key] = -5
        damaged.values[url.path] = -5
        let (events, _) = reader.read(since: damaged, knownServers: [])
        XCTAssertEqual(events.count, 1, "read from the start instead of crashing")
    }

    /// r3 394d: a FIFO or a symlink named `.jsonl` is skipped, never opened.
    func testFifoAndSymlinkNamedJsonlAreSkipped() {
        let real = write([line(name: "mcp__skill-librarian__librarian_find")], to: "real.txt")
        try! FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.jsonl"), withDestinationURL: real)
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe.jsonl").path, 0o600), 0)
        let reader = ClaudeCodeUsageReader(root: root)
        let (events, cursor) = reader.read(since: .empty, knownServers: [])
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(cursor.values.isEmpty, "neither was even looked at")
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
    /// 1.13: off for a new install, and an earlier one keeps counting.
    func testDefaultIsOffAndEarlierInstallsKeepCounting() {
        XCTAssertEqual(UsageWindow.default, .off)
        let suite = "mcpock.tests.usagedefault.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }

        AppPreferences.keepUsageForEarlierInstall(ranBefore: false, defaults: defaults)
        XCTAssertEqual(AppPreferences.loadUsageWindow(from: defaults), .off, "a new install")

        AppPreferences.keepUsageForEarlierInstall(ranBefore: true, defaults: defaults)
        XCTAssertEqual(AppPreferences.loadUsageWindow(from: defaults), .thirtyDays, "never touched: it was counting")

        for chosen in [UsageWindow.sevenDays, .allTime, .off] {
            AppPreferences.saveUsageWindow(chosen, to: defaults)
            AppPreferences.keepUsageForEarlierInstall(ranBefore: true, defaults: defaults)
            XCTAssertEqual(AppPreferences.loadUsageWindow(from: defaults), chosen, "its own choice stays")
        }
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

        XCTAssertEqual(AppPreferences.loadUsageWindow(from: defaults), .off, "default when nothing saved")
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

    /// Argon 2026-10-17 #11: in London, local midnight on 30 March 2026
    /// (after the clocks went forward) divided by 86,400 rounded down to the
    /// same index as 29 March.
    func testDayIndexAcrossSpringForwardInLondon() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let sunday = ISO8601DateFormatter().date(from: "2026-03-29T12:00:00Z")!
        let monday = ISO8601DateFormatter().date(from: "2026-03-30T12:00:00Z")!
        XCTAssertEqual(UsageStore.dayIndex(for: monday, calendar: calendar),
                       UsageStore.dayIndex(for: sunday, calendar: calendar) + 1)
        XCTAssertEqual(UsageStore.dayIndex(for: ISO8601DateFormatter().date(from: "1970-01-01T12:00:00Z")!,
                                           calendar: calendar), 0)
    }

    /// Indexes saved the old way map to the same local day, east and west.
    func testLegacyDayIndexesMapToTheSameDay() {
        for zone in ["Asia/Jerusalem", "America/New_York", "UTC"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!
            let legacy = Int((calendar.startOfDay(for: noon).timeIntervalSince1970 / 86400).rounded(.down))
            XCTAssertEqual(UsageStore.dayIndex(fromLegacy: legacy, calendar: calendar),
                           UsageStore.dayIndex(for: noon, calendar: calendar), zone)
        }
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

    /// Counts saved before 1.10.6 have no per-source "newest call" yet: a
    /// source that starts over after the update counts only calls made after
    /// the file was last saved, and the old counts stay as they were.
    func testCountsSavedBeforeTheUpdateAreNeverAddedTwice() async throws {
        let saved = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!
        let legacy = """
            {"buckets":[{"agent":"Code","server":"\(HealthMonitor.normalizedName("reed-md"))","days":{"\(UsageStore.dayIndex(for: saved))":5}}],
             "cursors":{"Code":{"values":{"src":900}}}}
            """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UsageStore.fileName)
        try Data(legacy.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: saved], ofItemAtPath: file.path)

        let replayed = [
            UsageEvent(agent: "Code", server: "reed-md", date: saved.addingTimeInterval(-3600)), // counted back then
            UsageEvent(agent: "Code", server: "reed-md", date: saved.addingTimeInterval(3600)), // new
        ]
        let store = UsageStore(readers: [RestartingReader(agent: "Code", events: replayed)], directory: directory, isHostingTests: false, defaults: defaults)
        await store.start(knownServers: [])?.value
        XCTAssertEqual(store.count(agent: "Code", server: "reed-md", window: .allTime), 6, "5 kept, 1 new, the old call not again")

        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(written?["version"] as? Int, 3)
    }

    /// Plays a source that started over: hands back every event it holds,
    /// minus the ones the cursor says were already counted.
    private struct RestartingReader: UsageReader {
        let agent: String
        let events: [UsageEvent]
        func read(since cursor: UsageCursor, knownServers: Set<String>) -> (events: [UsageEvent], cursor: UsageCursor) {
            var next = cursor
            let fresh = cursor.uncounted(events, from: "src")
            next.noteCounted(fresh, from: "src")
            next.values["src"] = 1
            return (fresh, next)
        }
    }

    func testCursorSavedBeforeTheUpdateStillDecodes() throws {
        let cursor = try JSONDecoder().decode(UsageCursor.self, from: Data(#"{"values":{"a":3}}"#.utf8))
        XCTAssertEqual(cursor, UsageCursor(values: ["a": 3]))
        var next = cursor
        next.noteCounted([UsageEvent(agent: "Code", server: "x", date: Date(timeIntervalSince1970: 10))], from: "a")
        let roundTrip = try JSONDecoder().decode(UsageCursor.self, from: JSONEncoder().encode(next))
        XCTAssertEqual(roundTrip.newest["a"], 10_000)
    }

    func testHostingTestsNeverWritesTheFile() async {
        let events = [UsageEvent(agent: "Code", server: "reed-md", date: Date())]
        let store = UsageStore(readers: [FakeReader(agent: "Code", events: events)], directory: directory, isHostingTests: true, defaults: defaults)
        await store.start(knownServers: [])?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// Argon 2026-10-16 #13: before the first scan ends there are no counts
    /// yet, so a dash, never a fake 0; turning Usage on reads at once.
    func testNoFakeZeroBeforeTheFirstScanAndOnTurningUsageOn() async {
        let suite = "mcpock.tests.usagestore.on.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        AppPreferences.saveUsageWindow(.off, to: defaults)
        let store = UsageStore(
            readers: [FakeReader(agent: "Code", events: [])], directory: directory, isHostingTests: true, defaults: defaults
        )
        XCTAssertNil(store.start(knownServers: ["reed-md"]))
        XCTAssertNil(store.count(agent: "Code", server: "reed-md", window: .thirtyDays), "nothing counted yet: a dash")

        AppPreferences.saveUsageWindow(.thirtyDays, to: defaults)
        await store.usageWindowChanged(knownServers: ["reed-md"])?.value
        XCTAssertEqual(store.count(agent: "Code", server: "reed-md", window: .thirtyDays), 0, "counted at once: a real 0")
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
