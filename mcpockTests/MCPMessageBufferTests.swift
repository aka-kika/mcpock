import XCTest
@testable import mcpock

/// Regression tests for MCPMessageBuffer, guarding against the crash where
/// `Data.removeFirst()` / `removeSubrange` leave `buffer.startIndex != 0`
/// (a well-known Swift `Data` footgun: `Data` does not re-base indices to 0
/// after front removal) while other code paths mix in a literal `0`.
final class MCPMessageBufferTests: XCTestCase {

    /// Crash repro: leading whitespace before an NDJSON line strips the whitespace
    /// via `removeFirst()`, leaving `buffer.startIndex == 1`. The subsequent
    /// `subdata(in: 0..<newlineIndex)` must not crash / go out of range.
    func testLeadingWhitespaceBeforeNDJSONLine() throws {
        let buffer = MCPMessageBuffer()
        buffer.append(" {\"a\":1}\n".data(using: .utf8)!)

        let msg = try buffer.nextMessage()

        XCTAssertNotNil(msg, "Expected a decoded message, got nil")
        XCTAssertEqual(String(data: msg!, encoding: .utf8), "{\"a\":1}")
    }

    /// Two NDJSON messages arriving in a single buffer must be returned one at a time.
    func testTwoNDJSONMessagesInOneBuffer() throws {
        let buffer = MCPMessageBuffer()
        buffer.append("{\"a\":1}\n{\"b\":2}\n".data(using: .utf8)!)

        let first = try buffer.nextMessage()
        XCTAssertEqual(String(data: first ?? Data(), encoding: .utf8), "{\"a\":1}")

        let second = try buffer.nextMessage()
        XCTAssertEqual(String(data: second ?? Data(), encoding: .utf8), "{\"b\":2}")

        let third = try buffer.nextMessage()
        XCTAssertNil(third)
    }

    /// Content-Length framing must still work after the fix.
    func testContentLengthFraming() throws {
        let buffer = MCPMessageBuffer()
        let body = "{\"jsonrpc\":\"2.0\"}"
        let byteCount = body.utf8.count
        let frame = "Content-Length: \(byteCount)\r\n\r\n\(body)"
        buffer.append(frame.data(using: .utf8)!)

        let msg = try buffer.nextMessage()

        XCTAssertNotNil(msg)
        XCTAssertEqual(String(data: msg!, encoding: .utf8), body)
    }

    /// Leading whitespace before a Content-Length header must also survive
    /// the whitespace-strip loop without corrupting subsequent indices.
    func testLeadingWhitespaceBeforeContentLengthHeader() throws {
        let buffer = MCPMessageBuffer()
        let body = "{\"jsonrpc\":\"2.0\"}"
        let byteCount = body.utf8.count
        let frame = "  \r\nContent-Length: \(byteCount)\r\n\r\n\(body)"
        buffer.append(frame.data(using: .utf8)!)

        let msg = try buffer.nextMessage()

        XCTAssertNotNil(msg)
        XCTAssertEqual(String(data: msg!, encoding: .utf8), body)
    }

    /// Partial input (no trailing newline yet) must return nil without consuming
    /// or corrupting the buffer; once the rest arrives, the full message must decode.
    func testPartialInputReturnsNilWithoutConsuming() throws {
        let buffer = MCPMessageBuffer()
        buffer.append("{\"a\":".data(using: .utf8)!)

        let partial = try buffer.nextMessage()
        XCTAssertNil(partial, "Partial (unterminated) line must not yield a message")

        buffer.append("1}\n".data(using: .utf8)!)

        let full = try buffer.nextMessage()
        XCTAssertNotNil(full)
        XCTAssertEqual(String(data: full!, encoding: .utf8), "{\"a\":1}")
    }

    /// A chatty server printing a large non-JSON banner before its first message
    /// must not overflow the stack (the old per-byte recursion crashed with SIGBUS).
    func testLargeNonJSONStdoutDoesNotOverflow() throws {
        let buffer = MCPMessageBuffer()
        // ~110 KB of newline-terminated noise with no `{` — previously recursed once
        // per byte and blew the stack.
        let banner = String(repeating: "npm warn using --force\n", count: 5000)
        buffer.append(banner.data(using: .utf8)!)

        XCTAssertNil(try buffer.nextMessage(), "noise with no message start yields nil, not a crash")

        buffer.append("{\"a\":1}\n".data(using: .utf8)!)
        let msg = try buffer.nextMessage()
        XCTAssertEqual(String(data: msg ?? Data(), encoding: .utf8), "{\"a\":1}")
    }

    /// Noise preceding a real message in the SAME buffer is skipped, not fatal.
    func testNoisePrefixBeforeMessageInSameBuffer() throws {
        let buffer = MCPMessageBuffer()
        buffer.append("some log line without json\n{\"a\":1}\n".data(using: .utf8)!)
        let msg = try buffer.nextMessage()
        XCTAssertEqual(String(data: msg ?? Data(), encoding: .utf8), "{\"a\":1}")
    }

    /// A malformed/malicious server sending a negative Content-Length must be rejected
    /// with a protocol error, not crash the body slice (bodyEnd < bodyStart).
    func testNegativeContentLengthThrowsInsteadOfCrashing() {
        let buffer = MCPMessageBuffer()
        buffer.append("Content-Length: -5\r\n\r\n{}".data(using: .utf8)!)

        XCTAssertThrowsError(try buffer.nextMessage()) { error in
            guard case ProbeError.protocolError = error else {
                return XCTFail("Expected ProbeError.protocolError, got \(error)")
            }
        }
    }

    /// A length near Int.max used to overflow `bodyStart + length` and trap
    /// the whole app (review, 2026-09-26).
    func testHugeContentLengthThrowsInsteadOfCrashing() {
        let buffer = MCPMessageBuffer()
        buffer.append("Content-Length: 9223372036854775807\r\n\r\n{}".data(using: .utf8)!)
        XCTAssertThrowsError(try buffer.nextMessage())
    }

    /// Bytes that aren't text are noise, not the start of a header: they used
    /// to be kept forever because an empty preview matched "content-length".
    func testBinaryNoiseIsDroppedNotKept() throws {
        let buffer = MCPMessageBuffer()
        buffer.append(Data([0xFF, 0xFE, 0xFD, 0x80, 0x81]))
        XCTAssertNil(try buffer.nextMessage())
        buffer.append("{\"jsonrpc\":\"2.0\",\"id\":1}\n".data(using: .utf8)!)
        let message = try XCTUnwrap(try buffer.nextMessage())
        XCTAssertEqual(String(data: message, encoding: .utf8), "{\"jsonrpc\":\"2.0\",\"id\":1}")
    }
}
