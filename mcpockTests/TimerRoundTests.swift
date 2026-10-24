import XCTest
@testable import mcpock

/// 9180 (r3, 2026-10-20): checks every 15 minutes by default, and a timer
/// round re-reads only the files already found instead of walking the home
/// folder. The full scan runs at launch and on Refresh.
final class TimerRoundTests: XCTestCase {
    private func config(_ id: String, name: String, path: String) -> ServerConfig {
        ServerConfig(id: id, name: name, source: ServerSource(label: "x", path: path), projectPath: nil,
                     transport: .stdio, command: "/bin/echo", args: [], env: [:], url: nil, headers: [:])
    }

    func testDefaultIsFifteenMinutesAndASavedChoiceStays() {
        let suite = "mcpock.tests.timer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        XCTAssertEqual(AppPreferences.loadProbeInterval(from: defaults), .fifteenMinutes)
        AppPreferences.saveProbeInterval(.oneMinute, to: defaults)
        XCTAssertEqual(AppPreferences.loadProbeInterval(from: defaults), .oneMinute,
                       "someone who picked 1 min keeps it")
    }

    @MainActor
    func testATimerRoundReadsOnlyTheKnownFiles() async {
        let suite = "mcpock.tests.timer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        let scanned = config("scan:/u/.tool/mcp.json:global:a", name: "tool", path: "/u/.tool/mcp.json")
        let registry = config("reg:Cursor:global:b", name: "other", path: "/u/.cursor/mcp.json")
        let monitor = HealthMonitor(defaults: defaults, isUpdate: true)
        let full = Counter(), known = Counter()
        let asked = FilesBox()
        monitor.discover = { full.bump(); return [scanned, registry] }
        monitor.discoverKnownFiles = { files in known.bump(); asked.set(files); return [scanned, registry] }
        monitor.probe = { _, _ in ProbeResult(state: .healthy, failureReason: nil, tools: []) }

        await monitor.refreshAll()
        XCTAssertEqual(full.value, 1, "Refresh scans the whole home folder")
        XCTAssertEqual(known.value, 0)

        await monitor.timerTick()
        XCTAssertEqual(full.value, 1, "a timer round does not")
        XCTAssertEqual(known.value, 1)
        XCTAssertEqual(asked.value, ["/u/.tool/mcp.json"], "only the scan-found files, the agents' own are read anyway")
        XCTAssertEqual(monitor.servers.count, 2)
    }

    @MainActor
    func testWithoutAKnownFilesReaderTheTimerReadsAsBefore() async {
        let suite = "mcpock.tests.timer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        let monitor = HealthMonitor(defaults: defaults, isUpdate: true)
        let full = Counter()
        monitor.discover = { full.bump(); return [] }
        await monitor.timerTick()
        XCTAssertEqual(full.value, 1)
    }

    func testScanOfKnownFilesRereadsAndDropsGoneOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-timer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("mcp.json")
        try #"{"mcpServers":{"one":{"command":"/bin/echo"}}}"#.write(to: file, atomically: true, encoding: .utf8)
        let path = ConfigScanner.canonicalPath(file.path)

        XCTAssertEqual(ConfigScanner.scan(files: [path]).first?.entries.map(\.name), ["one"])
        // A changed file is read again (a new size, so a new stamp).
        try #"{"mcpServers":{"one":{"command":"/bin/echo"},"two":{"command":"/bin/echo"}}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ConfigScanner.scan(files: [path]).first?.entries.map(\.name).sorted(), ["one", "two"])
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(ConfigScanner.scan(files: [path]).isEmpty, "a deleted file drops out")
    }

    func testScanFilesAreTheScanFoundSourcesOnly() {
        let configs = [
            config("scan:/u/.a/mcp.json:global:x", name: "x", path: "/u/.a/mcp.json"),
            config("scan:/u/.a/mcp.json:global:y", name: "y", path: "/u/.a/mcp.json"),
            config("reg:Cursor:global:z", name: "z", path: "/u/.cursor/mcp.json"),
        ]
        XCTAssertEqual(ConfigDiscovery.scanFiles(in: configs), ["/u/.a/mcp.json"])
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class FilesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String] = []
    func set(_ new: [String]) { lock.lock(); files = new; lock.unlock() }
    var value: [String] { lock.lock(); defer { lock.unlock() }; return files }
}
