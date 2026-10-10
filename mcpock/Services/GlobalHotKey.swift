import AppKit
import Carbon.HIToolbox
import Observation

/// One keyboard shortcut, ⌃⌥M, that opens and closes the panel from any app
/// (1.10, from the Wasdy note: a shelf you call up like Raycast, then arrow,
/// Return and Escape, which the panel already answers).
///
/// Carbon's `RegisterEventHotKey`, not an `NSEvent` global monitor: it needs
/// no Accessibility or Input Monitoring permission, and it swallows the key
/// so the app in front doesn't type it too. Registered exclusively, so a
/// shortcut another app already owns fails here instead of firing in both;
/// Settings then says so (`isTaken`).
///
/// On by default, off in Settings > General. Follows that setting through
/// `UserDefaults.didChangeNotification`, the same way the Glass panel follows
/// the theme.
@MainActor
@Observable
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    /// Shown in Settings and the help text.
    nonisolated static let displayText = "\u{2303}\u{2325}M"
    nonisolated static let spokenText = "Control-Option-M"
    nonisolated static let keyCode = UInt32(kVK_ANSI_M)
    nonisolated static let modifiers = UInt32(controlKey | optionKey)

    /// True when the setting is on but another app already owns the shortcut.
    private(set) var isTaken = false

    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var defaults: UserDefaults = .standard
    /// What a press does. Set by `start`; the app opens or closes the panel.
    @ObservationIgnored private var action: () -> Void = {}

    private init() {}

    /// Called once from `MCPockApp.init`, never while hosting tests.
    func start(defaults: UserDefaults = .standard, action: @escaping () -> Void) {
        guard defaultsObserver == nil else { return }
        self.defaults = defaults
        self.action = action
        installHandler()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    /// Registers or unregisters to match the setting. Cheap when nothing
    /// changed: every defaults write anywhere in the app lands here.
    private func sync() {
        let wanted = AppPreferences.loadOpenPanelHotKey(from: defaults)
        if wanted, hotKeyRef == nil {
            register()
        } else if !wanted {
            unregister()
            if isTaken { isTaken = false }
        }
    }

    private func register() {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x6D63_706B), id: 1) // 'mcpk'
        let status = RegisterEventHotKey(
            Self.keyCode, Self.modifiers, id,
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref
        )
        if status == noErr, let ref {
            hotKeyRef = ref
            if isTaken { isTaken = false }
        } else if !isTaken {
            isTaken = true
        }
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Carbon calls this on the main thread (the application event target).
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalHotKey.shared.action() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}

/// Opens or closes the panel for the shortcut. The Glass theme's own panel
/// (macOS 27+) opens itself (`GlassPanelController.toggleFromShortcut`);
/// every other theme gets a click on its MenuBarExtra item, which opens and
/// closes that window the same way a real click does.
@MainActor
enum PanelToggle {
    /// Set by `GlassPanelController`; true when it handled the press.
    static var glassToggle: (() -> Bool)?

    static func toggle() {
        if glassToggle?() == true { return }
        guard let button = statusItemButton() else { return }
        // A shortcut from another app: bring mcpock forward so the panel
        // takes the arrow keys, Return and Escape at once.
        NSApp.activate()
        button.performClick(nil)
    }

    /// The item's button in the menu bar of the screen she is working on.
    /// With several displays, every menu bar has its own copy of the item;
    /// one with no height is a copy that isn't on screen.
    private static func statusItemButton() -> NSButton? {
        let windows = NSApp.windows.filter {
            $0.className.contains("NSStatusBarWindow") && $0.isVisible && $0.frame.height > 0
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let onScreen = windows.filter { window in screen.map { $0.frame.intersects(window.frame) } ?? false }
        for window in onScreen + windows {
            if let button = findButton(in: window.contentView) { return button }
        }
        return nil
    }

    private static func findButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = findButton(in: sub) { return found }
        }
        return nil
    }
}
