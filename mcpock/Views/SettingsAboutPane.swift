import SwiftUI
import AppKit

/// Settings > About (round 7): icon, name, version, one line of what mcpock
/// does, "Made by Kika" and three icon-only links. Modelled on Vera's About,
/// tinted like the rest of mcpock (label greys, never accent).
struct SettingsAboutPane: View {
    let theme: ThemeColors
    /// The app's Sparkle updater (round 10); nil in tests and while hosting
    /// them, in which case the update controls don't show at all.
    var updateController: UpdateController?

    static let tagline = "Checks the MCP servers your agents use and tells you what needs attention."
    static let checkForUpdatesTitle = "Check for Updates\u{2026}"
    static let automaticUpdatesTitle = "Automatically check for updates"
    static let madeBy = "Made by Kika"
    static let copyright = "\u{00A9} 2026 AKAKIKA.COM"

    struct Link: Identifiable, Equatable {
        let name: String
        let asset: String
        let url: String
        var id: String { asset }
    }

    /// Icon-only; the name is the tooltip and the accessibility label.
    static let links: [Link] = [
        Link(name: "akakika.com", asset: "social-globe", url: "https://akakika.com"),
        Link(name: "X (@akakikaaa)", asset: "social-x", url: "https://x.com/akakikaaa"),
        Link(name: "GitHub (aka-kika)", asset: "social-github", url: "https://github.com/aka-kika"),
    ]

    /// "Version 1.5.0 (8)".
    static func versionLine(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "Version \(version)" : "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                Text("mcpock")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(Self.versionLine())
                    .font(Theme.caption)
                    .foregroundStyle(theme.textTertiary)
                    .textSelection(.enabled)
                Text(Self.tagline)
                    .font(Theme.body)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.top, 4)
            }

            if let updateController {
                UpdateControls(updateController: updateController, theme: theme)
                    .padding(.top, 16)
            }

            VStack(spacing: 10) {
                Text(Self.madeBy)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.textSecondary)
                HStack(spacing: 12) {
                    ForEach(Self.links) { link in
                        AboutLinkButton(link: link, theme: theme)
                    }
                }
            }
            .padding(.top, 30)

            Spacer(minLength: 20)
            Text(Self.copyright)
                .font(.system(size: 10))
                .tracking(0.4)
                .foregroundStyle(theme.textTertiary)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One icon-only link: the mono mark on a quiet rounded square, a touch
/// brighter on hover.
private struct AboutLinkButton: View {
    let link: SettingsAboutPane.Link
    let theme: ThemeColors
    @State private var isHovered = false

    var body: some View {
        Button {
            if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
        } label: {
            Image(link.asset)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 17, height: 17)
                .foregroundStyle(isHovered ? theme.textPrimary : theme.textSecondary)
                .frame(width: 38, height: 38)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isHovered ? theme.rowHighlight : theme.fieldFill)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(link.name)
        .accessibilityLabel(link.name)
    }
}

/// "Check for Updates…" and the automatic-checks toggle (round 10). Sparkle
/// owns the toggle's real state (`automaticallyChecksForUpdates`); this view
/// just reflects and drives it, the same shape as `LaunchAtLogin` in the
/// General pane. The button always taps through to Sparkle, which shows its
/// own progress window and disables re-entry on its own — kept minimal here.
private struct UpdateControls: View {
    let updateController: UpdateController
    let theme: ThemeColors
    @State private var automaticChecks: Bool

    init(updateController: UpdateController, theme: ThemeColors) {
        self.updateController = updateController
        self.theme = theme
        _automaticChecks = State(initialValue: updateController.automaticallyChecksForUpdates)
    }

    var body: some View {
        VStack(spacing: 8) {
            Button(SettingsAboutPane.checkForUpdatesTitle) {
                updateController.checkForUpdates()
            }
            Toggle(SettingsAboutPane.automaticUpdatesTitle, isOn: Binding(
                get: { automaticChecks },
                set: { newValue in
                    automaticChecks = newValue
                    updateController.automaticallyChecksForUpdates = newValue
                }
            ))
            .font(Theme.caption)
            .foregroundStyle(theme.textSecondary)
        }
    }
}
