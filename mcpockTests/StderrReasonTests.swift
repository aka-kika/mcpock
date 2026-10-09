import XCTest
@testable import mcpock

/// TODO 2026-09-26, "Show the real error line, not only the tail": a Node
/// stack trace's cause sits at the *top* of stderr, so `stderrTail()` alone
/// only ever shows `at ...` frames. Real case: wigolo in aka's tail showed
/// `at async main (...index.js:146:7)`, when the answer was the first line,
/// `Error: Could not locate the bindings file`. `ProcessRunner.stderrReason()`
/// now also surfaces the first line that looks like a real error, without
/// duplicating it when the tail already has it (a Python traceback's cause
/// sits at the *bottom*, already inside the tail).
///
/// These drive the full path through `StdioProbe.probe`, same as
/// `ProcessCleanupTests.testCrashedServerSurfacesStderrAndExitCode`: a real
/// `/bin/sh` child that never speaks MCP, so the probe fails the handshake
/// and builds its reason from whatever the child printed to stderr.
final class StderrReasonTests: XCTestCase {
    private func probe(script: String, name: String) async -> ProbeResult {
        let config = ServerConfig(
            id: "test:\(name)", name: name, source: .code, projectPath: nil,
            transport: .stdio, command: "/bin/sh", args: ["-c", script],
            env: [:], url: nil, headers: [:]
        )
        return await StdioProbe.probe(config: config, fetchTools: true)
    }

    /// The bindings-error case, with a dozen `at ...` frames after it — enough
    /// that the first line would have long since scrolled out of a 2-line
    /// tail, proving the buffer still holds it.
    func testNodeStackTraceSurfacesFirstLineBeforeTail() async throws {
        let frameLines = (1...12).map { "echo '    at frame\($0) (/app/index.js:\($0):7)' >&2" }
        let script = (["echo 'Error: Could not locate the bindings file' >&2"] + frameLines + ["exit 1"])
            .joined(separator: "\n")

        let result = await probe(script: script, name: "node-crash")
        let reason = result.failureReason ?? ""

        XCTAssertTrue(reason.contains("Error: Could not locate the bindings file"),
                      "Expected the real cause up front, got: \(reason)")
        XCTAssertTrue(reason.contains("frame12"), "Expected the tail's last frame too, got: \(reason)")
        XCTAssertEqual(
            reason.components(separatedBy: "Error: Could not locate the bindings file").count - 1, 1,
            "The cause line must not be duplicated, got: \(reason)"
        )
    }

    /// A Python traceback puts its cause at the *bottom* — already inside the
    /// default 2-line tail — so the generic "Traceback" header must not also
    /// get prepended; the reason should read exactly as the tail alone would.
    func testPythonTracebackCauseAlreadyInTailIsNotDuplicated() async throws {
        let script = """
        echo 'Traceback (most recent call last):' >&2
        echo '  File "server.py", line 12, in <module>' >&2
        echo '    raise ValueError("bad config")' >&2
        echo 'ValueError: bad config' >&2
        exit 1
        """

        let result = await probe(script: script, name: "python-crash")
        let reason = result.failureReason ?? ""

        XCTAssertTrue(reason.contains("ValueError: bad config"), "Expected the cause, got: \(reason)")
        XCTAssertFalse(reason.contains("Traceback"), "The generic header must not be prepended, got: \(reason)")
    }

    /// A Rust/Go-style `panic:` line, pushed out of the tail by later frames,
    /// must still surface up front.
    func testPanicLineSurfacesBeforeTail() async throws {
        let script = """
        echo 'panic: runtime error: index out of range [3] with length 3' >&2
        echo 'goroutine 1 [running]:' >&2
        echo 'main.main()' >&2
        echo '        /app/main.go:10 +0x1b' >&2
        exit 2
        """

        let result = await probe(script: script, name: "panic-crash")
        let reason = result.failureReason ?? ""

        XCTAssertTrue(reason.contains("panic: runtime error: index out of range"),
                      "Expected the panic line up front, got: \(reason)")
        XCTAssertTrue(reason.contains("main.go:10"), "Expected the tail too, got: \(reason)")
    }

    /// Plain stderr with nothing that looks like an error: behaviour is
    /// unchanged, the tail alone.
    func testPlainStderrWithNoErrorLineIsUnchanged() async throws {
        let script = """
        echo 'starting up' >&2
        echo 'still going' >&2
        echo 'connection refused, retrying' >&2
        exit 1
        """

        let result = await probe(script: script, name: "plain-crash")
        let reason = result.failureReason ?? ""

        XCTAssertTrue(reason.contains("connection refused, retrying"), "Expected the tail, got: \(reason)")
        // No " — " splice from a first-error-line that doesn't exist here.
        XCTAssertEqual(reason.components(separatedBy: " — ").count, 2,
                       "Expected exactly head — tail, got: \(reason)")
    }

    /// A secret sitting inside the surfaced error line must still be masked,
    /// same as the tail always was (`HealthMonitor.groupByName` scrubs the
    /// whole reason once it is built).
    func testSecretInsideErrorLineIsMasked() async throws {
        let script = """
        echo 'Error: invalid token sk-abcdefghijklmnopqrstuvwxyz123456' >&2
        echo 'authentication failed' >&2
        exit 1
        """

        let result = await probe(script: script, name: "secret-crash")
        let rawReason = result.failureReason ?? ""
        XCTAssertTrue(rawReason.contains("sk-abcdefghijklmnopqrstuvwxyz123456"),
                      "Sanity check: the raw probe result should still carry the secret, got: \(rawReason)")

        let scrubbed = SecretMask.scrub(rawReason)
        XCTAssertFalse(scrubbed.contains("sk-abcdefghijklmnopqrstuvwxyz123456"),
                       "Secret must be masked, got: \(scrubbed)")
        XCTAssertTrue(scrubbed.contains("Error: invalid token"), "Non-secret context must survive, got: \(scrubbed)")
        XCTAssertTrue(scrubbed.contains(SecretMask.dots), "Expected the mask dots, got: \(scrubbed)")
    }
}
