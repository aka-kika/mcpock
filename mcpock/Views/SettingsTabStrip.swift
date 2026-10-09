import SwiftUI
import Observation

/// The Preferences panes. General is the app's own settings; Servers takes
/// over pinning and hiding from the panel; Agents lists what discovery found,
/// read-only; Connect (round 7) hands out the mcpock-mcp snippets; About is last.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case servers
    case agents
    case connect
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .servers: return "Servers"
        case .agents: return "Agents"
        case .connect: return "Connect"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .servers: return "server.rack"
        case .agents: return "person.2"
        case .connect: return "point.3.connected.trianglepath.dotted"
        case .about: return "info.circle"
        }
    }
}

/// Which pane Settings shows. Owned by `SettingsLauncher` (one per app), so the
/// panel can open Settings straight onto a pane ("n hidden" → Servers) and a
/// reopened window remembers where it was. Observable, so the view follows a
/// change made from outside while the window is already open.
@MainActor
@Observable
final class SettingsSelection {
    var tab: SettingsTab = .general
}

/// The bar across the top of the Settings window: the selected pane's name where
/// the title would be, then one icon-over-label button per pane, the selected one
/// on a neutral fill (never accent). It sits under a transparent title bar, so
/// `titleBarHeight` keeps the name clear of the traffic lights' row.
struct SettingsTabStrip: View {
    @Binding var selection: SettingsTab
    let theme: ThemeColors

    /// The window's title-bar band (32pt for a titled window with its title
    /// hidden on macOS 26). The window hides its title and lets content run
    /// full-height, so the strip draws the pane's name in that band itself,
    /// centred on the traffic lights. `SettingsWindowSizingTests` checks the
    /// live window's inset still matches.
    static let titleBarHeight: CGFloat = 32
    /// Title band + 4 gap + 44 button + 8 bottom padding. Fixed so the pane below
    /// gets a fixed remainder (`SettingsWindowSizingTests` measures against it).
    static let height: CGFloat = 88
    static let buttonWidth: CGFloat = 72

    var body: some View {
        VStack(spacing: 4) {
            Text(selection.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(height: Self.titleBarHeight)
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    tabButton(tab)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(theme.chromeFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.divider).frame(height: 1)
        }
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let selected = tab == selection
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 16, weight: .regular))
                    .frame(height: 18)
                Text(tab.title)
                    .font(Theme.caption)
            }
            .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
            .frame(width: Self.buttonWidth)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? theme.elevated : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(tab.title)
    }
}
