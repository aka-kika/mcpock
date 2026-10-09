import Sparkle

/// In-app updates (round 10): owns Sparkle's standard updater controller for
/// the app's lifetime. One instance, created in `MCPockApp.init` and never
/// while hosting unit tests (same `isHostingTests` guard as `StatusWriter`
/// and `WidgetSnapshotWriter`) — a test run must never reach the network,
/// touch Sparkle's real "last checked" defaults, or show its permission
/// prompt.
///
/// `SPUStandardUpdaterController` reads its feed URL and public key from
/// `SUFeedURL` / `SUPublicEDKey` in Info.plist, and Sparkle itself persists
/// `automaticallyChecksForUpdates` (`SUEnableAutomaticChecks`) and the last
/// check date in UserDefaults — mcpock adds no preference of its own for
/// either.
@MainActor
final class UpdateController {
    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true begins Sparkle's own schedule right away.
        // Automatic checks are on by default; Sparkle asks the user's
        // permission the first time it is about to check on its own (usually
        // the second launch), never on this first one.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Settings > About "Check for Updates…" and the status-item right-click
    /// menu both call this. Sparkle shows its own progress window.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Settings > About "Automatically check for updates" toggle. Sparkle
    /// persists this itself; mcpock only reads and writes it through here.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
