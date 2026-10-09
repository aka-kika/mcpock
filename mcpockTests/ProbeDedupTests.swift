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
                       "no stored value → default (every minute)")

        AppPreferences.saveProbeInterval(.manual, to: defaults)
        XCTAssertEqual(AppPreferences.loadProbeInterval(from: defaults), .manual)
        XCTAssertNil(ProbeInterval.manual.seconds, "manual = no automatic timer")

        AppPreferences.saveProbeInterval(.fifteenMinutes, to: defaults)
        XCTAssertEqual(AppPreferences.loadProbeInterval(from: defaults).seconds, 900)

        // An odd stored value snaps to the nearest automatic stop (1 min here), never crashes.
        defaults.set(42, forKey: AppPreferences.probeIntervalKey)
        XCTAssertEqual(AppPreferences.loadProbeInterval(from: defaults), .default)
    }
}
