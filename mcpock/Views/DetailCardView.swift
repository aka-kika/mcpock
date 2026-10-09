import AppKit
import SwiftUI

/// Root of the card window: resolves the theme, finds the selected row and hands
/// the measured content height back to the presenter.
struct DetailCardHost: View {
    @Bindable var state: PanelState
    let onHeight: (CGFloat) -> Void
    @AppStorage(AppPreferences.themeKey) private var themeRaw = AppPreferences.defaultTheme.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var appTheme: AppTheme { AppTheme(rawValue: themeRaw) ?? .system }

    var body: some View {
        let scheme = appTheme.resolvedScheme(systemFallback: colorScheme)
        let isGlass = appTheme == .glass
        let theme = ThemeColors.resolve(scheme, forGlass: isGlass)
        ZStack(alignment: .top) {
            PanelBackdrop(scheme: scheme, isGlass: isGlass, cornerRadius: DetailCardPresenter.cornerRadius)
            if let group = state.selectedGroup {
                DetailCardView(group: group, state: state, theme: theme, onHeight: onHeight)
                    // Fresh view state (the copied flash, hover) per server.
                    .id(group.name)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: DetailCardPresenter.cornerRadius, style: .continuous)
                .strokeBorder(theme.divider, lineWidth: 1)
        }
        .environment(\.colorScheme, scheme)
        // The row went away under the open card (a rescan dropped it, or it was
        // hidden from its context menu): close rather than show an empty card.
        .onChange(of: state.selectedGroup == nil) { _, missing in
            if missing { state.closeCard() }
        }
    }
}

/// The detail card (v1.5 spec, Phase 3): what a row can't fit. Health and the
/// word for it, why it is broken or slow, how the agents' setups differ, which
/// agents use it (with their config files), its tools, and the row's actions.
struct DetailCardView: View {
    let group: ServerGroup
    @Bindable var state: PanelState
    let theme: ThemeColors
    let onHeight: (CGFloat) -> Void
    /// "+n more" under "Used by" was clicked: list every agent.
    @State private var showsAllSources = false
    /// "+N more" under the tools was clicked: list every tool (1.5.3).
    @State private var showsAllTools = false

    var body: some View {
        ScrollView(.vertical) {
            Group {
                if state.isComparing {
                    compareSetups
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    details
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .padding(16)
            .frame(width: DetailCardPresenter.width, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        }
        .panelScrollIndicators()
        .animation(.easeInOut(duration: 0.16), value: state.isComparing)
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                titleRow
                Text(CardText.subLine(for: group, now: Date()))
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.leading, HealthMark.boxSize + 10)
            }
            .contentShape(Rectangle())
            // The same server menu as the rows (1.5.3: "everywhere").
            .contextMenu {
                ServerContextMenu(
                    group: group,
                    isPinned: state.monitor.isPinned(group.name),
                    actions: state.rowActions(for: group.name)
                )
            }
            ForEach(CardText.problems(for: group), id: \.self) { problem in
                switch problem {
                case .why: whyBox
                case .differs: differsBox
                case .marked: markedLine
                }
            }
            if let note = quietNote {
                Text(note)
                    .font(Theme.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.fieldFill)
                    }
            }
            usedBy
            tools
            actions
        }
    }

    private var tone: Color {
        switch group.state {
        case .broken: return theme.statusBroken
        case .degraded: return theme.statusDegraded
        case .healthy: return group.differsNeedsAttention ? theme.statusDegraded : theme.statusHealthy
        case .unknown, .selfManaged, .paused: return theme.textSecondary
        }
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            HealthMark(state: group.state, theme: theme, checking: state.isChecking(group.name))
            Text(group.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(HealthMark.word(for: group))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tone)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(tone.opacity(0.12)))
                .fixedSize()
        }
    }

    /// Paused and self-managed rows aren't checked; an unknown row hasn't been yet.
    private var quietNote: String? {
        switch group.state {
        case .paused:
            return "Paused. mcpock won't launch this server until you resume it (right-click the row)."
        case .selfManaged:
            let host = CardText.list(group.agents.map(AgentBadge.displayLabel))
            return "Built into \(host). It runs inside that app, so mcpock doesn't check it."
        case .unknown:
            return "Waiting for the first check."
        case .healthy, .degraded, .broken:
            return nil
        }
    }

    private var whyBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(CardText.whyTitle(for: group))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(CardText.whyLines(for: group), id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(tone)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Layout B (1.5.3): one row of two equal-width buttons.
            HStack(spacing: Self.buttonGap) {
                askAgentButton
                CopyFlashButton(
                    title: CardText.copyErrorsButton,
                    help: "Copy the error report, ready to paste",
                    theme: theme
                ) {
                    PanelState.copyToPasteboard(group.copyText)
                    return true
                }
                // "Open log" would sit here; no probe keeps a log file yet, so it
                // is left out rather than shown disabled.
            }
        }
        .modifier(ToneBox(tone: tone))
    }

    /// Gap between the problem boxes' buttons, across and down.
    private static let buttonGap: CGFloat = 6

    private var askAgentButton: some View {
        CopyFlashButton(
            title: CardText.askAgentButton,
            help: "Copy a prompt that asks an agent to look into this and advise, without changing anything",
            theme: theme
        ) { state.askAgent(group.name) }
    }

    private var differsBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set up differently")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text(CardText.differsSentence(for: group))
                .font(.system(size: 12))
                .foregroundStyle(theme.statusDegraded)
                .fixedSize(horizontal: false, vertical: true)
            // Layout B (1.5.3): two by two, every button the same width and
            // height, nothing wraps.
            VStack(spacing: Self.buttonGap) {
                HStack(spacing: Self.buttonGap) {
                    CardButton(
                        title: CardText.compareButton,
                        fillsWidth: true,
                        help: "Compare each agent's setup side by side",
                        theme: theme
                    ) { state.isComparing = true }
                    askAgentButton
                }
                HStack(spacing: Self.buttonGap) {
                    CopyFlashButton(
                        title: CardText.copyDetailsButton,
                        help: "Copy this server's details (secret values hidden)",
                        theme: theme
                    ) { state.copyServerDetails(group.name) }
                    CardButton(
                        title: CardText.markAsIntendedButton,
                        fillsWidth: true,
                        help: "The agents are meant to differ. mcpock stops flagging it until a setup changes.",
                        theme: theme
                    ) { state.setMarkedAsIntended(true, name: group.name) }
                }
            }
        }
        .modifier(ToneBox(tone: theme.statusDegraded))
    }

    /// The quiet trace of a row marked as intended, with the way back. It
    /// replaces the "Set up differently" box, so Mark is never offered twice.
    private var markedLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.textTertiary)
            Text(CardText.markedLine)
                .font(Theme.caption)
                .foregroundStyle(theme.textSecondary)
                .help(CardText.onPurposeSentence(for: group))
            Text("\u{00B7}")
                .font(Theme.caption)
                .foregroundStyle(theme.textTertiary)
            QuietLinkButton(title: CardText.undoButton, theme: theme) {
                state.setMarkedAsIntended(false, name: group.name)
            }
            .help("Unmark as intended: flag the differences again")
            Spacer(minLength: 0)
        }
        .padding(.leading, HealthMark.boxSize + 10)
    }

    private var usedBy: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: CardText.usedByTitle(for: group), count: nil, theme: theme)
                .padding(.bottom, 2)
            let shown = CardText.usedByRows(for: group, expanded: showsAllSources)
            ForEach(shown.rows) { source in
                usedByRow(source)
            }
            if shown.folded > 0 {
                moreSourcesRow(folded: shown.folded)
            }
        }
    }

    /// "+5 more": expands the list in place. The card grows with it, up to the
    /// panel's height, and scrolls past that.
    private func moreSourcesRow(folded: Int) -> some View {
        Button {
            showsAllSources = true
        } label: {
            HStack(spacing: 8) {
                // Lines up with the agent names above, past the 20pt badges.
                Text("+\(folded) more")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.leading, 28)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 24)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(CardText.usedByOrder(for: group).dropFirst(CardText.usedByLimit)
            .map { AgentBadge.displayLabel($0.label) }.joined(separator: ", "))
        .accessibilityLabel("Show \(folded) more agents")
    }

    private func usedByRow(_ source: GroupSource) -> some View {
        UsedByRow(
            source: source,
            differs: group.differs.contains { $0.label == source.label },
            theme: theme
        )
    }

    /// 1.5.3 ("the chips look messy"): the tools window's list style,
    /// name in monospace with its first-line description underneath. The first
    /// few show; "+N more" lists the rest in place and "Show less" folds them
    /// again. The card grows with the list up to the panel's height and
    /// scrolls past that, so the old "+N more" side window is gone.
    @ViewBuilder
    private var tools: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Tools \u{00B7} \(group.tools.count)", count: nil, theme: theme)
            if group.tools.isEmpty {
                Text(group.state == .unknown ? "Tools show up after the first check." : "No tools reported.")
                    .font(Theme.caption)
                    .foregroundStyle(theme.textTertiary)
            } else {
                let shown = CardText.toolRows(for: group, expanded: showsAllTools)
                ToolsList(tools: shown.rows, theme: theme, rowInset: 0)
                if shown.folded > 0 || showsAllTools && group.tools.count > CardText.toolsLimit {
                    ShowMoreRow(
                        title: showsAllTools ? CardText.showLessTitle : CardText.showMoreTitle(folded: shown.folded),
                        expanded: showsAllTools,
                        help: showsAllTools ? "Show only the first \(CardText.toolsLimit)" : CardText.showMoreHelp(folded: shown.folded),
                        theme: theme
                    ) {
                        showsAllTools.toggle()
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Rectangle().fill(theme.divider).frame(height: 1)
            HStack(spacing: 6) {
                // Round 6: icon-only, same frame; the words are the tooltip
                // and the accessibility label (`CardText.actionIcon`).
                if group.state == .paused {
                    iconButton(.resume) { state.togglePause(group.name) }
                } else {
                    iconButton(.checkAgain, spinning: state.isChecking(group.name)) {
                        state.checkAgain(group.name)
                    }
                    .disabled(state.isChecking(group.name))
                }
                iconButton(state.monitor.isPinned(group.name) ? .unpin : .pin) {
                    state.togglePin(group.name)
                }
                iconButton(.hide) { state.hide(group.name) }
                Spacer(minLength: 0)
            }
        }
    }

    private func iconButton(
        _ action: CardAction,
        spinning: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        CardButton(
            title: action.title,
            systemImage: action.systemImage,
            spinning: spinning,
            iconOnly: true,
            theme: theme,
            action: perform
        )
    }

    // MARK: - Compare setups

    /// The small "sheet": every declaration's command or URL, one under the other,
    /// with env and header names but never their values. It replaces the card's
    /// content (a real sheet would take key status and close the panel).
    private var compareSetups: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Compare setups")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                CardButton(title: "Done", theme: theme) { state.isComparing = false }
            }
            Text(group.name)
                .font(Theme.caption)
                .foregroundStyle(theme.textSecondary)
            // The odd one out first, as in "Used by".
            ForEach(CardText.usedByOrder(for: group)) { source in
                compareRow(source)
            }
            Text("Values of env variables and headers are hidden.")
                .font(Theme.caption)
                .foregroundStyle(theme.textTertiary)
        }
    }

    private func compareRow(_ source: GroupSource) -> some View {
        let differs = group.differs.contains { $0.label == source.label }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentBadgeView(badge: AgentBadge.forLabel(source.agent), theme: theme, size: 20)
                Text(AgentBadge.displayLabel(source.label))
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(source.transport.rawValue)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.textTertiary)
                Spacer(minLength: 4)
                if differs {
                    Text("differs")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(theme.statusDegraded)
                }
            }
            Text(source.target.isEmpty ? "(nothing set)" : CardText.shortTarget(source.target))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(differs ? theme.statusDegraded : theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            let secrets = CardText.maskedEnv(source.envKeys) + CardText.maskedHeaders(source.headerKeys)
            if !secrets.isEmpty {
                Text(secrets.joined(separator: "\n"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.fieldFill)
        }
    }
}

// MARK: - Small pieces

/// The "why" and "set up differently" boxes: the state's colour at 7% fill with
/// a 26% edge.
private struct ToneBox: ViewModifier {
    let tone: Color

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tone.opacity(0.07))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tone.opacity(0.26), lineWidth: 1)
            }
    }
}

/// A small bordered button for the card ("Compare", "Mark as intended"). With
/// `iconOnly` (round 6: Check again, Pin, Hide) it shows just the symbol in the
/// same frame and height; `title` becomes the tooltip and accessibility label.
/// With `fillsWidth` (1.5.3, the problem boxes' grid) it takes the width it is
/// offered, so buttons side by side share a row equally.
struct CardButton: View {
    let title: String
    var systemImage: String? = nil
    var spinning = false
    var iconOnly = false
    var fillsWidth = false
    /// Tooltip; the title when nil.
    var help: String? = nil
    let theme: ThemeColors
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    /// Height of a text button (12pt text + 4pt padding each side), so icon and
    /// text buttons line up in one row.
    static let iconSide: CGFloat = 15

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if iconOnly, let systemImage {
                    SpinnableIcon(systemName: systemImage, spinning: spinning)
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(width: Self.iconSide + 3, height: Self.iconSide)
                } else {
                    if let systemImage {
                        SpinnableIcon(systemName: systemImage, spinning: spinning)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(title)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .font(.system(size: 12))
            .foregroundStyle(isEnabled ? theme.textPrimary : theme.textTertiary)
            .padding(.horizontal, iconOnly ? 5 : 10)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.fieldFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isHovered && isEnabled ? theme.rowHighlight : .clear)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.controlStroke, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help ?? title)
        .accessibilityLabel(title)
    }
}

/// A borderless text button in the secondary colour ("Undo" on the card's
/// "Marked as intended" line): quiet until hovered.
private struct QuietLinkButton: View {
    let title: String
    let theme: ThemeColors
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(isHovered ? theme.textPrimary : theme.textSecondary)
                .underline(isHovered)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
    }
}

/// A problem box button that copies something ("Ask an agent", "Copy
/// details", "Copy errors"; 1.5.3), then shows a short Claude-orange "Copied",
/// like Copy for Claude in Settings > Connect. An overlay, so the button keeps
/// its width and nothing shifts. Always fills its share of the row.
private struct CopyFlashButton: View {
    let title: String
    let help: String
    let theme: ThemeColors
    /// Copies; false when there was nothing to copy (no flash then).
    let copy: () -> Bool
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        CardButton(title: title, fillsWidth: true, help: help, theme: theme) {
            guard copy() else { return }
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.45)) { copied = false }
            }
        }
        .overlay {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.claudeOrange)
                Label("Copied", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.white)
            }
            .opacity(copied ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .accessibilityLabel(copied ? "Copied" : title)
    }
}

/// "+N more" / "Show less" under the card's tools: the same quiet row as
/// "+n more" under "Used by", text on the left, chevron on the right. Not
/// private (1.7): the Agents tab's server-list fold reuses it too.
struct ShowMoreRow: View {
    let title: String
    let expanded: Bool
    let help: String
    let theme: ThemeColors
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(isHovered ? theme.textPrimary : theme.textSecondary)
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 24)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Every tool given, one under the other: the name in monospace, its
/// first-line description underneath. The card's tools list (1.5.3; it was
/// the tools window's list until that window was dropped).
struct ToolsList: View {
    let tools: [MCPToolInfo]
    let theme: ThemeColors
    /// Horizontal padding of each row.
    var rowInset: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(tools) { tool in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !tool.firstLineDescription.isEmpty {
                        Text(tool.firstLineDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, rowInset)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(tool.description.isEmpty ? tool.name : tool.description)
            }
        }
    }
}

/// One "Used by" row (round 7: no open glyph). With a config file behind it,
/// right-click offers the shared path menu (round 8: Show in Finder, Copy Path,
/// Open Config… last; no double-click); a faint hover fill says the row does
/// something.
private struct UsedByRow: View {
    let source: GroupSource
    let differs: Bool
    let theme: ThemeColors
    @State private var isHovered = false

    var body: some View {
        let row = HStack(spacing: 8) {
            AgentBadgeView(badge: AgentBadge.forLabel(source.agent), theme: theme, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentBadge.displayLabel(source.label))
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if !source.path.isEmpty {
                    Text(CardText.shortPath(source.path))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if differs {
                Text("differs")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.statusDegraded)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.statusDegraded.opacity(0.12)))
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered && !source.path.isEmpty ? theme.rowHighlight : .clear)
        }
        .padding(.horizontal, -6)

        if source.path.isEmpty {
            row
        } else {
            row
                .onHover { isHovered = $0 }
                .configPathActions(source.path)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .configPathAccessibilityActions(source.path)
        }
    }
}
