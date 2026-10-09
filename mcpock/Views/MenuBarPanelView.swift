import SwiftUI

/// The menu-bar panel (v1.5, round 2): a dashboard you scan rather than a list
/// you read. Top: only the `Servers | Agents` tabs, with the search field under
/// them while it's open. Then the sectioned list, and one thin footer row like
/// 1.4.1: the summary on the left, then the attention toggle, search, refresh and
/// settings glyphs.
struct MenuBarPanelView: View {
    @Bindable var monitor: HealthMonitor
    @Bindable var panel: PanelState
    @AppStorage(AppPreferences.themeKey) private var themeRaw = AppPreferences.defaultTheme.rawValue
    @Environment(\.inGlassPanel) private var inGlassPanel
    @Environment(\.colorScheme) private var systemColorScheme
    @FocusState private var searchFocused: Bool

    private var appTheme: AppTheme { AppTheme(rawValue: themeRaw) ?? .system }
    private var theme: ThemeColors {
        appTheme.resolvedColors(systemFallback: systemColorScheme)
    }

    // MARK: - Height budget
    //
    // MenuBarExtra sizes its window ONCE (at launch) and never resizes it, and
    // SwiftUI clips an over-tall child rather than compressing it. So the panel is
    // a fixed 380 × 560 and every block in it has a fixed height: the list gets
    // exactly what the chrome leaves (`listHeight(searchOpen:)`), and scrolls
    // inside that. The search field, when open, takes its height from the list.
    // `PanelLayoutTests` checks the blocks add up to the panel either way.

    nonisolated static let panelWidth: CGFloat = 380
    nonisolated static let panelHeight: CGFloat = 560
    /// The tabs: 10 above, the 24pt control, 8 below.
    nonisolated static let headerHeight: CGFloat = 42
    /// The search field (26pt) and the 8pt under it, only while it's open.
    nonisolated static let searchHeight: CGFloat = 34
    /// One thin row, like 1.4.1.
    nonisolated static let footerHeight: CGFloat = 30
    /// The two 1pt rules: under the tabs (or the search) and above the footer.
    nonisolated static let dividersHeight: CGFloat = 2
    /// The list must keep at least this much, or the panel stops being useful.
    nonisolated static let listMinHeight: CGFloat = 300

    /// Chrome above and below the list. Both tabs share it.
    nonisolated static func chromeHeight(searchOpen: Bool) -> CGFloat {
        headerHeight + (searchOpen ? searchHeight : 0) + footerHeight + dividersHeight
    }

    nonisolated static func listHeight(searchOpen: Bool) -> CGFloat {
        panelHeight - chromeHeight(searchOpen: searchOpen)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelTabControl(tab: $panel.tab, theme: theme)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .frame(height: Self.headerHeight)
            if panel.isSearchOpen {
                searchField
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(height: Self.searchHeight)
            }
            rule
            content
                .frame(height: Self.listHeight(searchOpen: panel.isSearchOpen))
            rule
            footer
                .frame(height: Self.footerHeight)
        }
        // Fixed size, not a min/max range: MenuBarExtra sizes its window ONCE
        // (at launch, while the list is still empty → the minimum) and never
        // grows it, so flexible heights render a clipped panel forever.
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        // Soft dark solid in Dark, the native menu material in Light: one shared
        // backdrop so the panel, the detail card and Settings can't drift.
        .background {
            PanelBackdrop(
                scheme: appTheme.resolvedScheme(systemFallback: systemColorScheme),
                isGlass: appTheme == .glass,
                // The Glass panel's window is ours and rounded (1.8); the
                // MenuBarExtra window draws its own shape.
                cornerRadius: inGlassPanel ? GlassPanelStyle.cornerRadius : 0
            )
        }
        .background {
            WindowReader { panel.panelWindow = $0 }
        }
        .onChange(of: panel.searchFocusRequest) { _, _ in
            searchFocused = true
        }
        .onChange(of: hasBroken) { _, broken in
            if broken { panel.resultsChanged() }
        }
        .onAppear { panel.panelOpened() }
        .onDisappear { panel.panelClosed() }
        // Rebuild when preference changes so MenuBarExtra cannot cache old colors.
        .id(themeRaw)
        .applyAppTheme(appTheme, systemFallback: systemColorScheme)
    }

    private var rule: some View {
        Rectangle()
            .fill(theme.divider)
            .frame(height: 1)
    }

    // MARK: - Search

    private var searchPlaceholder: String {
        panel.tab == .servers ? "Search servers or tools" : "Search agents or servers"
    }

    /// Opens from the footer's magnifier or ⌘F. Escape and Return (handled by
    /// `PanelState`'s key monitor, which sees them first) close and clear it.
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)

            TextField(searchPlaceholder, text: $panel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.textPrimary)
                .focused($searchFocused)
                .accessibilityLabel(searchPlaceholder)
                // The field appears in the same update that asks for focus, so
                // the request can land before it exists; ask again once it does.
                .onAppear { searchFocused = true }

            if !panel.query.isEmpty {
                Button { panel.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.fieldFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(theme.controlStroke, lineWidth: 1)
        }
    }

    /// Drives the Needs you jump when results arrive with the panel open.
    private var hasBroken: Bool {
        monitor.visibleGroups.contains { $0.state == .broken }
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        switch panel.tab {
        case .servers:
            serverList
        case .agents:
            agentList
        }
    }

    @ViewBuilder
    private var agentList: some View {
        let sections = panel.agentSections
        if !sections.isEmpty {
            AgentsListView(sections: sections, panel: panel, theme: theme)
        } else if !panel.query.trimmingCharacters(in: .whitespaces).isEmpty {
            emptyState("Nothing matches \u{201C}\(panel.query)\u{201D}",
                       detail: "Search looks at agent names and the servers they declare.")
        } else {
            // The attention toggle no longer empties this list on its own (round
            // 9): an agent with nothing wrong stays, dimmed, instead of leaving
            // the tab looking half empty. This is reached only when there are no
            // agents at all.
            emptyState("No agents found",
                       detail: "mcpock lists an agent once it finds an MCP server in its config.")
        }
    }

    @ViewBuilder
    private var serverList: some View {
        let sections = panel.sections
        if sections.isEmpty {
            emptyServers
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            SectionHeader(title: section.title, count: section.count, theme: theme)
                                .padding(.horizontal, 8)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(section.groups) { group in
                                row(group)
                                    .id(Self.rowID(section: section.kind, name: group.name))
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .panelScrollIndicators()
                // Arriving from the Agents tab with a server already selected.
                .onAppear {
                    if let name = panel.selectedName, let id = Self.rowID(forName: name, in: sections) {
                        proxy.scrollTo(id)
                    }
                }
                .onChange(of: panel.selectedName) { _, name in
                    guard let name, let id = Self.rowID(forName: name, in: sections) else { return }
                    withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
            }
        }
    }

    /// A row's identity, section included (the stale-row fix). The two nested
    /// `ForEach`s (sections, then groups) flatten into one list of rows inside
    /// the single `LazyVStack`, so a server keyed only by its name carries the
    /// *same* id whichever section it's in. A server that moved sections while
    /// the panel was open (Everything else -> Needs you, or the reverse from
    /// "Mark as intended") kept its old row — old ring, no note — until a tab
    /// switch rebuilt the whole list from scratch. Folding the section into the
    /// id means a cross-section move is a different id: the old row is removed
    /// and the new one is built fresh from the current state, instead of the
    /// `LazyVStack` trying to update one row in place across the move.
    nonisolated static func rowID(section: PanelSection.Kind, name: String) -> String {
        "\(section.rawValue)|\(name)"
    }

    /// The id for a server by name, wherever it lives in `sections` right now.
    /// `scrollTo` must target the row where it actually is today, not where a
    /// stale caller thinks it is.
    nonisolated static func rowID(forName name: String, in sections: [PanelSection]) -> String? {
        for section in sections where section.groups.contains(where: { $0.name == name }) {
            return rowID(section: section.kind, name: name)
        }
        return nil
    }

    private func row(_ group: ServerGroup) -> some View {
        let name = group.name
        return ServerRowView(
            group: group,
            theme: theme,
            isPinned: monitor.isPinned(name),
            isSelected: panel.selectedName == name,
            isChecking: panel.isChecking(name),
            actions: panel.rowActions(for: name)
        )
    }

    @ViewBuilder
    private var emptyServers: some View {
        if !panel.query.trimmingCharacters(in: .whitespaces).isEmpty {
            emptyState("Nothing matches \u{201C}\(panel.query)\u{201D}",
                       detail: "Search looks at server names, agents and tool names.")
        } else if monitor.groups.isEmpty && !monitor.hasCompletedFirstPass {
            emptyState("Looking for servers\u{2026}",
                       detail: "mcpock is reading your agents' config files.")
        } else if monitor.groups.isEmpty {
            emptyState("No MCP servers found",
                       detail: "Configure servers in Claude Code, Claude Desktop, Cursor or another agent.")
        } else if monitor.visibleGroups.isEmpty {
            emptyState("All servers hidden", detail: "Bring them back in Preferences.")
        } else if panel.filter == .problems {
            emptyState("Nothing needs you", detail: "Every server answered normally.")
        } else {
            emptyState("No servers", detail: "")
        }
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(Theme.body)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            if !detail.isEmpty {
                Text(detail)
                    .font(Theme.caption)
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    /// Any check running, the first pass after launch included (discovery runs
    /// before the first probe cycle, so `isRefreshing` alone misses its start).
    private var isChecking: Bool {
        monitor.isRefreshing || !monitor.hasCompletedFirstPass
    }

    /// One thin row: the summary (or "Undo hide" for 5 s after a Hide) on the
    /// left, then attention (both tabs since round 5), search, refresh and settings.
    private var footer: some View {
        HStack(spacing: 4) {
            if panel.undoHideName != nil {
                FooterTextButton(title: "Undo hide", theme: theme) { panel.undoHide() }
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(footerSummary)
                        .font(Theme.caption)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(footerTooltip(now: context.date))
                }
            }
            Spacer(minLength: 6)
            attentionToggle
            FooterGlyphButton(
                systemImage: "magnifyingglass",
                title: panel.isSearchOpen ? "Close search" : "Search (\u{2318}F)",
                theme: theme,
                selected: panel.isSearchOpen
            ) {
                panel.toggleSearch()
            }
            FooterGlyphButton(
                systemImage: "arrow.clockwise",
                title: isChecking ? "Checking servers\u{2026}" : "Check all servers now",
                theme: theme,
                spinning: isChecking
            ) {
                // Not `.disabled` while checking: a dimmed glyph reads as "off",
                // and the spin must read as "working". A tap mid-check does nothing.
                guard !isChecking else { return }
                monitor.startRefreshAll()   // spins at once, not after discovery
            }
            FooterGlyphButton(systemImage: "gearshape", title: "Settings\u{2026}", theme: theme) {
                SettingsLauncher.open(tab: .general)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
        .background(theme.chromeFill)
    }

    /// Pressed is Needs you (neutral fill, filled symbol), unpressed is All. Off
    /// while something needs you, the glyph takes the worst state's colour so it
    /// quietly signals; with nothing to show it stays plain.
    private var attentionToggle: some View {
        let on = panel.filter == .problems
        let count = panel.needsYouCount
        let title: String
        let what = panel.tab == .servers ? "servers" : "agents"
        if on {
            title = "Showing what needs you. Click to show all \(what)"
        } else if count > 0 {
            title = "Show only what needs you (\(count))"
        } else {
            title = "Show only what needs you. Nothing does right now"
        }
        return FooterGlyphButton(
            systemImage: on ? "exclamationmark.circle.fill" : "exclamationmark.circle",
            title: title,
            theme: theme,
            selected: on,
            tint: on ? nil : attentionTint
        ) {
            panel.toggleNeedsYou()
        }
        .accessibilityValue(on ? "Needs you" : "All")
    }

    private var attentionTint: Color? {
        switch panel.worstNeedsYouRank {
        case 0: return theme.statusBroken
        case 1, 2: return theme.statusDegraded
        default: return nil
        }
    }

    private var footerSummary: String {
        panel.tab == .servers
            ? PanelText.compactSummary(monitor.visibleGroups, checking: isChecking)
            : AgentSections.compactSummary(panel.allAgentSections, checking: isChecking)
    }

    /// The full sentence, then "Checked 1 min ago · 2 hidden".
    private func footerTooltip(now: Date) -> String {
        let lastChecked = ServerGroup.newestCheck(monitor.groups)
        let hidden = monitor.hiddenGroups.count
        if panel.tab == .agents {
            return AgentSections.summary(panel.allAgentSections) + "\n"
                + PanelText.footer(lastChecked: lastChecked, hiddenCount: hidden, now: now)
        }
        return PanelText.footerTooltip(
            monitor.visibleGroups,
            firstPass: !monitor.hasCompletedFirstPass,
            lastChecked: lastChecked,
            hiddenCount: hidden,
            now: now
        )
    }
}
