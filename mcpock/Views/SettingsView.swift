import SwiftUI

/// The Settings window's content: a tab strip across the top and one pane under
/// it (General, Servers, Agents, Connect, About). It pins itself to `SettingsLauncher`'s fixed
/// size — the window never sizes from this view (the SIGABRT constraint loop of
/// 2026-08-03, see `SettingsLauncher.open()`); each pane scrolls what doesn't fit.
///
/// The backdrop is the shared `PanelBackdrop`, so Settings looks like the panel
/// in both looks: soft dark solid in Dark, the one menu material in Light.
struct SettingsView: View {
    /// The app's single health monitor: the Servers and Agents panes read its
    /// groups, General's Export reads its errors.
    var monitor: HealthMonitor?
    /// The app's Sparkle updater (round 10): About's "Check for Updates…" and
    /// its automatic-checks toggle. Nil in tests and while hosting them, and
    /// defaulted here so existing call sites that predate it still compile.
    var updateController: UpdateController? = nil
    /// Which pane is showing. Owned by the launcher so the panel can open
    /// Settings on a pane and the window remembers it while hidden.
    @Bindable var selection: SettingsSelection

    @AppStorage(AppPreferences.themeKey) private var themeRaw = AppPreferences.defaultTheme.rawValue
    @Environment(\.colorScheme) private var systemColorScheme

    private var appTheme: AppTheme { AppTheme(rawValue: themeRaw) ?? .system }
    private var scheme: ColorScheme { appTheme.resolvedScheme(systemFallback: systemColorScheme) }
    private var theme: ThemeColors { ThemeColors.resolve(scheme, forGlass: appTheme == .glass) }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabStrip(selection: $selection.tab, theme: theme)
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: SettingsLauncher.contentWidth, height: SettingsLauncher.frameHeight)
        .background { PanelBackdrop(scheme: scheme, isGlass: appTheme == .glass) }
        // No `.id(themeRaw)` here: the panel needs it to defeat MenuBarExtra's
        // colour caching, but on this window it only threw away @State (the
        // export note) every time the theme changed.
        .applyAppTheme(appTheme, systemFallback: systemColorScheme)
    }

    @ViewBuilder
    private var pane: some View {
        switch selection.tab {
        case .general:
            // A grouped Form (round 8), which scrolls itself.
            SettingsGeneralPane(monitor: monitor, theme: theme)
        case .servers:
            SettingsServersPane(monitor: monitor, theme: theme)
        case .agents:
            SettingsAgentsPane(monitor: monitor, theme: theme)
        case .connect:
            SettingsConnectPane(theme: theme)
        case .about:
            SettingsAboutPane(theme: theme, updateController: updateController)
        }
    }
}
