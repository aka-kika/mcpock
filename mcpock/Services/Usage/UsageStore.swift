import Foundation

/// Usage counts (1.7): how many times each agent called each MCP server, read
/// from each agent's own on-disk records via `UsageReader` (the shared
/// contract in `UsageReader.swift`). Read-only, and it keeps only agent,
/// server and time — never arguments, results or chat text.
///
/// Owns the readers (`UsageReaders.all` by default), runs them off the main
/// thread at utility priority, and folds their events into daily buckets per
/// (agent, server normalized with `HealthMonitor.normalizedName`, day), so the
/// 7-day / 30-day / all-time windows are cheap integer-range sums. Persists
/// only counts, cursors and buckets — atomically, and never while the app is
/// hosting unit tests — to `usage.json` next to `status.json`.
@MainActor
@Observable
final class UsageStore {
    /// One agent × server bucket. `agent` is `UsageEvent.agent` (a reader's own
    /// label, e.g. `AgentRegistry.claudeCodeLabel`); `server` is already
    /// normalized, so callers can pass either the raw or the normalized name.
    private struct BucketKey: Hashable {
        let agent: String
        let server: String
    }

    /// One agent × server × tool bucket (Part 2, 2026-11-10). `server` and
    /// `tool` are normalized with `HealthMonitor.normalizedName`, so a tool
    /// an agent spells `get-file` and the server lists as `get_file` meet.
    private struct ToolKey: Hashable {
        let agent: String
        let server: String
        let tool: String
    }

    /// At most once every ten minutes for the "after a full probe cycle"
    /// trigger; the very first call (the monitor starting) is never throttled.
    static let throttle: TimeInterval = 10 * 60

    private let readers: [UsageReader]
    private let directory: URL
    private let isHostingTests: Bool
    private let defaults: UserDefaults

    /// Day index (see `dayIndex`) -> call count, keyed by (agent, server).
    private var buckets: [BucketKey: [Int: Int]] = [:]
    /// Day index -> call count, keyed by (agent, server, tool).
    private var toolBuckets: [ToolKey: [Int: Int]] = [:]
    /// Where each reader left off, keyed by `UsageEvent.agent`.
    private var cursors: [String: UsageCursor] = [:]
    /// Counts saved before per-tool counts (version < 4) have server buckets
    /// but none per tool, and the cursors are already past those calls: the
    /// next refresh reads every source once more from the start for the tool
    /// buckets only.
    private var needsToolBackfill = false

    private var hasLoaded = false
    /// True once real counts exist: a saved file was read, or a scan finished.
    /// Until then `count` says nil (a dash), never a fake 0 (Argon 2026-10-16 #13).
    private(set) var hasCounts = false
    /// Whether `start` has run. The app starts the store only once discovery
    /// has named the servers (see `MCPockApp`).
    var isStarted: Bool { hasLoaded }
    private var lastRefreshDate: Date?
    /// A refresh in flight; a second trigger before it lands is a no-op —
    /// mirrors `HealthMonitor`'s single-flight probe cycles.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Called on the main actor after new counts land (1.16: the status file
    /// agents read follows them).
    @ObservationIgnored var onCountsChanged: (() -> Void)?

    init(
        readers: [UsageReader] = UsageReaders.all,
        directory: URL = MCPockStatus.defaultDirectory(),
        isHostingTests: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
        defaults: UserDefaults = .standard
    ) {
        self.readers = readers
        self.directory = directory
        self.isHostingTests = isHostingTests
        self.defaults = defaults
    }

    nonisolated static let fileName = "usage.json"
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    // MARK: - Lifecycle

    /// Call once, right after the monitor starts. Loads whatever was
    /// persisted, then always refreshes: the very first run can be big
    /// (`~/.claude/projects` alone ran past a gigabyte across ~800 files on a
    /// working Mac), but the readers stream and keep a byte offset per file,
    /// so that cost is paid once, off the main thread. Returns the refresh
    /// task (nil only if Usage is Off) so tests can await it.
    @discardableResult
    func start(knownServers: Set<String>) -> Task<Void, Never>? {
        guard !hasLoaded else { return nil }
        hasLoaded = true
        load()
        return refresh(knownServers: knownServers)
    }

    /// Call after every full probe cycle. Throttled so an idle Mac with a
    /// short check interval doesn't re-scan the transcripts every minute.
    @discardableResult
    func probeCycleCompleted(knownServers: Set<String>) -> Task<Void, Never>? {
        guard hasLoaded else { return nil } // start() not called yet; nothing to throttle against
        if let last = lastRefreshDate, Date().timeIntervalSince(last) < Self.throttle { return nil }
        return refresh(knownServers: knownServers)
    }

    // MARK: - Reading counts

    /// Whether `agent` (the base label — strip a "· profile" or "(Project)"
    /// suffix with `AgentBadge.agentName(fromLabel:)` first) has a reader at
    /// all. False means "this agent keeps no record": the view shows a dash.
    func hasReader(for agent: String) -> Bool {
        readers.contains { $0.agent == agent }
    }

    /// Calls for `server` by `agent` in `window`, or nil when this agent keeps
    /// no record. Never a fake 0: an agent with a reader and truly no calls in
    /// the window gets a real 0. `server` may be raw or already normalized.
    /// `recordedAs` is the label the reader filed the calls under when it
    /// differs from the base agent: a Hermes profile's own calls are
    /// "Hermes · scribe", not "Hermes".
    func count(agent: String, server: String, window: UsageWindow, recordedAs: String? = nil, now: Date = Date()) -> Int? {
        guard hasReader(for: agent), hasCounts else { return nil }
        let key = BucketKey(agent: recordedAs ?? agent, server: HealthMonitor.normalizedName(server))
        let days = buckets[key] ?? [:]
        guard let windowSize = window.days else { return days.values.reduce(0, +) } // All time
        let cutoff = Self.dayIndex(for: now) - (windowSize - 1)
        return days.reduce(0) { sum, entry in entry.key >= cutoff ? sum + entry.value : sum }
    }

    /// Calls for `server` in `window` across every agent's records, for the
    /// Servers tab's rows (11 Nov, 37f0). Nil until real counts exist, or
    /// with Usage off.
    func count(server: String, window: UsageWindow, now: Date = Date()) -> Int? {
        guard hasCounts, window != .off else { return nil }
        let wanted = HealthMonitor.normalizedName(server)
        let cutoff = window.days.map { Self.dayIndex(for: now) - ($0 - 1) }
        var total = 0
        for (key, days) in buckets where key.server == wanted {
            for (day, calls) in days where cutoff.map({ day >= $0 }) ?? true { total += calls }
        }
        return total
    }

    /// Per tool of `server`, across every agent's records: calls in `window`
    /// and the last day one was seen (any time, so a tool used 40 days ago
    /// still says when). Keys are normalized tool names (look them up with
    /// `toolKey`). Nil until real counts exist (never a fake "never used").
    func toolUsage(server: String, window: UsageWindow, now: Date = Date()) -> [String: ToolUsage]? {
        guard hasCounts, window != .off else { return nil }
        let wanted = HealthMonitor.normalizedName(server)
        let cutoff = window.days.map { Self.dayIndex(for: now) - ($0 - 1) }
        var result: [String: ToolUsage] = [:]
        for (key, days) in toolBuckets where key.server == wanted {
            var entry = result[key.tool] ?? ToolUsage(calls: 0, lastDay: nil)
            for (day, count) in days {
                if cutoff.map({ day >= $0 }) ?? true { entry.calls += count }
                if count > 0 { entry.lastDay = max(entry.lastDay ?? day, day) }
            }
            result[key.tool] = entry
        }
        return result
    }

    /// The key `toolUsage` files a tool under.
    nonisolated static func toolKey(_ tool: String) -> String {
        HealthMonitor.normalizedName(tool)
    }

    /// Settings changed the Usage window. Turning Usage on reads at once,
    /// not at the next (throttled) cycle end, which in Manual mode never came.
    @discardableResult
    func usageWindowChanged(knownServers: Set<String>) -> Task<Void, Never>? {
        // The status file shows the new window (or no counts, when Off) at once.
        onCountsChanged?()
        guard !knownServers.isEmpty else { return nil } // the first cycle's end starts it
        guard hasLoaded else { return start(knownServers: knownServers) }
        return refresh(knownServers: knownServers)
    }

    // MARK: - Refresh

    @discardableResult
    private func refresh(knownServers: Set<String>) -> Task<Void, Never>? {
        guard AppPreferences.loadUsageWindow(from: defaults) != .off else { return nil } // stop reading entirely
        guard refreshTask == nil else { return refreshTask }
        lastRefreshDate = Date()
        let readers = self.readers
        let cursorsSnapshot = cursors
        let existingBuckets = buckets
        let existingToolBuckets = toolBuckets
        let backfill = needsToolBackfill
        let isHostingTests = self.isHostingTests
        let directory = self.directory

        // A plain `Task` inherits this method's main-actor isolation, so
        // everything after the inner `await` — writing `self.buckets` back —
        // runs on the main actor with no extra hop. Only the actual work (file
        // I/O, the readers, the write to disk) is `Task.detached`, off the
        // main thread at utility priority, and takes no reference to `self`.
        let task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.process(
                    readers: readers, cursors: cursorsSnapshot, buckets: existingBuckets,
                    toolBuckets: existingToolBuckets, backfillTools: backfill,
                    knownServers: knownServers, isHostingTests: isHostingTests, directory: directory
                )
            }.value
            guard let self else { return }
            self.buckets = result.buckets
            self.toolBuckets = result.toolBuckets
            self.cursors = result.cursors
            self.needsToolBackfill = false
            self.hasCounts = true
            self.refreshTask = nil
            self.onCountsChanged?()
        }
        refreshTask = task
        return task
    }

    /// Every reader's new events, folded into `buckets`, off the main actor.
    /// Takes and returns only Sendable snapshots — never `self` — so it can
    /// run detached.
    ///
    /// `backfillTools`: the saved counts predate per-tool counts. Each reader
    /// first reads its sources from the start into the tool buckets only
    /// (the server buckets already hold those calls), then the usual read
    /// from the saved cursor fills the server buckets only. Calls written in
    /// the moment between the two reads miss the tool counts, never doubled.
    nonisolated private static func process(
        readers: [UsageReader], cursors: [String: UsageCursor], buckets: [BucketKey: [Int: Int]],
        toolBuckets: [ToolKey: [Int: Int]], backfillTools: Bool,
        knownServers: Set<String>, isHostingTests: Bool, directory: URL
    ) -> (buckets: [BucketKey: [Int: Int]], toolBuckets: [ToolKey: [Int: Int]], cursors: [String: UsageCursor]) {
        var newBuckets = buckets
        var newToolBuckets = backfillTools ? [:] : toolBuckets
        var newCursors = cursors
        for reader in readers {
            if backfillTools {
                let (all, _) = reader.read(since: .empty, knownServers: knownServers)
                for event in all { addTool(event, to: &newToolBuckets) }
            }
            let cursor = cursors[reader.agent] ?? .empty
            let (events, nextCursor) = reader.read(since: cursor, knownServers: knownServers)
            newCursors[reader.agent] = nextCursor
            for event in events {
                let key = BucketKey(agent: event.agent, server: HealthMonitor.normalizedName(event.server))
                let day = dayIndex(for: event.date)
                newBuckets[key, default: [:]][day, default: 0] += 1
                if !backfillTools { addTool(event, to: &newToolBuckets) }
            }
        }
        if !isHostingTests {
            try? persist(buckets: newBuckets, toolBuckets: newToolBuckets, cursors: newCursors, to: directory)
        }
        return (newBuckets, newToolBuckets, newCursors)
    }

    nonisolated private static func addTool(_ event: UsageEvent, to buckets: inout [ToolKey: [Int: Int]]) {
        guard let tool = event.tool, !toolKey(tool).isEmpty else { return }
        let key = ToolKey(agent: event.agent, server: HealthMonitor.normalizedName(event.server), tool: toolKey(tool))
        buckets[key, default: [:]][dayIndex(for: event.date), default: 0] += 1
    }

    // MARK: - Day math

    nonisolated private static let secondsPerDay: TimeInterval = 86400

    /// A day index (days since 1970-01-01, counted on the local calendar
    /// date) so window math is a plain integer comparison. `nonisolated` and
    /// pure: usable from the detached refresh task and from tests alike.
    ///
    /// From the date's own year, month and day, not its midnight divided by
    /// 86,400: where the clock goes from UTC+0 to UTC+1 (UK, Ireland,
    /// Portugal), two days in a row got the same index (Argon 2026-10-17 #11).
    nonisolated static func dayIndex(for date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return daysFromCivil(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's
    /// `days_from_civil`).
    nonisolated private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// A day index saved before version 3 (local midnight divided by 86,400):
    /// the local day whose midnight fell in that stretch.
    nonisolated static func dayIndex(fromLegacy index: Int, calendar: Calendar = .current) -> Int {
        dayIndex(for: Date(timeIntervalSince1970: Double(index + 1) * secondsPerDay - 1), calendar: calendar)
    }

    // MARK: - Persistence

    /// Only counts, cursors and buckets ever get to disk — never a call's
    /// arguments, result or any chat text (those never even reach `UsageEvent`).
    private struct Persisted: Codable {
        /// 2 since 1.10.6 (cursors carry `UsageCursor.newest`); 3 when day
        /// indexes come from the calendar date; missing before 1.10.6.
        var version: Int?
        var buckets: [PersistedBucket]
        /// Version 4 (Part 2, 2026-11-10): calls per tool.
        var tools: [PersistedToolBucket]?
        var cursors: [String: UsageCursor]
    }
    nonisolated private static let formatVersion = 4
    private struct PersistedToolBucket: Codable {
        let agent: String
        let server: String
        let tool: String
        let days: [String: Int]
    }
    private struct PersistedBucket: Codable {
        let agent: String
        let server: String
        /// Day index as a string (JSON object keys are strings) -> count.
        let days: [String: Int]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return }
        var loaded: [BucketKey: [Int: Int]] = [:]
        for bucket in decoded.buckets {
            let key = BucketKey(agent: bucket.agent, server: bucket.server)
            var days: [Int: Int] = [:]
            for (dayString, count) in bucket.days {
                guard let saved = Int(dayString) else { continue }
                let day = (decoded.version ?? 0) < 3 ? Self.dayIndex(fromLegacy: saved) : saved
                days[day, default: 0] += count
            }
            loaded[key] = days
        }
        buckets = loaded
        var loadedTools: [ToolKey: [Int: Int]] = [:]
        for bucket in decoded.tools ?? [] {
            let key = ToolKey(agent: bucket.agent, server: bucket.server, tool: bucket.tool)
            for (dayString, count) in bucket.days {
                guard let day = Int(dayString) else { continue }
                loadedTools[key, default: [:]][day, default: 0] += count
            }
        }
        toolBuckets = loadedTools
        needsToolBackfill = (decoded.version ?? 0) < 4
        cursors = decoded.cursors
        hasCounts = true
        // Saved before 1.10.6: the counts are kept as they are, and every
        // source read back then counts as read up to when the file was last
        // saved, so one that starts over later never adds those calls again.
        if decoded.version == nil,
           let saved = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date {
            for agent in cursors.keys where cursors[agent]?.countedBefore == nil {
                cursors[agent]?.countedBefore = UsageCursor.millis(saved)
            }
        }
    }

    nonisolated private static func persist(
        buckets: [BucketKey: [Int: Int]], toolBuckets: [ToolKey: [Int: Int]],
        cursors: [String: UsageCursor], to directory: URL
    ) throws {
        let bucketList = buckets.map { key, days in
            PersistedBucket(
                agent: key.agent,
                server: key.server,
                days: Dictionary(uniqueKeysWithValues: days.map { (String($0.key), $0.value) })
            )
        }
        let toolList = toolBuckets.map { key, days in
            PersistedToolBucket(
                agent: key.agent, server: key.server, tool: key.tool,
                days: Dictionary(uniqueKeysWithValues: days.map { (String($0.key), $0.value) })
            )
        }
        let payload = Persisted(version: formatVersion, buckets: bucketList, tools: toolList, cursors: cursors)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        try StatusWriter.ensurePrivateDirectory(directory)
        try StatusWriter.writePrivate(data, to: directory.appendingPathComponent(fileName))
    }
}

/// One tool's calls in the Usage window and the last day it was called
/// (`UsageStore.dayIndex`; nil = no call on record).
struct ToolUsage: Equatable, Sendable {
    var calls: Int
    var lastDay: Int?
}

/// "42", "1.2k" from 1,000 up, "3.4M" from 1,000,000 up (a trailing ".0" is
/// dropped: "2k", not "2.0k"). Pure, so `UsageStoreTests` can pin it.
enum UsageText {
    static func compact(_ count: Int) -> String {
        switch count {
        case ..<1000: return String(count)
        case ..<1_000_000: return scaled(count, by: 1000, suffix: "k")
        default: return scaled(count, by: 1_000_000, suffix: "M")
        }
    }

    private static func scaled(_ count: Int, by divisor: Int, suffix: String) -> String {
        let value = (Double(count) / Double(divisor) * 10).rounded() / 10
        if value == value.rounded() { return "\(Int(value))\(suffix)" }
        return String(format: "%.1f%@", value, suffix)
    }
}
