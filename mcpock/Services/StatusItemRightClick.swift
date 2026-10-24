import AppKit

/// Installs a right-click menu on the MenuBarExtra status item (Settings + Quit).
@MainActor
enum StatusItemRightClick {
    /// NSEvent monitor token (not to be confused with the app's HealthMonitor).
    private static var eventMonitor: Any?

    static func install() {
        guard eventMonitor == nil else { return }

        // Local event monitors are always called on the main thread.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            let isSecondary = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            guard isSecondary else { return event }
            return handleSecondaryClick(event)
        }
    }

    // MARK: - Private

    private static func handleSecondaryClick(_ event: NSEvent) -> NSEvent? {
        guard isStatusBarEvent(event) else { return event }
        showContextMenu(for: event)
        return nil
    }

    private static func isStatusBarEvent(_ event: NSEvent) -> Bool {
        // The status item lives in AppKit's dedicated status-bar window; the dropdown
        // panel and Settings window don't. When the event carries its window, that's
        // the authoritative answer — a panel that happens to sit near the top of a
        // screen must still get its own context menus.
        if let window = event.window {
            return window.className.contains("NSStatusBarWindow")
        }
        // Windowless event: fall back to the menu-bar strip geometry.
        let loc = NSEvent.mouseLocation
        let strip = NSStatusBar.system.thickness + 8
        for screen in NSScreen.screens {
            let frame = screen.frame
            if loc.x >= frame.minX, loc.x <= frame.maxX, loc.y >= frame.maxY - strip {
                return true
            }
        }
        return false
    }

    /// Settings, Check for Updates, What's New and Quit. "Rescan for agents" used to live
    /// here; the panel's "Refresh now" now re-runs discovery itself, so the
    /// separate action was a second spelling of the same thing.
    private static func showContextMenu(for event: NSEvent) {
        let menu = appMenu()
        if let view = event.window?.contentView {
            let point = event.locationInWindow
            menu.popUp(positioning: nil, at: NSPoint(x: point.x, y: point.y - 4), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    /// The same menu from the panel footer's gear (r3 2c37): before, Quit
    /// lived only behind a right-click on the icon.
    static func showFromFooter() {
        appMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "mcpock")

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(MenuTarget.openSettingsAction),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = [.command]
        settings.target = MenuTarget.shared

        menu.addItem(settings)

        // Round 10: only shown once the updater exists (never while hosting
        // tests, and never before MCPockApp.init has run).
        if SettingsLauncher.updateController != nil {
            let checkForUpdates = NSMenuItem(
                title: SettingsAboutPane.checkForUpdatesTitle,
                action: #selector(MenuTarget.checkForUpdatesAction),
                keyEquivalent: ""
            )
            checkForUpdates.target = MenuTarget.shared
            menu.addItem(checkForUpdates)
        }

        // 1.10.7: the notes shown once after an update, any time.
        let whatsNew = NSMenuItem(
            title: "What's New in mcpock",
            action: WhatsNewLauncher.hasNotes ? #selector(MenuTarget.whatsNewAction) : nil,
            keyEquivalent: ""
        )
        whatsNew.target = MenuTarget.shared
        menu.addItem(whatsNew)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit mcpock",
            action: #selector(MenuTarget.quitAction),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = [.command]
        quit.target = MenuTarget.shared

        menu.addItem(quit)
        return menu
    }
}

private final class MenuTarget: NSObject {
    static let shared = MenuTarget()

    // Menu actions are always delivered on the main thread.
    @objc func openSettingsAction() {
        MainActor.assumeIsolated {
            SettingsLauncher.open()
        }
    }

    @objc func quitAction() {
        NSApp.terminate(nil)
    }

    @objc func whatsNewAction() {
        MainActor.assumeIsolated {
            WhatsNewLauncher.open()
        }
    }

    @objc func checkForUpdatesAction() {
        MainActor.assumeIsolated {
            SettingsLauncher.updateController?.checkForUpdates()
        }
    }
}
