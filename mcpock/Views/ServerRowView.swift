import SwiftUI

/// What a row can ask the panel to do. One value instead of five closures;
/// `PanelState.rowActions(for:)` builds it for both tabs.
struct ServerRowActions {
    let select: () -> Void
    let checkAgain: () -> Void
    let hide: () -> Void
    let togglePause: () -> Void
    /// "Allow this file" for a row waiting on a scan-only file's OK (r3 f9f2).
    let allowFile: () -> Void
    let togglePin: () -> Void
    /// "Mark as Intended" (true) / "Unmark as Intended" (false) (1.5.2).
    let setIntended: (Bool) -> Void
    /// "Ask an Agent" (1.5.3): a prompt that asks an agent to investigate and advise.
    let askAgent: () -> Void
}

/// One server in the list (premium look, 22 Nov): its mono icon, which also
/// carries the state, the name, pin, and one value on the right (the tool
/// count in words); for a row that needs you, a short reason in the state's
/// colour underneath. Tools and the full error moved to the detail card,
/// so the row no longer expands.
struct ServerRowView: View {
    let group: ServerGroup
    let theme: ThemeColors
    let isPinned: Bool
    let isSelected: Bool
    /// Being re-checked on its own (Check again): the health mark spins.
    var isChecking = false
    /// An agent asks about this server (1.16): a small dot after the name.
    var asksYou = false
    /// The row's one value, "5 of 7 tools" (22 Nov); the calls are in its tooltip.
    var counts = RowCounts(tools: 0)
    let actions: ServerRowActions
    @State private var isHovered = false

    /// Where the second line starts: past the health mark and its gap.
    static let noteIndent: CGFloat = 18 + 10

    var body: some View {
        Button(action: actions.select) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    // The icon carries the state (22 Nov): no dot on a fine server.
                    ServerIconView(icon: ServerIcons.icon(for: group), theme: theme,
                                   badge: ServerIconView.badgeState(for: HealthMark.markState(for: group)),
                                   checking: isChecking, word: HealthMark.word(for: group))

                    Text(group.name)
                        .font(Theme.body)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if asksYou {
                        Circle()
                            .fill(theme.textSecondary)
                            .frame(width: 6, height: 6)
                            .help("An agent asks you about this server: open its card")
                            .accessibilityLabel("An agent asks you about it")
                    }

                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.textTertiary)
                            .accessibilityLabel("Pinned")
                    }

                    Spacer(minLength: 6)

                    // A row that needs you shows Check again under the pointer:
                    // before, it lived only on the card, the right-click menu
                    // and Cmd-R (open loop 2026-10-10, r3 50f1).
                    if isHovered && PanelSections.needsYou(group) {
                        Button(action: actions.checkAgain) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(CardAction.checkAgain.title)
                        .accessibilityLabel(CardAction.checkAgain.title)
                    }

                    // One value (22 Nov): the count in words. The agents and
                    // the calls are in the tooltip and on the card.
                    RowCountsLabel(counts: counts, theme: theme, noTools: Self.showsNoTools(group),
                                   extraHelp: Self.usedBy(group))
                }

                if let note = ShortReason.line(for: group) {
                    Text(note)
                        .font(Theme.caption)
                        .foregroundStyle(noteColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, Self.noteIndent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(fill)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: CardAction.checkAgain.title, actions.checkAgain)
        .contextMenu { ServerContextMenu(group: group, isPinned: isPinned, actions: actions) }
    }

    /// Every row is at least this tall, so one-line rows line up (22 Nov).
    static let minHeight: CGFloat = 36

    /// A broken server that never gave its tools reads "No tools" (22 Nov,
    /// Kika's pick), where a lone dim call count used to stand.
    static func showsNoTools(_ group: ServerGroup) -> Bool {
        group.state == .broken && group.tools.isEmpty
    }

    /// "Used by Claude Code, Cursor": the tooltip's second line, now that the
    /// agent icons left the row.
    static func usedBy(_ group: ServerGroup) -> String? {
        let agents = group.agents.map(AgentBadge.displayLabel)
        return agents.isEmpty ? nil : "Used by " + agents.joined(separator: ", ")
    }

    private var fill: Color {
        if isSelected { return theme.rowSelected }
        return isHovered ? theme.rowHighlight : .clear
    }

    private var noteColor: Color {
        // Not checked here is calm, like its dash (r3 b964, 5f42).
        if group.notCheckedHere { return theme.textSecondary }
        switch group.state {
        case .broken: return theme.badText
        case .degraded: return theme.warnText
        // "Off in Cursor" is her choice, not a warning.
        case .healthy: return group.attentionWhileHealthy ? theme.warnText : theme.textTertiary
        case .unknown, .selfManaged, .paused, .off: return theme.textTertiary
        case .needsApp: return theme.textSecondary
        }
    }

}

/// A row's one value (premium look, 22 Nov, Kika's picks): the count in
/// words, "5 of 7 tools", "29 servers", or "No tools" for a broken server
/// that never gave any. One view for server rows on both tabs and the
/// agents' own rows, so the same thing always looks the same; the calls and
/// the rest are in the tooltip.
struct RowCountsLabel: View {
    let counts: RowCounts
    let theme: ThemeColors
    var size: CGFloat = 11.5
    /// "No tools", in the broken text tone, in place of the count.
    var noTools = false
    /// A second tooltip line ("Used by Claude Code, Cursor").
    var extraHelp: String? = nil

    private var help: String {
        [noTools ? "No tools: it never answered" : counts.help, extraHelp ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var body: some View {
        if let text = noTools ? "No tools" : counts.words {
            Text(text)
                .font(.system(size: size, design: .rounded).monospacedDigit())
                .foregroundStyle(noTools ? theme.badText : theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .help(help)
                .accessibilityLabel(help)
        }
    }
}

/// A server's right-click menu, the same in the Servers tab, inside an open
/// agent and on the card's title (round 5). Kept from v1.4: pause, hide, copy;
/// round 5 added Check again (the card's button, so it spins there too).
/// 1.13: Copy Errors (only with an error) and Ask an Agent (only for a row
/// that needs you); Copy All Problems lives on the agent rows and the footer.
/// A row marked as intended offers only Unmark as Intended, never Mark again.
struct ServerContextMenu: View {
    let group: ServerGroup
    let isPinned: Bool
    let actions: ServerRowActions

    var body: some View {
        if group.awaitsFileOK {
            Button(action: actions.allowFile) {
                Label(CardAction.allowFile.title, systemImage: CardAction.allowFile.systemImage)
            }
        }
        if group.state == .paused {
            if group.isPausedByUser {
                Button(action: actions.togglePause) { Label("Resume checks", systemImage: "play.circle") }
            }
        } else {
            Button(action: actions.checkAgain) { Label("Check again", systemImage: "arrow.clockwise") }
            Button(action: actions.togglePause) { Label("Pause checks", systemImage: "pause.circle") }
        }
        Button(action: actions.togglePin) {
            if isPinned {
                Label("Unpin", systemImage: "pin.slash")
            } else {
                Label("Pin to top", systemImage: "pin")
            }
        }
        Button(action: actions.hide) { Label("Hide this server", systemImage: "eye.slash") }
        if let item = MenuText.intendedItem(for: group) {
            Button { actions.setIntended(item.marks) } label: {
                Label(item.title, systemImage: item.systemImage)
            }
        }
        if MenuText.copyError(for: group) != nil || ServerReport.canAskAgent(group) {
            Divider()
        }
        if let errors = MenuText.copyError(for: group) {
            Button { PanelState.copyToPasteboard(errors) } label: {
                Label(MenuText.copyErrorsTitle, systemImage: "exclamationmark.bubble")
            }
        }
        if ServerReport.canAskAgent(group) {
            Button(action: actions.askAgent) {
                Label(MenuText.askAgentTitle, systemImage: "text.bubble")
            }
        }
    }
}
