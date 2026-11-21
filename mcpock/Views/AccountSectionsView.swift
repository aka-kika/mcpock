import SwiftUI

/// The two sections under the agents (premium look, 22 Nov, Kika's picks):
/// "Claude account", the claude.ai connectors as Claude Code lists them, and
/// "Managed online", one row per agent whose servers live on the vendor's
/// site. Neither is checked by mcpock, so neither row opens a card: a
/// connector says what Claude Code said, a managed agent opens its page.
struct AccountSectionsView: View {
    @Bindable var panel: PanelState
    let theme: ThemeColors

    /// With the attention toggle pressed only the connectors with a problem
    /// stay, and the links (never a problem) leave.
    private var connectors: [ClaudeConnector] {
        panel.filter == .problems ? panel.connectors.filter { $0.state == .failing || $0.state == .needsSignIn } : panel.connectors
    }

    private var managed: [ManagedOnlineAgent] {
        panel.filter == .problems ? [] : panel.managedOnline
    }

    var body: some View {
        let connectors = self.connectors
        let managed = self.managed
        VStack(alignment: .leading, spacing: 0) {
            if panel.includesConnectors, !connectors.isEmpty || (panel.connectorsNote != nil && panel.filter != .problems) {
                header("Claude account", count: connectors.isEmpty ? nil : connectors.count)
                ForEach(connectors) { connector in
                    ConnectorRow(connector: connector, theme: theme)
                }
                Text(panel.connectorsNote ?? ClaudeConnectors.footnote)
                    .font(Theme.caption)
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, connectors.isEmpty ? 8 : 8 + HealthMark.boxSize + 10)
                    .padding(.trailing, 8)
                    .padding(.top, 4)
            }
            if !managed.isEmpty {
                header("Managed online", count: managed.count)
                ForEach(managed) { agent in
                    ManagedOnlineRow(agent: agent, names: panel.managedOnlineNames(for: agent), theme: theme)
                }
            }
        }
    }

    private func header(_ title: String, count: Int?) -> some View {
        SectionHeader(title: title, count: count, theme: theme)
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

/// "● Gmail  gmail.mcp.claude.com            Off in shop".
private struct ConnectorRow: View {
    let connector: ClaudeConnector
    let theme: ThemeColors

    private var help: String {
        var lines = ["\(connector.name), a claude.ai connector. Claude Code says: \(stateWords)."]
        if !connector.offProjects.isEmpty {
            lines.append("Switched off in: " + connector.offProjects.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private var stateWords: String {
        switch connector.state {
        case .connected: return "connected"
        case .failing: return "it could not connect"
        case .needsSignIn: return "it needs a sign-in"
        case .unknown: return "nothing mcpock can read"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            HealthMark(state: connector.mark, theme: theme, word: stateWords)
            Text(connector.name)
                .font(Theme.body)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            if !connector.host.isEmpty {
                Text(connector.host)
                    .font(Theme.caption)
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if let word = connector.word {
                Text(word)
                    .font(.system(size: 11.5))
                    .foregroundStyle(connector.wordIsProblem ? theme.badText : theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }
}

/// "☁ ChatGPT  notion, canva            Managed online ↗": a link, not a check.
private struct ManagedOnlineRow: View {
    let agent: ManagedOnlineAgent
    let names: [String]
    let theme: ThemeColors
    @State private var isHovered = false

    var body: some View {
        Button {
            if let url = URL(string: agent.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                // A cloud where a checked server has its mark: mcpock can't check these.
                Image(systemName: "cloud")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: HealthMark.boxSize + 4)
                    .accessibilityHidden(true)
                Text(agent.name)
                    .font(Theme.body)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !names.isEmpty {
                    Text(names.joined(separator: ", "))
                        .font(Theme.caption)
                        .foregroundStyle(theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                Text("Managed online")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isHovered ? theme.rowHighlight : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(agent.help)
        .accessibilityLabel("\(agent.name), managed online. \(agent.help)")
    }
}
