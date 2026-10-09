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

    private func startMock() throws -> (Process, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-sse-mock-\(UUID().uuidString).py")
        try mock.write(to: tmp, atomically: true, encoding: .utf8)
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
        defer { server.terminate(); server.waitUntilExit() }

        let config = ServerConfig(
            id: "test:sse", name: "sse-mock", source: .code, projectPath: nil,
            transport: .sse, command: nil, args: [], env: [:],
            url: "http://127.0.0.1:\(port)/sse", headers: [:])
        let result = await HTTPProbe.probe(config: config, fetchTools: true)
        XCTAssertEqual(result.state, .healthy, "got \(result.state): \(result.failureReason ?? "")")
        XCTAssertEqual(result.tools?.map(\.name), ["echo"])
    }

    /// A URL labelled `sse` that does not serve an event stream falls through to
    /// the streamable-HTTP probe rather than failing on the GET.
    func testNonStreamURLLabelledSSEFallsBackToStreamableProbe() async throws {
        let (server, port) = try startMock()
        defer { server.terminate(); server.waitUntilExit() }

        let result = await SSEProbe.probe(url: URL(string: "http://127.0.0.1:\(port)/not-a-stream")!,
                                          headers: [:], fetchTools: false)
        XCTAssertNil(result, "a 404 without text/event-stream is 'not SSE', not 'broken'")
    }
}
