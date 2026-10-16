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

    /// Argon 2026-10-17 #12: with an id, only that request's answer counts.
    func testPicksTheAnswerToItsOwnRequest() throws {
        let body = Data("""
        data: {"jsonrpc":"2.0","id":7,"result":{"other":true}}

        data: {"jsonrpc":"2.0","method":"notifications/message","params":{}}

        data: {"jsonrpc":"2.0","id":3,"result":{"mine":true}}

        """.utf8)
        let obj = try HTTPProbe.parseSSEJSON(body, id: 3)
        XCTAssertEqual((obj["result"] as? [String: Any])?["mine"] as? Bool, true)
        XCTAssertThrowsError(try HTTPProbe.parseSSEJSON(body, id: 9))
    }

    func testAnswerForAnotherRequest() {
        XCTAssertTrue(HTTPProbe.isForAnotherRequest(["id": 4, "result": [:]], id: 3))
        XCTAssertFalse(HTTPProbe.isForAnotherRequest(["id": 3, "result": [:]], id: 3))
        XCTAssertFalse(HTTPProbe.isForAnotherRequest(["id": "3", "result": [:]], id: 3))
        XCTAssertFalse(HTTPProbe.isForAnotherRequest(["id": NSNull(), "error": [:]], id: 3), "a parse error still shows")
    }
}
