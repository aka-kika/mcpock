import XCTest
@testable import mcpock

/// Panel state that must behave without a window: arrow-key stepping, the
/// remembered attention toggle, the search field, and Hide with its 5 s Undo. Each test uses its own
/// defaults suite (the test host is the app; `.standard` is the real prefs).
@MainActor
final class PanelStateTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "mcpock.tests.panelstate.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.retireSuite(named: suite)
        super.tearDown()
    }

    private func makeState() -> PanelState {
        PanelState(monitor: HealthMonitor(defaults: defaults), defaults: defaults)
    }

    func testArrowKeysStepAndStopAtTheEnds() {
        let names = ["a", "b", "c"]
        XCTAssertEqual(PanelState.nextSelection(in: names, from: "a", by: 1), "b")
        XCTAssertEqual(PanelState.nextSelection(in: names, from: "c", by: 1), "c", "no wrap past the end")
        XCTAssertEqual(PanelState.nextSelection(in: names, from: "a", by: -1), "a", "no wrap past the top")
        XCTAssertEqual(PanelState.nextSelection(in: names, from: "b", by: -1), "a")
    }

    func testArrowKeysStartAtTheFirstRow() {
        XCTAssertEqual(PanelState.nextSelection(in: ["a", "b"], from: nil, by: 1), "a")
        XCTAssertEqual(PanelState.nextSelection(in: ["a", "b"], from: "gone", by: -1), "a",
                       "a selection that left the list restarts at the top")
        XCTAssertNil(PanelState.nextSelection(in: [], from: nil, by: 1))
    }

    func testAttentionToggleIsRemembered() {
        let state = makeState()
        XCTAssertEqual(state.filter, .all, "first launch shows everything")
        state.toggleNeedsYou()
        XCTAssertEqual(state.filter, .problems)
        XCTAssertEqual(defaults.string(forKey: AppPreferences.panelFilterKey), "problems")
        XCTAssertEqual(makeState().filter, .problems, "survives a relaunch")
        state.toggleNeedsYou()
        XCTAssertEqual(state.filter, .all, "pressing it again goes back to All")
        XCTAssertEqual(makeState().filter, .all)
    }

    /// Round 1 had a Pinned chip; a saved "pinned" must not break the panel.
    func testSavedPinnedFilterReadsBackAsAll() {
        defaults.set("pinned", forKey: AppPreferences.panelFilterKey)
        XCTAssertEqual(makeState().filter, .all)
    }

    /// Something broken switches the panel to Needs you: on open, and on the
    /// first open after launch once the results arrive. A toggle she pressed in
    /// this panel session always wins.
    func testJumpToNeedsYouOnlyWhenBrokenAndNotPickedByHand() {
        XCTAssertTrue(PanelState.shouldJumpToNeedsYou(hasBroken: true, filter: .all, userPickedFilter: false))
        XCTAssertFalse(PanelState.shouldJumpToNeedsYou(hasBroken: false, filter: .all, userPickedFilter: false))
        XCTAssertFalse(PanelState.shouldJumpToNeedsYou(hasBroken: true, filter: .problems, userPickedFilter: false))
        XCTAssertFalse(PanelState.shouldJumpToNeedsYou(hasBroken: true, filter: .all, userPickedFilter: true),
                       "her own choice wins for the rest of the panel session")
    }

    func testPickedFilterResetsWhenThePanelOpensAgain() {
        let state = makeState()
        state.panelOpened()
        XCTAssertFalse(state.userPickedFilter)
        state.toggleNeedsYou()
        XCTAssertTrue(state.userPickedFilter)
        state.panelClosed()
        state.panelOpened()
        XCTAssertFalse(state.userPickedFilter, "a new panel session may jump again")
        state.panelClosed()
    }

    /// Round 8: the Agents tab starts with every agent closed; the one she
    /// opens stays open across panel closes and opens (this app session).
    func testOpenAgentIsKeptBetweenPanelOpens() {
        let state = makeState()
        state.panelOpened()
        XCTAssertNil(state.expandedAgent, "nothing starts open")
        state.toggleAgent("Grok", in: [])
        XCTAssertEqual(state.expandedAgent, "Grok")
        state.panelClosed()
        state.panelOpened()
        XCTAssertEqual(state.expandedAgent, "Grok", "still open on the next open")
        state.panelClosed()
    }

    // MARK: - Search

    func testSearchIsClosedByDefaultAndTogglesFromTheMagnifier() {
        let state = makeState()
        XCTAssertFalse(state.isSearchOpen)
        let request = state.searchFocusRequest
        state.toggleSearch()
        XCTAssertTrue(state.isSearchOpen)
        XCTAssertGreaterThan(state.searchFocusRequest, request, "opening asks the field for focus")
        state.query = "reed"
        state.toggleSearch()
        XCTAssertFalse(state.isSearchOpen)
        XCTAssertEqual(state.query, "", "closing clears, so a closed field never filters the list")
    }

    func testClosingThePanelClosesAndClearsTheSearch() {
        let state = makeState()
        state.panelOpened()
        state.openSearch()
        state.query = "wake"
        state.panelClosed()
        XCTAssertFalse(state.isSearchOpen)
        XCTAssertEqual(state.query, "")
    }

    func testRowClickOpensThenClosesTheCard() {
        let state = makeState()
        state.rowClicked("reed-md")
        XCTAssertEqual(state.selectedName, "reed-md")
        XCTAssertTrue(state.isCardOpen)
        state.rowClicked("reed-md")
        XCTAssertFalse(state.isCardOpen, "clicking the selected row again closes its card")
        XCTAssertEqual(state.selectedName, "reed-md", "…and keeps it selected")
        state.rowClicked("wake")
        XCTAssertEqual(state.selectedName, "wake")
        XCTAssertTrue(state.isCardOpen)
    }

    func testHideOffersUndoAndUndoBringsItBack() {
        let state = makeState()
        state.rowClicked("reed-md")
        state.hide("reed-md")
        XCTAssertTrue(state.monitor.isHidden("reed-md"))
        XCTAssertEqual(state.undoHideName, "reed-md")
        XCTAssertNil(state.selectedName, "a hidden row can't stay selected")
        XCTAssertFalse(state.isCardOpen)

        state.undoHide()
        XCTAssertFalse(state.monitor.isHidden("reed-md"))
        XCTAssertNil(state.undoHideName)
    }

    func testUndoOfferExpires() async throws {
        let state = makeState()
        state.hide("reed-md")
        XCTAssertNotNil(state.undoHideName)
        try await Task.sleep(for: .seconds(PanelState.undoSeconds + 0.5))
        XCTAssertNil(state.undoHideName, "Undo is only on offer for a few seconds")
        XCTAssertTrue(state.monitor.isHidden("reed-md"), "…and expiring never unhides")
    }

    // MARK: - Health bar animation (round 9)

    /// The Agents tab's health bar grows in exactly on the true -> false edge
    /// of `isRefreshing` — a full check finishing — and never on any other
    /// transition (starting a check, staying refreshing, staying idle).
    func testHealthBarGrowsOnlyWhenRefreshingFinishes() {
        XCTAssertTrue(PanelState.healthBarShouldGrow(wasRefreshing: true, isRefreshing: false),
                       "a full check finishing grows the bar")
        XCTAssertFalse(PanelState.healthBarShouldGrow(wasRefreshing: false, isRefreshing: true),
                        "a check starting does not")
        XCTAssertFalse(PanelState.healthBarShouldGrow(wasRefreshing: true, isRefreshing: true),
                        "still checking does not")
        XCTAssertFalse(PanelState.healthBarShouldGrow(wasRefreshing: false, isRefreshing: false),
                        "already idle does not")
    }

    /// The Agents tab's first real paint this launch (round 9b) grows the
    /// health bars, but only once, and only once there is something real to
    /// show; a peek before the first check finishes is skipped without
    /// spending that one-per-launch opportunity.
    func testHealthBarGrowsOnlyOnceForTheAgentsTabsFirstRealView() {
        XCTAssertTrue(PanelState.healthBarShouldGrowOnFirstAgentsView(
            hasShownAgentsTabOnce: false, hasCompletedFirstPass: true))
        XCTAssertFalse(PanelState.healthBarShouldGrowOnFirstAgentsView(
            hasShownAgentsTabOnce: false, hasCompletedFirstPass: false),
            "nothing real to grow yet")
        XCTAssertFalse(PanelState.healthBarShouldGrowOnFirstAgentsView(
            hasShownAgentsTabOnce: true, hasCompletedFirstPass: true),
            "already shown once this launch")
    }

    /// `agentsTabAppeared` opens the window exactly once, does not open it
    /// again on a later view, and a peek before results exist neither opens
    /// the window nor burns the one-per-launch opportunity — a later, real
    /// first view still gets it.
    func testAgentsTabAppearedOpensTheWindowOnceAndOnlyWithRealData() {
        let state = makeState()
        XCTAssertFalse(state.firstAgentsViewWindowOpen)
        XCTAssertFalse(state.hasShownAgentsTabOnce)

        state.agentsTabAppeared(hasCompletedFirstPass: false)
        XCTAssertFalse(state.firstAgentsViewWindowOpen, "nothing real yet")
        XCTAssertFalse(state.hasShownAgentsTabOnce, "so the opportunity is not spent")

        state.agentsTabAppeared(hasCompletedFirstPass: true)
        XCTAssertTrue(state.firstAgentsViewWindowOpen)
        XCTAssertTrue(state.hasShownAgentsTabOnce)

        state.closeFirstAgentsViewWindow()
        XCTAssertFalse(state.firstAgentsViewWindowOpen)

        state.agentsTabAppeared(hasCompletedFirstPass: true)
        XCTAssertFalse(state.firstAgentsViewWindowOpen, "a later view never reopens it")
    }

    /// Round 5: the Agents tab opens the card itself, so switching tabs drops
    /// the other tab's selection and card instead of carrying them over.
    func testSwitchingTabsClearsTheSelection() {
        let state = makeState()
        state.selectedName = "reed-md"
        state.isCardOpen = true
        state.tab = .servers
        XCTAssertNil(state.selectedName)
        XCTAssertFalse(state.isCardOpen)
        state.selectedName = "wake"
        state.tab = .servers
        XCTAssertEqual(state.selectedName, "wake", "picking the tab that is already showing changes nothing")
    }

    /// 1.5.4 ("by default it should open on the Agents tab, more
    /// impressive"): a fresh launch shows Agents. Not saved, so a tab she
    /// picks lasts until the app quits.
    func testThePanelOpensOnTheAgentsTab() {
        XCTAssertEqual(makeState().tab, .agents)
    }
}
