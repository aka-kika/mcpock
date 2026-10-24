import XCTest
@testable import mcpock

final class MCPJSONRPCTests: XCTestCase {
    func testIsResponseMatchesNumericId() {
        let response: [String: Any] = ["jsonrpc": "2.0", "id": 1, "result": [String: Any]()]
        XCTAssertTrue(MCPJSONRPC.isResponse(response, to: 1))
        XCTAssertFalse(MCPJSONRPC.isResponse(response, to: 2))
    }

    func testIsResponseMatchesStringIdEcho() {
        // Some servers echo the id back as a string; the spec says match it anyway.
        let response: [String: Any] = ["jsonrpc": "2.0", "id": "2", "error": ["message": "nope"]]
        XCTAssertTrue(MCPJSONRPC.isResponse(response, to: 2))
    }

    /// Review 2026-10-20 (7243): an error with a null id is the reply.
    func testErrorWithNullIdIsTheResponse() {
        let nullID: [String: Any] = ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Unsupported protocol version"]]
        XCTAssertTrue(MCPJSONRPC.isResponse(nullID, to: 1))
        XCTAssertThrowsError(try MCPJSONRPC.validateInitializeResponse(nullID)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unsupported protocol version"))
        }
        let noID: [String: Any] = ["jsonrpc": "2.0", "error": ["code": -32600, "message": "bad"]]
        XCTAssertTrue(MCPJSONRPC.isResponse(noID, to: 1))
        XCTAssertFalse(MCPJSONRPC.isResponse(["jsonrpc": "2.0", "id": NSNull(), "result": [:]], to: 1),
                       "only an error: a result needs its id")
        XCTAssertFalse(MCPJSONRPC.isResponse(["jsonrpc": "2.0", "id": 7, "error": ["code": 1]], to: 1))
    }

    /// r3 f730: after initialize, a null-id error (a server rejecting the
    /// initialized notice) is not the answer to tools/list.
    func testNullIdErrorOnlyAnswersInitialize() {
        let rejected: [String: Any] = ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "no"]]
        XCTAssertTrue(MCPJSONRPC.isResponse(rejected, to: MCPJSONRPC.initializeID))
        XCTAssertFalse(MCPJSONRPC.isResponse(rejected, to: 2))
        let noID: [String: Any] = ["jsonrpc": "2.0", "error": ["code": -32600, "message": "no"]]
        XCTAssertFalse(MCPJSONRPC.isResponse(noID, to: 2))
    }

    func testNotificationIsNotAResponse() {
        // A server-initiated log notification mid-handshake must be skipped, not
        // mistaken for the initialize/tools response (it has no id and no result).
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/message",
            "params": ["level": "info", "data": "starting up"],
        ]
        XCTAssertFalse(MCPJSONRPC.isResponse(notification, to: 1))
    }

    func testServerInitiatedRequestIsNotAResponse() {
        // A server-initiated *request* carries an id but no result/error.
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "roots/list"]
        XCTAssertFalse(MCPJSONRPC.isResponse(request, to: 1))
    }
}
