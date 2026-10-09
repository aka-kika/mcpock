import SwiftUI

/// The Servers pane (v1.5 spec, Phase 5; a grouped form since round 8): one
/// row per server with its health mark, tool count and a three-way "Show as"
/// control. Round 8: the control is three icons (pin, eye, eye.slash for
/// Pinned, Shown, Hidden; the names are tooltips and accessibility labels), so
/// the table and the window could get narrower.
///
/// Rows are in name order and stay put when a control changes, so a row never
/// jumps away from under the click. The form scrolls inside the fixed window.
struct SettingsServersPane: View {
    var monitor: HealthMonitor?
    let theme: ThemeColors

    static let intro = "Pin a server to keep it at the top of the panel, or hide it. Hidden servers leave "
        + "the panel, but mcpock still checks them and tells you if they break."

    static let showAsWidth: CGFloat = 96

    static let markedHelp = "Marked as intended: its agents are set up differently, and you marked that as "
        + "intended. Right-click it in the panel and choose Unmark as Intended to flag it again."

    /// Every discovered server, hidden ones included, by name.
    private var rows: [ServerGroup] {
        (monitor?.groups ?? []).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        let rows = self.rows
        Form {
            Section {
                if rows.isEmpty {
                    Text(monitor == nil ? "No servers yet." : "Still looking for servers\u{2026}")
                        .foregroundStyle(theme.textTertiary)
                } else {
                    ForEach(rows) { group in
                        row(group)
                    }
                }
            } header: {
                SettingsFormHeader(title: "What the panel shows", text: Self.intro, theme: theme)
            } footer: {
                footer(rows)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .panelScrollIndicators()
    }

    private func row(_ group: ServerGroup) -> some View {
        let hidden = monitor?.isHidden(group.name) ?? false
        let tools = group.tools.count
        return HStack(spacing: 10) {
            HealthMark(state: group.state, theme: theme)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.name)
                    .foregroundStyle(hidden ? theme.textTertiary : theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if tools > 0 {
                    Text("\(tools) tool\(tools == 1 ? "" : "s")")
                        .font(Theme.caption)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
                if group.isDifferentOnPurpose {
                    // 1.5.2: a small marker, no control (the card and the
                    // right-click menu take it back).
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                        .help(Self.markedHelp)
                        .accessibilityLabel("Marked as intended")
                }
            }
            Spacer(minLength: 8)
            showAsControl(for: group.name)
                .frame(width: Self.showAsWidth)
        }
    }

    private func showAsControl(for name: String) -> some View {
        NeutralSegments(
            options: ServerVisibility.allCases.map { ($0, $0.title) },
            selection: Binding(
                get: { monitor?.visibility(of: name) ?? .shown },
                set: { monitor?.setVisibility($0, name: name) }
            ),
            theme: theme,
            height: 20,
            fontSize: 11,
            accessibilityLabel: "Show \(name) as",
            symbols: ServerVisibility.allCases.map(\.systemImage),
            trackFill: theme.rowHighlight
        )
        .disabled(monitor == nil)
    }

    private func footer(_ rows: [ServerGroup]) -> some View {
        let pinned = rows.filter { monitor?.isPinned($0.name) ?? false }.count
        let hidden = rows.filter { monitor?.isHidden($0.name) ?? false }.count
        return Text(ServerVisibility.summary(total: rows.count, pinned: pinned, hidden: hidden))
            .font(Theme.caption)
            .foregroundStyle(theme.textTertiary)
    }
}
