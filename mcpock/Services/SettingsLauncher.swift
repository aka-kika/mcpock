import AppKit
import SwiftUI

/// Presents Settings as a real NSWindow.
/// Menu-bar (LSUIElement) apps often fail to surface SwiftUI's `Settings` scene via
/// `showSettingsWindow:` / `openSettings` — owning the window is reliable.
@MainActor
enum SettingsLauncher {
    private static var window: NSWindow?

    /// The app's single health monitor, set once at launch so Settings' Export can
    /// read the current errors regardless of which entry point opened the window.
    static weak var monitor: HealthMonitor?

    /// The app's Sparkle updater (round 10), set once at launch, same pattern as
    /// `monitor`. Settings > About reads it for the "Check for Updates…" button
    /// and the automatic-checks toggle; `StatusItemRightClick`'s menu reuses it
    /// too rather than holding a second weak reference to the same object.
    static weak var updateController: UpdateController?

    /// Which pane the window shows. Kept here, not in the view, so `open(tab:)`
    /// can switch a window that is already open and a reopened window keeps
    /// its last pane.
    static let selection = SettingsSelection()

    /// Settings' fixed content size. v1.5 round 8: 540 wide (was 640) now that
    /// the panes are grouped forms and Servers' Pinned | Shown | Hidden control
    /// is three icons; 580 tall so General's three sections fit unscrolled (with room for the export note). The
    /// tab strip takes `SettingsTabStrip.height` of it; the pane below gets the
    /// rest and scrolls past it.
    /// **Both must stay fixed** — a flexible dimension here reopens the
    /// constraint-update loop described in `open()`.
    /// `SettingsWindowSizingTests.testGeneralPaneFitsWithoutScrolling` fails
    /// if a new General section pushes its content past this.
    static let contentWidth: CGFloat = 540
    // 1.7: +40 for General's new "Usage" row (Off | 7 days | 30 days | All time).
    // 1.10: +40 for "Open with ⌃⌥M" (`GlobalHotKey`).
    static let contentHeight: CGFloat = 660
    /// What the SwiftUI root fills: AppKit's content size is the layout rect
    /// *below* the title bar even with `.fullSizeContentView`, and the root runs
    /// under that bar too (the tab strip's title band), so it is that much taller.
    static let frameHeight: CGFloat = contentHeight + SettingsTabStrip.titleBarHeight

    /// Open (or bring forward) Settings. `tab` switches the pane; `nil` keeps
    /// whatever the window showed last.
    static func open(tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }

        // Agent apps need activation or the window appears behind everything / not at all.
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            // Re-center only if somehow off-screen
            if !isOnScreen(window) {
                window.center()
            }
            return
        }

        // Fixed frame + scrolling content. The old `SettingsView` pinned its width
        // and used `.fixedSize(vertical: true)`, so its HEIGHT was intrinsic and
        // grew when the hidden-servers list populated a few seconds after open.
        //
        // That variable height fed back through
        // `sizingOptions = [.intrinsicContentSize, .preferredContentSize]`, so every
        // content change resized the window, which re-laid out the content, which
        // resized the window… AppKit's loop guard then threw "marked as needing
        // another Update Constraints in Window pass, but it has already had more …
        // passes than there are views in the window" and the app aborted every time
        // Settings opened (2026-08-03). Pinning the width alone did NOT fix it, and
        // neither did `safeAreaRegions = []` — the height was the live edge.
        //
        // A fixed window with scrolling content removes the feedback path entirely:
        // nothing the content does can resize the window, and anything taller than
        // the window scrolls instead of clipping. `SettingsView` pins both
        // dimensions itself; each pane scrolls its own overflow.
        let root = SettingsView(monitor: monitor, updateController: updateController, selection: selection)

        // The hosting view is a *subview* of a plain container, never the window's
        // own content view. As the content view, an NSHostingView sizes the
        // window's layout rect (the part below the title bar) to its root — even
        // with `sizingOptions = []` — and then AppKit adds the title bar on top,
        // so a 552pt root opened a 584pt window with the root floating 16pt off
        // both edges. A plain NSView asks the window for nothing.
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        // The title bar is transparent and the content runs under it (the tab
        // strip draws the pane's name there, like a Preferences toolbar), so the
        // title bar must not count as a safe-area inset — otherwise SwiftUI pushes
        // the fixed-height content down and clips the bottom of it.
        hosting.safeAreaRegions = []
        let frame = NSRect(x: 0, y: 0, width: Self.contentWidth, height: Self.frameHeight)
        hosting.frame = frame
        hosting.autoresizingMask = [.width, .height]
        let container = NSView(frame: frame)
        container.addSubview(hosting)

        // Explicit size, never derived from `fittingSize`: reading the content's
        // intrinsic height back into the window is exactly the feedback the
        // constraint-loop crash came from. Not resizable: the content is a fixed
        // frame, so a bigger window would only add empty margin around it. With
        // `.fullSizeContentView` the content rect is the whole frame, title bar
        // included, so it is `frameHeight` tall.
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        // The title stays set (Mission Control, the Window menu, tests) but is not
        // drawn: the strip shows the selected pane's name in its place.
        window.title = "mcpock Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .default
        window.center()
        // Keep settings above the menu-bar panel while open.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = WindowCloser.shared
        // Apply the user's theme choice directly (NSApp.appearance is deliberately
        // left nil so the menu-bar icon follows the system — see AppearanceApplier).
        let themeRaw = UserDefaults.standard.string(forKey: AppPreferences.themeKey)
        let theme = themeRaw.flatMap(AppTheme.init(rawValue:)) ?? AppPreferences.defaultTheme
        window.appearance = theme.nsAppearance

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func isOnScreen(_ window: NSWindow) -> Bool {
        let frame = window.frame
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }
}

/// Keeps a strong target for NSWindowDelegate without tying lifetime to SettingsLauncher cases.
private final class WindowCloser: NSObject, NSWindowDelegate {
    static let shared = WindowCloser()

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide instead of destroying so AppStorage state in the hosting view is preserved.
        sender.orderOut(nil)
        return false
    }
}
