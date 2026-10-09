import XCTest
@testable import mcpock

/// Claude Code's `headersHelper` on http/sse entries: parsing, the merge, the
/// failure words, a real probe against a header-checking server, and that what a
/// helper prints never reaches the status output. Fixtures are small shell
/// scripts in a temp dir; no real helper is ever run.
@MainActor
final class HeadersHelperTests: XCTestCase {
    private var dir: URL!
    private let secret = "helper-SECRET-token-9137"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func script(_ body: String) throws -> String {
        let url = dir.appendingPathComponent("helper-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func httpConfig(helper: String?, headers: [String: String] = [:], url: String = "http://127.0.0.1:9/mcp") -> ServerConfig {
        var config = ServerConfig(
            id: "Code:global:postiz", name: "postiz", source: .code, projectPath: nil,
            transport: .http, command: nil, args: [], env: [:], url: url, headers: headers)
        config.headersHelper = helper
        return config
    }

    // MARK: Parsing

    func testParsesHeadersHelperOnHTTPEntry() {
        let entry = DiscoveredEntry(name: "postiz", entry: [
            "type": "http", "url": "https://postiz.example.com/api/mcp",
            "headersHelper": "  /Users/k/bin/postiz-headers.sh ",
            "headers": ["X-Static": "1"],
        ])
        let configs = ConfigDiscovery.configs(from: [entry], source: .code, idPrefix: "Code")
        XCTAssertEqual(configs.first?.headersHelper, "/Users/k/bin/postiz-headers.sh")
        XCTAssertEqual(configs.first?.headers, ["X-Static": "1"])
    }

    func testNoHelperOrWrongTypeStaysNil() {
        let plain = DiscoveredEntry(name: "a", entry: ["type": "http", "url": "https://a.example.com/mcp"])
        let wrong = DiscoveredEntry(name: "b", entry: ["url": "https://b.example.com/mcp", "headersHelper": 5])
        let empty = DiscoveredEntry(name: "c", entry: ["url": "https://c.example.com/mcp", "headersHelper": "  "])
        let stdio = DiscoveredEntry(name: "d", entry: ["command": "npx", "headersHelper": "/x.sh"])
        let configs = ConfigDiscovery.configs(from: [plain, wrong, empty, stdio], source: .code, idPrefix: "Code")
        XCTAssertEqual(configs.count, 4)
        XCTAssertTrue(configs.allSatisfy { $0.headersHelper == nil })
    }

    func testProbeSpecSeparatesDifferentHelpers() {
        let a = httpConfig(helper: "/a.sh")
        let b = httpConfig(helper: "/b.sh")
        XCTAssertNotEqual(HealthMonitor.probeSpec(a), HealthMonitor.probeSpec(b))
        XCTAssertEqual(HealthMonitor.probeSpec(a), HealthMonitor.probeSpec(a.withHeaders([:])))
    }

    // MARK: Merge

    func testHelperWinsOverStaticHeaders() {
        let merged = HeadersHelper.merge(
            static: ["Authorization": "old", "X-Keep": "1"],
            helper: ["authorization": "new", "X-New": "2"])
        XCTAssertEqual(merged, ["authorization": "new", "X-Keep": "1", "X-New": "2"])
    }

    func testParseNeedsAJSONObjectOfStrings() {
        XCTAssertEqual(HeadersHelper.parse(Data(#"{"A":"b"}"#.utf8)), ["A": "b"])
        XCTAssertEqual(HeadersHelper.parse(Data("{\n  \"A\": \"b\"\n}\n".utf8)), ["A": "b"])
        XCTAssertNil(HeadersHelper.parse(Data(#"{"A":1}"#.utf8)))
        XCTAssertNil(HeadersHelper.parse(Data(#"["A"]"#.utf8)))
        XCTAssertNil(HeadersHelper.parse(Data("not json".utf8)))
        XCTAssertNil(HeadersHelper.parse(Data()))
    }

    // MARK: Running the helper

    func testHelperOutputAndEnvironment() async throws {
        let path = try script(#"printf '{"X-Name":"%s","X-Url":"%s"}' "$CLAUDE_CODE_MCP_SERVER_NAME" "$CLAUDE_CODE_MCP_SERVER_URL""#)
        let result = await HeadersHelper.run(helper: path, serverName: "postiz", serverURL: "https://p.example.com/mcp")
        XCTAssertEqual(try result.get(), ["X-Name": "postiz", "X-Url": "https://p.example.com/mcp"])
    }

    func testNonZeroExitIsReported() async throws {
        let path = try script("echo '{\"Authorization\":\"\(secret)\"}'\nexit 3")
        let result = await HeadersHelper.run(helper: path, serverName: "s", serverURL: "")
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.localizedDescription, "Header helper failed: exit 3")
        XCTAssertFalse(error.localizedDescription.contains(secret))
    }

    func testNotJSONIsReportedWithoutEchoingOutput() async throws {
        let path = try script("echo 'Bearer \(secret)'")
        let result = await HeadersHelper.run(helper: path, serverName: "s", serverURL: "")
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.localizedDescription, "Header helper did not return JSON")
        XCTAssertFalse(error.localizedDescription.contains(secret))
    }

    func testTimeoutKillsTheWholeTree() async throws {
        let pidFile = dir.appendingPathComponent("child.pid").path
        let path = try script("sleep 30 &\necho $! > '\(pidFile)'\nwait")
        let started = Date()
        let result = await HeadersHelper.run(helper: path, serverName: "s", serverURL: "", timeout: .seconds(1))
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.localizedDescription, "Header helper timed out after 1 s")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        let pid = Int32(try String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(pid, 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotEqual(kill(pid, 0), 0, "the helper's child \(pid) must not be left running")
    }

    // MARK: Probing

    func testProbeShowsHelperFailureInsteadOf401() async throws {
        let path = try script("exit 1")
        let result = await HTTPProbe.probe(config: httpConfig(helper: path), fetchTools: false)
        XCTAssertEqual(result.state, .broken)
        XCTAssertEqual(result.failureReason, "Header helper failed: exit 1")
        XCTAssertFalse(result.needsAttention)
    }

    /// A server that answers 401 unless the helper's header arrives; the static
    /// header it replaces is wrong on purpose.
    func testProbeSendsHelperHeaders() async throws {
        let server = """
        import http.server, json
        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_POST(self):
                n = int(self.headers.get('Content-Length', 0)); body = self.rfile.read(n)
                if self.headers.get('Authorization') != 'Bearer \(secret)':
                    self.send_response(401); self.end_headers(); return
                msg = json.loads(body or b'{}')
                out = json.dumps({'jsonrpc':'2.0','id':msg.get('id'),'result':{'protocolVersion':'2024-11-05','capabilities':{},'serverInfo':{'name':'m','version':'0'}}}).encode()
                self.send_response(200); self.send_header('Content-Type','application/json')
                self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)
            def do_DELETE(self):
                self.send_response(405); self.end_headers()
        s = http.server.HTTPServer(('127.0.0.1', 0), H)
        print(s.server_address[1], flush=True)
        s.serve_forever()
        """
        let pyURL = dir.appendingPathComponent("server.py")
        try server.write(to: pyURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [pyURL.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let line = out.fileHandleForReading.availableData
        let port = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(port.isEmpty)

        let url = "http://127.0.0.1:\(port)/mcp"
        let withoutHelper = await HTTPProbe.probe(
            config: httpConfig(helper: nil, headers: ["Authorization": "Bearer wrong"], url: url), fetchTools: false)
        XCTAssertTrue(withoutHelper.needsAttention, "no helper: the server answers 401")

        let path = try script("echo '{\"Authorization\":\"Bearer \(secret)\"}'")
        let withHelper = await HTTPProbe.probe(
            config: httpConfig(helper: path, headers: ["Authorization": "Bearer wrong"], url: url), fetchTools: false)
        XCTAssertEqual(withHelper.state, .healthy, "got \(withHelper.failureReason ?? "")")
    }

    // MARK: No secret leaves

    func testStatusOutputCarriesHeaderNamesOnly() throws {
        let config = httpConfig(helper: "/Users/k/bin/headers.sh", headers: ["X-Static": "static-visible-value"])
        let snapshot = ServerSnapshot(config: config, state: .broken, failureReason: "Header helper failed: exit 1")
        let status = StatusSnapshot.build(
            servers: [snapshot], isHidden: { _ in false }, isPinned: { _ in false },
            checking: false, firstCheckDone: true, interval: .fifteenMinutes,
            now: Date(timeIntervalSince1970: 1_800_000_000), pid: 1, appVersion: "1.9.0")
        let json = String(decoding: try MCPockStatus.encoder().encode(status), as: UTF8.self)
        XCTAssertFalse(json.contains("static-visible-value"))
        XCTAssertTrue(json.contains("X-Static"))
        XCTAssertTrue(json.contains("Header helper failed: exit 1"))
    }

    func testProbeScrubsHelperValuesFromItsFailureReason() async throws {
        // A server that echoes the Authorization header into a 400 body.
        let server = """
        import http.server
        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_POST(self):
                n = int(self.headers.get('Content-Length', 0)); self.rfile.read(n)
                out = ('bad credentials ' + self.headers.get('Authorization','')).encode()
                self.send_response(400); self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)
        s = http.server.HTTPServer(('127.0.0.1', 0), H)
        print(s.server_address[1], flush=True)
        s.serve_forever()
        """
        let pyURL = dir.appendingPathComponent("echo.py")
        try server.write(to: pyURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [pyURL.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let port = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let path = try script("echo '{\"Authorization\":\"Bearer \(secret)\"}'")
        let result = await HTTPProbe.probe(
            config: httpConfig(helper: path, url: "http://127.0.0.1:\(port)/mcp"), fetchTools: false)
        XCTAssertEqual(result.state, .broken)
        let reason = try XCTUnwrap(result.failureReason)
        XCTAssertTrue(reason.hasPrefix("HTTP 400"), reason)
        XCTAssertFalse(reason.contains(secret), "the helper's token leaked into the failure reason")
    }
}
