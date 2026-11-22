import SwiftUI

/// Three quiet tiles under the tabs, on both tabs (premium look, 22 Nov,
/// Kika's picks): servers in use, tools turned off, need you. Every tile has
/// the same rhythm: the label, a number, one grey line. Thin outlines, no
/// fills (her second pick, 22 Nov: "calmer and more balanced"): the tiles are
/// content, the glass stays on the panel's shell.
///
/// - The middle tile says how many of how many: "149/388", the total smaller
///   and grey.
/// - Only the Need you number takes a status colour. With nothing to do it is
///   a quiet grey 0 with "all fine" under it, so the third tile weighs the
///   same as the other two; never a tick, never a big word.
struct OverviewTilesView: View {
    let overview: PanelOverview
    let theme: ThemeColors

    /// The tile itself; `MenuBarPanelView.overviewHeight` adds the space around it.
    static let tileHeight: CGFloat = 62

    var body: some View {
        HStack(spacing: 8) {
            tile("Servers in use", number: "\(overview.inUse)", line: overview.inUseLine)
            tile("Tools turned off", number: "\(overview.toolsOff)", total: overview.toolsTotalText, line: overview.toolsOffLine,
                 spoken: overview.toolsOffSpoken)
            tile("Need you", number: "\(overview.needYou)", line: overview.needYouLine,
                 numberColor: overview.needYou > 0 ? (overview.hasBroken ? theme.statusBroken : theme.statusDegraded) : theme.textTertiary,
                 quiet: overview.needYou == 0)
        }
    }

    private func tile(_ label: String, number: String, total: String? = nil, line: String,
                      numberColor: Color? = nil, quiet: Bool = false, spoken: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(number)
                    .font(.system(size: 20, weight: quiet ? .medium : .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(numberColor ?? theme.textPrimary)
                if let total {
                    Text(total)
                        .font(.system(size: 13.5, weight: .regular, design: .rounded).monospacedDigit())
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(height: 25, alignment: .leading)
            Text(line.isEmpty ? " " : line)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.tileHeight)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.controlStroke, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([label, spoken ?? number, line].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
