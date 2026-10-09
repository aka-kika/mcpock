import XCTest
@testable import mcpock

/// The footer's compact summary, the full sentence in its tooltip and
/// "Checked 1 min ago" (v1.5 spec, Phase 2; round 2 footer).
final class PanelTextTests: XCTestCase {
    private func group(
        _ name: String,
        _ state: HealthState = .healthy,
        reason: String? = nil,
        differs: Bool = false,
        checked: Date? = nil
    ) -> ServerGroup {
        let issues = reason.map { [ServerIssue(label: "Code", reason: $0, command: "x")] } ?? []
        return ServerGroup(
            name: name, state: state, sourceLabels: ["Code"], tools: [], issues: issues,
            variantCount: 1,
            differs: differs ? [DiffNote(label: "Grok", target: "y")] : [],
            lastChecked: checked
        )
    }

    func testAllFineWhenNothingNeedsYou() {
        let groups = (1...19).map { group("s\($0)") }
        XCTAssertEqual(PanelText.summary(groups), "19 servers \u{00B7} all fine")
    }

    func testSingularServer() {
        XCTAssertEqual(PanelText.summary([group("a")]), "1 server \u{00B7} all fine")
    }

    func testPartsInOrderAndZeroPartsLeftOut() {
        let groups = [
            group("a", .broken, reason: "Non-zero exit (1)"),
            group("b", .degraded, reason: "Timed out after 10s"),
            group("c", differs: true),
            group("d"),
        ]
        XCTAssertEqual(PanelText.summary(groups),
                       "4 servers \u{00B7} 1 broken \u{00B7} 1 slow \u{00B7} 1 set up differently")
    }

    func testSignInCountsSeparatelyFromSlow() {
        let groups = [
            group("a", .degraded, reason: "Needs authentication (HTTP 401)"),
            group("b", .degraded, reason: "Needs authentication (HTTP 403)"),
        ]
        XCTAssertEqual(PanelText.summary(groups), "2 servers \u{00B7} 2 need sign-in")
    }

    func testUnknownReadsAsChecking() {
        XCTAssertEqual(PanelText.summary([group("a", .unknown), group("b")]),
                       "2 servers \u{00B7} 1 checking")
    }

    /// While the first check after launch runs, the line says so up front instead
    /// of counting unknowns or claiming "all fine", but keeps what it already found.
    func testFirstPassSaysChecking() {
        XCTAssertEqual(PanelText.summary([group("a", .unknown), group("b", .unknown)], firstPass: true),
                       "Checking\u{2026} \u{00B7} 2 servers")
        XCTAssertEqual(PanelText.summary([group("a", .broken, reason: "Non-zero exit (1)"), group("b"),
                                          group("c", .unknown)], firstPass: true),
                       "Checking\u{2026} \u{00B7} 3 servers \u{00B7} 1 broken")
        XCTAssertEqual(PanelText.summary([], firstPass: true), "Checking\u{2026}",
                       "discovery hasn't found anything yet")
        XCTAssertEqual(PanelText.summary([]), "No servers found")
    }

    /// A paused or self-managed row that differs isn't mcpock's business.
    func testQuietRowsNeverCount() {
        XCTAssertEqual(PanelText.summary([group("a", .paused, differs: true), group("b", .selfManaged)]),
                       "2 servers \u{00B7} all fine")
    }

    func testNoServers() {
        XCTAssertEqual(PanelText.summary([]), "No servers found")
    }

    // MARK: - Footer summary (round 2)

    /// Her example: the count, then only what needs you, in short words.
    func testCompactSummaryIsShortEnoughForTheFooter() {
        let groups = [
            group("a", .broken, reason: "Non-zero exit (1)"),
            group("b", .broken, reason: "Non-zero exit (1)"),
            group("c", .broken, reason: "Non-zero exit (1)"),
            group("d", .degraded, reason: "Needs authentication (HTTP 401)"),
            group("e", differs: true),
            group("f", differs: true),
        ] + (1...38).map { group("ok\($0)") }
        XCTAssertEqual(PanelText.compactSummary(groups), "44 \u{00B7} 3 broken \u{00B7} 1 sign-in \u{00B7} 2 differ")
    }

    func testCompactSummaryAllFine() {
        XCTAssertEqual(PanelText.compactSummary((1...44).map { group("s\($0)") }), "44 servers, all fine")
        XCTAssertEqual(PanelText.compactSummary([group("a")]), "1 server, all fine")
        XCTAssertEqual(PanelText.compactSummary([]), "No servers found")
    }

    func testCompactSummaryWordsEachPart() {
        let groups = [
            group("a", .degraded, reason: "Timed out after 10s"),
            group("b", differs: true),
            group("c", .unknown),
        ]
        XCTAssertEqual(PanelText.compactSummary(groups), "3 \u{00B7} 1 slow \u{00B7} 1 differs \u{00B7} 1 checking")
    }

    /// While any check runs (the first pass included) the footer says so and
    /// nothing else; the refresh glyph spins beside it.
    func testCompactSummaryWhileChecking() {
        XCTAssertEqual(PanelText.compactSummary([group("a", .broken)], checking: true), "Checking\u{2026}")
        XCTAssertEqual(PanelText.compactSummary([], checking: true), "Checking\u{2026}")
    }

    func testFooterTooltipHasTheFullSentenceAndWhenItWasChecked() {
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        let groups = [group("a", .degraded, reason: "Needs authentication (HTTP 401)"), group("b")]
        XCTAssertEqual(
            PanelText.footerTooltip(groups, firstPass: false, lastChecked: now.addingTimeInterval(-90),
                                    hiddenCount: 2, now: now),
            "2 servers \u{00B7} 1 needs sign-in\nChecked 1 min ago \u{00B7} 2 hidden"
        )
    }

    func testCheckedAgo() {
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        XCTAssertEqual(PanelText.checkedAgo(nil, now: now), "Not checked yet")
        XCTAssertEqual(PanelText.checkedAgo(now.addingTimeInterval(-20), now: now), "Checked just now")
        XCTAssertEqual(PanelText.checkedAgo(now.addingTimeInterval(-61), now: now), "Checked 1 min ago")
        XCTAssertEqual(PanelText.checkedAgo(now.addingTimeInterval(-59 * 60), now: now), "Checked 59 min ago")
        XCTAssertEqual(PanelText.checkedAgo(now.addingTimeInterval(-3 * 3600), now: now), "Checked 3 h ago")
        XCTAssertEqual(PanelText.checkedAgo(now.addingTimeInterval(-50 * 3600), now: now), "Checked 2 days ago")
        XCTAssertEqual(PanelText.checkedAgo(now.addingTimeInterval(30), now: now), "Checked just now",
                       "a clock that moved backwards never reads negative")
    }

    func testFooterAddsHiddenCountOnlyWhenThereAreAny() {
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        let checked = now.addingTimeInterval(-90)
        XCTAssertEqual(PanelText.footer(lastChecked: checked, hiddenCount: 0, now: now), "Checked 1 min ago")
        XCTAssertEqual(PanelText.footer(lastChecked: checked, hiddenCount: 2, now: now),
                       "Checked 1 min ago \u{00B7} 2 hidden")
    }

    func testNewestCheckAcrossRows() {
        let old = Date(timeIntervalSinceReferenceDate: 1_000)
        let new = Date(timeIntervalSinceReferenceDate: 2_000)
        XCTAssertEqual(ServerGroup.newestCheck([group("a", checked: old), group("b", checked: new), group("c")]), new)
        XCTAssertNil(ServerGroup.newestCheck([group("a")]))
    }

    func testDisplayLabelSpellsOutClaudeCode() {
        XCTAssertEqual(AgentBadge.displayLabel("Code"), "Claude Code")
        XCTAssertEqual(AgentBadge.displayLabel("Code (MyApp)"), "Claude Code (MyApp)")
        XCTAssertEqual(AgentBadge.displayLabel("VS Code"), "VS Code", "VS Code must never become Claude Code")
        XCTAssertEqual(AgentBadge.displayLabel("Hermes \u{00B7} scribe"), "Hermes \u{00B7} scribe")
    }
}
