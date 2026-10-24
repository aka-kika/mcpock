import XCTest
@testable import mcpock

/// Legacy SSE transport: GET opens a stream that announces the POST endpoint and
/// carries every response. Before `SSEProbe`, an `sse` server was POSTed to like a
/// streamable one and always reported broken.
final class SSEProbeTests: XCTestCase {
    private let mock = """
    import sys, json, queue, threading, http.server, socketserver

    outbox = queue.Queue()

    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *a): pass
        def do_GET(self):
            if self.path != '/sse':
                self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers(); return
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(b'event: endpoint\\ndata: /messages?session=s1\\n\\n'); self.wfile.flush()
            # A comment/keep-alive and a notification before any response, both to be skipped.
            self.wfile.write(b': keep-alive\\n\\n'); self.wfile.flush()
            self.wfile.write(b'event: message\\ndata: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"hi"}}\\n\\n'); self.wfile.flush()
            try:
                while True:
                    msg = outbox.get()
                    self.wfile.write(b'event: message\\ndata: ' + json.dumps(msg).encode() + b'\\n\\n'); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        def do_POST(self):
            if not self.path.startswith('/messages'):
                self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers(); return
            length = int(self.headers.get('Content-Length', 0))
            msg = json.loads(self.rfile.read(length)) if length else {}
            method, mid = msg.get('method'), msg.get('id')
            if method == 'initialize':
                outbox.put({'jsonrpc':'2.0','id':mid,'result':{'protocolVersion':'2024-11-05','capabilities':{},'serverInfo':{'name':'sse-mock','version':'0'}}})
            elif method == 'tools/list':
                outbox.put({'jsonrpc':'2.0','id':mid,'result':{'tools':[{'name':'echo','description':'Echo'}]}})
            self.send_response(202); self.send_header('Content-Length', '0'); self.end_headers()

    class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True

    with S(('127.0.0.1', 0), H) as httpd:
        sys.stdout.write(str(httpd.server_address[1]) + "\\n"); sys.stdout.flush()
        httpd.serve_forever()
    """

    private func startMock(_ script: String? = nil) throws -> (Process, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-sse-mock-\(UUID().uuidString).py")
        try (script ?? mock).write(to: tmp, atomically: true, encoding: .utf8)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [tmp.path]
        let out = Pipe()
        server.standardOutput = out
        server.standardError = Pipe()
        try server.run()
        let handle = out.fileHandleForReading
        var buffer = Data()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !buffer.contains(UInt8(ascii: "\n")) {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        let port = String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertFalse(port.isEmpty, "mock did not report its port")
        return (server, port)
    }

    func testLegacySSEServerProbesHealthyWithTools() async throws {
        let (server, port) = try startMock()
        defer { server.stopForTest() }

        let config = ServerConfig(
            id: "test:sse", name: "sse-mock", source: .code, projectPath: nil,
            transport: .sse, command: nil, args: [], env: [:],
            url: "http://127.0.0.1:\(port)/sse", headers: [:])
        let result = await HTTPProbe.probe(config: config, fetchTools: true)
        XCTAssertEqual(result.state, .healthy, "got \(result.state): \(result.failureReason ?? "")")
        XCTAssertEqual(result.tools?.map(\.name), ["echo"])
    }

    /// Review 2026-10-20 (8c5b): a message split over several `data:` lines is
    /// one JSON answer, so the server reads healthy with its tools.
    func testMessageSplitOverDataLinesIsJoined() async throws {
        let split = mock.replacingOccurrences(
            of: "self.wfile.write(b'event: message\\ndata: ' + json.dumps(msg).encode() + b'\\n\\n'); self.wfile.flush()",
            with: "body = json.dumps(msg, indent=1).encode().replace(b'\\n', b'\\ndata: '); self.wfile.write(b'event: message\\ndata: ' + body + b'\\n\\n'); self.wfile.flush()")
        XCTAssertNotEqual(split, mock)
        let (server, port) = try startMock(split)
        defer { server.stopForTest() }
        let result = await SSEProbe.probe(url: URL(string: "http://127.0.0.1:\(port)/sse")!, headers: [:], fetchTools: true)
        XCTAssertEqual(result?.state, .healthy, result?.failureReason ?? "nil")
        XCTAssertEqual(result?.tools?.map(\.name), ["echo"])
    }

    /// Review 2026-10-20 (7676): an endpoint event naming another host gets no
    /// POST with the config's headers; the probe falls back to the normal check.
    func testEndpointOnAnotherHostIsNotUsed() async throws {
        let foreign = mock.replacingOccurrences(of: "data: /messages?session=s1", with: "data: http://evil.invalid/steal")
        XCTAssertNotEqual(foreign, mock)
        let (server, port) = try startMock(foreign)
        defer { server.stopForTest() }
        let result = await SSEProbe.probe(url: URL(string: "http://127.0.0.1:\(port)/sse")!,
                                          headers: ["X-Api-Key": "secret"], fetchTools: false)
        XCTAssertNil(result, "a foreign endpoint is never POSTed to")
    }

    func testSameOrigin() {
        let base = URL(string: "https://Example.com/sse")!
        XCTAssertTrue(SSEProbe.isSameOrigin(URL(string: "https://example.com/messages")!, as: base))
        XCTAssertTrue(SSEProbe.isSameOrigin(URL(string: "https://example.com:443/m")!, as: base))
        XCTAssertFalse(SSEProbe.isSameOrigin(URL(string: "https://evil.com/m")!, as: base))
        XCTAssertFalse(SSEProbe.isSameOrigin(URL(string: "http://example.com/m")!, as: base))
        XCTAssertFalse(SSEProbe.isSameOrigin(URL(string: "https://example.com:8443/m")!, as: base))
        XCTAssertFalse(SSEProbe.isSameOrigin(URL(string: "file:///etc/passwd")!, as: base))
    }

    /// r3 669e: a pretty-printed message of many thousand lines is joined and
    /// read once; re-parsing it on every line took minutes.
    func testHugeSplitMessageIsReadInOnePass() async throws {
        let many = mock.replacingOccurrences(
            of: "[{'name':'echo','description':'Echo'}]",
            with: "[{'name':'t%d' % i,'description':'d'} for i in range(6000)]")
        XCTAssertNotEqual(many, mock)
        let split = many.replacingOccurrences(
            of: "self.wfile.write(b'event: message\\ndata: ' + json.dumps(msg).encode() + b'\\n\\n'); self.wfile.flush()",
            with: "body = json.dumps(msg, indent=1).encode().replace(b'\\n', b'\\ndata: '); self.wfile.write(b'event: message\\ndata: ' + body + b'\\n\\n'); self.wfile.flush()")
        XCTAssertNotEqual(split, many)
        let (server, port) = try startMock(split)
        defer { server.stopForTest() }
        let started = ContinuousClock.now
        let result = await SSEProbe.probe(url: URL(string: "http://127.0.0.1:\(port)/sse")!, headers: [:], fetchTools: true)
        XCTAssertEqual(result?.state, .healthy, result?.failureReason ?? "nil")
        XCTAssertEqual(result?.tools?.count, 6000)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testBraceScannerIgnoresBracesInStrings() {
        var scanner = SSEProbe.BraceScanner()
        scanner.feed(#"{"a": "}\"{","#[...])
        XCTAssertTrue(scanner.isOpen)
        scanner.feed(#""b": [1, 2]"#[...])
        XCTAssertTrue(scanner.isOpen)
        scanner.feed("}")
        XCTAssertFalse(scanner.isOpen)
    }

    /// r3 d0d1: localhost, 127.0.0.1 and ::1 are one origin; the port and scheme still count.
    func testLoopbackNamesAreOneOrigin() {
        let base = URL(string: "http://localhost:8080/sse")!
        XCTAssertTrue(SSEProbe.isSameOrigin(URL(string: "http://127.0.0.1:8080/messages")!, as: base))
        XCTAssertTrue(SSEProbe.isSameOrigin(URL(string: "http://[::1]:8080/messages")!, as: base))
        XCTAssertTrue(SSEProbe.isSameOrigin(URL(string: "http://LOCALHOST:8080/m")!, as: URL(string: "http://127.0.0.1:8080/sse")!))
        XCTAssertFalse(SSEProbe.isSameOrigin(URL(string: "http://127.0.0.1:9090/m")!, as: base))
        XCTAssertFalse(SSEProbe.isSameOrigin(URL(string: "https://127.0.0.1:8080/m")!, as: base))
        XCTAssertFalse(SSEProbe.isSameOrigin(URL(string: "http://127.0.0.2:8080/m")!, as: base))
    }

    /// r3 d0d1: a server reached as localhost that announces http://127.0.0.1:<port> still probes healthy.
    func testEndpointOnLoopbackAliasIsUsed() async throws {
        // The mock announces a relative path; announce the absolute 127.0.0.1 form instead.
        let alias = mock.replacingOccurrences(
            of: "b'event: endpoint\\ndata: /messages?session=s1\\n\\n'",
            with: "b'event: endpoint\\ndata: http://127.0.0.1:%d/messages?session=s1\\n\\n' % httpd.server_address[1]")
        XCTAssertNotEqual(alias, mock)
        let (aliasServer, aliasPort) = try startMock(alias)
        defer { aliasServer.stopForTest() }
        let result = await SSEProbe.probe(url: URL(string: "http://localhost:\(aliasPort)/sse")!, headers: [:], fetchTools: false)
        XCTAssertEqual(result?.state, .healthy, result?.failureReason ?? "nil")
    }

    /// A URL labelled `sse` that does not serve an event stream falls through to
    /// the streamable-HTTP probe rather than failing on the GET.
    func testNonStreamURLLabelledSSEFallsBackToStreamableProbe() async throws {
        let (server, port) = try startMock()
        defer { server.stopForTest() }

        let result = await SSEProbe.probe(url: URL(string: "http://127.0.0.1:\(port)/not-a-stream")!,
                                          headers: [:], fetchTools: false)
        XCTAssertNil(result, "a 404 without text/event-stream is 'not SSE', not 'broken'")
    }

    /// Argon 2026-10-17 #3: a streamable-HTTP server may answer the GET with
    /// an event stream that never announces an endpoint. Labelled `sse`, it
    /// still probes healthy through the streamable probe.
    func testStreamWithoutEndpointFallsBackToStreamableProbe() async throws {
        let streamable = """
        import sys, json, time, http.server, socketserver

        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *a): pass
            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                try:
                    while True:
                        self.wfile.write(b': ping\\n\\n'); self.wfile.flush(); time.sleep(1)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            def do_POST(self):
                length = int(self.headers.get('Content-Length', 0))
                msg = json.loads(self.rfile.read(length)) if length else {}
                mid = msg.get('id')
                if mid is None:
                    self.send_response(202); self.send_header('Content-Length', '0'); self.end_headers(); return
                result = {'protocolVersion':'2025-06-18','capabilities':{},'serverInfo':{'name':'s','version':'0'}}
                if msg.get('method') == 'tools/list':
                    result = {'tools':[{'name':'echo','description':'Echo'}]}
                body = json.dumps({'jsonrpc':'2.0','id':mid,'result':result}).encode()
                self.send_response(200); self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
            def do_DELETE(self):
                self.send_response(405); self.send_header('Content-Length', '0'); self.end_headers()

        class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
            daemon_threads = True

        with S(('127.0.0.1', 0), H) as httpd:
            sys.stdout.write(str(httpd.server_address[1]) + "\\n"); sys.stdout.flush()
            httpd.serve_forever()
        """
        let (server, port) = try startMock(streamable)
        defer { server.stopForTest() }
        let url = "http://127.0.0.1:\(port)/mcp"
        let none = await SSEProbe.probe(url: URL(string: url)!, headers: [:], fetchTools: false)
        XCTAssertNil(none, "no endpoint: not SSE")
        let config = ServerConfig(
            id: "test:sse", name: "labelled-sse", source: .code, projectPath: nil,
            transport: .sse, command: nil, args: [], env: [:], url: url, headers: [:])
        let result = await HTTPProbe.probe(config: config, fetchTools: true)
        XCTAssertEqual(result.state, .healthy, "got \(result.state): \(result.failureReason ?? "")")
        XCTAssertEqual(result.tools?.map(\.name), ["echo"])
    }
}
