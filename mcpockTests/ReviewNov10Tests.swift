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

    // MARK: b36c (fable-6 / mcode-6): switch temp file 0600 from the start

    private func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-nov10-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testNewFileIsMadeWithItsModeAndRefusesAnOldOne() throws {
        let file = try tempFolder().appendingPathComponent("a.json")
        try SwitchWriter.writeNew(Data("{\"k\":1}".utf8), to: file, mode: 0o644)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{\"k\":1}")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o644)
        XCTAssertThrowsError(try SwitchWriter.writeNew(Data("x".utf8), to: file, mode: 0o600))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{\"k\":1}", "an existing file is never overwritten")
    }

    func testLeftoverTempFilesAreRemovedOnlyWhenOld() throws {
        let folder = try tempFolder()
        let target = folder.appendingPathComponent("settings.json")
        let old = folder.appendingPathComponent(".settings.json.mcpock-\(UUID().uuidString)")
        let fresh = folder.appendingPathComponent(".settings.json.mcpock-\(UUID().uuidString)")
        let other = folder.appendingPathComponent(".settings.json.mcpock-notauuid")
        for file in [old, fresh, other] { try Data("x".utf8).write(to: file) }
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: other.path)
        SwitchWriter.removeLeftovers(of: target, now: now)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
        XCTAssertTrue(fm.fileExists(atPath: other.path))
    }

    // MARK: 6d0a (fable-1): the parked store is never started over

    func testParkedStoreRefusesAStoreItCannotRead() throws {
        let folder = try tempFolder()
        let store = folder.appendingPathComponent(ParkedStore.fileName(forAgent: "Cursor"))
        try Data("{ not json".utf8).write(to: store)
        XCTAssertThrowsError(try ParkedStore.add(name: "a", raw: "{}", agent: "Cursor", configPath: "/x/mcp.json", directory: folder)) {
            XCTAssertEqual($0 as? ParkedStore.StoreError, .unreadable)
        }
        XCTAssertEqual(try String(contentsOf: store, encoding: .utf8), "{ not json", "left as it was")
    }

    func testParkedStoreRefusesServersParkedFromAnotherFile() throws {
        let folder = try tempFolder()
        try ParkedStore.add(name: "a", raw: "{\"command\":\"x\"}", agent: "Cursor", configPath: "/old/mcp.json", directory: folder)
        XCTAssertThrowsError(try ParkedStore.add(name: "b", raw: "{}", agent: "Cursor", configPath: "/new/mcp.json", directory: folder)) {
            XCTAssertEqual($0 as? ParkedStore.StoreError, .otherFile("/old/mcp.json"))
        }
        XCTAssertEqual(ParkedStore.entries(agent: "Cursor", configPath: "/old/mcp.json", directory: folder), ["a": "{\"command\":\"x\"}"])
    }

    func testParkedStoreFromAnotherFileWithNothingInItStartsOver() throws {
        let folder = try tempFolder()
        try ParkedStore.add(name: "a", raw: "{}", agent: "Cursor", configPath: "/old/mcp.json", directory: folder)
        try ParkedStore.remove(name: "a", agent: "Cursor", directory: folder)
        try ParkedStore.add(name: "b", raw: "{}", agent: "Cursor", configPath: "/new/mcp.json", directory: folder)
        XCTAssertEqual(ParkedStore.entries(agent: "Cursor", configPath: "/new/mcp.json", directory: folder), ["b": "{}"])
        let store = folder.appendingPathComponent(ParkedStore.fileName(forAgent: "Cursor"))
        let mode = try FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
}
