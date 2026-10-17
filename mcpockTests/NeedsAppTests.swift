import XCTest
@testable import mcpock

/// "Needs <App> open" (2026-10-16): a server that belongs to a closed Mac app
/// waits; it is not broken.
final class HostAppsTests: XCTestCase {
    func testBundlePathFromAPathInsideAnApp() {
        XCTAssertEqual(HostApps.bundlePath(inPath: "/Applications/Wake.app/Contents/MacOS/wake-mcp"), "/Applications/Wake.app")
        XCTAssertEqual(HostApps.bundlePath(inPath: "/Applications/Kartina.app"), "/Applications/Kartina.app")
        XCTAssertNil(HostApps.bundlePath(inPath: "/usr/local/bin/eventkit-mcp"))
        XCTAssertNil(HostApps.bundlePath(inPath: "npx"))
    }

    func testLocalPorts() {
        XCTAssertEqual(HostApps.localPort(inURL: "http://127.0.0.1:8742/mcp"), 8742)
        XCTAssertEqual(HostApps.localPort(inURL: "http://localhost:3000/sse"), 3000)
        XCTAssertNil(HostApps.localPort(inURL: "http://the-zen:4340/mcp"), "another machine is not an app here")
        XCTAssertNil(HostApps.localPort(inURL: "https://mcp.context7.com/mcp"))
    }

    func testLauncherScriptHints() {
        let script = """
        #!/bin/zsh
        # Stdio proxy to the reed.md app's MCP server (127.0.0.1:8742)
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin"
        exec /Users/k/.local/bin/mcp-remote "http://127.0.0.1:8742/mcp"
        """
        let hints = HostApps.scriptHints(script)
        XCTAssertEqual(hints.ports, [8742])
        XCTAssertEqual(hints.bundles, [])
        XCTAssertEqual(HostApps.scriptHints("exec \"/Applications/Vera.app/Contents/MacOS/vera-mcp\" --stdio").bundles,
                       ["/Applications/Vera.app"])
    }

    /// A real app on every Mac: its command inside the bundle names it.
    @MainActor
    func testAppForACommandInsideARealBundle() {
        let config = ServerConfig(id: "T:calc", name: "calc", source: ServerSource(label: "T"), projectPath: nil,
                                  transport: .stdio, command: "/System/Applications/Calculator.app/Contents/MacOS/Calculator",
                                  args: [], env: [:], url: nil, headers: [:])
        let app = HostApps.app(for: config, learnedPorts: [:])
        XCTAssertEqual(app?.name, "Calculator")
        XCTAssertEqual(app?.bundlePath, "/System/Applications/Calculator.app")
        let plain = ServerConfig(id: "T:x", name: "x", source: ServerSource(label: "T"), projectPath: nil,
                                 transport: .stdio, command: "/bin/sh", args: ["-c", "true"], env: [:], url: nil, headers: [:])
        XCTAssertNil(HostApps.app(for: plain, learnedPorts: [:]), "when unsure, a normal check")
    }
}

@MainActor
final class NeedsAppMonitorTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "mcpock.tests.needsapp.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.retireSuite(named: suite)
        super.tearDown()
    }

    private let wake = HostApp(name: "Wake", bundlePath: "/Applications/Wake.app", bundleID: "com.example.wake")

    private func monitor(wakeRunning: AppRunning, answer: HealthState) async -> HealthMonitor {
        let configs = [
            ServerConfig(id: "T:wake", name: "wake", source: ServerSource(label: "T"), projectPath: nil,
                         transport: .stdio, command: "/Applications/Wake.app/Contents/MacOS/wake-mcp", args: [],
                         env: [:], url: nil, headers: [:]),
            ServerConfig(id: "T:other", name: "other", source: ServerSource(label: "T"), projectPath: nil,
                         transport: .stdio, command: "x", args: [], env: [:], url: nil, headers: [:]),
        ]
        let monitor = HealthMonitor(defaults: defaults)
        monitor.discover = { configs }
        monitor.probe = { config, _ in
            config.name == "wake" && answer != .healthy
                ? ProbeResult(state: .broken, failureReason: "Non-zero exit (1)", tools: nil)
                : ProbeResult(state: .healthy, failureReason: nil, tools: [MCPToolInfo(name: "wake_search", description: "")])
        }
        let wake = self.wake
        monitor.hostAppOf = { $0.name == "wake" ? wake : nil }
        monitor.appIsRunning = { _ in wakeRunning.value }
        await monitor.reloadConfigs()
        await monitor.refreshNow(force: true)
        return monitor
    }

    func testFailingWhileItsAppIsClosedIsCalmNotBroken() async throws {
        let monitor = await monitor(wakeRunning: AppRunning(false), answer: .broken)
        let group = try XCTUnwrap(monitor.groups.first { $0.name == "wake" })
        XCTAssertEqual(group.state, .needsApp)
        XCTAssertEqual(group.needsAppName, "Wake")
        XCTAssertEqual(ShortReason.line(for: group), "Needs Wake open")
        XCTAssertEqual(HealthMark.word(for: group), "Needs Wake open")
        XCTAssertFalse(PanelSections.needsYou(group), "calm: not in Needs you")
        XCTAssertEqual(monitor.aggregate, .allHealthy, "never turns the icon red")

        let status = monitor.statusSnapshot()
        let entry = try XCTUnwrap(status.servers.first { $0.name == "wake" })
        XCTAssertEqual(entry.status, "needs Wake open")
        XCTAssertFalse(entry.needsAttention)
        XCTAssertEqual(entry.needsApp, "Wake")
        XCTAssertEqual(status.counts.broken, 0)
        XCTAssertEqual(status.counts.needsAppOpen, 1)
        XCTAssertTrue(StatusReport.problems(in: status).isEmpty)
        let problems = StatusReport.problemLines(status, now: Date()).joined(separator: "\n")
        XCTAssertTrue(problems.contains("wake needs Wake open"), problems)
        XCTAssertTrue(problems.contains("Ask the user to open the app"), problems)
        let detail = StatusReport.serverLines(entry, number: nil, full: true, now: Date()).joined(separator: "\n")
        XCTAssertTrue(detail.contains("Ask the user to open Wake"), detail)
        XCTAssertEqual(MCPockWidgetSnapshot.build(from: status).problemCount, 0, "widgets don't count it")
    }

    func testFailingWhileItsAppRunsIsStillBroken() async throws {
        let monitor = await monitor(wakeRunning: AppRunning(true), answer: .broken)
        await monitor.refreshNow(force: true)
        XCTAssertEqual(monitor.groups.first { $0.name == "wake" }?.state, .broken)
    }

    func testItTurnsFineOnceTheAppRuns() async throws {
        let running = AppRunning(false)
        let monitor = await monitor(wakeRunning: running, answer: .broken)
        XCTAssertEqual(monitor.groups.first { $0.name == "wake" }?.state, .needsApp)
        running.value = true
        monitor.probe = { _, _ in ProbeResult(state: .healthy, failureReason: nil, tools: []) }
        await monitor.refreshNow()
        XCTAssertEqual(monitor.groups.first { $0.name == "wake" }?.state, .healthy, "no backoff while it waited")
    }

    func testLearnsWhichAppServesALocalPort() async {
        let monitor = HealthMonitor(defaults: defaults)
        let config = ServerConfig(id: "T:reed", name: "reed", source: ServerSource(label: "T"), projectPath: nil,
                                  transport: .http, command: nil, args: [], env: [:], url: "http://127.0.0.1:8742/mcp",
                                  headers: [:])
        monitor.discover = { [config] }
        monitor.probe = { _, _ in ProbeResult(state: .healthy, failureReason: nil, tools: []) }
        let reed = HostApp(name: "Reed", bundlePath: "/Applications/Reed.app", bundleID: "com.example.reed")
        monitor.listeningApp = { $0 == 8742 ? reed : nil }
        await monitor.reloadConfigs()
        await monitor.refreshNow(force: true)
        XCTAssertEqual(monitor.learnedHostPorts[8742], "/Applications/Reed.app")
        XCTAssertEqual(HealthMonitor(defaults: defaults).learnedHostPorts[8742], "/Applications/Reed.app", "kept")
    }

}

private final class AppRunning: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    init(_ on: Bool) { self.on = on }
    var value: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}
