import XCTest
@testable import mcpock

/// The v1.5 panel reads like a dashboard: Needs you, then Pinned, then Everything
/// else. These cover the ordering, the Needs you filter and search. The search cases
/// at the bottom are carried over from the old `ServerFilterTests` (the footer
/// magnifier's filter), now matching tool names as well.
final class PanelSectionsTests: XCTestCase {
    private func group(
        _ name: String,
        _ state: HealthState = .healthy,
        sources: [String] = ["Code"],
        tools: [String] = [],
        differs: [String] = []
    ) -> ServerGroup {
        ServerGroup(
            name: name,
            state: state,
            sourceLabels: sources,
            tools: tools.map { MCPToolInfo(name: $0, description: "") },
            issues: [],
            variantCount: sources.count,
            differs: differs.map { DiffNote(label: $0, target: "x") }
        )
    }

    private func pinned(_ names: String...) -> Set<String> {
        Set(names.map(HealthMonitor.normalizedName))
    }

    private func build(
        _ groups: [ServerGroup],
        pinned: Set<String> = [],
        filter: PanelFilter = .all,
        query: String = ""
    ) -> [PanelSection] {
        PanelSections.build(groups: groups, pinned: pinned, filter: filter, query: query)
    }

    private func names(_ section: PanelSection?) -> [String] {
        section?.groups.map(\.name) ?? []
    }

    // MARK: - Sections and order

    func testSectionsComeInOrderAndEmptyOnesAreLeftOut() {
        let sections = build([group("b"), group("a", .broken), group("c")], pinned: pinned("c"))
        XCTAssertEqual(sections.map(\.kind), [.needsYou, .pinned, .everythingElse])

        let calm = build([group("a"), group("b")])
        XCTAssertEqual(calm.map(\.kind), [.everythingElse], "no problems, no pins: one section")
        XCTAssertTrue(build([]).isEmpty)
    }

    func testNeedsYouRanksBrokenDegradedDiffersThenName() {
        let groups = [
            group("mid", .healthy, differs: ["Grok"]),
            group("slow-b", .degraded),
            group("slow-a", .degraded),
            group("dead-z", .broken),
            group("dead-a", .broken),
            group("fine"),
        ]
        let needs = build(groups).first { $0.kind == .needsYou }
        XCTAssertEqual(names(needs), ["dead-a", "dead-z", "slow-a", "slow-b", "mid"])
    }

    /// Right after launch every server is unknown. They must not pile into Needs
    /// you as "Checking": each stays in its normal section, sorted by name with
    /// the rest, and a pinned one stays pinned.
    func testUnknownStaysInItsNormalSection() {
        let groups = [
            group("zeta", .unknown),
            group("alpha", .unknown),
            group("mid"),
            group("pin", .unknown),
            group("dead", .broken),
        ]
        let sections = build(groups, pinned: pinned("pin"))
        XCTAssertEqual(names(sections.first { $0.kind == .needsYou }), ["dead"])
        XCTAssertEqual(names(sections.first { $0.kind == .pinned }), ["pin"])
        XCTAssertEqual(names(sections.first { $0.kind == .everythingElse }), ["alpha", "mid", "zeta"])
        XCTAssertFalse(PanelSections.needsYou(group("x", .unknown)))

        let allUnknown = build([group("a", .unknown), group("b", .unknown)])
        XCTAssertEqual(allUnknown.map(\.kind), [.everythingElse], "a fresh launch has no Needs you section")
        XCTAssertTrue(build([group("a", .unknown)], filter: .problems).isEmpty)
    }

    func testPinnedProblemsStayInNeedsYouAndTheRestArePinnedByName() {
        let groups = [group("zed"), group("amp"), group("bad", .broken), group("other")]
        let sections = build(groups, pinned: pinned("zed", "amp", "bad"))
        XCTAssertEqual(names(sections.first { $0.kind == .needsYou }), ["bad"],
                       "a pinned server that breaks still shows under Needs you")
        XCTAssertEqual(names(sections.first { $0.kind == .pinned }), ["amp", "zed"])
        XCTAssertEqual(names(sections.first { $0.kind == .everythingElse }), ["other"])
    }

    func testPinnedIsMatchedOnTheNormalizedName() {
        let sections = build([group("Chrome DevTools")], pinned: ["chromedevtools"])
        XCTAssertEqual(sections.map(\.kind), [.pinned])
    }

    func testEverythingElseIsByNameWithSelfManagedAndPausedLast() {
        let groups = [
            group("quiet-b", .paused),
            group("zulu"),
            group("quiet-a", .selfManaged),
            group("alpha"),
        ]
        XCTAssertEqual(names(build(groups).first), ["alpha", "zulu", "quiet-a", "quiet-b"])
    }

    /// Differing only needs you when mcpock probes the server: a paused or
    /// self-managed row that differs stays in Everything else.
    func testDiffersOnlyNeedsYouForProbedServers() {
        let sections = build([group("p", .paused, differs: ["Grok"]), group("h", .healthy, differs: ["Grok"])])
        XCTAssertEqual(names(sections.first { $0.kind == .needsYou }), ["h"])
        XCTAssertEqual(names(sections.first { $0.kind == .everythingElse }), ["p"])
    }

    // MARK: - Filter (the attention toggle)

    func testProblemsFilterShowsOnlyNeedsYou() {
        let groups = [group("ok"), group("bad", .broken), group("pin")]
        let sections = build(groups, pinned: pinned("pin"), filter: .problems)
        XCTAssertEqual(sections.map(\.kind), [.needsYou])
        XCTAssertEqual(names(sections.first), ["bad"])
        XCTAssertTrue(build([group("ok")], filter: .problems).isEmpty)
    }

    /// Pinned servers keep their own section in the All view, and a pinned row
    /// that isn't a problem stays out of the Needs you view.
    func testPinnedSectionInAllButNotInNeedsYou() {
        let groups = [group("ok"), group("bad", .broken), group("pin")]
        XCTAssertEqual(build(groups, pinned: pinned("pin")).map(\.kind), [.needsYou, .pinned, .everythingElse])
        XCTAssertEqual(build(groups, pinned: pinned("pin"), filter: .problems).map(\.kind), [.needsYou])
    }

    func testWorstNeedsYouRank() {
        XCTAssertNil(PanelSections.worstNeedsYouRank([group("ok"), group("p", .paused)]))
        XCTAssertEqual(PanelSections.worstNeedsYouRank([group("ok"), group("d", differs: ["Grok"])]), 2)
        XCTAssertEqual(PanelSections.worstNeedsYouRank([group("s", .degraded), group("b", .broken)]), 0)
    }

    func testFilterRawValuesAreStable() {
        // The panel remembers the attention toggle by raw value.
        XCTAssertEqual(PanelFilter.allCases.map(\.rawValue), ["all", "problems"])
    }

    // MARK: - Search (carried over from ServerFilterTests)

    private var sample: [ServerGroup] {
        [
            group("reed-md", sources: ["Code", "Claude Desktop", "Grok"], tools: ["note_get_active"]),
            group("wigolo", sources: ["Code"]),
            group("notes-vault", sources: ["Cursor", "Goose"], tools: ["search_notes"]),
        ]
    }

    private func search(_ query: String) -> [String] {
        build(sample, query: query).flatMap(\.groups).map(\.name)
    }

    func testEmptyQueryReturnsEverything() {
        XCTAssertEqual(search("").count, 3)
        XCTAssertEqual(search("   ").count, 3, "whitespace-only is still an empty query")
    }

    func testMatchesOnServerName() {
        XCTAssertEqual(search("reed"), ["reed-md"])
    }

    /// Typing an agent name should surface everything that agent declares.
    func testMatchesOnSourceLabel() {
        XCTAssertEqual(search("cursor"), ["notes-vault"])
        XCTAssertEqual(Set(search("Code")), ["reed-md", "wigolo"])
    }

    /// The v1.5 field says "Search servers or tools".
    func testMatchesOnToolName() {
        XCTAssertEqual(search("search_notes"), ["notes-vault"])
        XCTAssertEqual(search("get_active"), ["reed-md"])
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(search("WIGOLO"), ["wigolo"])
        XCTAssertEqual(search("wIgOlO"), ["wigolo"])
    }

    func testSubstringAnywhereMatches() {
        XCTAssertEqual(search("vault"), ["notes-vault"])
    }

    func testNoMatchesReturnsEmpty() {
        XCTAssertTrue(search("zzzz").isEmpty)
        XCTAssertTrue(build(sample, query: "zzzz").isEmpty, "no empty sections either")
    }
}
