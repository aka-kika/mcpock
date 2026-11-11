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
        XCTAssertEqual(HostApps.scriptHints("FOO=1 /Applications/Wake.app/Contents/MacOS/wake-mcp \"$@\"").bundles,
                       ["/Applications/Wake.app"])
    }

    /// Review 2026-10-20 (5345): a `.app` the script only mentions is not the
    /// server's app, and no port is guessed before an app was seen on it.
    @MainActor
    func testOnlyTheLaunchedProgramNamesAnApp() {
        let script = """
        #!/bin/sh
        # Works with /Applications/Reed.app too
        cd /Applications/Foo.app/Contents/Resources
        exec node /Applications/Foo.app/Contents/Resources/server.js --log /Applications/Bar.app/log
        """
        XCTAssertEqual(HostApps.scriptHints(script).bundles, [])
        let reedPort = ServerConfig(id: "T:r", name: "r", source: ServerSource(label: "T"), projectPath: nil,
                                    transport: .http, command: nil, args: [], env: [:],
                                    url: "http://127.0.0.1:8742/mcp", headers: [:])
        XCTAssertNil(HostApps.app(for: reedPort, learnedPorts: [:]), "8742 is not Reed's until Reed is seen there")
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

    /// Argon 2026-10-17 #9: Xcode's tools and files an argument names inside
    /// an app do not need that app open.
    @MainActor
    func testDeveloperToolsAndArgumentsDoNotNameAnApp() {
        XCTAssertNil(HostApps.bundlePath(ofExecutable: "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"))
        XCTAssertEqual(HostApps.bundlePath(ofExecutable: "/Applications/Wake.app/Contents/MacOS/wake-mcp"),
                       "/Applications/Wake.app")
        let argument = ServerConfig(id: "T:arg", name: "arg", source: ServerSource(label: "T"), projectPath: nil,
                                    transport: .stdio, command: "/bin/sh",
                                    args: ["/System/Applications/Calculator.app/Contents/Resources/run.sh"],
                                    env: [:], url: nil, headers: [:])
        XCTAssertNil(HostApps.app(for: argument, learnedPorts: [:]))
    }
}

/// Review 2026-10-30 (cf4b): a failing server on a learned port that changed owner.
final class StaleLearnedPortTests: XCTestCase {
    private let config = ServerConfig(id: "x", name: "x", source: ServerSource(label: "Cursor"), projectPath: nil, transport: .http,
                                      command: nil, args: [], env: [:], url: "http://127.0.0.1:8742/mcp", headers: [:])
    private let old = "/Applications/Old.app"

    private func lookUp(listening: HostApp?, taken: Bool, skip: Set<Int> = []) -> HostLookup {
        HostApps.lookUp(config, healthy: false, learned: [8742: old], skip: skip, hostAppOf: { _, _ in nil },
                        listeningApp: { _ in listening }, portIsTaken: { _ in taken })
    }

    func testAPlainServerOnThePortForgetsIt() {
        let lookup = lookUp(listening: nil, taken: true)
        XCTAssertEqual(lookup.forgotten, [8742])
        XCTAssertEqual(lookup.lookedUp, [8742])
    }

    func testAnotherAppOnThePortTakesIt() {
        let lookup = lookUp(listening: HostApp(name: "New", bundlePath: "/Applications/New.app", bundleID: nil), taken: true)
        XCTAssertEqual(lookup.learned[8742], "/Applications/New.app")
    }

    func testNobodyListeningKeepsIt() {
        let lookup = lookUp(listening: nil, taken: false)
        XCTAssertTrue(lookup.forgotten.isEmpty)
        XCTAssertTrue(lookup.lookedUp.isEmpty, "a later success still checks it")
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
        monitor.hostAppOf = { config, _ in config.name == "wake" ? wake : nil }
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
        let onMain = CallNames()
        monitor.listeningApp = { port in
            onMain.add(Thread.isMainThread ? "main" : "background")
            return port == 8742 ? reed : nil
        }
        await monitor.reloadConfigs()
        await monitor.refreshNow(force: true)
        XCTAssertEqual(monitor.learnedHostPorts[8742], "/Applications/Reed.app")
        // lsof never runs on the main thread (Argon 2026-10-17 #7).
        XCTAssertEqual(onMain.names, ["background"])
        await monitor.refreshNow(force: true)
        XCTAssertEqual(onMain.names.count, 1, "once per port")
        XCTAssertEqual(HealthMonitor(defaults: defaults).learnedHostPorts[8742], "/Applications/Reed.app", "kept")
    }

    /// Argon 2026-10-17 #9: a port learned in an earlier session that a plain
    /// server now answers on is forgotten, so its failures read broken.
    func testForgetsAPortNoAppServesAnyMore() async {
        AppPreferences.saveHostAppPorts([4000: "/Applications/Old.app"], to: defaults)
        let monitor = HealthMonitor(defaults: defaults)
        XCTAssertEqual(monitor.learnedHostPorts[4000], "/Applications/Old.app")
        let config = ServerConfig(id: "T:local", name: "local", source: ServerSource(label: "T"), projectPath: nil,
                                  transport: .http, command: nil, args: [], env: [:], url: "http://127.0.0.1:4000/mcp",
                                  headers: [:])
        monitor.discover = { [config] }
        monitor.probe = { _, _ in ProbeResult(state: .healthy, failureReason: nil, tools: []) }
        monitor.listeningApp = { _ in nil }
        await monitor.reloadConfigs()
        await monitor.refreshNow(force: true)
        XCTAssertNil(monitor.learnedHostPorts[4000])
        XCTAssertNil(HealthMonitor(defaults: defaults).learnedHostPorts[4000], "forgotten for good")
    }

}

/// 11 Nov: a server whose command is an app's own program (Native Screen,
/// "Native Screen --mcp") opened that app at every check. While the app is
/// closed it now waits without being started.
@MainActor
final class ClosedAppNotStartedTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ClosedAppNotStartedTests-\(UUID().uuidString)"
    private var folder: URL!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-launch-\(UUID().uuidString)")
    }

    override func tearDown() {
        defaults.retireSuite(named: suite)
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private let screen = HostApp(name: "Native Screen", bundlePath: "/Applications/Native Screen.app",
                                 bundleID: "com.example.screen")

    private func config(_ command: String, args: [String] = []) -> ServerConfig {
        ServerConfig(id: "T:\(command)", name: "nativescreen", source: ServerSource(label: "T"), projectPath: nil,
                     transport: .stdio, command: command, args: args, env: [:], url: nil, headers: [:])
    }

    func testAClosedAppIsNeverStartedByACheck() async throws {
        let monitor = HealthMonitor(defaults: defaults)
        let configs = [config("/Applications/Native Screen.app/Contents/MacOS/Native Screen", args: ["--mcp"])]
        monitor.discover = { configs }
        let started = CallNames()
        monitor.probe = { config, _ in
            started.add(config.name)
            return ProbeResult(state: .healthy, failureReason: nil, tools: [])
        }
        let screen = self.screen
        let running = AppRunning(false)
        monitor.launchedAppOf = { _ in screen }
        monitor.hostAppOf = { _, _ in screen }
        monitor.appIsRunning = { _ in running.value }
        await monitor.reloadConfigs()
        await monitor.refreshNow(force: true)
        await monitor.refreshNow(force: true)
        await monitor.refresh(groupName: "nativescreen")
        XCTAssertEqual(started.names, [], "no check, the Timer, Refresh nor Check again starts it")
        let group = try XCTUnwrap(monitor.groups.first)
        XCTAssertEqual(group.state, .needsApp)
        XCTAssertEqual(group.needsAppName, "Native Screen")
        XCTAssertEqual(ShortReason.line(for: group), "Needs Native Screen open")

        // She opens it: checked again, and fine.
        running.value = true
        await monitor.refreshNow(force: true)
        XCTAssertEqual(started.names, ["nativescreen"])
        XCTAssertEqual(monitor.groups.first?.state, .healthy)

        // She quits it again: it waits, not started.
        running.value = false
        await monitor.refreshNow(force: true)
        XCTAssertEqual(started.names, ["nativescreen"])
        XCTAssertEqual(monitor.groups.first?.state, .needsApp)
    }

    /// A fake app on disk: `<name>.app` with its main program and a helper.
    private func makeApp(_ name: String) throws -> String {
        let app = folder.appendingPathComponent("\(name).app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleExecutable": name, "CFBundleIdentifier": "com.example.\(UUID().uuidString)",
                                    "CFBundleName": name, "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        for file in [name, "\(name.lowercased())-mcp"] {
            let url = macOS.appendingPathComponent(file)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return app.path
    }

    func testOnlyTheAppsOwnProgramOpensIt() throws {
        let app = try makeApp("Screen")
        XCTAssertEqual(HostApps.launchedApp(for: config("\(app)/Contents/MacOS/Screen", args: ["--mcp"]))?.name, "Screen")
        XCTAssertNil(HostApps.launchedApp(for: config("\(app)/Contents/MacOS/screen-mcp")),
                     "a helper beside it runs without the app: still checked")
        XCTAssertEqual(HostApps.app(for: config("\(app)/Contents/MacOS/screen-mcp"), learnedPorts: [:])?.name, "Screen",
                       "but it still waits for the app after a failed check")
        XCTAssertNil(HostApps.launchedApp(for: config("/usr/bin/env", args: ["\(app)/Contents/MacOS/Screen"])),
                     "an argument is not the program")
        // An Electron app given a script runs as Node, no window (review 11 Nov).
        XCTAssertNil(HostApps.launchedApp(for: config("\(app)/Contents/MacOS/Screen", args: ["/x/server.js"])))
        let asNode = ServerConfig(id: "T:node", name: "node", source: ServerSource(label: "T"), projectPath: nil,
                                  transport: .stdio, command: "\(app)/Contents/MacOS/Screen", args: ["--stdio"],
                                  env: ["ELECTRON_RUN_AS_NODE": "1"], url: nil, headers: [:])
        XCTAssertNil(HostApps.launchedApp(for: asNode))
    }

    func testALauncherScriptThatRunsTheApp() throws {
        let app = try makeApp("Screen")
        let script = folder.appendingPathComponent("screen-launch")
        try Data("#!/bin/zsh\n# \(app)/Contents/MacOS/Other\nexec \"\(app)/Contents/MacOS/Screen\" --mcp\n".utf8).write(to: script)
        XCTAssertEqual(HostApps.launchedApp(for: config(script.path))?.name, "Screen")
        let helper = folder.appendingPathComponent("helper-launch")
        try Data("#!/bin/zsh\nexec \"\(app)/Contents/MacOS/screen-mcp\"\n".utf8).write(to: helper)
        XCTAssertNil(HostApps.launchedApp(for: config(helper.path)))
    }

    func testAnHTTPServerIsNeverSkipped() {
        let http = ServerConfig(id: "T:h", name: "h", source: ServerSource(label: "T"), projectPath: nil,
                                transport: .http, command: nil, args: [], env: [:], url: "http://127.0.0.1:9/mcp", headers: [:])
        XCTAssertNil(HostApps.launchedApp(for: http))
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

private final class CallNames: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var names: [String] { lock.withLock { list } }
    func add(_ name: String) { lock.withLock { list.append(name) } }
}
