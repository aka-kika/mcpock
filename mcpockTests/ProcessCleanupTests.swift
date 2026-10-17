import XCTest
@testable import mcpock

final class ProcessCleanupTests: XCTestCase {
    /// Spawns a long-running mock process and verifies terminateAndReap leaves no orphan.
    func testSpawnAndTerminateLeavesNoOrphan() async throws {
        let runner = try ProcessRunner(
            command: "/bin/sh",
            args: ["-c", "while true; do sleep 1; done"],
            env: [:]
        )

        let pid = runner.processIdentifier
        XCTAssertGreaterThan(pid, 0)
        XCTAssertTrue(runner.isRunning)
        XCTAssertTrue(isProcessAlive(pid), "Process should be alive after spawn")

        await runner.terminateAndReap(gracePeriod: .milliseconds(300))

        // Allow kernel to reap
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(runner.isRunning, "Runner should report not running")
        XCTAssertFalse(isProcessAlive(pid), "Process \(pid) must not remain as an orphan")
    }

    /// A server that exits as soon as its stdin closes, leaving a child running
    /// (1.9.0, found by the slow-start work): closing stdin used to come before
    /// the tree was listed, so the child was reparented away and never killed.
    func testServerThatExitsOnStdinEOFLeavesNoOrphanChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-eof-child-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let runner = try ProcessRunner(
            command: "/bin/sh",
            args: ["-c", "sleep 300 & echo $! > '\(pidFile.path)'; read line; exit 0"],
            env: [:]
        )
        var childPID: Int32 = 0
        for _ in 0..<100 where childPID == 0 {
            try await Task.sleep(for: .milliseconds(20))
            childPID = Int32((try? String(contentsOf: pidFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        }
        XCTAssertGreaterThan(childPID, 0)
        defer { if isProcessAlive(childPID) { kill(childPID, SIGKILL) } }
        XCTAssertTrue(isProcessAlive(childPID))

        await runner.terminateAndReap(gracePeriod: .milliseconds(300))
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(isProcessAlive(runner.processIdentifier))
        XCTAssertFalse(isProcessAlive(childPID), "child \(childPID) must not outlive its server")
    }

    /// Argon 2026-10-16 #3: a launcher that exits right away and leaves a child
    /// holding stdout. The child is reparented to launchd before teardown, so
    /// only its process group still ties it to the server.
    func testLauncherThatExitsEarlyLeavesNoOrphanChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-early-exit-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let runner = try ProcessRunner(
            command: "/bin/sh",
            args: ["-c", "sleep 300 & echo $! > '\(pidFile.path)'; exit 0"],
            env: [:]
        )
        var childPID: Int32 = 0
        for _ in 0..<100 where childPID == 0 || runner.isRunning {
            try await Task.sleep(for: .milliseconds(20))
            childPID = Int32((try? String(contentsOf: pidFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        }
        XCTAssertGreaterThan(childPID, 0)
        defer { if isProcessAlive(childPID) { kill(childPID, SIGKILL) } }
        XCTAssertFalse(runner.isRunning, "the launcher has exited")
        XCTAssertTrue(isProcessAlive(childPID))

        await runner.terminateAndReap(gracePeriod: .milliseconds(300))
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(isProcessAlive(childPID), "child \(childPID) must not outlive its launcher")
        XCTAssertTrue(runner.stdoutDidFinish, "stdout reader reaches EOF once the child is gone")
    }

    /// Argon 2026-10-17 #5: a launcher that forks its server and exits at
    /// once can be gone before its start time is read; without a floor its
    /// child was never found. Repeated, since the race is narrow.
    func testInstantLauncherExitLeavesNoOrphanChild() async throws {
        for round in 0..<10 {
            let pidFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("mcpock-instant-\(UUID().uuidString).pid")
            defer { try? FileManager.default.removeItem(at: pidFile) }
            let runner = try ProcessRunner(
                command: "/bin/sh",
                args: ["-c", "/bin/sh -c 'echo $$ > \"\(pidFile.path)\"; exec sleep 300' & exit 0"],
                env: [:]
            )
            var childPID: Int32 = 0
            for _ in 0..<100 where childPID == 0 {
                try await Task.sleep(for: .milliseconds(10))
                childPID = Int32((try? String(contentsOf: pidFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            }
            XCTAssertGreaterThan(childPID, 0)
            defer { if childPID > 0, isProcessAlive(childPID) { kill(childPID, SIGKILL) } }

            await runner.terminateAndReap(gracePeriod: .milliseconds(300))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(isProcessAlive(childPID), "round \(round): child \(childPID) must not outlive its launcher")
        }
    }

    /// Argon 2026-10-17 #4: teardown in a cancelled task used to spin: every
    /// `Task.sleep` threw at once, so the wait loops ran flat out.
    func testTeardownInACancelledTaskDoesNotSpin() async throws {
        let runner = try ProcessRunner(
            command: "/bin/sh",
            args: ["-c", "trap '' TERM; while true; do sleep 1; done"],
            env: [:]
        )
        let pid = runner.processIdentifier
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        }
        let before = cpuSeconds()
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await runner.terminateAndReap(gracePeriod: .milliseconds(500))
        }
        await task.value
        let elapsed = clock.now - start
        let used = cpuSeconds() - before

        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(450), "the grace period is still waited out")
        XCTAssertLessThan(used, 0.25, "waiting must not burn CPU (used \(used) s)")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(isProcessAlive(pid), "the process that ignores SIGTERM is killed")
    }

    /// Argon 2026-10-16 #4: a server that floods stderr keeps its first lines
    /// (where the cause is) and its newest ones, never all of it.
    func testStderrFloodIsCapped() async throws {
        let runner = try ProcessRunner(
            command: "/bin/sh",
            args: ["-c", "echo 'Error: first cause' >&2; head -c 6000000 /dev/zero | tr '\\0' 'x' >&2; echo >&2; echo 'last words' >&2; sleep 30"],
            env: [:]
        )
        for _ in 0..<250 where !runner.stderrString.contains("last words") {
            try await Task.sleep(for: .milliseconds(20))
        }
        let text = runner.stderrString
        XCTAssertTrue(text.hasPrefix("Error: first cause"))
        XCTAssertTrue(text.contains("last words"))
        XCTAssertLessThan(text.utf8.count, 3 * 512 * 1024 + 16, "memory stays bounded")
        XCTAssertEqual(runner.firstErrorLine(), "Error: first cause")
        await runner.terminateAndReap(gracePeriod: .milliseconds(200))
    }

    /// Spawns a mock MCP server that speaks the real MCP stdio transport
    /// (newline-delimited JSON, NOT Content-Length framing), probes it, ensures cleanup.
    func testMockMCPServerProbeAndCleanup() async throws {
        let script = """
        #!/usr/bin/env python3
        import sys, json

        def write_message(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            method = msg.get('method')
            mid = msg.get('id')
            if method == 'initialize':
                write_message({
                    'jsonrpc': '2.0',
                    'id': mid,
                    'result': {
                        'protocolVersion': '2024-11-05',
                        'capabilities': {},
                        'serverInfo': {'name': 'mock', 'version': '0.0.1'}
                    }
                })
            elif method == 'notifications/initialized':
                pass
            elif method == 'tools/list':
                write_message({
                    'jsonrpc': '2.0',
                    'id': mid,
                    'result': {
                        'tools': [
                            {'name': 'echo', 'description': 'Echo a message\\nSecond line'}
                        ]
                    }
                })
                break
        """

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-mock-\(UUID().uuidString).py")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = ServerConfig(
            id: "test:mock",
            name: "mock",
            source: .code,
            projectPath: nil,
            transport: .stdio,
            command: "/usr/bin/python3",
            args: [tmp.path],
            env: [:],
            url: nil,
            headers: [:]
        )

        let result = await StdioProbe.probe(config: config, fetchTools: true)

        XCTAssertEqual(result.state, .healthy, "Expected healthy, got \(result.state) \(result.failureReason ?? "")")
        XCTAssertEqual(result.tools?.count, 1)
        XCTAssertEqual(result.tools?.first?.name, "echo")
        XCTAssertEqual(result.tools?.first?.firstLineDescription, "Echo a message")
    }

    /// A server that interleaves `notifications/message` log traffic before its
    /// responses is healthy MCP behavior. Regression: the probe used to treat the
    /// next message as *the* response and mark such servers broken.
    func testProbeSkipsNotificationsBeforeResponses() async throws {
        let script = """
        #!/usr/bin/env python3
        import sys, json

        def write_message(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()

        def log(text):
            write_message({'jsonrpc': '2.0', 'method': 'notifications/message',
                           'params': {'level': 'info', 'data': text}})

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            method = msg.get('method')
            mid = msg.get('id')
            if method == 'initialize':
                log('booting')
                log('almost there')
                write_message({
                    'jsonrpc': '2.0',
                    'id': mid,
                    'result': {
                        'protocolVersion': '2024-11-05',
                        'capabilities': {},
                        'serverInfo': {'name': 'noisy', 'version': '0.0.1'}
                    }
                })
            elif method == 'notifications/initialized':
                pass
            elif method == 'tools/list':
                log('listing tools')
                write_message({
                    'jsonrpc': '2.0',
                    'id': mid,
                    'result': {'tools': [{'name': 'echo', 'description': 'Echo'}]}
                })
                break
        """

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-noisy-mock-\(UUID().uuidString).py")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = ServerConfig(
            id: "test:noisy",
            name: "noisy",
            source: .code,
            projectPath: nil,
            transport: .stdio,
            command: "/usr/bin/python3",
            args: [tmp.path],
            env: [:],
            url: nil,
            headers: [:]
        )

        let result = await StdioProbe.probe(config: config, fetchTools: true)
        XCTAssertEqual(
            result.state, .healthy,
            "Notifications before responses must be skipped, got \(result.state): \(result.failureReason ?? "")"
        )
        XCTAssertEqual(result.tools?.first?.name, "echo")
    }

    func testDiscoverConfigsFindsLocalServers() throws {
        let configs = ConfigDiscovery.discover()
        // Local machine may have Claude/Cursor configs; discovery must not throw and may be empty.
        // When present, entries should have valid ids and names.
        for config in configs {
            XCTAssertFalse(config.id.isEmpty)
            XCTAssertFalse(config.name.isEmpty)
            if config.transport == .stdio {
                XCTAssertNotNil(config.command)
            } else {
                XCTAssertNotNil(config.url)
            }
        }
    }

    func testNonexistentBinaryReportsSpawnError() async throws {
        let config = ServerConfig(
            id: "test:broken",
            name: "broken",
            source: .code,
            projectPath: nil,
            transport: .stdio,
            command: "nonexistent-binary-mcpock-test",
            args: [],
            env: [:],
            url: nil,
            headers: [:]
        )

        let result = await StdioProbe.probe(config: config, fetchTools: true)
        XCTAssertEqual(result.state, .broken)
        XCTAssertFalse(result.transientFailure, "a spawn error is definitive and must not be smoothed to amber")
        XCTAssertNotNil(result.failureReason)
        let reason = result.failureReason ?? ""
        XCTAssertTrue(
            reason.localizedCaseInsensitiveContains("spawn")
                || reason.localizedCaseInsensitiveContains("not found")
                || reason.localizedCaseInsensitiveContains("doesn't exist")
                || reason.localizedCaseInsensitiveContains("no such file"),
            "Readable spawn error expected, got: \(reason)"
        )
    }

    /// A server that prints to stderr and exits non-zero should surface both
    /// the exit code and the stderr text — not a generic "No response".
    func testCrashedServerSurfacesStderrAndExitCode() async throws {
        let config = ServerConfig(
            id: "test:crash",
            name: "crash",
            source: .code,
            projectPath: nil,
            transport: .stdio,
            command: "/bin/sh",
            args: ["-c", "echo 'fatal: MISSING_API_KEY not set' >&2; exit 3"],
            env: [:],
            url: nil,
            headers: [:]
        )

        let result = await StdioProbe.probe(config: config, fetchTools: true)
        XCTAssertEqual(result.state, .broken)
        let reason = result.failureReason ?? ""
        XCTAssertTrue(
            reason.contains("MISSING_API_KEY"),
            "Failure reason should include stderr, got: \(reason)"
        )
        XCTAssertTrue(
            reason.contains("3"),
            "Failure reason should include the exit code, got: \(reason)"
        )
    }

    /// A streamable-HTTP server that assigns an Mcp-Session-Id on initialize and
    /// rejects follow-up requests that omit it. The probe must capture and replay it.
    func testHTTPProbeReplaysSessionId() async throws {
        let script = """
        import sys, json, http.server, socketserver

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def _send(self, code, body=b'', session=None):
                self.send_response(code)
                if session:
                    self.send_header('Mcp-Session-Id', session)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                if body:
                    self.wfile.write(body)
            def do_POST(self):
                length = int(self.headers.get('Content-Length', 0))
                msg = json.loads(self.rfile.read(length)) if length else {}
                method = msg.get('method')
                mid = msg.get('id')
                sid = self.headers.get('Mcp-Session-Id')
                if method == 'initialize':
                    body = json.dumps({'jsonrpc':'2.0','id':mid,'result':{
                        'protocolVersion':'2024-11-05','capabilities':{},
                        'serverInfo':{'name':'mock','version':'0'}}}).encode()
                    self._send(200, body, session='sess-abc')
                elif method == 'notifications/initialized':
                    self._send(202)
                elif method == 'tools/list':
                    if sid != 'sess-abc':
                        self._send(400, b'{"error":"missing session"}')
                        return
                    body = json.dumps({'jsonrpc':'2.0','id':mid,'result':{
                        'tools':[{'name':'echo','description':'Echo a message'}]}}).encode()
                    self._send(200, body)
                else:
                    self._send(404)

        # A connection that goes quiet is dropped after 5 s, and each one gets
        # its own thread, so one stuck socket can't wedge the server (CI hung
        # 14 min once, 2026-09-25).
        H.timeout = 5
        class S(socketserver.ThreadingTCPServer):
            daemon_threads = True

        with S(('127.0.0.1', 0), H) as httpd:
            sys.stdout.write(str(httpd.server_address[1]) + "\\n")
            sys.stdout.flush()
            httpd.serve_forever()
        """

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-http-mock-\(UUID().uuidString).py")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [tmp.path]
        let outPipe = Pipe()
        server.standardOutput = outPipe
        server.standardError = Pipe()
        try server.run()
        defer { stopMockServer(server) }

        // Read the ephemeral port the server bound to.
        let port = try readLine(from: outPipe.fileHandleForReading, timeout: 5)
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmedPort.isEmpty, "Mock server did not report its port")

        let config = ServerConfig(
            id: "test:http",
            name: "http-mock",
            source: .code,
            projectPath: nil,
            transport: .http,
            command: nil,
            args: [],
            env: [:],
            url: "http://127.0.0.1:\(trimmedPort)/mcp",
            headers: [:]
        )

        let result = try await probeWithin(30, config: config, fetchTools: true)
        XCTAssertEqual(
            result.state, .healthy,
            "Expected healthy, got \(result.state): \(result.failureReason ?? "")"
        )
        XCTAssertEqual(result.tools?.first?.name, "echo")
    }

    /// Argon 2026-10-17 #6: a Streamable-HTTP server that answers on an event
    /// stream and keeps it open (pings after the answer) timed out every probe,
    /// because the whole body was awaited.
    func testHTTPProbeReadsAnswerFromAStreamThatStaysOpen() async throws {
        let script = """
        import sys, json, time, http.server, socketserver

        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *a): pass
            def do_POST(self):
                length = int(self.headers.get('Content-Length', 0))
                msg = json.loads(self.rfile.read(length)) if length else {}
                method = msg.get('method')
                mid = msg.get('id')
                if mid is None:
                    self.send_response(202)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                if method == 'initialize':
                    result = {'protocolVersion':'2024-11-05','capabilities':{},
                              'serverInfo':{'name':'stream','version':'0'}}
                else:
                    result = {'tools':[{'name':'echo','description':'Echo'}]}
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Cache-Control', 'no-cache')
                self.send_header('Transfer-Encoding', 'chunked')
                self.end_headers()
                def chunk(text):
                    data = text.encode()
                    self.wfile.write(b'%x\\r\\n%s\\r\\n' % (len(data), data))
                    self.wfile.flush()
                chunk('event: message\\ndata: {"jsonrpc":"2.0","method":"notifications/message","params":{}}\\n\\n')
                chunk('event: message\\ndata: ' + json.dumps({'jsonrpc':'2.0','id':mid,'result':result}) + '\\n\\n')
                try:
                    for _ in range(60):
                        time.sleep(1)
                        chunk(': ping\\n\\n')
                except Exception:
                    pass

        H.timeout = 70
        class S(socketserver.ThreadingTCPServer):
            daemon_threads = True

        with S(('127.0.0.1', 0), H) as httpd:
            sys.stdout.write(str(httpd.server_address[1]) + "\\n")
            sys.stdout.flush()
            httpd.serve_forever()
        """

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-stream-mock-\(UUID().uuidString).py")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [tmp.path]
        let outPipe = Pipe()
        server.standardOutput = outPipe
        server.standardError = Pipe()
        try server.run()
        defer { stopMockServer(server) }

        let port = try readLine(from: outPipe.fileHandleForReading, timeout: 5)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(port.isEmpty, "Mock server did not report its port")

        let config = ServerConfig(
            id: "test:stream", name: "stream-mock", source: .code, projectPath: nil, transport: .http,
            command: nil, args: [], env: [:], url: "http://127.0.0.1:\(port)/mcp", headers: [:]
        )
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await probeWithin(30, config: config, fetchTools: true)
        XCTAssertEqual(result.state, .healthy, result.failureReason ?? "")
        XCTAssertEqual(result.tools?.map(\.name), ["echo"])
        XCTAssertLessThan(clock.now - start, .seconds(5), "answered as soon as the event arrived")
    }

    /// An HTTP server that answers `initialize` with 401 must probe as a stable amber
    /// "needs attention" (auth), not red "broken": result carries `needsAttention` and
    /// a human-readable reason. Mirrors the real Vercel MCP (mcp.vercel.com → 401).
    func testHTTPAuthFailureNeedsAttention() async throws {
        let script = """
        import sys, json, http.server, socketserver

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_POST(self):
                body = b'{"error":"unauthorized"}'
                self.send_response(401)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        # A connection that goes quiet is dropped after 5 s, and each one gets
        # its own thread, so one stuck socket can't wedge the server (CI hung
        # 14 min once, 2026-09-25).
        H.timeout = 5
        class S(socketserver.ThreadingTCPServer):
            daemon_threads = True

        with S(('127.0.0.1', 0), H) as httpd:
            sys.stdout.write(str(httpd.server_address[1]) + "\\n")
            sys.stdout.flush()
            httpd.serve_forever()
        """

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-401-mock-\(UUID().uuidString).py")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [tmp.path]
        let outPipe = Pipe()
        server.standardOutput = outPipe
        server.standardError = Pipe()
        try server.run()
        defer { stopMockServer(server) }

        let port = try readLine(from: outPipe.fileHandleForReading, timeout: 5)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(port.isEmpty, "Mock server did not report its port")

        let config = ServerConfig(
            id: "test:auth", name: "auth-mock", source: .code, projectPath: nil,
            transport: .http, command: nil, args: [], env: [:],
            url: "http://127.0.0.1:\(port)/mcp", headers: [:]
        )

        let result = try await probeWithin(30, config: config, fetchTools: false)
        XCTAssertTrue(result.needsAttention, "401 must set needsAttention (stable amber)")
        XCTAssertEqual(result.failureReason, "Needs authentication (HTTP 401)")

        // And through smoothing it lands on amber degraded, not red broken.
        let smoothed = HealthMonitor.smoothedState(
            probe: result.state, transientFailure: result.transientFailure,
            needsAttention: result.needsAttention, priorFailures: 0)
        XCTAssertEqual(smoothed.state, .degraded)
    }

    /// A server that never replies must make `readMessage` return `ProbeError.timeout`,
    /// not hang. Regression guard for the stuck-continuation bug where a timed-out read
    /// left a `CheckedContinuation` unresumed, deadlocking the probe (and leaking the
    /// spawned server for the app's lifetime).
    func testReadMessageTimesOutWithoutHanging() async throws {
        let runner = try ProcessRunner(command: "/bin/sleep", args: ["30"], env: [:])

        let box = OutcomeBox()
        // Run the read off the test's task so a regression hangs the read, not the test.
        let probe = Task.detached {
            do {
                _ = try await runner.readMessage(timeout: .seconds(1))
                box.set("unexpected-data")
            } catch let e as ProbeError {
                if case .timeout = e { box.set("timeout") } else { box.set("probeerror") }
            } catch {
                box.set("other")
            }
        }

        // The read should resolve in ~1s; allow generous slack. If it's still nil after
        // this, the read hung past its own timeout — the bug.
        let deadline = ContinuousClock.now + .seconds(5)
        while box.get() == nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }

        let outcome = box.get()
        probe.cancel()
        await runner.terminateAndReap()

        XCTAssertNotNil(
            outcome,
            "readMessage did not return within 5s — it hung past its 1s timeout (stuck-continuation bug)"
        )
        XCTAssertEqual(outcome, "timeout", "Expected a clean ProbeError.timeout, got \(outcome ?? "nil")")
    }

    /// Review 2026-10-14: a bad Content-Length that arrived before any read
    /// was waiting was dropped, and the read then waited out its whole
    /// timeout. It now fails at once with the framing error.
    func testFramingErrorBeforeTheReadFailsAtOnce() async throws {
        let runner = try ProcessRunner(
            command: "/bin/sh", args: ["-c", "printf 'Content-Length: -5\\r\\n\\r\\n'; sleep 30"], env: [:]
        )
        try? await Task.sleep(for: .milliseconds(500))   // the header lands with no read parked

        let box = OutcomeBox()
        let probe = Task.detached {
            do {
                _ = try await runner.readMessage(timeout: .seconds(10))
                box.set("unexpected-data")
            } catch let e as ProbeError {
                if case .protocolError = e { box.set("protocol") } else { box.set("other-probeerror") }
            } catch {
                box.set("other")
            }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while box.get() == nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let outcome = box.get()
        probe.cancel()
        await runner.terminateAndReap()
        XCTAssertEqual(outcome, "protocol", "fails with the framing error, not after the 10 s timeout")
    }

    /// The port wait must give up on time when the server prints nothing.
    /// It used to block in `availableData` past its own timeout (CI, 2026-09-25).
    func testReadLineTimesOutOnASilentProcess() throws {
        let silent = Process()
        silent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        silent.arguments = ["30"]
        let outPipe = Pipe()
        silent.standardOutput = outPipe
        try silent.run()
        defer { stopMockServer(silent) }

        let start = Date()
        XCTAssertThrowsError(try readLine(from: outPipe.fileHandleForReading, timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "the wait ran past its timeout")
    }

    // MARK: - Helpers

    /// Read a single newline-terminated line from a file handle with a timeout.
    /// `availableData` blocks until the other end writes, so the handle is
    /// polled first: a server that never prints its port used to hang the test
    /// past its own timeout (CI, 2026-09-25).
    private func readLine(from handle: FileHandle, timeout: TimeInterval) throws -> String {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var fds = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let waitMs = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&fds, 1, waitMs) > 0 else { continue }
            let chunk = handle.availableData
            if chunk.isEmpty { break } // closed: the server exited
            buffer.append(chunk)
            if let nl = buffer.firstIndex(of: 0x0A) {
                return String(data: buffer[..<nl], encoding: .utf8) ?? ""
            }
        }
        throw ProbeError.timeout(.seconds(timeout))
    }

    /// Run an HTTP probe off the test's task and give up after `seconds`, so a
    /// stuck socket fails the test instead of hanging the runner.
    private func probeWithin(_ seconds: Double, config: ServerConfig, fetchTools: Bool) async throws -> ProbeResult {
        let box = ResultBox()
        let probe = Task.detached {
            box.set(await HTTPProbe.probe(config: config, fetchTools: fetchTools))
        }
        let deadline = ContinuousClock.now + .seconds(seconds)
        while box.get() == nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let result = box.get() else {
            probe.cancel()
            XCTFail("HTTP probe did not finish within \(Int(seconds)) s")
            throw ProbeError.timeout(.seconds(seconds))
        }
        return result
    }

    /// SIGTERM, then SIGKILL after 2 s. Bounded throughout: `waitUntilExit`
    /// once hung a run for 10 minutes after the server was already gone.
    private func stopMockServer(_ server: Process) {
        server.terminate()
        var deadline = Date().addingTimeInterval(2)
        while server.isRunning && Date() < deadline { usleep(20_000) }
        if server.isRunning { kill(server.processIdentifier, SIGKILL) }
        deadline = Date().addingTimeInterval(2)
        while server.isRunning && Date() < deadline { usleep(20_000) }
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        // kill(pid, 0) returns 0 if process exists
        kill(pid, 0) == 0
    }
}

/// Thread-safe holder for a probe result finished on another task.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ProbeResult?
    func set(_ r: ProbeResult) { lock.lock(); value = r; lock.unlock() }
    func get() -> ProbeResult? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Thread-safe single-value holder for observing an async result across tasks.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ s: String) { lock.lock(); value = s; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
