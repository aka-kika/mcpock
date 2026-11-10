import XCTest
@testable import mcpock

/// Fixes from the three-reviewer round on 1.15.0 (10 Nov 2026).
final class ReviewNov10Tests: XCTestCase {
    // MARK: 4de7 (ds-1): event-stream answer with a line that never ends

    /// A server that sends an event-stream line one byte at a time and never
    /// ends it held `bytes.lines`, so the deadline was never read.
    func testEventStreamLineWithNoBreakStopsAtTheDeadline() async throws {
        let (server, port) = try ProbeR3Tests().startServer("""
        import sys, time, http.server, socketserver
        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *a): pass
            def do_GET(self):
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
                try:
                    self.wfile.write(b'data: '); self.wfile.flush()
                    while True:
                        self.wfile.write(b'x'); self.wfile.flush(); time.sleep(0.02)
                except (BrokenPipeError, ConnectionResetError):
                    pass
        class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
        with S(('127.0.0.1', 0), H) as httpd:
            sys.stdout.write(str(httpd.server_address[1]) + "\\n"); sys.stdout.flush()
            httpd.serve_forever()
        """)
        defer { server.stopForTest() }
        let (bytes, _) = try await ProbeSession.shared.bytes(for: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        defer { bytes.task.cancel() }
        let started = ContinuousClock.now
        do {
            _ = try await HTTPProbe.answer(in: bytes, id: 1, deadline: started + .seconds(1))
            XCTFail("a line that never ends must hit the deadline")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testLineSplitterEndsLinesOnEveryBreak() {
        var splitter = SSELineSplitter()
        var lines: [String] = []
        for byte in Array("a\nb\r\nc\rd".utf8) {
            if let line = splitter.feed(byte) { lines.append(line) }
        }
        if let last = splitter.finish() { lines.append(last) }
        XCTAssertEqual(lines, ["a", "b", "c", "d"])
    }

    func testLineSplitterKeepsBlankLines() {
        var splitter = SSELineSplitter()
        var lines: [String] = []
        for byte in Array("data: 1\n\ndata: 2\r\n\r\n".utf8) {
            if let line = splitter.feed(byte) { lines.append(line) }
        }
        XCTAssertNil(splitter.finish())
        XCTAssertEqual(lines, ["data: 1", "", "data: 2", ""])
    }

    func testLineSplitterKeepsUTF8Whole() {
        var splitter = SSELineSplitter()
        var lines: [String] = []
        for byte in Array("data: \"caf\u{e9} \u{4E2D}\"\n".utf8) {
            if let line = splitter.feed(byte) { lines.append(line) }
        }
        XCTAssertEqual(lines, ["data: \"caf\u{e9} \u{4E2D}\""])
    }
}
