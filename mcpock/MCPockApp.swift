import SwiftUI

@main
struct MCPockApp: App {
    @State private var monitor: HealthMonitor
    /// Selection, tab, filter, search and card state. Owned here, not by the panel view,
    /// which is rebuilt on every theme change.
    @State private var panel: PanelState
    /// Usage counts (1.7): read-only, off the main thread. Owned here so it
    /// survives the panel view's theme-change rebuilds, same as `monitor`.
    @State private var usageStore: UsageStore
    /// The Glass theme's own panel on macOS 27+ (`GlassPanelController`),
    /// kept alive for the app's lifetime. `AnyObject` so this property needs
    /// no availability check; nil on macOS 26 and in tests.
    @State private var glassPanel: AnyObject?
    /// Sparkle's updater (round 10), kept alive for the app's lifetime like
    /// `monitor` and `glassPanel`. Nil while hosting unit tests.
    @State private var updateController: UpdateController?
    /// Read so the MenuBarExtra item hides the moment the theme turns Glass.
    @AppStorage(AppPreferences.themeKey) private var themeRaw = AppPreferences.defaultTheme.rawValue

    init() {
        // A server can exit between the "still running?" check and a write
        // to its stdin. The write then raises SIGPIPE, whose default action
        // ends the whole app; ignored, it is an ordinary write error the
        // probe already reports as broken (review, 2026-09-26).
        signal(SIGPIPE, SIG_IGN)
        // Not while the app is hosting unit tests: those must never touch the
        // real status file or the user's real defaults.
        let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        // Demo mode, for screenshots (`--demo` / `MCPOCK_DEMO=1`): a curated,
        // fully offline sample set instead of the user's real setup, never
        // written to her real files or defaults. See `DemoData`. Off, and
        // invisible, otherwise; never true while hosting tests.
        let isDemo = !isHostingTests && DemoData.isActive()
        // The one-time settings copy from the old com.mcpbar.app domain (1.6.0)
        // runs BEFORE anything reads defaults: HealthMonitor.init loads the
        // hidden, paused and marked-as-intended servers once. In 1.6.0 the copy
        // ran after it, so the first launch showed none of them (1.6.1). Demo
        // mode skips it too: it must never read or write the user's real domain.
        if !isHostingTests && !isDemo { SettingsMigration.migrateIfNeeded() }
        // Demo mode's monitor and panel persist into a throwaway suite, never
        // `.standard` (the user's real saved pins, hidden/paused servers, theme…).
        let monitorDefaults = isDemo ? DemoData.makeThrowawayDefaults() : .standard
        if isDemo { DemoData.seedPreferences(monitorDefaults) }
        let monitor = HealthMonitor(defaults: monitorDefaults)
        if isDemo {
            monitor.discover = { DemoData.configs }
            monitor.probe = { config, _ in DemoData.probeResult(for: config) }
        }
        // The status file agents read through mcpock-mcp (round 7). Never in
        // demo mode either: it is the real setup's own record.
        if !isHostingTests && !isDemo { monitor.statusWriter = StatusWriter() }
        // The widgets' snapshot in the App Group container (round 8). Same
        // guard: a test run or a demo run must never touch the real
        // container, same reason as the status file above.
        if !isHostingTests && !isDemo { monitor.widgetSnapshotWriter = WidgetSnapshotWriter() }
        let usageStore = UsageStore(
            readers: isDemo ? DemoData.usageReaders : UsageReaders.all,
            directory: isDemo ? DemoData.throwawayDirectory() : MCPockStatus.defaultDirectory(),
            isHostingTests: isHostingTests || isDemo,
            defaults: monitorDefaults
        )
        let panel = PanelState(monitor: monitor, defaults: monitorDefaults)
        panel.usageStore = usageStore
        _monitor = State(initialValue: monitor)
        _panel = State(initialValue: panel)
        _usageStore = State(initialValue: usageStore)
        guard !isHostingTests else { return }
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            _glassPanel = State(initialValue: GlassPanelController(monitor: monitor, state: panel))
        }
        #endif
        SettingsLauncher.monitor = monitor
        // In-app updates (round 10): never started while hosting tests (the
        // guard above already returned by then), so a test run never reaches
        // the network or shows Sparkle's permission prompt.
        let updateController = UpdateController()
        _updateController = State(initialValue: updateController)
        SettingsLauncher.updateController = updateController
        // A full check cycle just finished. The usage store starts only once
        // discovery has named the servers: the Cursor and Hermes readers split
        // call names against them, and a reader's cursor never goes back, so a
        // first scan with no names would file those calls under wrong names for
        // good. Throttled inside the store itself.
        monitor.onCycleFinished = { [weak monitor, weak usageStore] in
            guard let monitor, let usageStore else { return }
            let names = Self.knownServerNames(monitor)
            guard !names.isEmpty else { return }
            if usageStore.isStarted {
                usageStore.probeCycleCompleted(knownServers: names)
            } else {
                usageStore.start(knownServers: names)
            }
        }
        // Check from launch (1.7.1), not from the first panel open: before,
        // after an install, restart or login nothing was checked, status.json
        // stayed old and agents got no answer until someone opened the panel.
        monitor.start()
    }

    var body: some Scene {
        // Hidden while the Glass theme's own panel owns the menu-bar item.
        MenuBarExtra(isInserted: .constant(!GlassPanelStyle.usesGlassPanel(themeRaw: themeRaw))) {
            MenuBarPanelView(monitor: monitor, panel: panel)
                .onAppear {
                    StatusItemRightClick.install()
                }
        } label: {
            StatusIconView(aggregate: monitor.aggregate)
        }
        .menuBarExtraStyle(.window)
    }

    /// Every server mcpock currently knows about, normalized — what the
    /// readers use to resolve a call name that can't be split on its own
    /// (a plugin's combined `<plugin>_<server>`, Cursor's dashes-both-ways).
    private static func knownServerNames(_ monitor: HealthMonitor) -> Set<String> {
        Set(monitor.groups.map { HealthMonitor.normalizedName($0.name) })
    }
}
