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
