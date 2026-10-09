import XCTest
import SwiftUI
@testable import mcpock

/// Regression guard for the Settings-window crash (2026-08-03).
///
/// `SettingsLauncher` once set `hosting.sizingOptions = [.intrinsicContentSize,
/// .preferredContentSize]`, so **every** content-size change resized the window.
/// With a flexible dimension that closes a feedback loop — taller content →
/// taller window → content re-lays out → new intrinsic height → resize again —
/// until AppKit's loop guard throws `-[NSWindow _postWindowNeedsUpdateConstraints]`
/// and the process aborts. Adding icons to the Settings labels was enough to trip it.
///
/// The fix is a *fixed* content size in both dimensions, with each pane scrolling
/// its own overflow. These tests pin that invariant: if someone reintroduces
/// `minWidth`/`minHeight`, the size stops being constant across differing
/// content and the first test fails.
@MainActor
final class SettingsWindowSizingTests: XCTestCase {
    private func fittingSize(minHeight: CGFloat) -> CGSize {
        let root = SettingsView(monitor: nil, selection: SettingsSelection())
            .frame(width: SettingsLauncher.contentWidth)
            .frame(minHeight: minHeight)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
        return hosting.view.fittingSize
    }

    /// Width must be the pinned constant, and must not drift when the height
    /// constraint changes — that independence is what breaks the loop.
    func testContentWidthIsFixedRegardlessOfHeight() {
        let narrow = fittingSize(minHeight: 300)
        let tall = fittingSize(minHeight: 900)
        XCTAssertEqual(narrow.width, SettingsLauncher.contentWidth, accuracy: 0.5)
        XCTAssertEqual(tall.width, SettingsLauncher.contentWidth, accuracy: 0.5)
        XCTAssertEqual(narrow.width, tall.width, accuracy: 0.5,
                       "Settings width must not vary with content — see SettingsLauncher.open()")
    }

    /// The view pins its own height too, so a monitor that populates later can't
    /// change what the hosting view asks for.
    func testContentHeightIsFixed() {
        let hosting = NSHostingController(rootView: SettingsView(monitor: nil, selection: SettingsSelection()))
        let size = hosting.view.fittingSize
        XCTAssertEqual(size.width, SettingsLauncher.contentWidth, accuracy: 0.5)
        XCTAssertEqual(size.height, SettingsLauncher.frameHeight, accuracy: 0.5)
    }

    /// Round 8: wanted a narrower window once the panes became
    /// grouped forms and Servers' control became three icons.
    func testContentWidthIsTheNarrowerRound8Width() {
        XCTAssertGreaterThanOrEqual(SettingsLauncher.contentWidth, 520)
        XCTAssertLessThanOrEqual(SettingsLauncher.contentWidth, 560)
    }

    /// General should fit under the tab strip without scrolling — the form's
    /// own scrolling is a safety net for a bigger font, not the normal state.
    /// A grouped Form is scroll-backed, so this lays it out at the pane's real
    /// size and compares its scroll view's document with the visible area.
    func testGeneralPaneFitsWithoutScrolling() throws {
        let available = SettingsLauncher.frameHeight - SettingsTabStrip.height
        let pane = SettingsGeneralPane(monitor: nil, theme: ThemeColors.resolve(.dark))
            .frame(width: SettingsLauncher.contentWidth, height: available)
        let hosting = NSHostingView(rootView: pane)
        hosting.frame = NSRect(x: 0, y: 0, width: SettingsLauncher.contentWidth, height: available)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Closed by the test, released by ARC: not by AppKit too.
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let scroll = try XCTUnwrap(Self.scrollViews(in: hosting).first, "the form has a scroll view")
        let document = scroll.documentView?.frame.height ?? 0
        let visible = scroll.contentView.bounds.height
        XCTAssertGreaterThan(document, 100, "the form laid out")
        XCTAssertLessThanOrEqual(
            document, visible + 1,
            "General is \(document)pt but the pane shows \(visible)pt — it would open scrolled. "
            + "Trim a section or raise contentHeight."
        )
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scroll = view as? NSScrollView { found.append(scroll) }
        for subview in view.subviews { found += scrollViews(in: subview) }
        return found
    }

    /// The real repro: open the actual Settings window and pump the run loop so the
    /// display cycle runs. The abort was thrown from
    /// `-[NSWindow _postWindowNeedsUpdateConstraints]` during that cycle, so a test
    /// that only builds the view can't catch it — this one can. If the safe-area
    /// loop returns, this test takes the whole runner down with SIGABRT, which is
    /// exactly the signal we want.
    func testOpeningSettingsSurvivesTheDisplayCycle() {
        SettingsLauncher.open()
        pumpRunLoop()

        let settingsWindow = try? XCTUnwrap(NSApp.windows.first { $0.title == "mcpock Settings" })
        XCTAssertNotNil(settingsWindow, "Settings window should exist after open()")
        if let settingsWindow {
            XCTAssertEqual(settingsWindow.frame.width, SettingsLauncher.contentWidth, accuracy: 1.0)
            settingsWindow.close()
        }
    }

    /// v1.5: switching panes swaps the whole content under the tab strip (the
    /// Servers table is a very different height from General). The window must
    /// not move a point for any of them, and the pane asked for must be the one
    /// showing — including on a window that is already open.
    func testSwitchingTabsKeepsTheWindowSize() {
        SettingsLauncher.open(tab: .general)
        pumpRunLoop()
        guard let settingsWindow = NSApp.windows.first(where: { $0.title == "mcpock Settings" }) else {
            return XCTFail("Settings window should exist after open()")
        }
        defer { settingsWindow.close() }

        for tab in [SettingsTab.servers, .agents, .connect, .about, .general] {
            SettingsLauncher.open(tab: tab)
            pumpRunLoop()
            XCTAssertEqual(SettingsLauncher.selection.tab, tab)
            let content = settingsWindow.contentView?.frame.size ?? .zero
            XCTAssertEqual(content.width, SettingsLauncher.contentWidth, accuracy: 1.0,
                           "content width changed on the \(tab.title) pane")
            XCTAssertEqual(content.height, SettingsLauncher.frameHeight, accuracy: 1.0,
                           "content height changed on the \(tab.title) pane")
            XCTAssertEqual(settingsWindow.contentLayoutRect.height, SettingsLauncher.contentHeight, accuracy: 1.0,
                           "layout rect changed on the \(tab.title) pane")
        }
    }

    /// The tab strip draws the pane's name in the title-bar band, so its height
    /// must be the band AppKit actually reserves; if an OS release changes it,
    /// this points at `SettingsTabStrip.titleBarHeight`.
    func testTitleBandMatchesTheWindowsTitleBar() {
        SettingsLauncher.open()
        pumpRunLoop()
        guard let settingsWindow = NSApp.windows.first(where: { $0.title == "mcpock Settings" }) else {
            return XCTFail("Settings window should exist after open()")
        }
        defer { settingsWindow.close() }
        let titleBar = settingsWindow.frame.height - settingsWindow.contentLayoutRect.height
        XCTAssertEqual(titleBar, SettingsTabStrip.titleBarHeight, accuracy: 0.5)
        XCTAssertEqual(settingsWindow.contentView?.safeAreaInsets.top ?? 0, SettingsTabStrip.titleBarHeight, accuracy: 0.5)
    }

    /// Several turns: the loop guard trips during window layout, not on open().
    private func pumpRunLoop() {
        for _ in 0..<8 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
