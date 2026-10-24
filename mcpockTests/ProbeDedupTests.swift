import XCTest
@testable import mcpock

/// Identical probe targets (same command/args/env/cwd or url/headers) are probed
/// once per cycle and the result fanned out — the same server declared in five
/// agents must not spawn five identical subprocesses every minute.
final class ProbeDedupTests: XCTestCase {
    private func config(
        id: String,
        source: String,
        command: String? = "/usr/bin/true",
        args: [String] = ["--mcp"],
        env: [String: String] = [:],
        projectPath: String? = nil,
        url: String? = nil
    ) -> ServerConfig {
        ServerConfig(
            id: id,
            name: "eventkit",
            source: ServerSource(label: source),
            projectPath: projectPath,
            transport: url == nil ? .stdio : .http,
            command: url == nil ? command : nil,
            args: url == nil ? args : [],
            env: env,
            url: url,
            headers: [:]
        )
    }

    func testIdenticalConfigsShareOneSpec() {
        let a = HealthMonitor.probeSpec(config(id: "reg:Code:eventkit", source: "Code"))
        let b = HealthMonitor.probeSpec(config(id: "reg:Cursor:eventkit", source: "Cursor"))
        XCTAssertEqual(a, b, "same command/args/env/cwd from different agents is one probe target")
    }

    func testDifferingLaunchDetailsKeepSeparateSpecs() {
        let base = config(id: "a", source: "Code")
        XCTAssertNotEqual(
            HealthMonitor.probeSpec(base),
            HealthMonitor.probeSpec(config(id: "b", source: "Code", args: ["--mcp", "--verbose"])),
            "different args launch differently"
        )
        XCTAssertNotEqual(
            HealthMonitor.probeSpec(base),
            HealthMonitor.probeSpec(config(id: "c", source: "Code", env: ["API_KEY": "x"])),
            "different env launches differently"
        )
        XCTAssertNotEqual(
            HealthMonitor.probeSpec(base),
            HealthMonitor.probeSpec(config(id: "d", source: "Code", projectPath: "/tmp/proj")),
            "a per-project cwd must never be merged away"
        )
    }

    func testTransportsNeverMerge() {
        XCTAssertNotEqual(
            HealthMonitor.probeSpec(config(id: "a", source: "Code")),
            HealthMonitor.probeSpec(config(id: "b", source: "Code", url: "http://localhost:1234/mcp"))
        )
    }
}

final class ProbeIntervalTests: XCTestCase {
    func testRoundTripAndDefault() {
        let suite = "ProbeIntervalTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.retireSuite(named: suite) }

        XCTAssertEqual(AppPreferences.loadProbeInterval(from: defaults), .default,
                       "no stored value → default (every 15 minutes since 1.12)")

        AppPreferences.saveProbeInterval(.manual, to: defaults)
        XCTAssertEqual(AppPreferences.loadProbeInterval(from: defaults), .manual)
        XCTAssertNil(ProbeInterval.manual.seconds, "manual = no automatic timer")

        AppPreferences.saveProbeInterval(.fifteenMinutes, to: defaults)
        XCTAssertEqual(AppPreferences.loadProbeInterval(from: defaults).seconds, 900)

        // An odd stored value snaps to the nearest automatic stop (1 min here), never crashes.
        defaults.set(42, forKey: AppPreferences.probeIntervalKey)
        XCTAssertEqual(AppPreferences.loadProbeInterval(from: defaults), .oneMinute)
    }
}

/// Review 2026-10-20 (7d92): a cycle checks at most a few servers at once,
/// and a flood of unread messages can't grow a runner's queue without end.
final class ProbeLimitTests: XCTestCase {
    @MainActor
    func testACycleRunsAFewProbesAtATime() async {
        let suite = "mcpock.tests.limit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        let monitor = HealthMonitor(defaults: defaults)
        let configs = (0..<20).map { i in
            ServerConfig(id: "T:s\(i)", name: "s\(i)", source: ServerSource(label: "T"), projectPath: nil,
                         transport: .stdio, command: "/nonexistent/s\(i)", args: [], env: [:], url: nil, headers: [:])
        }
        monitor.discover = { configs }   // stands in for the scan: never touches this Mac
        let counter = ConcurrencyCounter()
        monitor.probe = { _, _ in
            counter.enter()
            try? await Task.sleep(for: .milliseconds(40))
            counter.leave()
            return ProbeResult(state: .healthy, failureReason: nil, tools: [])
        }
        await monitor.refreshAll()
        XCTAssertEqual(counter.total, 20, "every server is still checked")
        XCTAssertLessThanOrEqual(counter.peak, HealthMonitor.maxConcurrentProbes)
        XCTAssertGreaterThan(counter.peak, 1, "still in parallel")
    }

    func testQueuedMessagesAreCapped() async throws {
        let runner = try ProcessRunner(
            command: "/usr/bin/python3",
            args: ["-c", "import sys\nfor i in range(2000): sys.stdout.write('{\"jsonrpc\":\"2.0\",\"method\":\"n\",\"params\":{\"i\":%d}}\\n' % i)\nsys.stdout.flush()"],
            env: [:])
        for _ in 0..<100 where !runner.stdoutDidFinish { try await Task.sleep(for: .milliseconds(20)) }
        let first = try await runner.readMessage(timeout: .seconds(1))
        let text = String(decoding: first, as: UTF8.self)
        XCTAssertTrue(text.contains("\"i\":\(2000 - ProcessRunner.maxQueuedMessages)"), "oldest dropped, got \(text)")
        await runner.terminateAndReap()
    }
}

private final class ConcurrencyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var peak = 0
    private(set) var total = 0
    func enter() { lock.withLock { current += 1; total += 1; peak = max(peak, current) } }
    func leave() { lock.withLock { current -= 1 } }
}
