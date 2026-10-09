import XCTest
@testable import mcpock

/// 1.9.0: a stdio server that is slow to answer (hermes ~9 s, mcp-remote while it
/// renews a login) is retried once, at once, before it is called broken. The
/// limit is injected so these use seconds, not the real 20.
final class SlowStartTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-slowstart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A fake server. With `hangFirst`, its first run goes silent and later runs
    /// answer. With `alwaysHang`, every run is silent. Every run appends its own
    /// pid and its child's (a `sleep`, like npx's node) to `pids.txt`.
    private func fakeServer(hangFirst: Bool = false, alwaysHang: Bool = false) throws -> ServerConfig {
        let hang = alwaysHang ? "True" : (hangFirst ? "first" : "False")
        let script = """
        import sys, json, os, subprocess, time
        base = os.path.dirname(os.path.abspath(__file__))
        marker = os.path.join(base, 'ran-once')
        pidfile = os.path.join(base, 'pids.txt')
        if os.path.exists(pidfile):
            # A retry: which of the first run's processes still exist right now?
            alive = []
            for pid in [int(x) for x in open(pidfile).read().split()]:
                try:
                    os.kill(pid, 0)
                    alive.append(pid)
                except OSError:
                    pass
            open(os.path.join(base, 'alive-at-retry.txt'), 'w').write(' '.join(map(str, alive)))
        child = subprocess.Popen(['/bin/sleep', '120'])
        with open(os.path.join(base, 'pids.txt'), 'a') as f:
            f.write('%d\\n%d\\n' % (os.getpid(), child.pid))
        first = not os.path.exists(marker)
        open(marker, 'w').close()
        if \(hang):
            time.sleep(120)
        for line in sys.stdin:
            msg = json.loads(line)
            if msg.get('method') == 'initialize':
                sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': msg['id'], 'result': {
                    'protocolVersion': '2024-11-05', 'capabilities': {},
                    'serverInfo': {'name': 'slow', 'version': '1'}}}) + '\\n')
                sys.stdout.flush()
            elif msg.get('method') == 'tools/list':
                sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': msg['id'], 'result': {
                    'tools': [{'name': 'echo', 'description': 'Echo'}]}}) + '\\n')
                sys.stdout.flush()
        # Like npx's node: stay up after stdin closes, so only the tree kill ends us.
        time.sleep(120)
        """
        let path = dir.appendingPathComponent("server.py")
        try script.write(to: path, atomically: true, encoding: .utf8)
        return ServerConfig(
            id: "test:slow", name: "slow", source: .code, projectPath: nil, transport: .stdio,
            command: "/usr/bin/python3", args: [path.path], env: [:], url: nil, headers: [:]
        )
    }

    private func recordedPIDs() -> [Int32] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("pids.txt"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { Int32($0) }
    }

    func testTimeoutThenSuccessIsHealthyWithSlowStartNote() async throws {
        let config = try fakeServer(hangFirst: true)
        let result = await StdioProbe.probe(config: config, fetchTools: true, timeout: .seconds(2))

        XCTAssertEqual(result.state, .healthy, result.failureReason ?? "")
        XCTAssertNil(result.failureReason)
        XCTAssertFalse(result.transientFailure)
        XCTAssertEqual(result.tools?.map(\.name), ["echo"])
        let waited = try XCTUnwrap(result.slowStartSeconds)
        XCTAssertEqual(waited, 2, accuracy: 1, "the note says how long the first try waited")
        XCTAssertEqual(recordedPIDs().count, 4, "two runs, each with one child")
    }

    func testAnswerOnFirstTryHasNoSlowStartNote() async throws {
        let config = try fakeServer()
        let result = await StdioProbe.probe(config: config, fetchTools: false, timeout: .seconds(5))
        XCTAssertEqual(result.state, .healthy)
        XCTAssertNil(result.slowStartSeconds)
        XCTAssertEqual(recordedPIDs().count, 2, "no retry when the first try answers")
    }

    func testTwoTimeoutsStayTransientSoSmoothingShowsAmberFirst() async throws {
        let config = try fakeServer(alwaysHang: true)
        let result = await StdioProbe.probe(config: config, fetchTools: false, timeout: .seconds(1))

        XCTAssertEqual(result.state, .broken)
        XCTAssertTrue(result.transientFailure)
        XCTAssertNil(result.slowStartSeconds)
        XCTAssertTrue(result.failureReason?.hasPrefix("Timed out after 1") ?? false, result.failureReason ?? "")
        XCTAssertEqual(recordedPIDs().count, 4, "exactly one retry, not a loop")

        let first = HealthMonitor.smoothedState(
            probe: result.state, transientFailure: result.transientFailure, priorFailures: 0)
        XCTAssertEqual(first.state, .degraded)
        let repeated = HealthMonitor.smoothedState(
            probe: result.state, transientFailure: result.transientFailure, priorFailures: 1)
        XCTAssertEqual(repeated.state, .broken)
    }

    func testRetryLeavesNoOrphans() async throws {
        let config = try fakeServer(hangFirst: true)
        _ = await StdioProbe.probe(config: config, fetchTools: false, timeout: .seconds(1))
        let pids = recordedPIDs()
        XCTAssertEqual(pids.count, 4)

        // The first try's server process was fully reaped before the retry
        // spawned (checked by the retry itself, the moment it started).
        let seen = (try? String(contentsOf: dir.appendingPathComponent("alive-at-retry.txt"), encoding: .utf8)) ?? "missing"
        XCTAssertFalse(seen.split(separator: " ").contains(Substring(String(pids[0]))),
                       "first server \(pids[0]) still alive when the retry started")

        // And nothing from either run outlives the check (poll: the kernel
        // reaps an orphaned grandchild a moment after its parent dies).
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        for pid in pids {
            XCTAssertNotEqual(kill(pid, 0), 0, "process \(pid) must not outlive the check")
        }
    }

    func testRealLimitIsTwentySeconds() {
        XCTAssertEqual(StdioProbe.probeTimeout, .seconds(20))
    }

    // MARK: - Wording and where the note lands

    func testSlowStartNoteWording() {
        XCTAssertEqual(CardText.slowStartNote(20), "Slow to start (over 20 s)")
        XCTAssertEqual(CardText.slowStartNote(19.6), "Slow to start (over 20 s)")
        XCTAssertNil(CardText.slowStartNote(nil))
        XCTAssertNil(CardText.slowStartNote(0))
    }

    private func snapshot(_ state: HealthState, slow: Double?) -> ServerSnapshot {
        let config = ServerConfig(
            id: "Cursor:vercel", name: "vercel", source: .code, projectPath: nil, transport: .stdio,
            command: "npx", args: [], env: [:], url: nil, headers: [:])
        return ServerSnapshot(config: config, state: state, lastChecked: Date(), slowStartSeconds: slow)
    }

    func testHealthySlowRowKeepsNoteButIsNotAProblem() throws {
        let groups = HealthMonitor.groupByName([snapshot(.healthy, slow: 20)])
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.state, .healthy)
        XCTAssertEqual(group.slowStartSeconds, 20)
        XCTAssertTrue(CardText.subLine(for: group, now: Date()).contains("Slow to start (over 20 s)"))
        XCTAssertTrue(CardText.problems(for: group).isEmpty)
        XCTAssertNil(ShortReason.line(for: group))
        XCTAssertEqual(StatusSnapshot.statusWords(group), "fine")
    }

    func testNoteIsDroppedWhenTheRowIsNotHealthy() throws {
        let group = try XCTUnwrap(HealthMonitor.groupByName([snapshot(.broken, slow: 20)]).first)
        XCTAssertNil(group.slowStartSeconds)
    }

    @MainActor
    func testStatusFileCarriesTheNoteAsAnOptionalField() throws {
        let status = StatusSnapshot.build(
            servers: [snapshot(.healthy, slow: 20)], isHidden: { _ in false }, isPinned: { _ in false },
            checking: false, firstCheckDone: true, interval: .fifteenMinutes,
            now: Date(), pid: 1, appVersion: "1.9.0")
        let server = try XCTUnwrap(status.servers.first)
        XCTAssertEqual(server.note, "Slow to start (over 20 s)")
        XCTAssertFalse(server.needsAttention)
        XCTAssertEqual(status.counts.fine, 1)

        // Older files have no "note" key and must still decode.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: MCPockStatus.encoder().encode(status)) as? [String: Any])
        var servers = try XCTUnwrap(object["servers"] as? [[String: Any]])
        servers[0].removeValue(forKey: "note")
        object["servers"] = servers
        let data = try JSONSerialization.data(withJSONObject: object)
        let old = try MCPockStatus.decoder().decode(MCPockStatus.self, from: data)
        XCTAssertNil(old.servers[0].note)
    }
}
