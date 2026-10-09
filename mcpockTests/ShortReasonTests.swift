import XCTest
@testable import mcpock

/// The short line under a "Needs you" row. Known probe wordings map to plain
/// words; anything else falls back to its first 60 characters, never blank.
final class ShortReasonTests: XCTestCase {
    private func short(_ reason: String, _ state: HealthState = .broken) -> String {
        ShortReason.from(reason, state: state)
    }

    func testSpawnErrors() {
        XCTAssertEqual(short("Spawn error: Command not found: uvx"), "Could not start: command not found")
        XCTAssertEqual(short("Spawn error: Not executable: /tmp/x"), "Could not start: not executable")
        XCTAssertEqual(short("Spawn error: Missing command"), "Could not start: no command set")
        XCTAssertEqual(short("Spawn error: Operation not permitted"), "Could not start: Operation not permitted")
    }

    func testAuthReadsAsNeedsSignIn() {
        XCTAssertEqual(short("Needs authentication (HTTP 401)", .degraded), "Needs sign-in")
        XCTAssertEqual(short("Needs authentication (HTTP 403)", .degraded), "Needs sign-in")
    }

    /// The first timeout is amber ("Slow"); a repeat is red and says so plainly.
    func testTimeoutWordingFollowsTheState() {
        XCTAssertEqual(short("Timed out after 10s", .degraded), "Slow: no answer in 10 s")
        XCTAssertEqual(short("Timed out after 10.0s", .degraded), "Slow: no answer in 10 s")
        XCTAssertEqual(short("Timed out after 10s", .broken), "No answer in 10 s")
        XCTAssertEqual(short("Timed out after 2.5s — npm warn deprecated", .degraded), "Slow: no answer in 2.5 s")
    }

    /// The stdio probe appends " — <stderr tail>"; the head decides the wording.
    func testExitCodeIgnoresTheStderrTail() {
        XCTAssertEqual(short("Non-zero exit (127) — env: node: No such file or directory"), "Quit on start (exit 127)")
    }

    func testOtherKnownShapes() {
        XCTAssertEqual(short("Handshake rejected: bad version"), "Refused the handshake")
        XCTAssertEqual(short("Invalid URL: ht!tp://"), "Bad address in config")
        XCTAssertEqual(short("Protocol error: unexpected id"), "Unexpected reply")
        XCTAssertEqual(short("No response from server"), "No response")
        XCTAssertEqual(short("HTTP 500: Internal Server Error"), "Server error (HTTP 500)")
    }

    func testUnknownReasonFallsBackToFirstSixtyCharacters() {
        let long = String(repeating: "abcdefghij", count: 8)
        let line = short(long)
        XCTAssertEqual(line, String(long.prefix(60)) + "\u{2026}")
        XCTAssertEqual(short("Something odd"), "Something odd")
        XCTAssertEqual(short("first line\nsecond line"), "first line")
    }

    private func group(_ state: HealthState, reason: String? = nil, differs: [String] = []) -> ServerGroup {
        ServerGroup(
            name: "x", state: state, sourceLabels: ["Code"], tools: [],
            issues: reason.map { [ServerIssue(label: "Code", reason: $0, command: "x")] } ?? [],
            variantCount: 1,
            differs: differs.map { DiffNote(label: $0, target: "t") }
        )
    }

    func testRowLine() {
        XCTAssertEqual(ShortReason.line(for: group(.broken, reason: "Spawn error: Command not found: x")),
                       "Could not start: command not found")
        XCTAssertEqual(ShortReason.line(for: group(.degraded, reason: "Needs authentication (HTTP 401)")), "Needs sign-in")
        XCTAssertEqual(ShortReason.line(for: group(.healthy, differs: ["Grok"])), "Set up differently in Grok")
        XCTAssertNil(ShortReason.line(for: group(.unknown)), "unknown rows sit in their normal section, no second line")
        XCTAssertNil(ShortReason.line(for: group(.healthy)))
        XCTAssertNil(ShortReason.line(for: group(.paused, differs: ["Grok"])))
    }

    func testDiffersWording() {
        let notes = ["Grok", "Cursor", "Goose"].map { DiffNote(label: $0, target: "t") }
        XCTAssertEqual(ShortReason.differs(Array(notes.prefix(1))), "Set up differently in Grok")
        XCTAssertEqual(ShortReason.differs(Array(notes.prefix(2))), "Set up differently in Grok and Cursor")
        XCTAssertEqual(ShortReason.differs(notes), "Set up differently in 3 agents")
        // Round 7: the registry's short "Code" reads as Claude Code.
        XCTAssertEqual(ShortReason.differs([DiffNote(label: "Claude Desktop", target: "a"), DiffNote(label: "Code", target: "b")]),
                       "Set up differently in Claude Desktop and Claude Code")
    }

    /// The UI words from the spec's health-mark table.
    func testHealthMarkWords() {
        XCTAssertEqual(HealthMark.word(for: .healthy), "Healthy")
        XCTAssertEqual(HealthMark.word(for: .broken), "Broken")
        XCTAssertEqual(HealthMark.word(for: .unknown), "Checking")
        XCTAssertEqual(HealthMark.word(for: .paused), "Paused")
        XCTAssertEqual(HealthMark.word(for: .selfManaged), "Runs inside its app")
        XCTAssertEqual(HealthMark.word(for: group(.degraded, reason: "Timed out after 10s")), "Slow")
        XCTAssertEqual(HealthMark.word(for: group(.degraded, reason: "Needs authentication (HTTP 401)")), "Needs sign-in")
        XCTAssertEqual(HealthMark.word(for: group(.healthy, differs: ["Grok"])), "Set up differently")
    }
}
