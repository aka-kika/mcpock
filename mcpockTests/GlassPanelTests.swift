import AppKit
import XCTest
@testable import mcpock

/// 1.8: the Glass theme's own panel on macOS 27+ (`GlassPanelController`).
/// The window itself needs a real menu bar; these cover the pure parts.
final class GlassPanelTests: XCTestCase {
    /// Only Glass uses it, and only where the expanded-interface API exists.
    func testOnlyGlassUsesTheGlassPanel() {
        for theme in [AppTheme.system, .dark, .light] {
            XCTAssertFalse(GlassPanelStyle.usesGlassPanel(themeRaw: theme.rawValue), "\(theme) keeps MenuBarExtra")
        }
        XCTAssertFalse(GlassPanelStyle.usesGlassPanel(themeRaw: nil))
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            XCTAssertTrue(GlassPanelStyle.usesGlassPanel(themeRaw: AppTheme.glass.rawValue))
        } else {
            XCTAssertFalse(GlassPanelStyle.usesGlassPanel(themeRaw: AppTheme.glass.rawValue))
        }
        #else
        XCTAssertFalse(GlassPanelStyle.usesGlassPanel(themeRaw: AppTheme.glass.rawValue), "no macOS 27 SDK, no glass panel")
        #endif
    }

    /// Centered under the item, the top edge a small gap below it.
    func testFrameSitsCenteredUnderTheItem() {
        let anchor = NSRect(x: 1000, y: 1056, width: 40, height: 24)
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1050)
        let frame = GlassPanelStyle.frame(anchor: anchor, visible: visible, width: 380, height: 560)
        XCTAssertEqual(frame.midX, anchor.midX)
        XCTAssertEqual(frame.maxY, anchor.minY - GlassPanelStyle.menuBarGap)
        XCTAssertEqual(frame.size, NSSize(width: 380, height: 560))
    }

    /// An item near the right edge keeps the panel on screen, with a margin.
    func testFrameStaysInsideTheScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1050)
        let right = GlassPanelStyle.frame(
            anchor: NSRect(x: 1890, y: 1056, width: 24, height: 24), visible: visible, width: 380, height: 560)
        XCTAssertEqual(right.maxX, visible.maxX - GlassPanelStyle.screenMargin)
        let left = GlassPanelStyle.frame(
            anchor: NSRect(x: 4, y: 1056, width: 24, height: 24), visible: visible, width: 380, height: 560)
        XCTAssertEqual(left.minX, visible.minX + GlassPanelStyle.screenMargin)
    }

    /// ⌃⌥M (1.10) opens the panel on the screen the pointer is on: the item's
    /// copy there sits as far from that screen's right edge as the real one.
    func testShortcutAnchorMovesToTheOtherScreensMenuBar() {
        let home = NSRect(x: -320, y: 900, width: 1920, height: 1080)
        let target = NSRect(x: 0, y: 0, width: 1600, height: 900)
        let button = NSRect(x: 1151, y: 1950, width: 38, height: 30)
        let moved = GlassPanelStyle.anchor(button, movedFrom: home, to: target, top: 870)
        XCTAssertEqual(home.maxX - button.midX, target.maxX - moved.midX, "same distance from the right edge")
        XCTAssertEqual(moved.minY, 870, "just under the target's menu bar")
        XCTAssertEqual(moved.size, button.size)
    }
}

/// Escape in the glass panel: card, compare and search come first, then the
/// panel itself closes through `requestClose`.
@MainActor
final class PanelEscapeTests: XCTestCase {
    func testEscapeClosesThePanelOnlyWhenNothingElseWantsIt() {
        let suite = "mcpock.tests.escape.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        let state = PanelState(monitor: HealthMonitor(defaults: defaults), defaults: defaults)
        var closed = 0
        state.requestClose = { closed += 1 }

        state.openSearch()
        XCTAssertTrue(state.handleEscape())
        XCTAssertEqual(closed, 0, "the first Escape closes the search")
        XCTAssertTrue(state.handleEscape())
        XCTAssertEqual(closed, 1, "the next one closes the panel")
    }

    /// Under MenuBarExtra there is no `requestClose`: the Escape travels on,
    /// and the MenuBarExtra window closes itself.
    func testEscapeWithoutCloseRequestIsNotHandled() {
        let suite = "mcpock.tests.escape.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        let state = PanelState(monitor: HealthMonitor(defaults: defaults), defaults: defaults)
        XCTAssertFalse(state.handleEscape())
    }
}
