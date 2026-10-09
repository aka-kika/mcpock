import AppKit
import SwiftUI

/// Shows the detail card as a borderless panel **beside** the menu-bar panel
/// (v1.5 spec, Phase 3). The MenuBarExtra window is fixed size and can't grow to
/// hold the card, so the card gets its own window: 340 wide, top edges aligned,
/// 10pt to the left of the panel (to the right, or clamped to the screen edge,
/// when there is no room on the left), its height fitted to the content up to the
/// panel's height, scrolling past that.
///
/// It is a **child window** of the MenuBarExtra window, so it moves with it, and
/// it can never become key: the MenuBarExtra window closes the moment it loses
/// key status, so a card that took focus would close the panel it belongs to.
/// Keyboard input (Escape, the arrows) keeps going to the panel, whose key
/// handler drives the card.
@MainActor
final class DetailCardPresenter {
    nonisolated static let width: CGFloat = 340
    nonisolated static let gap: CGFloat = 10
    nonisolated static let cornerRadius: CGFloat = 12
    /// Until the content reports its height.
    nonisolated static let initialHeight: CGFloat = 240

    private var panel: CardPanel?
    private weak var parent: NSWindow?
    private var contentHeight: CGFloat = initialHeight

    /// The card's window, for the panel's key handler.
    var window: NSWindow? { panel }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(state: PanelState, parent: NSWindow) {
        let panel = self.panel ?? makePanel(state: state)
        self.panel = panel
        self.parent = parent
        layout()
        SidePanel.attach(panel, to: parent)
    }

    func hide() {
        guard let panel else { return }
        SidePanel.detach(panel)
    }

    /// The card's content measured itself; refit the window (top edge fixed).
    func contentHeightChanged(_ height: CGFloat) {
        let rounded = ceil(height)
        guard abs(rounded - contentHeight) >= 1 else { return }
        contentHeight = rounded
        if isVisible { layout() }
    }

    /// Where the card goes, given the panel's frame and the screen. Pure, so
    /// `DetailCardPlacementTests` covers the left / right / clamp choice.
    nonisolated static func frame(
        besides parent: NSRect,
        contentHeight: CGFloat,
        screen: NSRect?
    ) -> NSRect {
        let height = min(max(contentHeight, 1), parent.height)
        var x = parent.minX - gap - width
        if let screen, x < screen.minX {
            let right = parent.maxX + gap
            x = right + width <= screen.maxX ? right : screen.minX
        }
        return NSRect(x: x, y: parent.maxY - height, width: width, height: height)
    }

    private func layout() {
        guard let panel, let parent else { return }
        let frame = Self.frame(
            besides: parent.frame,
            contentHeight: contentHeight,
            screen: parent.screen?.visibleFrame
        )
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func makePanel(state: PanelState) -> CardPanel {
        let root = DetailCardHost(state: state) { [weak self] height in
            self?.contentHeightChanged(height)
        }
        return SidePanel.make(width: Self.width, height: Self.initialHeight, root: root)
    }
}

/// The detail card's window rules (round 5; the tools window that shared them
/// was dropped in 1.5.3): a
/// borderless child `NSPanel` that never takes key or main (the MenuBarExtra
/// window closes the moment it loses key), takes the first click, is sized by
/// its presenter (never from the content), and is removed as a child and
/// ordered out explicitly on close (an ordered-out parent would otherwise bring
/// a stale child back on the next open).
@MainActor
enum SidePanel {
    static func make<Content: View>(width: CGFloat, height: CGFloat, root: Content) -> CardPanel {
        let panel = CardPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .moveToActiveSpace]

        // Rounded, clipped container: the window itself is clear, so the corners
        // (and the shadow, which follows the content's alpha) come from this layer.
        let container = NSView(frame: panel.contentLayoutRect)
        container.wantsLayer = true
        container.layer?.cornerRadius = DetailCardPresenter.cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]

        let hosting = CardHostingView(rootView: root)
        // The window's size is set here, never read back from the content: the
        // Settings window's constraint-loop crash came from exactly that feedback.
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        return panel
    }

    /// Theme it like every mcpock window, put it at the menu-bar panel's level
    /// (beside it, not under it), and hang it on the panel.
    static func attach(_ panel: NSPanel, to parent: NSWindow) {
        // Theme: the user's choice (nil follows the system), as every mcpock
        // window gets from `AppearanceApplier`.
        let themeRaw = UserDefaults.standard.string(forKey: AppPreferences.themeKey)
        panel.appearance = (themeRaw.flatMap(AppTheme.init(rawValue:)) ?? AppPreferences.defaultTheme).nsAppearance
        panel.level = parent.level
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    static func detach(_ panel: NSPanel) {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

/// A panel that never takes key or main status (see `DetailCardPresenter`).
final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Clicks land on the first try: the card is never the key window, and a
/// non-key window otherwise swallows the first click to "activate" it.
final class CardHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
