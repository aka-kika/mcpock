import XCTest
@testable import mcpock

/// The MenuBarExtra window is sized once and never resizes, and SwiftUI clips an
/// over-tall child instead of compressing it. So the v1.5 panel is a fixed
/// 380 × 560 built from fixed-height blocks, and the list gets exactly what the
/// chrome leaves. If a block grows without the list shrinking, rows fall off the
/// bottom of the panel; these catch that.
final class PanelLayoutTests: XCTestCase {
    func testPanelIsThreeEightyByFiveSixty() {
        XCTAssertEqual(MenuBarPanelView.panelWidth, 380)
        XCTAssertEqual(MenuBarPanelView.panelHeight, 560)
    }

    func testChromePlusListFillsThePanelExactlyWithSearchOpenOrClosed() {
        for open in [false, true] {
            XCTAssertEqual(
                MenuBarPanelView.chromeHeight(searchOpen: open) + MenuBarPanelView.listHeight(searchOpen: open),
                MenuBarPanelView.panelHeight,
                "search open \(open): the blocks must add up to the fixed panel height"
            )
        }
    }

    func testListKeepsItsMinimumWithSearchOpenOrClosed() {
        for open in [false, true] {
            XCTAssertGreaterThanOrEqual(
                MenuBarPanelView.listHeight(searchOpen: open), MenuBarPanelView.listMinHeight,
                "search open \(open): chrome must never squeeze the list below its minimum"
            )
        }
    }

    /// Opening the search takes exactly its own height from the list.
    func testSearchTakesItsHeightFromTheList() {
        XCTAssertEqual(
            MenuBarPanelView.listHeight(searchOpen: false) - MenuBarPanelView.listHeight(searchOpen: true),
            MenuBarPanelView.searchHeight
        )
    }

    /// Round 2: the tabs, the thin footer and two rules are all the chrome there is
    /// while the search is closed.
    func testClosedChromeIsTabsFooterAndRules() {
        XCTAssertEqual(MenuBarPanelView.chromeHeight(searchOpen: false), 42 + 30 + 2)
        XCTAssertEqual(MenuBarPanelView.listHeight(searchOpen: false), 486)
    }

    /// Four footer glyphs plus the summary fit the 380pt row, with room left for
    /// the compact summary text.
    func testFooterGlyphsLeaveRoomForTheSummary() {
        let glyphs = 4 * FooterGlyphButton.size + 3 * 4
        let padding: CGFloat = 14 + 8 + 6
        XCTAssertGreaterThanOrEqual(MenuBarPanelView.panelWidth - glyphs - padding, 230)
    }
}
