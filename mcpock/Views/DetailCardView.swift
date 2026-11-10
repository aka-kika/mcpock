import SwiftUI

/// Root of the card window: resolves the theme, finds the selected row and hands
/// the measured content height back to the presenter.
struct DetailCardHost: View {
    @Bindable var state: PanelState
    let onHeight: (CGFloat) -> Void
    @AppStorage(AppPreferences.themeKey, store: AppPreferences.store) private var themeRaw = AppPreferences.defaultTheme.rawValue
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
    /// The "Not used in 30 days" and "Hidden" folds under the tools (Part 2).
    @State private var showsUnusedTools = false
    @State private var showsHiddenTools = false
    @AppStorage(AppPreferences.usageWindowKey, store: AppPreferences.store) private var usageWindowRaw = UsageWindow.default.rawValue
    private var usageWindow: UsageWindow { UsageWindow(rawValue: usageWindowRaw) ?? .default }
    @State private var contentHeight: CGFloat = 0

    /// The card is as tall as its content, plus the sheet's pinned buttons.
    private func reportHeight() {
        onHeight(contentHeight + (state.pendingSwitch == nil ? 0 : SwitchSheetButtons.height))
    }

    var body: some View {
        ScrollView(.vertical) {
            Group {
                if let plan = state.pendingSwitch {
                    SwitchSheet(plan: plan, state: state, theme: theme)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if state.isComparing {
                    compareSetups
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    details
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .padding(16)
            .frame(width: DetailCardPresenter.width, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .panelScrollIndicators()
        // The sheet's buttons stay in view however many agents it lists
        // (seen in the VM: with six, Turn Off was below the fold).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let plan = state.pendingSwitch {
                SwitchSheetButtons(plan: plan, state: state, theme: theme)
            }
        }
        .onChange(of: contentHeight) { _, _ in reportHeight() }
        .onChange(of: state.pendingSwitch != nil) { _, _ in reportHeight() }
        .animation(.easeInOut(duration: 0.16), value: state.isComparing)
        .animation(.easeInOut(duration: 0.16), value: state.pendingSwitch != nil)
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
            if let warning = CardText.plainHTTPWarning(for: group) {
                Text(warning)
                    .font(Theme.caption)
                    .foregroundStyle(theme.statusDegraded)
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
        case .healthy: return group.attentionWhileHealthy ? theme.statusDegraded : theme.statusHealthy
        case .unknown, .selfManaged, .paused, .needsApp, .off: return theme.textSecondary
        }
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            HealthMark(state: HealthMark.markState(for: group), theme: theme, checking: state.isChecking(group.name),
                       word: HealthMark.word(for: group))
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
            return CardText.awaitingFileNote(for: group)
                ?? "Paused. mcpock won't launch this server until you resume it (right-click the row)."
        case .selfManaged:
            if let cloud = AgentRegistry.cloudHost(forAgents: group.agents) {
                return CardText.cloudNote(agents: group.agents, cloud: cloud)
            }
            let host = CardText.list(group.agents.map(AgentBadge.displayLabel))
            return "Built into \(host). It runs inside that app, so mcpock doesn't check it."
        case .off:
            return "Turned off in every agent that has it, so nothing starts it and mcpock doesn't check it."
        case .unknown:
            return "Waiting for the first check."
        case .needsApp:
            let app = group.needsAppName ?? "its app"
            return "Needs \(app) open. It belongs to \(app), which is closed, so it can't answer now. "
                + "mcpock checks it again once \(app) is running."
        case .healthy, .degraded, .broken:
            // Another source is checked, but one waits for its file's OK: say so.
            return CardText.sessionDropNote(group.droppedInSession ? group.sessionDrops : [], now: Date())
                ?? CardText.awaitingFileNote(for: group)
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
            nextStepLine
            // A quiet way to the config, without the right-click and the
            // warning (r3 50f1): Finder only, mcpock never opens it for editing.
            if let path = CardText.failingConfigPath(for: group) {
                Button("Show \(CardText.shortPath(path)) in Finder") { ConfigFileActions.showInFinder(path) }
                    .buttonStyle(.link)
                    .font(Theme.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Layout B (1.5.3): one row of two equal-width buttons. Not on a Not
            // checked row: nothing is failing there, and Ask copied nothing
            // (review 2026-10-30, f241).
            if !group.notCheckedHere {
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
        }
        .modifier(ToneBox(tone: tone))
    }

    /// "Next step: …" (1.13), the same words agents read in `mcpock_problems`.
    @ViewBuilder
    private var nextStepLine: some View {
        if let step = NextStep.line(for: group) {
            Text("Next step: \(step)")
                .font(Theme.caption)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Gap between the problem boxes' buttons, across and down.
    private static let buttonGap: CGFloat = 6

    private var askAgentButton: some View {
        CopyFlashButton(
            title: CardText.askAgentButton,
            help: "Copy a prompt that asks an agent to look into this and advise, without changing anything",
            theme: theme,
            copiedTitle: CardText.askAgentCopied
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
            nextStepLine
            // Every button the same height, nothing wraps; Ask an agent alone
            // carries the details and the errors (1.13: Copy details is gone).
            VStack(spacing: Self.buttonGap) {
                HStack(spacing: Self.buttonGap) {
                    CardButton(
                        title: CardText.compareButton,
                        fillsWidth: true,
                        help: "Compare each agent's setup side by side",
                        theme: theme
                    ) { state.isComparing = true }
                    CardButton(
                        title: CardText.markAsIntendedButton,
                        fillsWidth: true,
                        help: "The agents are meant to differ. mcpock stops flagging it until a setup changes.",
                        theme: theme
                    ) { state.setMarkedAsIntended(true, name: group.name) }
                }
                askAgentButton
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
            HStack(spacing: 8) {
                SectionHeader(title: CardText.usedByTitle(for: group), count: nil, theme: theme)
                // One switch for every agent that has one ("All 5", 10 Nov; a button in 1.14).
                if state.monitor.switchesEnabled, let everywhere = CardText.everywhereSwitch(for: group) {
                    everywhereControl(everywhere)
                }
            }
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

    /// "All 5" and a switch, lined up with the agents' switches below
    /// (Kika's pick, Mocker 10 Nov). Opens the same sheet as before.
    private func everywhereControl(_ everywhere: CardText.EverywhereSwitch) -> some View {
        HStack(spacing: 8) {
            Text(everywhere.label)
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
            MiniSwitch(isOn: !everywhere.turnOn, theme: theme) {
                state.askSwitch(group.name, turnOn: everywhere.turnOn)
            }
            .help(everywhere.actionTitle)
            .accessibilityLabel(everywhere.actionTitle)
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

    private func toolNote(for source: GroupSource) -> String? {
        guard !source.isOff else { return nil }
        let hidden = state.hiddenTools(for: group.name)
        return CardText.toolNote(canHide: hidden[source.configID] != nil, hiddenHere: hidden[source.configID]?.count ?? 0,
                                 anyHidden: hidden.values.contains { !$0.isEmpty }, toolCount: group.tools.count)
    }

    private func usedByRow(_ source: GroupSource) -> some View {
        UsedByRow(
            source: source,
            differs: group.differs.contains { $0.label == source.label },
            theme: theme,
            note: state.switchNotes[source.configID],
            toolNote: toolNote(for: source),
            flip: source.canSwitch && state.monitor.switchesEnabled
                ? { state.askSwitch(group.name, source: source, turnOn: source.isOff) } : nil
        )
    }

    /// 1.5.3 ("the chips look messy"): the tools window's list style,
    /// name in monospace with its first-line description underneath. The first
    /// few show; "+N more" lists the rest in place and "Show less" folds them
    /// again. The card grows with the list up to the panel's height and
    /// scrolls past that, so the old "+N more" side window is gone.
    ///
    /// Part 2 (Kika's pick, 2026-11-10): a switch beside each tool, most-used
    /// first with their calls, the ones not used in the Usage window folded
    /// with one "Hide all" button, the hidden ones folded last. A switch
    /// never writes: it opens the sheet.
    @ViewBuilder
    private var tools: some View {
        let hidden = state.hiddenTools(for: group.name)
        let canHide = state.monitor.switchesEnabled && !hidden.isEmpty && group.state != .off
        let usage = state.usageStore?.toolUsage(server: group.name, window: usageWindow)
        let sections = CardText.toolSections(tools: group.tools, usage: usage, hidden: hidden,
                                             labels: Dictionary(group.sources.map { ($0.configID, $0.label) },
                                                                uniquingKeysWith: { first, _ in first }))
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: ["Tools \u{00B7} \(group.tools.count)", usage == nil ? nil : CardText.callsWindowTitle(window: usageWindow)]
                .compactMap { $0 }.joined(separator: " \u{00B7} "), count: nil, theme: theme)
            if group.tools.isEmpty {
                Text(group.state == .unknown ? "Tools show up after the first check." : "No tools reported.")
                    .font(Theme.caption)
                    .foregroundStyle(theme.textTertiary)
            } else {
                let (shown, folded) = CardText.toolRows(sections.used, expanded: showsAllTools)
                toolRows(shown, canHide: canHide)
                if folded > 0 || showsAllTools && sections.used.count > CardText.toolsLimit {
                    ShowMoreRow(
                        title: showsAllTools ? CardText.showLessTitle : CardText.showMoreTitle(folded: folded),
                        expanded: showsAllTools,
                        help: showsAllTools ? "Show only the first \(CardText.toolsLimit)" : CardText.showMoreHelp(folded: folded),
                        theme: theme
                    ) {
                        showsAllTools.toggle()
                    }
                }
                if !sections.unused.isEmpty {
                    toolFold(title: "\(CardText.unusedTitle(window: usageWindow)) \u{00B7} \(sections.unused.count)",
                             expanded: showsUnusedTools,
                             hideAll: canHide ? sections.unused.map(\.tool.name) : nil) { showsUnusedTools.toggle() }
                    if showsUnusedTools { toolRows(sections.unused, canHide: canHide) }
                }
                if !sections.hidden.isEmpty {
                    toolFold(title: "Hidden \u{00B7} \(sections.hidden.count)", expanded: showsHiddenTools,
                             showAll: canHide ? sections.hidden.map(\.tool.name) : nil) {
                        showsHiddenTools.toggle()
                    }
                    if showsHiddenTools { toolRows(sections.hidden, canHide: canHide) }
                }
            }
        }
        .task(id: "\(group.name)|\(group.tools.count)|\(group.sources.count)") { state.loadHiddenTools(for: group.name) }
    }

    private func toolRows(_ rows: [CardText.ToolRow], canHide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                ToolSwitchRow(row: row, theme: theme, flip: canHide ? {
                    if row.hiddenEverywhere {
                        state.askToolSwitch(group.name, show: [row.tool.name])
                    } else {
                        state.askToolSwitch(group.name, hide: [row.tool.name])
                    }
                } : nil)
            }
        }
    }

    /// "Not used in 30 days · 22   [Hide all 22…]" / "Hidden · 1", a line
    /// that opens its tools in place.
    private func toolFold(title: String, expanded: Bool, hideAll: [String]? = nil, showAll: [String]? = nil,
                          toggle: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Rectangle().fill(theme.divider).frame(height: 1)
            HStack(spacing: 8) {
                ShowMoreRow(title: title, expanded: expanded, help: expanded ? "Fold these tools" : "Show these tools",
                            theme: theme, action: toggle)
                if let hideAll {
                    CardButton(title: "Hide all \(hideAll.count)", help: "Hide every tool in this group", theme: theme) {
                        state.askToolSwitch(group.name, hide: hideAll)
                    }
                    .fixedSize()
                }
                if let showAll {
                    CardButton(title: "Show all \(showAll.count)", help: "Show every hidden tool again", theme: theme) {
                        state.askToolSwitch(group.name, show: showAll)
                    }
                    .fixedSize()
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
                if group.awaitsFileOK {
                    iconButton(.allowFile) { state.allowFile(group.name) }
                }
                if group.state == .paused {
                    if group.isPausedByUser {
                        iconButton(.resume) { state.togglePause(group.name) }
                    }
                } else if group.state != .off {
                    // Labeled: the key fix action was an unlabeled arrow (r3 50f1).
                    iconButton(.checkAgain, spinning: state.isChecking(group.name), labeled: true) {
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
        labeled: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        CardButton(
            title: action.title,
            systemImage: action.systemImage,
            spinning: spinning,
            iconOnly: !labeled,
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
/// errors"; 1.5.3), then shows a short Claude-orange "Copied",
/// like Copy for Claude in Settings > Connect. An overlay, so the button keeps
/// its width and nothing shifts. Always fills its share of the row.
private struct CopyFlashButton: View {
    let title: String
    let help: String
    let theme: ThemeColors
    /// What the flash says ("Copied"; Ask an agent says where it goes).
    var copiedTitle = "Copied"
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
                Label(copiedTitle, systemImage: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.white)
            }
            .opacity(copied ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .accessibilityLabel(copied ? copiedTitle : title)
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

/// One "Used by" row (round 7: no open glyph). With a config file behind it,
/// right-click offers the shared path menu (round 8: Show in Finder, Copy Path,
/// Open Config… last; no double-click); a faint hover fill says the row does
/// something.
private struct UsedByRow: View {
    let source: GroupSource
    let differs: Bool
    let theme: ThemeColors
    /// "Off after Cursor reopens": what the last flip said, this session.
    var note: String? = nil
    /// "2 tools hidden" / "Sees all 26 tools: can't hide single tools" (Part 2).
    var toolNote: String? = nil
    /// Flips this agent's switch (opens the sheet); nil when mcpock has no
    /// way to switch it there.
    var flip: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        let row = HStack(spacing: 8) {
            AgentBadgeView(badge: AgentBadge.forLabel(source.agent), theme: theme, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentBadge.displayLabel(source.label))
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if let line = CardText.switchLine(isOff: source.isOff, note: note) {
                    Text(line)
                        .font(.system(size: 11))
                        // Calm gray, even right after a flip (Kika's pick, Mocker 10 Nov):
                        // the amber read 2.5:1 on light glass and turned the card yellow.
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                } else if !source.path.isEmpty {
                    Text(CardText.shortPath(source.path))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let toolNote {
                    Text(toolNote)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let flip {
                MiniSwitch(isOn: !source.isOff, theme: theme, action: flip)
                    .help(source.isOff ? "Turn on in \(AgentBadge.displayLabel(source.label))"
                        : "Turn off in \(AgentBadge.displayLabel(source.label))")
                    .accessibilityLabel("\(AgentBadge.displayLabel(source.label)) switch")
            }
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

/// One tool on the card (Part 2): name and first line of its description,
/// its calls and last use, and a switch when an agent can hide it.
struct ToolSwitchRow: View {
    let row: CardText.ToolRow
    let theme: ThemeColors
    /// Opens the sheet; nil when no agent of this server can hide tools.
    let flip: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.tool.name)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(row.hiddenEverywhere ? theme.textTertiary : theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !row.hiddenIn.isEmpty {
                    Text("Hidden in \(CardText.list(row.hiddenIn))")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                } else if !row.tool.firstLineDescription.isEmpty {
                    // Masked: a server that got a header could echo it here (r3 505c).
                    Text(SecretMask.scrub(row.tool.firstLineDescription))
                        .font(.system(size: 11))
                        .foregroundStyle(row.hiddenEverywhere ? theme.textTertiary : theme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if let calls = row.calls {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(calls == 0 && row.lastDay == nil ? "never" : UsageText.compact(calls))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(calls == 0 ? theme.textTertiary : theme.textSecondary)
                    if let last = CardText.lastUsed(row.lastDay) {
                        Text(last)
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .help(row.lastDay == nil ? "No call on record" : "Calls in the Usage window; last used \(CardText.lastUsed(row.lastDay) ?? "")")
            }
            if let flip {
                MiniSwitch(isOn: !row.hiddenEverywhere, theme: theme, action: flip)
                    .help(row.hiddenEverywhere ? "Show \(row.tool.name) to your agents again" : "Hide \(row.tool.name) from your agents")
                    .accessibilityLabel("\(row.tool.name) switch")
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(row.tool.description.isEmpty ? row.tool.name : SecretMask.scrub(row.tool.description))
    }
}

/// A tick on a tools sheet: the agent is changed when it is ticked. `action`
/// nil is a greyed box (an agent that can't hide tools).
struct TickBox: View {
    let isOn: Bool
    let theme: ThemeColors
    let action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isOn ? theme.textSecondary : .clear)
                .frame(width: 14, height: 14)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(theme.controlStroke, lineWidth: isOn ? 0 : 1)
                }
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.background)
                    }
                }
                .opacity(action == nil ? 0.4 : 1)
                .padding(.top, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "ticked" : "not ticked")
    }
}

/// The small on/off switch beside an agent under "Used by" (1.14). A click
/// never writes: it opens the sheet that says what would change.
struct MiniSwitch: View {
    let isOn: Bool
    let theme: ThemeColors
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(isOn ? theme.statusHealthy : theme.selectedFill)
                .frame(width: 28, height: 16)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white.opacity(isOn ? 1 : 0.75))
                        .frame(width: 12, height: 12)
                        .padding(2)
                }
                .overlay { Capsule().strokeBorder(theme.controlStroke, lineWidth: isOn ? 0 : 1) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

/// What a flip of the switch would do, in place of the card's details (a real
/// sheet would take key and close the panel): each agent in plain words, when
/// it counts, the exact change one click away. Nothing is written until the
/// Turn Off / Turn On button (Kika's pick, 2026-11-10).
struct SwitchSheet: View {
    let plan: SwitchPlan
    @Bindable var state: PanelState
    let theme: ThemeColors

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(plan.isEmpty ? "Nothing to change" : plan.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !plan.isEmpty {
                Text(plan.reassuranceText)
                    .font(Theme.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(plan.changes) { change in
                Rectangle().fill(theme.divider).frame(height: 1)
                changeRow(change)
            }
            if plan.tools != nil {
                ForEach(plan.skipped, id: \.self) { agent in
                    Rectangle().fill(theme.divider).frame(height: 1)
                    skippedRow(agent)
                }
            }
            if !plan.isEmpty {
                Rectangle().fill(theme.divider).frame(height: 1)
                ShowMoreRow(
                    title: state.switchShowsChange ? "Hide the exact change" : "Show the exact change in each file",
                    expanded: state.switchShowsChange,
                    help: "The lines that change, keys hidden",
                    theme: theme
                ) { state.switchShowsChange.toggle() }
            }
            ForEach(CardText.switchNotes(for: plan), id: \.self) { line in
                Text(line)
                    .font(Theme.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = state.switchError {
                Text(error)
                    .font(Theme.caption)
                    .foregroundStyle(theme.statusBroken)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !plan.isEmpty {
                Text(SwitchPlan.backupLine)
                    .font(Theme.caption)
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    /// An agent that can't hide single tools, on a tools sheet: greyed, no tick.
    private func skippedRow(_ agent: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            TickBox(isOn: false, theme: theme, action: nil)
            AgentBadgeView(badge: AgentBadge.forLabel(CardText.agentLabel(forDisplay: agent)), theme: theme, size: 20)
                .opacity(0.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                Text("Can't hide single tools from its file. Use its own tool list, or turn \(plan.server) off there.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func changeRow(_ change: SwitchChange) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if plan.tools != nil {
                let ticked = !state.untickedPaths.contains(change.path)
                TickBox(isOn: ticked, theme: theme) {
                    if ticked { state.untickedPaths.insert(change.path) } else { state.untickedPaths.remove(change.path) }
                }
                .help(ticked ? "Leave \(change.agents.first ?? "this agent") as it is" : "Change \(change.agents.first ?? "this agent") too")
                .accessibilityLabel("\(change.agents.joined(separator: ", "))")
            }
            AgentBadgeView(badge: AgentBadge.forLabel(CardText.agentLabel(forDisplay: change.agents.first ?? "")),
                           theme: theme, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.agents.joined(separator: ", "))
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textPrimary)
                Text(change.what)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(change.when)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.switchShowsChange {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(CardText.shortPath(change.path))
                            .foregroundStyle(theme.textTertiary)
                        ForEach(Array(change.diff.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .foregroundStyle(line.hasPrefix("+") ? theme.statusHealthy
                                    : line.hasPrefix("-") ? theme.statusBroken : theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.fieldFill) }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        // Unticked: left as it is, so it reads quieter.
        .opacity(plan.tools != nil && state.untickedPaths.contains(change.path) ? 0.45 : 1)
    }
}

/// Cancel and Turn Off / Turn On, pinned under the sheet so they never
/// scroll out of view.
struct SwitchSheetButtons: View {
    let plan: SwitchPlan
    @Bindable var state: PanelState
    let theme: ThemeColors

    static let height: CGFloat = 47

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.divider).frame(height: 1)
            HStack(spacing: 6) {
                CardButton(title: plan.isEmpty ? "Close" : "Cancel", fillsWidth: true, theme: theme) { state.cancelSwitch() }
                if !plan.isEmpty {
                    let ticked = PanelState.ticked(plan, unticked: state.untickedPaths).changes.count
                    CardButton(title: plan.tools != nil && ticked != plan.changes.count
                                   ? "\(plan.confirmTitle) in \(ticked) agent\(ticked == 1 ? "" : "s")" : plan.confirmTitle,
                               fillsWidth: true, theme: theme) {
                        state.confirmSwitch()
                    }
                    .disabled(state.isApplyingSwitch || ticked == 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .frame(width: DetailCardPresenter.width, height: Self.height)
        .background(theme.background)
    }
}
