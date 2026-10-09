import XCTest
@testable import mcpock

/// Round 8: the widgets' own small snapshot, built from a full `MCPockStatus`
/// — all fine, problems ordering and the 4-row limit, per-agent rows and
/// their 5-row limit, and the file round trip through a throwaway directory
/// (never the real App Group container).
@MainActor
final class WidgetSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func config(_ name: String, agent: String, command: String = "npx") -> ServerConfig {
        ServerConfig(
            id: "\(agent):\(name)", name: name, source: ServerSource(label: agent, path: "/Users/k/\(agent).json"),
            projectPath: nil, transport: .stdio, command: command, args: [], env: [:], url: nil, headers: [:]
        )
    }

    private func status(_ servers: [ServerSnapshot], hidden: Set<String> = []) -> MCPockStatus {
        StatusSnapshot.build(
            servers: servers,
            isHidden: { hidden.contains($0) },
            isPinned: { _ in false },
            checking: false,
            firstCheckDone: true,
            interval: .fifteenMinutes,
            now: now,
            pid: 1,
            appVersion: "1.8.0"
        )
    }

    func testAllFine() {
        let servers = (1...3).map { i in
            ServerSnapshot(config: config("s\(i)", agent: "Cursor"), state: .healthy, lastChecked: now)
        }
        let snapshot = MCPockWidgetSnapshot.build(from: status(servers))
        XCTAssertTrue(snapshot.problems.isEmpty)
        XCTAssertEqual(snapshot.problemCount, 0)
        XCTAssertEqual(snapshot.totalServers, 3)
        XCTAssertEqual(snapshot.fineCount, 3)
    }

    func testProblemsAreWorstFirstAndLimitedToFour() {
        let servers: [ServerSnapshot] = [
            ServerSnapshot(config: config("broken1", agent: "Cursor"), state: .broken,
                           failureReason: "Non-zero exit (1)", lastChecked: now),
            ServerSnapshot(config: config("broken2", agent: "Cursor"), state: .broken,
                           failureReason: "Spawn error", lastChecked: now),
            ServerSnapshot(config: config("slow1", agent: "Cursor"), state: .degraded,
                           failureReason: "Timed out", lastChecked: now),
            ServerSnapshot(config: config("signin1", agent: "Cursor"), state: .degraded,
                           failureReason: "Needs authentication (HTTP 401)", lastChecked: now),
            // "set up differently": two sources, different commands, same server name.
            ServerSnapshot(config: config("differs1", agent: "Cursor", command: "cmd-a"), state: .healthy, lastChecked: now),
            ServerSnapshot(config: config("differs1", agent: "Grok", command: "cmd-b"), state: .healthy, lastChecked: now),
            // Hidden: never counted, never listed, never in the total.
            ServerSnapshot(config: config("hiddenBroken", agent: "Cursor"), state: .broken,
                           failureReason: "Non-zero exit (1)", lastChecked: now),
        ]
        let snapshot = MCPockWidgetSnapshot.build(from: status(servers, hidden: ["hiddenBroken"]))

        XCTAssertEqual(snapshot.problemCount, 5, "5 problems total, hidden one excluded")
        XCTAssertEqual(snapshot.problems.count, 4, "only the worst 4 are listed")
        XCTAssertEqual(snapshot.problems.map(\.name), ["broken1", "broken2", "slow1", "signin1"],
                       "broken, then slow, then needs sign-in — the 5th (set up differently) is dropped by the limit")
        XCTAssertEqual(snapshot.problems.map(\.status), ["not answering", "not answering", "slow", "needs sign-in"],
                       "\"broken\" reads as \"not answering\" on a widget glance")
        XCTAssertEqual(snapshot.totalServers, 5, "6 groups total, the hidden one left out")
    }

    func testPerAgentRowsAreLimitedToFive() {
        let servers = (1...6).map { i in
            ServerSnapshot(config: config("s\(i)", agent: "Agent\(i)"), state: .healthy, lastChecked: now)
        }
        let snapshot = MCPockWidgetSnapshot.build(from: status(servers))
        XCTAssertEqual(snapshot.agents.count, 5, "6 agents in the status file, only the top 5 in the widget")
        XCTAssertEqual(snapshot.agents.map(\.name), ["Agent1", "Agent2", "Agent3", "Agent4", "Agent5"],
                       "all fine, so alphabetical — same order the Agents tab would show them in")
        XCTAssertEqual(snapshot.agents.first?.serverCount, 1)
        XCTAssertEqual(snapshot.agents.first?.fineCount, 1)
        XCTAssertEqual(snapshot.agents.first?.problemCount, 0)
    }

    /// Each agent row carries the same logo asset the Agents tab shows.
    func testAgentsCarryTheirLogo() {
        let snapshot = MCPockWidgetSnapshot.build(
            from: status([ServerSnapshot(config: config("s1", agent: "Cursor"), state: .healthy, lastChecked: now)]),
            logo: HealthMonitor.widgetLogo
        )
        XCTAssertEqual(snapshot.agents.first?.logo, "agent-cursor")
        XCTAssertNil(MCPockWidgetSnapshot.build(from: status([
            ServerSnapshot(config: config("s1", agent: "Cursor"), state: .healthy, lastChecked: now),
        ])).agents.first?.logo, "no logo lookup: a plain dot")
    }

    /// A profile or project label finds its agent's logo, as in the Agents
    /// tab (review, 2026-09-26: "Hermes · scribe" got a plain dot).
    func testProfileAndProjectLabelsFindTheirLogo() {
        XCTAssertEqual(HealthMonitor.widgetLogo("Hermes · scribe"), "agent-hermesagent")
        XCTAssertEqual(HealthMonitor.widgetLogo("Claude Code (MyApp)"), "agent-claudecode")
        XCTAssertEqual(HealthMonitor.widgetLogo("Cursor"), "agent-cursor")
    }

    /// 1.9.1: the widgets color like the panel, red only for broken and
    /// amber for slow, needs sign-in and set up differently. The snapshot
    /// says which problems are broken, per server and per agent.
    func testSnapshotSaysWhatIsBrokenForTheColors() {
        let servers: [ServerSnapshot] = [
            ServerSnapshot(config: config("dead", agent: "Codex"), state: .broken,
                           failureReason: "Non-zero exit (1)", lastChecked: now),
            ServerSnapshot(config: config("fine", agent: "Codex"), state: .healthy, lastChecked: now),
            ServerSnapshot(config: config("sluggish", agent: "Cursor"), state: .degraded,
                           failureReason: "Timed out", lastChecked: now),
        ]
        let snapshot = MCPockWidgetSnapshot.build(from: status(servers))
        XCTAssertEqual(snapshot.problems.map(\.name), ["dead", "sluggish"])
        XCTAssertEqual(snapshot.problems.map(\.isBroken), [true, false])
        XCTAssertEqual(snapshot.brokenCount, 1)
        let codex = snapshot.agents.first { $0.name == "Codex" }
        let cursor = snapshot.agents.first { $0.name == "Cursor" }
        XCTAssertEqual(codex?.brokenCount, 1)
        XCTAssertEqual(codex?.problemCount, 1)
        XCTAssertEqual(cursor?.brokenCount, 0, "slow is amber, not red")
        XCTAssertEqual(cursor?.problemCount, 1)

        XCTAssertEqual(snapshot.problems.map(\.showsRed), [true, false])
        XCTAssertEqual(codex?.redCount, 1)
        XCTAssertEqual(cursor?.redCount, 0)
        XCTAssertTrue(snapshot.markIsRed)
        let onlySlow = MCPockWidgetSnapshot.build(from: status([servers[2]]))
        XCTAssertFalse(onlySlow.markIsRed, "only slow left: amber mark")
    }

    /// A snapshot written by 1.9.0 (no broken fields) still reads; the
    /// widgets then fall back to treating every problem as broken, as before.
    func testA190SnapshotStillDecodes() throws {
        let json = """
        {"agents":[{"fineCount":1,"name":"Cursor","problemCount":1,"serverCount":2}],"checking":false,
         "fineCount":1,"firstCheckDone":true,"generated":"2026-10-09T21:08:21Z","problemCount":1,
         "problems":[{"name":"x","status":"slow"}],"schema":1,"totalServers":2}
        """
        let snapshot = try MCPockWidgetSnapshot.decoder().decode(MCPockWidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.brokenCount)
        XCTAssertNil(snapshot.problems.first?.isBroken)
        XCTAssertNil(snapshot.agents.first?.brokenCount)
        XCTAssertTrue(snapshot.problems.first?.showsRed ?? false, "older data keeps the old red")
        XCTAssertEqual(snapshot.agents.first?.redCount, 1)
        XCTAssertTrue(snapshot.markIsRed)
    }

    func testStoreRoundTripsThroughAThrowawayDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-widget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = MCPockWidgetSnapshot.build(from: status([
            ServerSnapshot(config: config("s1", agent: "Cursor"), state: .healthy, lastChecked: now),
        ]))
        try WidgetSnapshotStore.write(snapshot, to: dir)
        XCTAssertEqual(WidgetSnapshotStore.read(from: dir), snapshot)
    }

    func testReadWithNothingWrittenYetIsNil() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-widget-missing-\(UUID().uuidString)")
        XCTAssertNil(WidgetSnapshotStore.read(from: dir), "no snapshot yet: the widgets fall back to their empty state")
    }
}
