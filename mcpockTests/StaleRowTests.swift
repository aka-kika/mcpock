import XCTest
@testable import mcpock

/// The "stale row" bug (HANDOFF Gotchas, TODO "Stale row after a section
/// move"): a server that moved from "Everything else" into "Needs you" while
/// the panel was open kept its old unknown ring and no note until a tab
/// switch rebuilt the list. The data was always right (`HealthMonitor` and
/// the status file); only the row's rendering lagged.
///
/// Root cause: `serverList`'s two nested `ForEach`s (sections, then that
/// section's groups) flatten into one list of rows inside a single
/// `LazyVStack`. The row carried `.id(group.name)`, the same explicit
/// identity whichever section it was in. When a group crossed from
/// "Everything else" into "Needs you", the `LazyVStack` saw the *same* id
/// relocate rather than a new one appear, and (this is the documented
/// `LazyVStack` hazard) sometimes reused the old row instead of asking for a
/// fresh one built from the group's current state.
///
/// The fix folds the section into the id (`MenuBarPanelView.rowID`), so a
/// cross-section move is a *different* id: the old row is removed and the
/// new one is always built fresh. These tests pin that: they don't render
/// SwiftUI (there's no rendering harness in this target), but they prove the
/// property the fix depends on — a server's row id changes exactly when, and
/// only when, it changes section — using the same `PanelSections.build` the
/// real panel calls. If someone reverts to a bare `.id(group.name)`, this
/// file won't catch that directly (it tests the id function, not the view),
/// but `testRowIDIsSectionQualified` pins the id's actual shape so a
/// regression to `name` alone fails immediately.
final class StaleRowTests: XCTestCase {
    private func group(
        _ name: String,
        _ state: HealthState = .healthy,
        differs: [String] = []
    ) -> ServerGroup {
        ServerGroup(
            name: name,
            state: state,
            sourceLabels: ["Code"],
            tools: [],
            issues: [],
            variantCount: 1,
            differs: differs.map { DiffNote(label: $0, target: "x") }
        )
    }

    /// The id is section-qualified, not just the name (the exact regression:
    /// a bare `group.name` id is what let the `LazyVStack` conflate two
    /// sections' rows).
    func testRowIDIsSectionQualified() {
        let id = MenuBarPanelView.rowID(section: .needsYou, name: "reed-md")
        XCTAssertEqual(id, "needsYou|reed-md")
        XCTAssertNotEqual(id, "reed-md", "a bare name id is exactly the bug this test guards against")
    }

    /// Same server, three different sections: three different ids. This is
    /// the property the fix relies on — whichever section a row is in, its
    /// id says so, so the `LazyVStack` can never mistake one section's row
    /// for another's.
    func testSameNameGetsADifferentIDPerSection() {
        let ids = PanelSection.Kind.allKinds.map { MenuBarPanelView.rowID(section: $0, name: "reed-md") }
        XCTAssertEqual(Set(ids).count, ids.count, "every section must give the server a distinct id")
    }

    /// The forward direction from the bug report: a server that was fine
    /// (Everything else) breaks while the panel is open and moves into Needs
    /// you. Its id before and after the move must differ, so the `LazyVStack`
    /// treats it as a fresh row rather than an update-in-place of the old one.
    func testServerMovingIntoNeedsYouGetsANewRowID() {
        let before = PanelSections.build(groups: [group("reed-md")], pinned: [], filter: .all, query: "")
        let idBefore = MenuBarPanelView.rowID(forName: "reed-md", in: before)
        XCTAssertEqual(idBefore, "everythingElse|reed-md")

        let after = PanelSections.build(groups: [group("reed-md", .broken)], pinned: [], filter: .all, query: "")
        let idAfter = MenuBarPanelView.rowID(forName: "reed-md", in: after)
        XCTAssertEqual(idAfter, "needsYou|reed-md")

        XCTAssertNotEqual(idBefore, idAfter, "a section move must change the row's identity")
    }

    /// The reverse direction: "Mark as intended" moves a row *out* of Needs
    /// you. Same requirement, the other way.
    func testServerLeavingNeedsYouAfterMarkedAsIntendedGetsANewRowID() {
        let before = PanelSections.build(
            groups: [group("reed-md", differs: ["Grok"])], pinned: [], filter: .all, query: ""
        )
        let idBefore = MenuBarPanelView.rowID(forName: "reed-md", in: before)
        XCTAssertEqual(idBefore, "needsYou|reed-md")

        // Marking as intended empties `differs` for a matching row (Differs.swift);
        // simulated here by building from a group with no differs note left.
        let after = PanelSections.build(groups: [group("reed-md")], pinned: [], filter: .all, query: "")
        let idAfter = MenuBarPanelView.rowID(forName: "reed-md", in: after)
        XCTAssertEqual(idAfter, "everythingElse|reed-md")

        XCTAssertNotEqual(idBefore, idAfter)
    }

    /// A server pinned *and* broken lives in Needs you, not Pinned (pinned
    /// problems still surface top); unpinning or fixing it moves it again.
    /// Every leg of that trip must be a distinct id.
    func testPinnedServerMovingThroughAllThreeSections() {
        let pinned = Set([HealthMonitor.normalizedName("reed-md")])

        let brokenAndPinned = PanelSections.build(
            groups: [group("reed-md", .broken)], pinned: pinned, filter: .all, query: ""
        )
        XCTAssertEqual(MenuBarPanelView.rowID(forName: "reed-md", in: brokenAndPinned), "needsYou|reed-md")

        let fixedAndPinned = PanelSections.build(
            groups: [group("reed-md")], pinned: pinned, filter: .all, query: ""
        )
        XCTAssertEqual(MenuBarPanelView.rowID(forName: "reed-md", in: fixedAndPinned), "pinned|reed-md")

        let fixedAndUnpinned = PanelSections.build(
            groups: [group("reed-md")], pinned: [], filter: .all, query: ""
        )
        XCTAssertEqual(MenuBarPanelView.rowID(forName: "reed-md", in: fixedAndUnpinned), "everythingElse|reed-md")
    }

    /// `scrollTo` must find the row where it actually lives today; a name
    /// that isn't in any visible section (hidden, or filtered by the search
    /// or the attention toggle) has no id to scroll to.
    func testRowIDForNameIsNilWhenTheNameIsntShown() {
        let sections = PanelSections.build(groups: [group("reed-md")], pinned: [], filter: .all, query: "")
        XCTAssertNil(MenuBarPanelView.rowID(forName: "not-there", in: sections))
    }
}

private extension PanelSection.Kind {
    static let allKinds: [PanelSection.Kind] = [.needsYou, .pinned, .everythingElse]
}
