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
}
