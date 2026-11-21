import SwiftUI

/// Three quiet tiles under the tabs, on both tabs (premium look, 22 Nov,
/// Kika's pick): servers in use, tools turned off, need you. The label once,
/// the number big, one grey line. Only the Need you number takes a status
/// colour; with nothing to do it reads "All fine" in grey, never a tick.
/// Plain fills: the tiles are content, the glass stays on the panel's shell.
struct OverviewTilesView: View {
    let overview: PanelOverview
    let theme: ThemeColors

    /// The tile itself; `MenuBarPanelView.overviewHeight` adds the space around it.
    static let tileHeight: CGFloat = 66

    var body: some View {
        HStack(spacing: 8) {
            tile("Servers in use", number: "\(overview.inUse)", line: overview.inUseLine)
            tile("Tools turned off", number: "\(overview.toolsOff)", line: overview.toolsOffLine)
            needYouTile
        }
    }

    private var needYouTile: some View {
        Group {
            if overview.needYou > 0 {
                tile("Need you", number: "\(overview.needYou)", line: overview.needYouLine,
                     numberColor: overview.hasBroken ? theme.statusBroken : theme.statusDegraded)
            } else {
                tile("Need you", number: nil, line: overview.checkingLine ?? "", calmWord: "All fine")
            }
        }
    }

    private func tile(_ label: String, number: String?, line: String,
                      numberColor: Color? = nil, calmWord: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
            Group {
                if let number {
                    Text(number)
                        .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(numberColor ?? theme.textPrimary)
                } else {
                    Text(calmWord ?? "")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(height: 28, alignment: .leading)
            Text(line.isEmpty ? " " : line)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.tileHeight)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.rowHighlight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([label, number ?? calmWord ?? "", line].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
