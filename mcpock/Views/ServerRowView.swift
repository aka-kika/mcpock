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

/// One server in the v1.5 list: health mark, name, pin, agent badges and tool
/// count on the first line; for a row that needs you, a short reason in the
/// state's colour underneath. Tools and the full error moved to the detail card,
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
    /// "70/100 tools · 130 calls" (11 Nov, 4b6a and 37f0).
    var counts = RowCounts(tools: 0)
    let actions: ServerRowActions
    @State private var isHovered = false

    /// Badges shown before the rest fold into "+N".
    static let badgeLimit = 3
    /// Where the second line starts: past the health mark and its gap.
    static let noteIndent: CGFloat = HealthMark.boxSize + 10

    var body: some View {
        Button(action: actions.select) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    HealthMark(state: HealthMark.markState(for: group), theme: theme, checking: isChecking,
                               word: HealthMark.word(for: group))

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

                    badges

                    RowCountsLabel(counts: counts, theme: theme)
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
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
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


    @ViewBuilder
    private var badges: some View {
        let agents = group.agents
        HStack(spacing: 5) {
            ForEach(agents.prefix(Self.badgeLimit), id: \.self) { agent in
                AgentBadgeView(badge: AgentBadge.forLabel(agent), theme: theme)
            }
            if agents.count > Self.badgeLimit {
                MoreBadgeView(count: agents.count - Self.badgeLimit, theme: theme)
                    .help(agents.dropFirst(Self.badgeLimit).map(AgentBadge.displayLabel).joined(separator: ", "))
            }
        }
        .fixedSize()
    }
}

/// A row's numbers: "9/54 · 74", the calls and their dot dimmer (12 Nov,
/// Kika's picks). One view for server rows on both tabs and the agents' own
/// rows, so the same thing always looks the same; the words are in the
/// tooltip.
struct RowCountsLabel: View {
    let counts: RowCounts
    let theme: ThemeColors
    var size: CGFloat = 11

    var body: some View {
        let on = counts.onPart
        let calls = counts.callsPart
        if on != nil || calls != nil {
            HStack(spacing: 4) {
                if let on {
                    Text(on).foregroundStyle(theme.textSecondary)
                }
                if on != nil && calls != nil {
                    Text("\u{00B7}").foregroundStyle(theme.textDim)
                }
                if let calls {
                    Text(calls).foregroundStyle(theme.textDim)
                }
            }
            .font(.system(size: size).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .help(counts.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(counts.help)
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
