import XCTest
import AppKit
@testable import mcpock

/// The detail card's wording and placement (v1.5 spec, Phase 3).
final class CardTextTests: XCTestCase {
    private func source(
        _ label: String,
        target: String = "npx server",
        transport: TransportKind = .stdio,
        path: String = "",
        env: [String] = [],
        headers: [String] = [],
        state: HealthState = .healthy
    ) -> GroupSource {
        GroupSource(
            configID: "\(label)-\(target)", label: label,
            agent: label.components(separatedBy: " (").first ?? label,
            path: path, transport: transport, target: target,
            envKeys: env, headerKeys: headers, state: state, failureReason: nil
        )
    }

    private func group(
        _ state: HealthState = .healthy,
        tools: Int = 0,
        sources: [GroupSource],
        differs: [String] = [],
        issues: [ServerIssue] = [],
        checked: Date? = nil
    ) -> ServerGroup {
        ServerGroup(
            name: "firecrawl", state: state, sourceLabels: sources.map(\.label),
            tools: (0..<tools).map { MCPToolInfo(name: "t\($0)", description: "") },
            issues: issues, variantCount: sources.count,
            differs: differs.map { label in DiffNote(label: label, target: sources.first { $0.label == label }?.target ?? "") },
            sources: sources, lastChecked: checked
        )
    }

    // MARK: Sub line

    func testSubLine() {
        let now = Date(timeIntervalSinceReferenceDate: 50_000)
        let g = group(tools: 14, sources: [source("Code")], checked: now.addingTimeInterval(-70))
        XCTAssertEqual(CardText.subLine(for: g, now: now), "14 tools \u{00B7} stdio \u{00B7} checked 1 min ago")
    }

    func testSubLineNamesBothTransportsWhenAgentsDisagree() {
        let g = group(tools: 1, sources: [source("Code"), source("Grok", target: "http://x", transport: .http)])
        XCTAssertEqual(CardText.subLine(for: g, now: Date()), "1 tool \u{00B7} stdio / http \u{00B7} not checked yet")
    }

    func testSubLineForQuietRows() {
        XCTAssertEqual(CardText.subLine(for: group(.paused, sources: [source("Code")]), now: Date()),
                       "No tools yet \u{00B7} stdio \u{00B7} paused")
        XCTAssertEqual(CardText.subLine(for: group(.selfManaged, sources: [source("MiniMax")]), now: Date()),
                       "No tools yet \u{00B7} stdio \u{00B7} not checked by mcpock")
    }

    // MARK: Used by

    /// A server used by many agents shows four rows and "+n more"; the rows that
    /// explain a problem (the odd one out, then the failing ones) come first so
    /// they are never the ones folded away.
    func testUsedByShowsFourAndFoldsTheRest() {
        let labels = ["Code", "Claude Desktop", "Cursor", "Goose", "Hermes", "Kimi Code", "Grok"]
        var sources = labels.map { source($0) }
        sources[5] = source("Kimi Code", state: .broken)
        sources[6] = source("Grok", target: "npx other")
        let g = group(sources: sources, differs: ["Grok"])

        let folded = CardText.usedByRows(for: g, expanded: false)
        XCTAssertEqual(folded.rows.map(\.label), ["Grok", "Kimi Code", "Code", "Claude Desktop"])
        XCTAssertEqual(folded.folded, 3)

        let open = CardText.usedByRows(for: g, expanded: true)
        XCTAssertEqual(open.rows.count, 7)
        XCTAssertEqual(open.folded, 0)
    }

    func testUsedByFewSourcesNeverFold() {
        let g = group(sources: ["Code", "Cursor", "Grok", "Goose"].map { source($0) })
        let rows = CardText.usedByRows(for: g, expanded: false)
        XCTAssertEqual(rows.rows.map(\.label), ["Code", "Cursor", "Grok", "Goose"], "discovery order when nothing stands out")
        XCTAssertEqual(rows.folded, 0)
    }

    func testShortTargetShortensHomeEverywhere() {
        XCTAssertEqual(CardText.shortTarget("/Users/k/.node/bin/node /Users/k/apps/x/server.mjs", home: "/Users/k"),
                       "~/.node/bin/node ~/apps/x/server.mjs")
        XCTAssertEqual(CardText.shortTarget("https://example.com/mcp", home: "/Users/k"), "https://example.com/mcp")
    }

    // MARK: Why box

    func testWhyTitleAndLines() {
        let issues = [ServerIssue(label: "Code", reason: "Non-zero exit (127)", command: "x"),
                      ServerIssue(label: "Cursor", reason: "Spawn error: Command not found", command: "x")]
        let broken = group(.broken, sources: [source("Code"), source("Cursor")], issues: issues)
        XCTAssertEqual(CardText.whyTitle(for: broken), "Why it is broken")
        XCTAssertEqual(CardText.whyLines(for: broken),
                       ["Claude Code: Non-zero exit (127)", "Cursor: Spawn error: Command not found"])

        let auth = group(.degraded, sources: [source("Code")],
                         issues: [ServerIssue(label: "Code", reason: "Needs authentication (HTTP 401)", command: "")])
        XCTAssertEqual(CardText.whyTitle(for: auth), "Why it needs sign-in")
        let slow = group(.degraded, sources: [source("Code")],
                         issues: [ServerIssue(label: "Code", reason: "Timed out after 10s", command: "")])
        XCTAssertEqual(CardText.whyTitle(for: slow), "Why it is slow")
    }

    // MARK: Differs

    func testDiffersSentenceNamesTheOddOneOutAgainstTheRest() {
        let g = group(sources: [
            source("Code", target: "https://a", transport: .http),
            source("Cursor", target: "https://a", transport: .http),
            source("Grok", target: "https://b", transport: .http),
        ], differs: ["Grok"])
        XCTAssertEqual(CardText.differsSentence(for: g),
                       "Grok points at a different address than Claude Code and Cursor.")
    }

    func testDiffersSentenceForCommands() {
        let g = group(sources: [source("Code"), source("Cursor"), source("Goose", target: "uvx other")],
                      differs: ["Goose"])
        XCTAssertEqual(CardText.differsSentence(for: g),
                       "Goose points at a different command than Claude Code and Cursor.")
    }

    /// A 2-vs-2 split has no majority; the sentence says how the agents split.
    func testDiffersSentenceWithoutAMajorityDescribesTheCamps() {
        let g = group(sources: [
            source("Cursor", target: "node a"), source("Grok", target: "node a"),
            source("Hermes", target: "npx b"), source("mcporter", target: "npx b"),
        ], differs: ["Cursor", "Grok", "Hermes", "mcporter"])
        XCTAssertEqual(CardText.differsSentence(for: g),
                       "Cursor and Grok use one command, Hermes and mcporter another.")
    }

    func testDiffersSentenceOneVersusOne() {
        let g = group(sources: [source("Code", target: "a"), source("Grok", target: "b")],
                      differs: ["Code", "Grok"])
        XCTAssertEqual(CardText.differsSentence(for: g), "Claude Code uses one command, Grok another.")
    }

    func testDiffersSentenceEmptyWhenTheSetupsAgree() {
        XCTAssertEqual(CardText.differsSentence(for: group(sources: [source("Code"), source("Cursor")])), "")
    }

    func testDiffersLineSeenFromEachAgent() {
        let g = group(sources: [
            source("Code", target: "https://a", transport: .http),
            source("Grok", target: "https://b", transport: .http),
            source("Cursor", target: "https://a", transport: .http),
        ], differs: ["Grok"])
        XCTAssertEqual(CardText.differsLine(for: g, agent: "Grok"), "Points at a different address than the others")
        XCTAssertEqual(CardText.differsLine(for: g, agent: "Code"), "Grok has a different setup")
    }

    // MARK: Used by, paths, masking

    func testUsedByCountsAgentsNotDeclarations() {
        let g = group(sources: [source("Code (AppA)"), source("Code (AppB)"), source("Cursor")])
        XCTAssertEqual(CardText.usedByTitle(for: g), "Used by \u{00B7} 2 agents")
        XCTAssertEqual(CardText.usedByTitle(for: group(sources: [source("Code")])), "Used by \u{00B7} 1 agent")
    }

    func testShortPathUsesTilde() {
        XCTAssertEqual(CardText.shortPath("/Users/me/.cursor/mcp.json", home: "/Users/me"), "~/.cursor/mcp.json")
        XCTAssertEqual(CardText.shortPath("/Users/meother/x.json", home: "/Users/me"), "/Users/meother/x.json",
                       "a sibling folder with the same prefix is not home")
        XCTAssertEqual(CardText.shortPath("/etc/x.json", home: "/Users/me"), "/etc/x.json")
    }

    func testSecretsAreMasked() {
        XCTAssertEqual(CardText.maskedEnv(["API_KEY"]), ["API_KEY=\u{2022}\u{2022}\u{2022}\u{2022}"])
        XCTAssertEqual(CardText.maskedHeaders(["Authorization"]), ["Authorization: \u{2022}\u{2022}\u{2022}\u{2022}"])
    }

    func testList() {
        XCTAssertEqual(CardText.list([]), "")
        XCTAssertEqual(CardText.list(["A"]), "A")
        XCTAssertEqual(CardText.list(["A", "B"]), "A and B")
        XCTAssertEqual(CardText.list(["A", "B", "C"]), "A, B and C")
    }

    /// Round 6: Check again, Pin/Unpin and Hide are icons; the words live on as
    /// tooltip and accessibility label.
    func testCardActionIconsAndWords() {
        XCTAssertEqual(CardAction.checkAgain.systemImage, "arrow.clockwise")
        XCTAssertEqual(CardAction.pin.systemImage, "pin")
        XCTAssertEqual(CardAction.unpin.systemImage, "pin.slash")
        XCTAssertEqual(CardAction.hide.systemImage, "eye.slash")
        XCTAssertEqual(CardAction.allCases.map(\.title), ["Check again", "Resume", "Pin", "Unpin", "Hide"])
        for action in CardAction.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil), action.title)
        }
    }

    // MARK: Tools list (1.5.3)

    func testToolsShowTheFirstFiveThenShowMore() {
        let many = group(tools: 12, sources: [source("Code")])
        let folded = CardText.toolRows(for: many, expanded: false)
        XCTAssertEqual(folded.rows.map(\.name), ["t0", "t1", "t2", "t3", "t4"], "the server's own order")
        XCTAssertEqual(folded.folded, 7)
        XCTAssertEqual(CardText.showMoreHelp(folded: folded.folded), "Show 7 more tools")
        XCTAssertEqual(CardText.showMoreHelp(folded: 1), "Show 1 more tool")
        let open = CardText.toolRows(for: many, expanded: true)
        XCTAssertEqual(open.rows.count, 12, "Show more lists every tool in place")
        XCTAssertEqual(open.folded, 0)

        let few = group(tools: 5, sources: [source("Code")])
        XCTAssertEqual(CardText.toolRows(for: few, expanded: false).rows.count, 5)
        XCTAssertEqual(CardText.toolRows(for: few, expanded: false).folded, 0, "five or fewer: no Show more")
        XCTAssertEqual(CardText.showMoreTitle(folded: 7), "+7 more")
        XCTAssertEqual(CardText.showLessTitle, "Show less")
    }
}

/// Where the card window goes (`DetailCardPresenter.frame`): left of the panel,
/// top edges aligned, 10pt gap; right when the left has no room; never taller
/// than the panel.
final class DetailCardPlacementTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1920, height: 1055)
    private let panel = NSRect(x: 1400, y: 470, width: 380, height: 560)

    func testCardSitsLeftOfThePanelTopAligned() {
        let frame = DetailCardPresenter.frame(besides: panel, contentHeight: 300, screen: screen)
        XCTAssertEqual(frame.maxX, panel.minX - DetailCardPresenter.gap)
        XCTAssertEqual(frame.width, DetailCardPresenter.width)
        XCTAssertEqual(frame.maxY, panel.maxY, "top edges aligned")
        XCTAssertEqual(frame.height, 300, "fitted to its content")
    }

    func testCardNeverGrowsPastThePanel() {
        let frame = DetailCardPresenter.frame(besides: panel, contentHeight: 2000, screen: screen)
        XCTAssertEqual(frame.height, panel.height)
        XCTAssertEqual(frame.maxY, panel.maxY)
    }

    func testCardMovesRightWhenTheLeftHasNoRoom() {
        let leftPanel = NSRect(x: 100, y: 470, width: 380, height: 560)
        let frame = DetailCardPresenter.frame(besides: leftPanel, contentHeight: 300, screen: screen)
        XCTAssertEqual(frame.minX, leftPanel.maxX + DetailCardPresenter.gap)
    }

    func testCardClampsToTheScreenWhenNeitherSideFits() {
        let narrow = NSRect(x: 0, y: 0, width: 700, height: 1055)
        let middle = NSRect(x: 200, y: 470, width: 380, height: 560)
        let frame = DetailCardPresenter.frame(besides: middle, contentHeight: 300, screen: narrow)
        XCTAssertEqual(frame.minX, narrow.minX)
    }
}
