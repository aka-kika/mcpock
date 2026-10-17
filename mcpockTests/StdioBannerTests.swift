import XCTest
@testable import mcpock

/// Argon 2026-10-17 #1: healthy stdio servers that print a startup banner
/// (or answer with Content-Length frames after one) read Broken or hung
/// until the timeout.
final class StdioBannerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-banner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A fake server that prints `banner` first, then answers each request
    /// either as a JSON line or as a Content-Length frame (no line end).
    private func fakeServer(banner: String, contentLength: Bool) throws -> ServerConfig {
        let script = """
        import sys, json
        sys.stdout.write(\(String(reflecting: banner)))
        sys.stdout.flush()
        def send(obj):
            body = json.dumps(obj)
            if \(contentLength ? "True" : "False"):
                sys.stdout.write('Content-Length: %d\\r\\n\\r\\n%s' % (len(body.encode()), body))
            else:
                sys.stdout.write(body + '\\n')
            sys.stdout.flush()
        for line in sys.stdin:
            msg = json.loads(line)
            if msg.get('method') == 'initialize':
                send({'jsonrpc': '2.0', 'id': msg['id'], 'result': {
                    'protocolVersion': '2024-11-05', 'capabilities': {},
                    'serverInfo': {'name': 'banner', 'version': '1'}}})
            elif msg.get('method') == 'tools/list':
                send({'jsonrpc': '2.0', 'id': msg['id'], 'result': {
                    'tools': [{'name': 'echo', 'description': 'Echo'}]}})
        """
        let path = dir.appendingPathComponent("server.py")
        try script.write(to: path, atomically: true, encoding: .utf8)
        return ServerConfig(
            id: "test:banner", name: "banner", source: .code, projectPath: nil, transport: .stdio,
            command: "/usr/bin/python3", args: [path.path], env: [:], url: nil, headers: [:]
        )
    }

    func testBannerWithBraceThenJSONLinesIsHealthy() async throws {
        let config = try fakeServer(banner: "[dotenv] injecting env {path: .env}\n", contentLength: false)
        let result = await StdioProbe.probe(config: config, fetchTools: true, timeout: .seconds(5))
        XCTAssertEqual(result.state, .healthy, result.failureReason ?? "")
        XCTAssertEqual(result.tools?.map(\.name), ["echo"])
    }

    func testBannerThenContentLengthFramesIsHealthy() async throws {
        let config = try fakeServer(banner: "Server starting on stdio\n", contentLength: true)
        let result = await StdioProbe.probe(config: config, fetchTools: true, timeout: .seconds(5))
        XCTAssertEqual(result.state, .healthy, result.failureReason ?? "")
        XCTAssertEqual(result.tools?.map(\.name), ["echo"])
    }

    /// A banner line that is only brace-shaped (`{path: .env}`) is skipped
    /// by the probe, not reported as malformed JSON.
    func testBraceShapedBannerLineIsNotMalformedJSON() async throws {
        let config = try fakeServer(banner: "{path: .env}\n", contentLength: false)
        let result = await StdioProbe.probe(config: config, fetchTools: false, timeout: .seconds(5))
        XCTAssertEqual(result.state, .healthy, result.failureReason ?? "")
    }
}
