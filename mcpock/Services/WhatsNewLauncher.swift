import AppKit
import SwiftUI

/// Shows `WhatsNewSheet` (1.10.7). mcpock has no main window to hang a sheet
/// on, so the notes open in a small window of their own, like Settings: once
/// on the first launch after an update, and from the right-click menu.
@MainActor
enum WhatsNewLauncher {
    private static var window: NSWindow?

    /// The 1.10.6 users updating to 1.10.7 have no `WhatsNew.lastSeenKey` yet,
    /// which `WhatsNew.shouldShow` reads as a first install. Before the first
    /// check, a Mac where mcpock already ran (its one-time settings copy left
    /// its flag) gets a last-seen version older than any, so the update shows
    /// its notes. Must run before `SettingsMigration.migrateIfNeeded`, which
    /// sets that flag on a first install too.
    static func markEarlierRun(defaults: UserDefaults = AppPreferences.store) {
        guard defaults.object(forKey: WhatsNew.lastSeenKey) == nil,
              defaults.object(forKey: SettingsMigration.migratedFlagKey) != nil else { return }
        defaults.set("1.10.6", forKey: WhatsNew.lastSeenKey)
    }

    /// Once after an update, a moment after launch.
    static func showIfUpdated(defaults: UserDefaults = AppPreferences.store) {
        guard WhatsNew.shouldShow(defaults: defaults) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            // Shown without taking the keyboard: after an update at login it
            // used to jump in front of whatever she was typing (r3 8987).
            open(defaults: defaults, activate: false)
        }
    }

    /// Whether this version has notes to show (the menu item's state).
    static var hasNotes: Bool { WhatsNew.notes(for: WhatsNew.currentVersion) != nil }

    static func open(defaults: UserDefaults = AppPreferences.store, activate: Bool = true) {
        guard let lines = WhatsNew.notes(for: WhatsNew.currentVersion) else { return }
        if activate { NSApp.activate(ignoringOtherApps: true) }
        if let window {
            if activate { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
            return
        }
        let root = WhatsNewSheet(appName: "mcpock", lines: lines) { close(defaults: defaults) }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        let frame = NSRect(x: 0, y: 0, width: 480, height: 520)
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.title = "What's New in mcpock"
        window.isReleasedWhenClosed = false
        window.level = .normal   // not above every other app (r3 e78a)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = WhatsNewCloser.shared
        let themeRaw = AppPreferences.store.string(forKey: AppPreferences.themeKey)
        window.appearance = (themeRaw.flatMap(AppTheme.init(rawValue:)) ?? AppPreferences.defaultTheme).nsAppearance
        window.center()
        self.window = window
        if activate { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
    }

    /// Continue, or the close button: seen, and gone.
    static func close(defaults: UserDefaults = AppPreferences.store) {
        WhatsNew.markSeen(defaults: defaults)
        window?.orderOut(nil)
        window = nil
    }
}

private final class WhatsNewCloser: NSObject, NSWindowDelegate {
    static let shared = WhatsNewCloser()

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { WhatsNewLauncher.close() }
        return false
    }
}
