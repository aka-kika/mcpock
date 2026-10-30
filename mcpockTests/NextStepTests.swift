import XCTest
@testable import mcpock

/// 1.13: the "what do I do now" line under a reason.
final class NextStepTests: XCTestCase {
    private func group(_ state: HealthState, reason: String? = nil, transport: TransportKind = .stdio) -> ServerGroup {
        ServerGroup(name: "x", state: state, sourceLabels: ["Cursor"], tools: [],
                    issues: reason.map { [ServerIssue(label: "Cursor", reason: $0, command: "")] } ?? [], variantCount: 1,
                    sources: [GroupSource(configID: "c", label: "Cursor", agent: "Cursor", path: "/k/mcp.json", transport: transport,
                                          target: "", envKeys: [], headerKeys: [], state: state, failureReason: reason)])
    }

    func testEveryKnownReasonHasItsLine() {
        let table: [(String, Bool, String)] = [
            ("Spawn error: Command not found: xapi-mcp", false, "Install it, or write the full path in the config."),
            ("Spawn error: Command not found: ./s (a relative path, and this config names no folder for it)", false, "Write the full path in the config."),
            ("Spawn error: Not executable: /x/y", false, "Make the file executable, or point the config at the right one."),
            ("Spawn error: Process is not running", false, "Run its command in Terminal to see why."),
            ("Non-zero exit (1) — Error: no key", false, "Read its error above: usually a missing key or package."),
            ("Non-zero exit (1)", false, "Run its command in Terminal to see why: usually a missing key or package."),
            ("Exited after start (3)", false, "Run its command in Terminal to see why it quits."),
            ("Timed out after 20s", false, "Check again. If it stays slow, run its command in Terminal."),
            ("Timed out after 10.0s", true, "Check again. If it stays slow, see whether the server is up."),
            ("Handshake rejected: nope", false, "Read its error above: often the server needs an update."),
            ("Invalid URL: x", true, "Fix the address in the config."),
            ("Protocol error: bad", true, "Check that this really is an MCP server, and update it if it is."),
            ("No response from server", false, "Run its command in Terminal to see whether it starts."),
            ("No response from server", true, "Check the address, and that the server is up."),
            ("Header helper failed: exit 1", true, "Run the config's headersHelper in Terminal to see why it fails."),
            ("HTTP 502: bad gateway", true, "The trouble is on the server's side: check again later."),
            ("HTTP 404", true, "Check the address in the config."),
            ("Needs authentication (HTTP 401)", true, "The token in the config is old or wrong: sign in again in the agent."),
            ("Could not connect to the server.", true, "Check the address, and that the server is up."),
            (HealthMonitor.noEndpointReason, false, "Add a command or url to this entry, or remove it."),
        ]
        for (reason, remote, line) in table {
            XCTAssertEqual(NextStep.line(forReason: reason, remote: remote), line, reason)
        }
    }

    func testRowsThatNeedNoLine() {
        XCTAssertNil(NextStep.line(for: group(.healthy)))
        XCTAssertNil(NextStep.line(for: group(.paused)))
        XCTAssertNil(NextStep.line(for: group(.unknown)))
        XCTAssertNil(NextStep.line(for: group(.selfManaged)))
        XCTAssertNil(NextStep.line(for: group(.needsApp)))
        var lost = group(.healthy)
        lost.sessionDrops = [SessionDrop(folder: "/u/x", at: Date())]
        XCTAssertNil(NextStep.line(for: lost), "its reason already says run /mcp")
    }

    func testDiffersAndRemoteRows() {
        var odd = group(.healthy)
        odd.differs = [DiffNote(label: "Cursor", target: "x")]
        XCTAssertEqual(NextStep.line(for: odd), "Compare the setups, then fix the odd one or Mark as intended.")
        XCTAssertEqual(NextStep.line(for: group(.broken, reason: "Timed out after 10.0s", transport: .http)),
                       "Check again. If it stays slow, see whether the server is up.")
    }

    /// The same words reach the status file, the helper and `status.md`.
    func testTheLineReachesTheStatusFile() {
        let entry = StatusSnapshot.server(group(.broken, reason: "Spawn error: Command not found: x"), byID: [:], hidden: false, pinned: false)
        XCTAssertEqual(entry.nextStep, "Install it, or write the full path in the config.")
        let lines = StatusReport.serverLines(entry, number: 1, full: false, now: Date())
        XCTAssertTrue(lines.contains("   Next step: Install it, or write the full path in the config."), lines.joined(separator: "\n"))
    }
}
