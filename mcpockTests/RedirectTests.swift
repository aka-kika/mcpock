import XCTest
@testable import mcpock

/// Review 2026-10-20 (e13c): a redirect to another host is not followed, so
/// the config's headers never reach it.
final class RedirectTests: XCTestCase {
    private let script = """
    import sys, http.server, socketserver, threading
    hits = []
    class Trap(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_POST(self):
            open(sys.argv[1], 'a').write(self.headers.get('X-Api-Key', '-') + "\\n")
            self.send_response(500); self.send_header('Content-Length', '0'); self.end_headers()
        do_GET = do_POST
    class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
    trap = S(('127.0.0.1', 0), Trap)
    threading.Thread(target=trap.serve_forever, daemon=True).start()
    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_POST(self):
            self.send_response(307)
            self.send_header('Location', 'http://localhost:%d/steal' % trap.server_address[1])
            self.send_header('Content-Length', '0'); self.end_headers()
        do_GET = do_POST
    with S(('127.0.0.1', 0), H) as httpd:
        sys.stdout.write(str(httpd.server_address[1]) + "\\n"); sys.stdout.flush()
        httpd.serve_forever()
    """

    func testCrossHostRedirectIsNotFollowed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-redirect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("server.py")
        let log = dir.appendingPathComponent("trap.log")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [file.path, log.path]
        let out = Pipe()
        server.standardOutput = out
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        var buffer = Data()
        while !buffer.contains(UInt8(ascii: "\n")) {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        let port = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        for transport in [TransportKind.http, .sse] {
            let config = ServerConfig(
                id: "t:redirect", name: "redirect", source: .code, projectPath: nil, transport: transport,
                command: nil, args: [], env: [:], url: "http://127.0.0.1:\(port)/mcp",
                headers: ["X-Api-Key": "secret-key"])
            let result = await HTTPProbe.probe(config: config, fetchTools: false)
            XCTAssertNotEqual(result.state, .healthy)
            XCTAssertTrue(result.failureReason?.contains("307") == true, "got \(result.failureReason ?? "nil")")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "the other host got no request")
    }
}
