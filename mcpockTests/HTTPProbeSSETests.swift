import XCTest
@testable import mcpock

/// Streamable HTTP servers answer a POST with an SSE body. Some end its lines with
/// CRLF (sse-starlette); before the fix those probed as "No JSON in SSE stream".
final class HTTPProbeSSETests: XCTestCase {
    private let reply = #"{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"the-board"}}}"#

    func testParsesLFLineEndings() throws {
        let body = Data("event: message\ndata: \(reply)\n\n".utf8)
        let obj = try HTTPProbe.parseSSEJSON(body)
        XCTAssertNotNil(obj["result"])
    }

    func testParsesCRLFLineEndings() throws {
        let body = Data("event: message\r\ndata: \(reply)\r\n\r\n".utf8)
        let obj = try HTTPProbe.parseSSEJSON(body)
        XCTAssertNotNil(obj["result"])
    }

    func testNoDataLineStillThrows() {
        XCTAssertThrowsError(try HTTPProbe.parseSSEJSON(Data(": ping\r\n\r\n".utf8)))
    }
}
