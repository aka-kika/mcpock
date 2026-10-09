import AppKit
import SwiftUI

/// The Agents tab (v1.5 spec, Phase 4): one row per agent, sorted by what needs
/// you, each with a health bar. One agent open at a time.
/// Round 5: the open agent lists all its servers (problems first) or, with the
/// footer's attention toggle pressed, only its problem servers. Clicking one
/// selects it and opens the same detail card as the Servers tab, staying here;
/// the arrow keys and Escape work as they do there. Round 8: every agent starts
/// closed; the one she opens stays open, also the next time the panel opens.
/// With the attention toggle pressed (round 9), agents with nothing wrong stay
/// in the list too, dimmed, below a thin divider, so the tab never looks half
/// empty; they open the same way as any other row.
struct AgentsListView: View {
    let sections: [AgentSection]
    @Bindable var panel: PanelState
    let theme: ThemeColors

    /// The first dimmed section's index, so a divider can mark where the
    /// agents that need you end and the fine ones begin. nil when nothing is
    /// dimmed, or when every section is (nothing needs you at all).
    private var firstDimmedIndex: Int? {
        guard panel.filter == .problems else { return nil }
        let index = sections.firstIndex { AgentSections.isDimmed($0, filter: panel.filter) }
        return (index ?? 0) > 0 ? index : nil
    }

    var body: some View {
        let open = panel.openAgent(in: sections)
        let groups = Dictionary(panel.monitor.visibleGroups.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let dividerBefore = firstDimmedIndex
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        if index == dividerBefore {
                            Rectangle().fill(theme.divider).frame(height: 1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        AgentRowView(
                            section: section,
                            isOpen: open == section.agent,
                            isDimmed: AgentSections.isDimmed(section, filter: panel.filter),
                            groups: groups,
                            panel: panel,
                            theme: theme,
                            toggle: { toggle(section.agent) }
                        )
                        .id(section.agent)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
            .panelScrollIndicators()
            // An agent opened low in the list comes up to the top, so its
            // servers are on screen rather than under the footer.
            .onChange(of: panel.expandedAgent) { _, agent in
                guard let agent else { return }
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(agent, anchor: .top) }
            }
            // Back to the agent she left open, if the list reopened scrolled away.
            // Round 9b: also opens the health bars' "grow together" window for
            // this first real paint (no-op on a later view); closed again once
            // this pass has settled, so a row the LazyVStack mounts later, on a
            // scroll, never sees it open.
            .onAppear {
                panel.agentsTabAppeared(hasCompletedFirstPass: panel.monitor.hasCompletedFirstPass)
                Task { @MainActor in
                    await Task.yield()
                    panel.closeFirstAgentsViewWindow()
                }
                guard let open else { return }
                proxy.scrollTo(open, anchor: .top)
            }
            .onChange(of: panel.selectedName) { _, name in
                guard let name else { return }
                withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(AgentServerRow.scrollID(name)) }
            }
        }
    }

    private func toggle(_ agent: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            panel.toggleAgent(agent, in: sections)
        }
    }
}

private struct AgentRowView: View {
    let section: AgentSection
    let isOpen: Bool
    /// Nothing wrong with it; listed only to keep the tab from looking half
    /// empty while the attention toggle is on. Still fully interactive: opacity
    /// alone doesn't affect hit testing. Opening it lifts the dim, so its
    /// summary reads clearly.
    let isDimmed: Bool
    let groups: [String: ServerGroup]
    @Bindable var panel: PanelState
    let theme: ThemeColors
    let toggle: () -> Void
    @State private var isHovered = false

    /// Where the health bar and the expanded content start: past the 24pt badge.
    static let contentIndent: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        AgentBadgeView(badge: AgentBadge.forLabel(section.agent), theme: theme, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            Text("\(section.servers.count) server\(section.servers.count == 1 ? "" : "s")")
                                .font(Theme.caption)
                                .foregroundStyle(theme.textTertiary)
                        }
                        Spacer(minLength: 6)
                        Text(AgentSections.problemText(section))
                            .font(.system(size: 11.5, weight: section.problems.isEmpty ? .regular : .medium))
                            .foregroundStyle(problemColor)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                    HealthBar(
                        section: section,
                        theme: theme,
                        isRefreshing: panel.monitor.isRefreshing,
                        firstViewWindowOpen: panel.firstAgentsViewWindowOpen
                    )
                        .padding(.leading, Self.contentIndent)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityAddTraits(isOpen ? .isSelected : [])
            .contextMenu { agentMenu }

            if isOpen {
                expanded
                    .padding(.leading, Self.contentIndent + 2)
                    .padding(.trailing, 4)
                    .padding(.bottom, 10)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isOpen ? theme.rowHighlight : (isHovered ? theme.rowHighlight : .clear))
        }
        .opacity(isDimmed && !isOpen ? 0.45 : 1)
    }

    private var problemColor: Color {
        if section.brokenCount > 0 { return theme.statusBroken }
        return section.problems.isEmpty ? theme.textTertiary : theme.statusDegraded
    }

    /// Right-click on an agent (round 5, round 8): Copy All Problems first when
    /// it has any (2026-10-04), then the shared path menu, Show in Finder, Copy
    /// Path, then Open Config… last. Two files: Show in Finder and Open Config…
    /// are submenus naming the files; Copy Paths copies both.
    @ViewBuilder
    private var agentMenu: some View {
        if let report = MenuText.agentProblems(section, groups: groups) {
            Button(MenuText.copyAllProblemsTitle) { PanelState.copyToPasteboard(report) }
            Divider()
        }
        if section.paths.count == 1, let path = section.paths.first {
            ConfigPathMenuItems(path: path)
        } else if !section.paths.isEmpty {
            Menu(MenuText.showInFinderTitle) {
                ForEach(section.paths, id: \.self) { path in
                    Button(CardText.shortPath(path)) { ConfigFileActions.showInFinder(path) }
                }
            }
            Button(MenuText.copyPathsTitle(count: section.paths.count)) {
                PanelState.copyToPasteboard(MenuText.configPaths(section.paths))
            }
            Divider()
            Menu(MenuText.openConfigTitle) {
                ForEach(section.paths, id: \.self) { path in
                    Button(CardText.shortPath(path)) { ConfigFileActions.confirmAndOpen(path) }
                }
            }
        }
    }

    @ViewBuilder
    private var expanded: some View {
        let isFoldExpanded = panel.expandedFoldAgents.contains(section.agent)
        let fold = AgentSections.ServerFold.shown(section.listed, expanded: isFoldExpanded)
        VStack(alignment: .leading, spacing: 1) {
            ForEach(fold.rows) { server in
                AgentServerRow(
                    server: server,
                    group: groups[server.name],
                    isPinned: panel.monitor.isPinned(server.name),
                    isSelected: panel.selectedName == server.name,
                    isChecking: panel.isChecking(server.name),
                    actions: panel.rowActions(for: server.name),
                    theme: theme,
                    usageStore: panel.usageStore,
                    usageAgent: AgentBadge.agentName(fromLabel: section.agent),
                    // A profile keeps its own counts ("Hermes · scribe"); a
                    // project-scoped Claude Code row counts under the agent.
                    usageRecordedAs: section.agent.contains(" · ") ? section.agent : nil
                )
                .id(AgentServerRow.scrollID(server.name))
            }
            // The fold (round X): more servers than fit fold away past
            // `ServerFold.limit`, problems first and never among them.
            if fold.hiddenCount > 0 || (isFoldExpanded && section.listed.count > AgentSections.ServerFold.limit) {
                ShowMoreRow(
                    title: isFoldExpanded ? CardText.showLessTitle : CardText.showMoreTitle(folded: fold.hiddenCount),
                    expanded: isFoldExpanded,
                    help: isFoldExpanded
                        ? "Show only the first \(AgentSections.ServerFold.limit)"
                        : AgentSections.ServerFold.showMoreHelp(folded: fold.hiddenCount),
                    theme: theme
                ) {
                    panel.toggleServerFold(for: section.agent)
                }
                // Lines up with the server names: the row's 6pt inset, the
                // mark, then the 8pt gap.
                .padding(.leading, 6 + HealthMark.boxSize + 8)
            }
            // With the toggle pressed only the problems are listed; say what else
            // is there. With it off every server is listed already.
            if section.listed.count < section.servers.count {
                Text(AgentSections.restText(section))
                    .font(Theme.caption)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.leading, HealthMark.boxSize + 14)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
            }
            Rectangle().fill(theme.divider).frame(height: 1)
                .padding(.top, 6)
                .padding(.horizontal, 6)
            // The config file(s), path only (round 8: no "Open config" button;
            // right-click has the shared menu, opening is its last item).
            ForEach(section.paths, id: \.self) { path in
                AgentPathLine(path: path, theme: theme)
                    .padding(.top, 6)
            }
        }
    }
}

/// One config path under an open agent: the path in small mono, a hover fill,
/// right-click for Show in Finder / Copy Path / Open Config….
private struct AgentPathLine: View {
    let path: String
    let theme: ThemeColors
    @State private var isHovered = false

    var body: some View {
        Text(CardText.shortPath(path))
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(theme.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? theme.rowHighlight : .clear)
            }
            .onHover { isHovered = $0 }
            .configPathActions(path)
            .accessibilityAddTraits(.isButton)
            .configPathAccessibilityActions(path)
    }
}

/// A server inside an open agent. A click selects it and opens its detail card
/// beside the panel, as in the Servers tab; right-click has the same menu.
private struct AgentServerRow: View {
    let server: AgentServer
    /// The row's display group, for the right-click menu (nil only while a
    /// rescan is replacing it).
    let group: ServerGroup?
    let isPinned: Bool
    let isSelected: Bool
    /// Being re-checked on its own: the health mark spins (1.5.3).
    let isChecking: Bool
    let actions: ServerRowActions
    let theme: ThemeColors
    /// Usage counts (1.7): nil whenever the panel wasn't given a store (every
    /// test that builds this row for something else).
    let usageStore: UsageStore?
    /// The agent's base label (a "· profile" or "(Project)" suffix already
    /// stripped by the caller), for the usage lookup.
    let usageAgent: String
    /// The label the reader filed this agent's calls under, when not the base
    /// agent (a Hermes profile).
    let usageRecordedAs: String?
    @State private var isHovered = false
    @AppStorage(AppPreferences.usageWindowKey) private var usageWindowRaw = UsageWindow.default.rawValue

    /// Server rows share the scroll view with the agent rows, whose ids are the
    /// agent labels; a prefix keeps a server called "mcp" apart from the agent.
    static func scrollID(_ name: String) -> String { "server:" + name }

    private var usageWindow: UsageWindow { UsageWindow(rawValue: usageWindowRaw) ?? .default }

    var body: some View {
        Button(action: actions.select) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    HealthMark(state: server.state, theme: theme, checking: isChecking)
                    Text(server.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.textTertiary)
                            .accessibilityLabel("Pinned")
                    }
                    Spacer(minLength: 0)
                    usageCount
                }
                if let note = server.note {
                    Text(note)
                        .font(Theme.caption)
                        .foregroundStyle(noteColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, HealthMark.boxSize + 8)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? theme.rowSelected : (isHovered ? theme.rowHighlight : .clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if let group {
                ServerContextMenu(group: group, isPinned: isPinned, actions: actions)
            }
        }
    }

    /// The trailing call count (1.7): compact ("1.2k"), monospaced,
    /// `textTertiary`. Nothing at all with the Usage setting Off; a dash with
    /// a tooltip for an agent whose reader doesn't exist yet, never a fake 0.
    @ViewBuilder
    private var usageCount: some View {
        if usageWindow != .off, let usageStore {
            let calls = usageStore.count(agent: usageAgent, server: server.name, window: usageWindow, recordedAs: usageRecordedAs)
            Text(calls.map(UsageText.compact) ?? "\u{2013}")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
                .help(calls == nil ? "No usage record for this agent" : "")
        }
    }

    private var noteColor: Color {
        switch server.state {
        case .broken: return theme.statusBroken
        case .degraded, .healthy: return theme.statusDegraded
        case .unknown, .selfManaged, .paused: return theme.textTertiary
        }
    }
}

/// The 4pt bar under an agent: broken, needs-you, fine and not-checked-yet
/// segments, sized by their counts.
///
/// Grows in from the left (round 9, "health bar micro-animation"): a single
/// `scaleEffect(x:)` on the segment row, anchored `.leading`, animates a
/// GPU transform rather than recomputing `GeometryReader` widths every frame.
/// Two triggers:
/// - **The first real view of the Agents tab this launch** (round 9b —
///   "the first time the panel opens": the bar lives only here, so this is
///   the moment that reads as opening it). `panel.firstAgentsViewWindowOpen`
///   is only briefly true, for the rows already on screen when the tab
///   first paints with real data; `AgentsListView` closes it right after, so
///   a row the `LazyVStack` mounts later, on a scroll, never starts its own
///   grow — it just appears. Both the immediate check (mount already inside
///   the window) and `onChange` (the window opens a beat after mount,
///   `MenuBarExtra`'s children can appear before their parent) are needed:
///   whichever one is true first wins, `sawFirstView` stops the other from
///   firing twice.
/// - **Every full refresh after that** (`isRefreshing`'s true -> false edge
///   — the timer's own cycle or the footer's Refresh — never a single row's
///   "Check again", which never touches `isRefreshing`).
///
/// Reduce Motion: `growth` never leaves 1, so the bar just appears either way.
private struct HealthBar: View {
    let section: AgentSection
    let theme: ThemeColors
    let isRefreshing: Bool
    let firstViewWindowOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var growth: CGFloat = 1
    /// Guards the first-view trigger against firing twice (the mount-time
    /// check and the `onChange` below can both see it open).
    @State private var sawFirstView = false

    var body: some View {
        GeometryReader { proxy in
            let segments = self.segments
            let gaps = CGFloat(max(segments.count - 1, 0)) * 2
            let total = CGFloat(max(section.servers.count, 1))
            HStack(spacing: 2) {
                ForEach(segments.indices, id: \.self) { index in
                    Capsule()
                        .fill(segments[index].color)
                        .frame(width: max(0, (proxy.size.width - gaps) * CGFloat(segments[index].count) / total))
                }
            }
            .scaleEffect(x: growth, y: 1, anchor: .leading)
        }
        .frame(height: 4)
        .accessibilityHidden(true)
        .onAppear { grow(ifFirstViewOpen: firstViewWindowOpen) }
        .onChange(of: firstViewWindowOpen) { _, open in grow(ifFirstViewOpen: open) }
        .onChange(of: isRefreshing) { old, new in
            guard PanelState.healthBarShouldGrow(wasRefreshing: old, isRefreshing: new) else { return }
            growIn()
        }
    }

    private func grow(ifFirstViewOpen open: Bool) {
        guard open, !sawFirstView else { return }
        sawFirstView = true
        growIn()
    }

    private func growIn() {
        guard !reduceMotion else { return }
        growth = 0
        withAnimation(.easeOut(duration: 0.5)) { growth = 1 }
    }

    private var segments: [(count: Int, color: Color)] {
        [
            (section.brokenCount, theme.statusBroken),
            (section.attentionCount, theme.statusDegraded),
            (section.fineCount, theme.statusHealthy),
            (section.checkingCount, theme.elevated),
        ].filter { $0.count > 0 }
    }
}
