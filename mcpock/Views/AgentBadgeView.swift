import SwiftUI

/// An agent's badge (v1.5 round 3). Always the agent's real mono logo (LobeHub
/// Icons, see `AgentBadge.logoName`) in the secondary text colour, on its own with
/// no frame; no colour app icons anywhere ("use overall the symbols instead
/// of the colour icons"). Agents without a logo show their two-letter monogram.
///
/// No circle behind it either, in any size: the circled version in the detail
/// card, Agents tab and Settings "felt off" next to the app's rounded-rectangle
/// framing, and the bare marks in the server rows already read cleanly (2026-09-24). Rows use 18pt, the detail card 20pt, the Agents tab 24pt. The
/// tooltip is the agent's name.
struct AgentBadgeView: View {
    let badge: AgentBadge
    let theme: ThemeColors
    var size: CGFloat = 18

    var body: some View {
        mark
            .frame(width: size, height: size)
            .help(AgentBadge.displayLabel(badge.agent))
            .accessibilityLabel(AgentBadge.displayLabel(badge.agent))
    }

    @ViewBuilder
    private var mark: some View {
        if let name = badge.logoName {
            // A vector template image, so it takes the foreground style.
            Image(name)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size * Self.logoScale, height: size * Self.logoScale)
                .foregroundStyle(theme.textSecondary)
        } else {
            Text(badge.monogram)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// The logo's box as a share of the badge. The marks fill their 24pt canvas
    /// edge to edge, so a touch under the badge keeps them the visual weight of
    /// the text beside them.
    static let logoScale: CGFloat = 0.72
}

/// "+2" after the first three badges on a row, as plain text like the logos.
struct MoreBadgeView: View {
    let count: Int
    let theme: ThemeColors
    var height: CGFloat = 18

    var body: some View {
        Text("+\(count)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 1)
            .frame(height: height)
    }
}
