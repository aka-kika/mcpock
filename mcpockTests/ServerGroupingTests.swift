import XCTest
@testable import mcpock

/// The same server name declared in multiple apps/projects collapses to one row,
/// whose status is the worst across its instances (broken if any instance is broken).
final class ServerGroupingTests: XCTestCase {
    func testAllHealthyAggregatesToHealthy() {
        XCTAssertEqual(HealthMonitor.aggregateState([.healthy, .healthy, .healthy]), .healthy)
    }

    func testAnyBrokenAggregatesToBroken() {
        XCTAssertEqual(HealthMonitor.aggregateState([.healthy, .broken, .healthy]), .broken,
                       "broken in one instance must show broken for the whole group")
    }

    func testDegradedBeatsHealthyButNotBroken() {
        XCTAssertEqual(HealthMonitor.aggregateState([.healthy, .degraded]), .degraded)
        XCTAssertEqual(HealthMonitor.aggregateState([.broken, .degraded]), .broken)
    }

    func testUnknownWhenStillWaiting() {
        XCTAssertEqual(HealthMonitor.aggregateState([.healthy, .unknown]), .unknown)
    }

    func testEmptyIsUnknown() {
        XCTAssertEqual(HealthMonitor.aggregateState([]), .unknown)
    }

    func testServerSourceEqualityByLabel() {
        XCTAssertEqual(ServerSource(label: "Cursor"), ServerSource(label: "Cursor"))
        XCTAssertNotEqual(ServerSource(label: "Cursor"), ServerSource(label: "Goose"))
        XCTAssertEqual(ServerSource.grok.label, "Grok")
    }

    private func snap(_ source: ServerSource, _ state: HealthState, reason: String? = nil) -> ServerSnapshot {
        let cfg = ServerConfig(
            id: "\(source.label):tolaria", name: "tolaria", source: source, projectPath: nil,
            transport: .stdio, command: "node", args: ["server.js"], env: [:], url: nil, headers: [:]
        )
        return ServerSnapshot(config: cfg, state: state, failureReason: reason)
    }

    /// The grouping itself: three snapshots of one name → one group, broken because one is.
    func testGroupsCollapseByNameAndAggregate() {
        let snaps = [snap(.code, .healthy), snap(.desktop, .healthy), snap(.cursor, .broken, reason: "Timed out after 10s")]
        let groups = HealthMonitor.groupByName(snaps)
        XCTAssertEqual(groups.count, 1, "three instances of one name → one row")
        let g = groups[0]
        XCTAssertEqual(g.name, "tolaria")
        XCTAssertEqual(g.state, .broken, "broken in Cursor → group broken")
        XCTAssertEqual(g.variantCount, 3)
        XCTAssertEqual(Set(g.sourceLabels), ["Code", "Desktop", "Cursor"])
        XCTAssertEqual(g.issues.count, 1)
        XCTAssertEqual(g.issues.first?.label, "Cursor")
    }

    private func named(_ name: String, _ source: ServerSource, _ state: HealthState = .healthy) -> ServerSnapshot {
        let cfg = ServerConfig(
            id: "\(source.label):\(name)", name: name, source: source, projectPath: nil,
            transport: .stdio, command: "x", args: [], env: [:], url: nil, headers: [:]
        )
        return ServerSnapshot(config: cfg, state: state)
    }

    /// Every agent behind a merged row is kept, in discovery order: the row's
    /// badges and the detail card's "Used by" list both read from it.
    func testSourceSummaryListsEveryAgent() {
        let snaps = ["Code", "Claude Desktop", "Cursor", "Grok", "Goose", "Hermes"]
            .map { named("tolaria", ServerSource(label: $0)) }
        let g = HealthMonitor.groupByName(snaps)[0]
        XCTAssertEqual(g.sourceSummary, "Code · Claude Desktop · Cursor · Grok · Goose · Hermes")
    }

    /// The same MCP tool declared with different naming styles across agents
    /// (Goose writes `Chrome DevTools`, Cursor writes `chrome-devtools`) collapses
    /// to one row, shown under the canonical lowercase id.
    func testMergesAcrossCaseAndSeparators() {
        let snaps = [named("chrome-devtools", .cursor), named("Chrome DevTools", .goose)]
        let groups = HealthMonitor.groupByName(snaps)
        XCTAssertEqual(groups.count, 1, "same tool, different naming → one row")
        XCTAssertEqual(groups[0].name, "chrome-devtools", "prefer the canonical lowercase id")
        XCTAssertEqual(Set(groups[0].sourceLabels), ["Cursor", "Goose"])
        XCTAssertEqual(groups[0].variantCount, 2)
    }

    /// Case-only difference (`Pieces` vs `pieces`) merges; the most common id wins.
    func testMergesCaseOnlyDifference() {
        let snaps = [named("pieces", .grok), named("pieces", .code), named("Pieces", .goose)]
        let groups = HealthMonitor.groupByName(snaps)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "pieces")
        XCTAssertEqual(groups[0].variantCount, 3)
    }

    /// Genuinely different servers must NOT be merged by the normalization.
    func testDistinctServersStaySeparate() {
        let snaps = [named("color-palette", .code), named("codebase-memory-mcp", .cursor)]
        XCTAssertEqual(HealthMonitor.groupByName(snaps).count, 2)
    }

    func testNormalizedNameIgnoresCaseAndSeparators() {
        XCTAssertEqual(HealthMonitor.normalizedName("macOS Automator"),
                       HealthMonitor.normalizedName("macos-automator"))
        XCTAssertEqual(HealthMonitor.normalizedName("EventKit"),
                       HealthMonitor.normalizedName("eventkit"))
        XCTAssertNotEqual(HealthMonitor.normalizedName("fetch"),
                          HealthMonitor.normalizedName("fetcher"))
    }

    /// A merged row is named by its canonical id, so selection and pins key on it.
    func testMergedRowUsesCanonicalName() {
        let snaps = [named("chrome-devtools", .cursor), named("Chrome DevTools", .goose)]
        let g = HealthMonitor.groupByName(snaps)[0]
        XCTAssertEqual(g.name, "chrome-devtools")
    }

    /// The right-click "copy for Claude" text names the server, sources, error, and command.
    func testCopyTextIncludesErrorAndCommand() {
        let snaps = [snap(.code, .healthy), snap(.cursor, .broken, reason: "Timed out after 10s")]
        let g = HealthMonitor.groupByName(snaps)[0]
        let text = g.copyText
        XCTAssertTrue(text.contains("tolaria"), text)
        XCTAssertTrue(text.contains("Cursor"), text)
        XCTAssertTrue(text.contains("Timed out after 10s"), text)
        XCTAssertTrue(text.contains("node server.js"), "should include the command for context: \(text)")
    }

    /// A hidden name matches on the normalized key, so a case/separator variant is still hidden.
    func testIsHiddenMatchesOnNormalizedName() {
        let hidden: Set<String> = [HealthMonitor.normalizedName("Chrome DevTools")]
        XCTAssertTrue(HealthMonitor.isHidden("chrome-devtools", in: hidden))
        XCTAssertTrue(HealthMonitor.isHidden("Chrome DevTools", in: hidden))
        XCTAssertFalse(HealthMonitor.isHidden("pieces", in: hidden))
    }

    /// partition() splits groups into shown vs hidden by the normalized key.
    func testPartitionSplitsVisibleAndHidden() {
        let groups = HealthMonitor.groupByName(
            [named("pieces", .code), named("eventkit", .cursor)])
        let (visible, hidden) = HealthMonitor.partition(
            groups, hidden: [HealthMonitor.normalizedName("eventkit")])
        XCTAssertEqual(visible.map(\.name), ["pieces"])
        XCTAssertEqual(hidden.map(\.name), ["eventkit"])
    }

    /// The copied error report opens with LLM-facing framing so a paste is self-explanatory.
    func testCopyTextHasFramingPreamble() {
        let snaps = [snap(.cursor, .broken, reason: "Timed out after 10s")]
        let g = HealthMonitor.groupByName(snaps)[0]
        XCTAssertTrue(g.copyText.hasPrefix("This is an automated health report from mcpock"),
                      g.copyText)
        XCTAssertTrue(g.copyText.contains("MCP server: tolaria"), g.copyText)
    }
}
