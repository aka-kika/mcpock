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

    /// At most once every ten minutes for the "after a full probe cycle"
    /// trigger; the very first call (the monitor starting) is never throttled.
    static let throttle: TimeInterval = 10 * 60

    private let readers: [UsageReader]
    private let directory: URL
    private let isHostingTests: Bool
    private let defaults: UserDefaults

    /// Day index (see `dayIndex`) -> call count, keyed by (agent, server).
    private var buckets: [BucketKey: [Int: Int]] = [:]
    /// Where each reader left off, keyed by `UsageEvent.agent`.
    private var cursors: [String: UsageCursor] = [:]

    private var hasLoaded = false
    /// Whether `start` has run. The app starts the store only once discovery
    /// has named the servers (see `MCPockApp`).
    var isStarted: Bool { hasLoaded }
    private var lastRefreshDate: Date?
    /// A refresh in flight; a second trigger before it lands is a no-op —
    /// mirrors `HealthMonitor`'s single-flight probe cycles.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

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
        guard hasReader(for: agent) else { return nil }
        let key = BucketKey(agent: recordedAs ?? agent, server: HealthMonitor.normalizedName(server))
        let days = buckets[key] ?? [:]
        guard let windowSize = window.days else { return days.values.reduce(0, +) } // All time
        let cutoff = Self.dayIndex(for: now) - (windowSize - 1)
        return days.reduce(0) { sum, entry in entry.key >= cutoff ? sum + entry.value : sum }
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
        let isHostingTests = self.isHostingTests
        let directory = self.directory

        // A plain `Task` inherits this method's main-actor isolation, so
        // everything after the inner `await` — writing `self.buckets` back —
        // runs on the main actor with no extra hop. Only the actual work (file
        // I/O, the readers, the write to disk) is `Task.detached`, off the
        // main thread at utility priority, and takes no reference to `self`.
        let task = Task { [weak self] in
            let (newBuckets, newCursors) = await Task.detached(priority: .utility) {
                Self.process(
                    readers: readers, cursors: cursorsSnapshot, buckets: existingBuckets,
                    knownServers: knownServers, isHostingTests: isHostingTests, directory: directory
                )
            }.value
            guard let self else { return }
            self.buckets = newBuckets
            self.cursors = newCursors
            self.refreshTask = nil
        }
        refreshTask = task
        return task
    }

    /// Every reader's new events, folded into `buckets`, off the main actor.
    /// Takes and returns only Sendable snapshots — never `self` — so it can
    /// run detached.
    nonisolated private static func process(
        readers: [UsageReader], cursors: [String: UsageCursor], buckets: [BucketKey: [Int: Int]],
        knownServers: Set<String>, isHostingTests: Bool, directory: URL
    ) -> (buckets: [BucketKey: [Int: Int]], cursors: [String: UsageCursor]) {
        var newBuckets = buckets
        var newCursors = cursors
        for reader in readers {
            let cursor = cursors[reader.agent] ?? .empty
            let (events, nextCursor) = reader.read(since: cursor, knownServers: knownServers)
            newCursors[reader.agent] = nextCursor
            for event in events {
                let key = BucketKey(agent: event.agent, server: HealthMonitor.normalizedName(event.server))
                let day = dayIndex(for: event.date)
                newBuckets[key, default: [:]][day, default: 0] += 1
            }
        }
        if !isHostingTests {
            try? persist(buckets: newBuckets, cursors: newCursors, to: directory)
        }
        return (newBuckets, newCursors)
    }

    // MARK: - Day math

    nonisolated private static let secondsPerDay: TimeInterval = 86400

    /// A day index (days since the Unix epoch, local calendar) so window math
    /// is a plain integer comparison. `nonisolated` and pure: usable from the
    /// detached refresh task and from tests alike.
    nonisolated static func dayIndex(for date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        return Int((start.timeIntervalSince1970 / secondsPerDay).rounded(.down))
    }

    // MARK: - Persistence

    /// Only counts, cursors and buckets ever get to disk — never a call's
    /// arguments, result or any chat text (those never even reach `UsageEvent`).
    private struct Persisted: Codable {
        var buckets: [PersistedBucket]
        var cursors: [String: UsageCursor]
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
                guard let day = Int(dayString) else { continue }
                days[day] = count
            }
            loaded[key] = days
        }
        buckets = loaded
        cursors = decoded.cursors
    }

    nonisolated private static func persist(
        buckets: [BucketKey: [Int: Int]], cursors: [String: UsageCursor], to directory: URL
    ) throws {
        let bucketList = buckets.map { key, days in
            PersistedBucket(
                agent: key.agent,
                server: key.server,
                days: Dictionary(uniqueKeysWithValues: days.map { (String($0.key), $0.value) })
            )
        }
        let payload = Persisted(buckets: bucketList, cursors: cursors)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }
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
