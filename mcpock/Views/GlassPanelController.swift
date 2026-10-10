import AppKit
import Observation
import SwiftUI

// Built only with the macOS 27 SDK (Swift 6.4, Xcode 27): the expanded-
// interface API doesn't exist in older SDKs, and CI builds with Xcode 26.
// Without it, Glass keeps the MenuBarExtra window (`GlassPanelStyle`).
#if compiler(>=6.4)
/// The Glass theme's own menu-bar panel, on macOS 27+ (1.8).
///
/// Why not the MenuBarExtra window every other theme uses: that window blurs
/// the desktop with its own material *before* the panel's glass sees it, so in
/// Light the glass could only refract a flat white haze (2026-09-26:
/// "settings have the effect but the menu app not"; checked over colored
/// stripes, the Settings window stayed see-through and the panel went milky,
/// whatever glass variant, window level or blur setting was tried). A plain
/// see-through `NSPanel` lets the glass see the real desktop.
///
/// macOS 27's expanded-interface session (`NSStatusItem.expandedInterfaceDelegate`)
/// gives that panel the menu bar's own open and close behavior: a click on the
/// item begins a session, a click on another menu extra ends it. Clicks in
/// other windows and Escape are ours to handle, and end the session through
/// `cancel()`. The recipe follows Syrtis's `GlassPanelPresenter`
/// (github.com/Nanako0129/syrtis, MIT).
///
/// Only the Glass theme uses it: the status item exists while the theme is
/// Glass, and the app hides its MenuBarExtra item at the same time (see
/// `GlassPanelStyle.usesGlassPanel`). The panel content is the same
/// `MenuBarPanelView`, installed on open and removed on close, so its
/// `onAppear` / `onDisappear` (key monitor, card, search) run as before.
@available(macOS 27.0, *)
@MainActor
final class GlassPanelController: NSObject {
    private let monitor: HealthMonitor
    private let state: PanelState
    private let panel = GlassPanelWindow()
    private let host = NSHostingController(rootView: AnyView(EmptyView()))
    private var statusItem: NSStatusItem?
    /// The session the menu bar opened: ended with `cancel()` when we close.
    private var session: NSStatusItemExpandedInterfaceSession?
    private var eventMonitors: [Any] = []
    private var keyObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    /// The theme the item was last synced to. Any defaults write posts the
    /// change notification — creating the status item itself saves its
    /// position — so only a real theme change may act, and never while a
    /// sync is already running (that re-entry created items without end and
    /// crashed on launch, 2026-09-26).
    private var syncedThemeRaw: String??
    private var isSyncing = false
    /// Bumped on every open, so a close fade that ends after a reopen
    /// doesn't order the reopened panel out.
    private var generation = 0
    private(set) var isShown = false

    init(monitor: HealthMonitor, state: PanelState) {
        self.monitor = monitor
        self.state = state
        super.init()
        // No automatic sizing: the panel view has a fixed frame and the
        // window is laid out by `layout(under:)`.
        host.sizingOptions = []
        panel.contentViewController = host
        panel.contentView?.wantsLayer = true
        // Round the window itself, so the corners are truly empty and the
        // shadow (computed from the window's alpha) follows the rounded shape.
        if let layer = panel.contentView?.layer {
            layer.cornerRadius = GlassPanelStyle.cornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
        }
        panel.onPerformClose = { [weak self] in self?.close() }
        state.requestClose = { [weak self] in self?.close() }
        PanelToggle.glassToggle = { [weak self] in self?.toggleFromShortcut() ?? false }
        // Follow the theme: the item exists only while it is Glass.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncWithTheme() }
        }
        syncWithTheme()
        observeIcon()
    }

    // MARK: - Status item

    private func syncWithTheme() {
        let themeRaw = UserDefaults.standard.string(forKey: AppPreferences.themeKey)
        guard !isSyncing, syncedThemeRaw != .some(themeRaw) else { return }
        isSyncing = true
        defer { isSyncing = false }
        syncedThemeRaw = .some(themeRaw)
        let active = GlassPanelStyle.usesGlassPanel(themeRaw: themeRaw)
        if active, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // Its own name. AppKit otherwise saves visibility per creation
            // slot ("Item-0", "Item-1"), and the MenuBarExtra item, hidden
            // while Glass is on, saved "hidden" into a slot this item later
            // took: the icon vanished (2026-09-26). Choosing Glass means
            // wanting its icon, so it starts visible.
            item.autosaveName = "mcpock.glassPanel"
            item.isVisible = true
            item.expandedInterfaceDelegate = self
            statusItem = item
            updateIcon()
            // The right-click menu (Settings, Quit) watches every status-bar
            // window, this item's included.
            StatusItemRightClick.install()
        } else if !active, let item = statusItem {
            // Hide here and now: the session's end callback may come after
            // the delegate is gone, and the panel would stay on screen.
            session?.cancel()
            session = nil
            hide()
            item.expandedInterfaceDelegate = nil
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// The same image the MenuBarExtra label draws, redrawn whenever the
    /// monitor's overall state changes.
    private func observeIcon() {
        withObservationTracking {
            _ = monitor.aggregate
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateIcon()
                self?.observeIcon()
            }
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let aggregate = monitor.aggregate
        button.image = StatusIconView.image(for: StatusBadgeKind.forAggregate(aggregate))
        button.setAccessibilityLabel(StatusIconView.accessibilityLabel(for: aggregate))
    }

    // MARK: - Open and close

    /// `onMouseScreen` (the shortcut): under the item in the menu bar of the
    /// screen the pointer is on, not the one AppKit keeps the button in.
    private func present(from button: NSStatusBarButton, onMouseScreen: Bool = false) {
        host.rootView = AnyView(
            MenuBarPanelView(monitor: monitor, panel: state)
                .environment(\.inGlassPanel, true)
        )
        layout(under: button, onMouseScreen: onMouseScreen)
        generation += 1
        isShown = true
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        // Pay the first layout and draw while the panel is still invisible,
        // then fade in on the next turn (Syrtis measured the first draw at
        // 65-125 ms; animating through it drops every frame).
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation, self.isShown else { return }
            self.animateIn()
        }
        installEventMonitors()
    }

    /// ⌃⌥M (`GlobalHotKey`, 1.10). A click on the item from code doesn't begin
    /// an expanded-interface session, so the shortcut opens the panel itself,
    /// without one: the outside-click monitors and Escape close it as usual.
    /// False while the theme isn't Glass (no item), so the caller falls back
    /// to the MenuBarExtra item.
    func toggleFromShortcut() -> Bool {
        guard let button = statusItem?.button else { return false }
        if isShown {
            close()
        } else {
            present(from: button, onMouseScreen: true)
        }
        return true
    }

    /// Ends the menu bar's session when there is one (its end callback then
    /// hides the panel), otherwise hides directly.
    func close() {
        if let session {
            session.cancel()
        } else {
            hide()
        }
    }

    private func hide() {
        removeEventMonitors()
        guard isShown else { return }
        isShown = false
        let generation = generation
        let finish = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.panel.orderOut(nil)
                self.panel.contentView?.layer?.opacity = 1
                // Removing the view runs its onDisappear: card and search close.
                self.host.rootView = AnyView(EmptyView())
            }
        }
        guard panel.isVisible, let layer = panel.contentView?.layer else {
            finish()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock(finish)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.opacity = 0
        layer.add(fade, forKey: "close")
        CATransaction.commit()
    }

    /// A short fade and drop from the menu bar, like the system dropdowns.
    private func animateIn() {
        guard let layer = panel.contentView?.layer else {
            panel.alphaValue = 1
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = 8
        slide.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade, slide]
        group.duration = 0.18
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.removeAnimation(forKey: "close")
        layer.opacity = 1
        layer.add(group, forKey: "open")
        panel.alphaValue = 1
        CATransaction.commit()
    }

    /// Top edge just under the item, centered on it, kept inside the screen.
    private func layout(under button: NSStatusBarButton, onMouseScreen: Bool = false) {
        guard let window = button.window else { return }
        var anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        var screen = window.screen
        if onMouseScreen, let home = window.screen {
            let mouse = NSEvent.mouseLocation
            if let target = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }), target != home {
                anchor = GlassPanelStyle.anchor(anchor, movedFrom: home.frame, to: target.frame, top: target.visibleFrame.maxY)
                screen = target
            }
        }
        let frame = GlassPanelStyle.frame(
            anchor: anchor,
            visible: screen?.visibleFrame,
            width: MenuBarPanelView.panelWidth,
            height: MenuBarPanelView.panelHeight
        )
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    // MARK: - Outside clicks

    /// The session leaves clicks in other apps and in our own windows to us;
    /// clicks on other menu extras end it on their own. Escape goes through
    /// `PanelState` first (card, compare, search), then `requestClose`.
    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
        ) {
            eventMonitors.append(global)
        }
        // Clicks in mcpock's own ordinary windows (Settings) never reach the
        // global monitor. The detail card sits at the panel's level, and the
        // menu bar is at status-bar level: neither is an outside click.
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, let window = event.window, window !== self.panel,
                       window.level.rawValue < NSWindow.Level.statusBar.rawValue {
                        self.close()
                    }
                }
                return event
            }
        ) {
            eventMonitors.append(local)
        }
        // Another mcpock window taking the keyboard (Settings from the gear)
        // closes the panel, as the MenuBarExtra window did.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window !== self.panel,
                      window.level.rawValue < NSWindow.Level.statusBar.rawValue else { return }
                self.close()
            }
        }
    }

    private func removeEventMonitors() {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors.removeAll()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }
}

@available(macOS 27.0, *)
extension GlassPanelController: @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        guard let button = statusItem.button else {
            session.cancel()
            return
        }
        self.session = session
        present(from: button)
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        session = nil
        hide()
    }
}
#endif

/// The glass panel's measures and the one rule for when it is used. Not tied
/// to macOS 27 like the controller, so the panel view and the app can read it.
enum GlassPanelStyle {
    /// The corner of the macOS 27 menu-bar dropdowns, near enough.
    nonisolated static let cornerRadius: CGFloat = 16
    /// Gap between the menu bar and the panel's top edge.
    nonisolated static let menuBarGap: CGFloat = 6
    /// Keeps the panel off the screen edge when the item sits near a corner.
    nonisolated static let screenMargin: CGFloat = 8

    /// The Glass theme on macOS 27+ uses the glass panel; every other theme,
    /// and Glass on macOS 26, keeps the MenuBarExtra window.
    nonisolated static func usesGlassPanel(themeRaw: String?) -> Bool {
        #if compiler(>=6.4)
        guard #available(macOS 27.0, *) else { return false }
        return themeRaw == AppTheme.glass.rawValue
        #else
        return false // built without the macOS 27 SDK: no glass panel to show
        #endif
    }

    /// The item's place in another screen's menu bar, for the shortcut (1.10):
    /// every display has its own copy of the menu bar, with the status items
    /// lined up from the right edge, so the copy sits as far from that
    /// screen's right edge as the button does from its own. `top` is the
    /// bottom of the target's menu bar. Pure, for the tests.
    nonisolated static func anchor(_ anchor: NSRect, movedFrom home: NSRect, to target: NSRect, top: CGFloat) -> NSRect {
        let fromRight = home.maxX - anchor.midX
        return NSRect(x: target.maxX - fromRight - anchor.width / 2, y: top, width: anchor.width, height: anchor.height)
    }

    /// Top edge just under the item, centered on it, kept inside the screen.
    /// Pure, for the tests.
    nonisolated static func frame(anchor: NSRect, visible: NSRect?, width: CGFloat, height: CGFloat) -> NSRect {
        var x = anchor.midX - width / 2
        if let visible {
            x = min(max(x, visible.minX + screenMargin), visible.maxX - width - screenMargin)
        }
        let top = anchor.minY - menuBarGap
        return NSRect(x: x, y: top - height, width: width, height: height)
    }
}

/// The see-through window the glass panel lives in: borderless, clear, at the
/// menu level, on every Space, never moved.
final class GlassPanelWindow: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }

    /// A borderless panel has no close button, so `performClose` (Esc in a
    /// text field, the system) would do nothing; route it to the controller.
    var onPerformClose: (() -> Void)?
    override func performClose(_ sender: Any?) { onPerformClose?() }
}

private struct InGlassPanelKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside the Glass theme's own panel (`GlassPanelController`): the
    /// panel rounds its glass to the window's corner.
    var inGlassPanel: Bool {
        get { self[InGlassPanelKey.self] }
        set { self[InGlassPanelKey.self] = newValue }
    }
}
