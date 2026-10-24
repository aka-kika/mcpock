import XCTest
@testable import mcpock

/// Fixes from the 2026-10-20 review round 3 (r3) and Argon 2026-10-16 #14 for
/// the HTTP, SSE and JSON-RPC probes. Each test runs a local fake server.
final class ProbeR3Tests: XCTestCase {
    /// Runs a python script that prints its port on the first line.
    func startServer(_ script: String) throws -> (Process, String) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-r3-\(UUID().uuidString).py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [file.path]
        let out = Pipe()
        server.standardOutput = out
        server.standardError = Pipe()
        try server.run()
        var buffer = Data()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !buffer.contains(UInt8(ascii: "\n")) {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        let port = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(port.isEmpty, "server did not report its port")
        return (server, port)
    }

    func httpConfig(_ url: String, transport: TransportKind = .http, headers: [String: String] = [:]) -> ServerConfig {
        ServerConfig(
            id: "t:r3", name: "r3", source: .code, projectPath: nil, transport: transport,
            command: nil, args: [], env: [:], url: url, headers: headers)
    }

    // MARK: 3e24

    /// A body that drips one byte at a time never trips the request timeout
    /// (it only covers silence); the clock is read on every byte.
    func testDrippingBodyStopsAtTheDeadline() async throws {
        let (server, port) = try startServer("""
        import sys, time, http.server, socketserver
        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *a): pass
            def do_GET(self):
                self.send_response(200); self.send_header('Content-Length', '1000000'); self.end_headers()
                try:
                    while True:
                        self.wfile.write(b'x'); self.wfile.flush(); time.sleep(0.02)
                except (BrokenPipeError, ConnectionResetError):
                    pass
        class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
        with S(('127.0.0.1', 0), H) as httpd:
            sys.stdout.write(str(httpd.server_address[1]) + "\\n"); sys.stdout.flush()
            httpd.serve_forever()
        """)
        defer { server.terminate(); server.waitUntilExit() }
        let (bytes, _) = try await ProbeSession.shared.bytes(for: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        defer { bytes.task.cancel() }
        let started = ContinuousClock.now
        do {
            _ = try await HTTPProbe.collect(bytes, limit: 1_000_000, deadline: started + .seconds(1))
            XCTFail("a dripping body must hit the deadline")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    // MARK: Deadline (Argon 2026-10-16 #14)

    func testRequestTimeoutIsWhatIsLeftOfTheBudget() throws {
        let now = ContinuousClock.now
        XCTAssertEqual(try HTTPProbe.timeoutInterval(until: now + .seconds(60), cap: 3), 3)
        let left = try HTTPProbe.timeoutInterval(until: now + .seconds(2), cap: 10)
        XCTAssertLessThanOrEqual(left, 2)
        XCTAssertGreaterThan(left, 1)
        XCTAssertThrowsError(try HTTPProbe.timeoutInterval(until: now - .seconds(1), cap: 10)) { error in
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    /// A server that answers initialize at once but sits on the initialized
    /// notice and the closing DELETE costs about 3 s plus 2 s, not 10 plus 5.
    func testSlowNoticeAndDeleteStayShort() async throws {
        let (server, port) = try startServer("""
        import sys, json, time, http.server, socketserver
        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *a): pass
            def do_POST(self):
                n = int(self.headers.get('Content-Length', 0)); msg = json.loads(self.rfile.read(n) or b'{}')
                if msg.get('id') is None:
                    time.sleep(30)
                out = json.dumps({'jsonrpc':'2.0','id':msg.get('id'),'result':{'protocolVersion':'2024-11-05','capabilities':{},'serverInfo':{'name':'m','version':'0'}}}).encode()
                self.send_response(200); self.send_header('Content-Type','application/json')
                self.send_header('Mcp-Session-Id', 's1')
                self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)
            def do_DELETE(self):
                time.sleep(30)
        class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
        with S(('127.0.0.1', 0), H) as httpd:
            sys.stdout.write(str(httpd.server_address[1]) + "\\n"); sys.stdout.flush()
            httpd.serve_forever()
        """)
        defer { server.terminate(); server.waitUntilExit() }
        let started = ContinuousClock.now
        let result = await HTTPProbe.probe(config: httpConfig("http://127.0.0.1:\(port)/mcp"), fetchTools: false)
        XCTAssertEqual(result.state, .healthy, result.failureReason ?? "")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(8))
    }

    // MARK: a9ec

    func testRefusedConnectionIsDefinite() async throws {
        XCTAssertFalse(HTTPProbe.isTransient(URLError(.cannotConnectToHost)))
        XCTAssertTrue(HTTPProbe.isTransient(URLError(.timedOut)))
        // A port that was just open and is closed again.
        let (server, port) = try startServer("""
        import sys, socket
        s = socket.socket(); s.bind(('127.0.0.1', 0))
        sys.stdout.write(str(s.getsockname()[1]) + "\\n"); sys.stdout.flush()
        """)
        server.waitUntilExit()
        let result = await HTTPProbe.probe(config: httpConfig("http://127.0.0.1:\(port)/mcp"), fetchTools: false)
        XCTAssertEqual(result.state, .broken)
        XCTAssertFalse(result.transientFailure, "connection refused is not slow")
    }

    // MARK: 3c71

    /// A config that sets its own Accept and Content-Type must not turn the
    /// probe's request into one the server answers 406 or 415.
    func testTransportHeadersWinOverConfigHeaders() async throws {
        let (server, port) = try startServer("""
        import sys, json, http.server, socketserver
        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *a): pass
            def do_POST(self):
                n = int(self.headers.get('Content-Length', 0)); msg = json.loads(self.rfile.read(n) or b'{}')
                if 'text/event-stream' not in self.headers.get('Accept', '') or self.headers.get('Content-Type') != 'application/json':
                    self.send_response(406); self.send_header('Content-Length', '0'); self.end_headers(); return
                out = json.dumps({'jsonrpc':'2.0','id':msg.get('id'),'result':{'protocolVersion':'2024-11-05','capabilities':{},'serverInfo':{'name':'m','version':'0'}}}).encode()
                self.send_response(200); self.send_header('Content-Type','application/json')
                self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)
        class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
        with S(('127.0.0.1', 0), H) as httpd:
            sys.stdout.write(str(httpd.server_address[1]) + "\\n"); sys.stdout.flush()
            httpd.serve_forever()
        """)
        defer { server.terminate(); server.waitUntilExit() }
        let config = httpConfig(
            "http://127.0.0.1:\(port)/mcp", headers: ["accept": "application/json", "Content-Type": "text/plain"])
        let result = await HTTPProbe.probe(config: config, fetchTools: false)
        XCTAssertEqual(result.state, .healthy, result.failureReason ?? "")
    }
}
