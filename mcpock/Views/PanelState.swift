import AppKit
import Observation

/// The panel's two tabs (v1.5 header segment).
enum PanelTab: String, CaseIterable, Identifiable {
    case servers
    case agents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .servers: return "Servers"
        case .agents: return "Agents"
        }
    }
}

/// What the panel is showing and what is selected, shared by the list, the
/// keyboard handler and (Phase 3) the detail card window. It lives on the app, not
/// on `MenuBarPanelView`: the panel view is rebuilt on every theme change
/// (`.id(themeRaw)`), and a selection or an Undo offer must survive that.
@MainActor
@Observable
final class PanelState {
    let monitor: HealthMonitor
    /// Usage counts (1.7): set once at launch (`MCPockApp`); nil in every test
    /// that builds a `PanelState` for something else, and those never touch
    /// usage. `AgentServerRow` reads it directly.
    @ObservationIgnored var usageStore: UsageStore?

    /// Agents first (1.5.4): the health bars are the most telling view.
    /// Not saved; the tab she picks lasts until the app quits.
    var tab: PanelTab = .agents {
        // Each tab has its own list, so a selection (and its card) never carries
        // over: the Servers tab's row may not be in the open agent, and back.
        didSet {
            guard tab != oldValue else { return }
            closeCard()
            selectedName = nil
        }
    }
    /// The footer's attention toggle: pressed is Needs you, unpressed is All.
    /// Remembered between opens and launches when she sets it by hand. Shared by
    /// both tabs (round 5): pressed, the Agents tab keeps only agents with a
    /// problem and lists only their problem servers.
    var filter: PanelFilter {
        didSet {
            guard !isAutoFiltering else { return }
            defaults.set(filter.rawValue, forKey: AppPreferences.panelFilterKey)
        }
    }
    /// The search text. Only ever non-empty while the search field is open: a
    /// closed field must never filter the list out of sight.
    var query = ""
    /// The search field under the tabs. Closed by default; the footer's
    /// magnifier or ⌘F opens it, Escape or Return closes and clears it.
    private(set) var isSearchOpen = false
    /// The selected server row (by display name): in the Servers list, or among
    /// the open agent's servers in the Agents tab (round 5).
    var selectedName: String? {
        didSet {
            guard selectedName != oldValue else { return }
            isComparing = false
            // A server the arrow keys landed on but the fold is hiding: unfold
            // its agent so the row (and the scroll that follows) has something
            // to land on. A click can only ever hit a row already on screen,
            // so this is a no-op then.
            expandFoldIfHidden(selectedName)
        }
    }
    /// True while the detail card shows the selected row.
    var isCardOpen = false
    /// The card is showing Compare ("Compare setups") instead of its details.
    var isComparing = false
    /// Bumped whenever the search opens (magnifier, ⌘F); the panel focuses its
    /// search field when it changes.
    var searchFocusRequest = 0
    /// The row hidden last, while its 5 s Undo is on offer in the footer.
    private(set) var undoHideName: String?
    /// Rows being re-checked on their own (the card's or the menu's "Check
    /// again"), by display name. Filled in the tap's own turn and emptied when
    /// that row's probe has finished: the card's button spins and the row's
    /// health mark turns into a spinning arc meanwhile (1.5.3), in both tabs.
    private(set) var checkingNames: Set<String> = []
    /// The open agent in the Agents tab. Round 8: every agent starts closed;
    /// the one she opens stays open while the panel is open and is still open
    /// the next time the panel opens (this app session only, never saved).
    var expandedAgent: String?

    /// Open agents whose server list shows every row rather than folding past
    /// `ServerFold.limit` (round X). Session-only, like `expandedAgent`
    /// — never saved, and never reset just by closing and reopening the agent.
    private(set) var expandedFoldAgents: Set<String> = []

    /// The "+N more" / "Show less" link under an open agent's servers.
    func toggleServerFold(for agent: String) {
        if expandedFoldAgents.contains(agent) {
            expandedFoldAgents.remove(agent)
        } else {
            expandedFoldAgents.insert(agent)
        }
    }

    /// If `name` is one of the open agent's servers but the fold is hiding it,
    /// unfold that agent so it's on screen.
    private func expandFoldIfHidden(_ name: String?) {
        guard tab == .agents, let name, let agent = openAgent(in: agentSections),
              !expandedFoldAgents.contains(agent),
              let section = agentSections.first(where: { $0.agent == agent })
        else { return }
        let shown = AgentSections.ServerFold.shown(section.listed, expanded: false)
        if !shown.rows.contains(where: { $0.name == name }) {
            expandedFoldAgents.insert(agent)
        }
    }

    /// True once the Agents tab has shown its health bars with real data at
    /// least once this launch (round 9b: "the first time the panel opens" —
    /// the health bar lives only on this tab, so its first paint is the
    /// moment that reads as opening). Session-only, never persisted: a
    /// relaunch starts over, and a later tab switch or panel re-open never
    /// replays it — only a refresh finishing does (`healthBarShouldGrow`).
    @ObservationIgnored private(set) var hasShownAgentsTabOnce = false
    /// True for the short window right after that first real paint:
    /// every `HealthBar` that exists then — the rows visible without
    /// scrolling — grows in together. `AgentsListView` closes it once that
    /// paint has settled, so a row the `LazyVStack` mounts later, scrolled
    /// into view, never sees it open and never starts its own grow.
    private(set) var firstAgentsViewWindowOpen = false

    /// The MenuBarExtra window, found through the panel's hosting view. The
    /// keyboard handler only answers events aimed at it (or at the card).
    @ObservationIgnored weak var panelWindow: NSWindow?
    /// Closes the panel on Escape once nothing else wants it (card, compare,
    /// search). Set by the Glass theme's own panel (`GlassPanelController`);
    /// nil under MenuBarExtra, which closes itself on an unhandled Escape.
    @ObservationIgnored var requestClose: (() -> Void)?
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?
    /// The detail card's window (Phase 3).
    @ObservationIgnored private let card = DetailCardPresenter()
    @ObservationIgnored private let defaults: UserDefaults
    /// Set while the panel switches the filter on its own, so that switch is not
    /// remembered as the user's choice.
    @ObservationIgnored private var isAutoFiltering = false
    /// True between `panelOpened` and `panelClosed`.
    @ObservationIgnored private(set) var isPanelOpen = false
    /// She pressed the attention toggle since the panel opened. From then on the
    /// panel never switches the filter for her, whatever the results say.
    @ObservationIgnored private(set) var userPickedFilter = false

    /// How long the footer offers "Undo" after a Hide.
    nonisolated static let undoSeconds: Double = 5

    init(monitor: HealthMonitor, defaults: UserDefaults = .standard) {
        self.monitor = monitor
        self.defaults = defaults
        filter = defaults.string(forKey: AppPreferences.panelFilterKey)
            .flatMap(PanelFilter.init(rawValue:)) ?? .all
    }

    // MARK: - Derived

    var sections: [PanelSection] {
        PanelSections.build(
            groups: monitor.visibleGroups,
            pinned: monitor.pinnedNames,
            filter: filter,
            query: query
        )
    }

    /// The Agents tab, built from the same visible rows, search text and
    /// attention toggle.
    var agentSections: [AgentSection] {
        AgentSections.build(groups: monitor.visibleGroups, query: query, filter: filter)
    }

    /// Every agent, whatever the toggle and the search say: the footer's summary
    /// and the toggle's count describe the whole setup.
    var allAgentSections: [AgentSection] {
        AgentSections.build(groups: monitor.visibleGroups)
    }

    /// The open agent: the one she opened, while it is in the list. nil until
    /// she opens one (round 8: nothing starts open, not even the worst agent),
    /// when she closed it, or when it left the list (the attention toggle can
    /// take it out; it comes back open when the toggle lets it back in).
    func openAgent(in sections: [AgentSection]) -> String? {
        Self.openAgent(in: sections, expanded: expandedAgent)
    }

    nonisolated static func openAgent(in sections: [AgentSection], expanded: String?) -> String? {
        guard let expanded else { return nil }
        return sections.contains { $0.agent == expanded } ? expanded : nil
    }

    /// Rows in on-screen order, for the arrow keys: the server list, or the open
    /// agent's servers in the Agents tab.
    var orderedNames: [String] {
        switch tab {
        case .servers:
            return sections.flatMap { $0.groups.map(\.name) }
        case .agents:
            let agents = agentSections
            return Self.agentServerNames(in: agents, open: openAgent(in: agents))
        }
    }

    /// The servers the open agent lists, in order. Pure.
    nonisolated static func agentServerNames(in sections: [AgentSection], open: String?) -> [String] {
        sections.first { $0.agent == open }?.listed.map(\.name) ?? []
    }

    var selectedGroup: ServerGroup? {
        guard let selectedName else { return nil }
        return monitor.groups.first { $0.name == selectedName }
    }

    /// Rows that need you, ignoring the search text: the attention toggle
    /// describes the whole setup while the list narrows. On the Agents tab,
    /// the agents that need you.
    var needsYouCount: Int {
        switch tab {
        case .servers: return monitor.visibleGroups.filter(PanelSections.needsYou).count
        case .agents: return allAgentSections.filter { !$0.problems.isEmpty }.count
        }
    }

    /// 0 broken, 1 degraded, 2 differs; nil when nothing needs you. Tints the
    /// attention toggle while it is off. On the Agents tab it follows the
    /// per-agent rule (1.5.3), like the count beside it.
    var worstNeedsYouRank: Int? {
        switch tab {
        case .servers: return PanelSections.worstNeedsYouRank(monitor.visibleGroups)
        case .agents: return AgentSections.worstRank(allAgentSections)
        }
    }

    func isChecking(_ name: String) -> Bool {
        checkingNames.contains(name)
    }

    // MARK: - Panel lifecycle

    /// The panel window just opened. Something broken jumps the list to Needs you
    /// (spec: the icon's diamond brought you here, so show the reason first).
    func panelOpened() {
        installKeyMonitor()
        isPanelOpen = true
        userPickedFilter = false
        jumpToNeedsYouIfBroken()
        // The open agent is kept (round 8): she comes back to where she was.
        if let selectedName, !orderedNames.contains(selectedName) {
            self.selectedName = nil
        }
    }

    func panelClosed() {
        isPanelOpen = false
        closeCard()
        closeSearch()
    }

    /// A filter she chose. Remembered (the `filter` setter persists it) and it
    /// stops the panel from switching the filter on its own until it next opens.
    func pickFilter(_ newFilter: PanelFilter) {
        userPickedFilter = true
        filter = newFilter
    }

    /// The footer's attention toggle: Needs you on, or back to All.
    func toggleNeedsYou() {
        pickFilter(filter == .problems ? .all : .problems)
    }

    // MARK: - Search

    /// Open the search field (or focus it again when it's already open).
    func openSearch() {
        isSearchOpen = true
        searchFocusRequest += 1
    }

    /// Close the search field and clear what was typed, like 1.4.1's filter.
    func closeSearch() {
        isSearchOpen = false
        query = ""
    }

    /// The footer's magnifier.
    func toggleSearch() {
        if isSearchOpen { closeSearch() } else { openSearch() }
    }

    /// Results changed while the panel is open. On the first open after launch
    /// the panel appears before the first check has found anything, so the jump
    /// in `panelOpened` sees nothing broken; this makes it happen once the
    /// results arrive, as long as she hasn't pressed the toggle herself.
    func resultsChanged() {
        guard isPanelOpen else { return }
        jumpToNeedsYouIfBroken()
    }

    private func jumpToNeedsYouIfBroken() {
        let hasBroken = monitor.visibleGroups.contains { $0.state == .broken }
        guard Self.shouldJumpToNeedsYou(hasBroken: hasBroken, filter: filter, userPickedFilter: userPickedFilter) else {
            return
        }
        isAutoFiltering = true
        filter = .problems
        isAutoFiltering = false
        // The selected row may not be a problem; don't leave its card open over a
        // list that no longer shows it.
        if let selectedName, !orderedNames.contains(selectedName) {
            closeCard()
            self.selectedName = nil
        }
    }

    /// Whether the panel should switch itself to Needs you. Pure.
    nonisolated static func shouldJumpToNeedsYou(hasBroken: Bool, filter: PanelFilter, userPickedFilter: Bool) -> Bool {
        hasBroken && filter != .problems && !userPickedFilter
    }

    /// Whether the Agents tab's health bars (`HealthBar`, round 9) should grow
    /// in: only on the `isRefreshing` true -> false edge, a full check (the
    /// timer's own cycle or the footer's Refresh) finishing. A single row's
    /// "Check again" (`HealthMonitor.refresh(groupName:)`) never touches
    /// `isRefreshing`, so it never qualifies here. Pure.
    nonisolated static func healthBarShouldGrow(wasRefreshing: Bool, isRefreshing: Bool) -> Bool {
        wasRefreshing && !isRefreshing
    }

    /// Whether the Agents tab's first view this launch should open the
    /// health bars' "grow together" window (round 9b): only the first time,
    /// and only once there is something real to grow. A peek before the
    /// first check finishes is skipped without spending the one-per-launch
    /// opportunity — `healthBarShouldGrow`'s refresh edge covers it once
    /// results arrive, and a later, real first view still gets this one. Pure.
    nonisolated static func healthBarShouldGrowOnFirstAgentsView(
        hasShownAgentsTabOnce: Bool, hasCompletedFirstPass: Bool
    ) -> Bool {
        !hasShownAgentsTabOnce && hasCompletedFirstPass
    }

    /// The Agents tab appeared. Opens `firstAgentsViewWindowOpen` for the
    /// rows already visible without scrolling to grow in together; does
    /// nothing on a later view (tab switch, panel re-open) or when there is
    /// nothing real to show yet. `AgentsListView` closes the window again
    /// once its first paint has settled.
    func agentsTabAppeared(hasCompletedFirstPass: Bool) {
        guard Self.healthBarShouldGrowOnFirstAgentsView(
            hasShownAgentsTabOnce: hasShownAgentsTabOnce,
            hasCompletedFirstPass: hasCompletedFirstPass
        ) else { return }
        hasShownAgentsTabOnce = true
        firstAgentsViewWindowOpen = true
    }

    /// Closes the window `agentsTabAppeared` opened.
    func closeFirstAgentsViewWindow() {
        firstAgentsViewWindowOpen = false
    }

    // MARK: - Selection and card

    /// A click on a row: select it and open its card; a click on the row whose
    /// card is already open closes the card.
    func rowClicked(_ name: String) {
        if selectedName == name && isCardOpen {
            closeCard()
        } else {
            selectedName = name
            openCard()
        }
    }

    func openCard() {
        guard selectedName != nil else { return }
        isCardOpen = true
        // Tests (and a panel that hasn't reported its window yet) have no window
        // to hang the card on; the state still says "open".
        if let panelWindow {
            card.show(state: self, parent: panelWindow)
        }
    }

    func closeCard() {
        isCardOpen = false
        isComparing = false
        card.hide()
    }

    /// Arrow keys. With nothing selected, either key lands on the first row.
    func moveSelection(by delta: Int) {
        if let next = Self.nextSelection(in: orderedNames, from: selectedName, by: delta) {
            selectedName = next
        }
    }

    /// The row the arrow keys land on: one step along the list, stopping at either
    /// end (no wrap, like a menu). A selection that is no longer in the list, or
    /// none at all, lands on the first row. Pure.
    nonisolated static func nextSelection(in names: [String], from current: String?, by delta: Int) -> String? {
        guard !names.isEmpty else { return nil }
        guard let current, let index = names.firstIndex(of: current) else { return names[0] }
        return names[min(max(index + delta, 0), names.count - 1)]
    }

    /// A click on an agent: open it, or close it when it's open. The selection
    /// (and its card) belonged to the agent that was open, so it goes.
    func toggleAgent(_ agent: String, in sections: [AgentSection]) {
        let wasOpen = openAgent(in: sections) == agent
        expandedAgent = wasOpen ? nil : agent
        if let selectedName, !Self.agentServerNames(in: sections, open: expandedAgent).contains(selectedName) {
            closeCard()
            self.selectedName = nil
        }
    }

    /// The row's actions, for both tabs' rows and their right-click menus.
    func rowActions(for name: String) -> ServerRowActions {
        ServerRowActions(
            select: { [weak self] in self?.rowClicked(name) },
            checkAgain: { [weak self] in self?.checkAgain(name) },
            hide: { [weak self] in self?.hide(name) },
            togglePause: { [weak self] in self?.togglePause(name) },
            togglePin: { [weak self] in self?.togglePin(name) },
            setIntended: { [weak self] marked in self?.setMarkedAsIntended(marked, name: name) },
            copyDetails: { [weak self] in self?.copyServerDetails(name) },
            askAgent: { [weak self] in self?.askAgent(name) }
        )
    }

    // MARK: - Row actions

    /// Hide a row and offer Undo in the footer for `undoSeconds`.
    func hide(_ name: String) {
        monitor.setHidden(true, name: name)
        if selectedName == name {
            closeCard()
            selectedName = nil
        }
        undoHideName = name
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoSeconds))
            guard !Task.isCancelled else { return }
            self?.undoHideName = nil
        }
    }

    func undoHide() {
        guard let name = undoHideName else { return }
        undoTask?.cancel()
        undoHideName = nil
        monitor.setHidden(false, name: name)
    }

    func togglePin(_ name: String) {
        monitor.setPinned(!monitor.isPinned(name), name: name)
    }

    /// "Mark as intended" (true) on a row that is set up differently, or
    /// "Unmark as Intended" / Undo (false). Explicit rather than a toggle, so a
    /// double click on "Mark as intended" can never take the mark back.
    func setMarkedAsIntended(_ marked: Bool, name: String) {
        // The monitor ignores a repeat (same marks, or nothing to unmark).
        monitor.setDifferentOnPurpose(marked, name: name)
    }

    func togglePause(_ name: String) {
        monitor.setPaused(!monitor.isPaused(name), name: name)
    }

    /// Re-probe one row, with the card's button spinning until it's done.
    func checkAgain(_ name: String) {
        guard !checkingNames.contains(name) else { return }
        checkingNames.insert(name)
        Task {
            await monitor.refresh(groupName: name)
            checkingNames.remove(name)
        }
    }

    /// ⌘C: the error report for a failing row (the menu's Copy Errors), the
    /// masked server details for anything else (Copy Details).
    static func copyText(for group: ServerGroup, servers: [ServerSnapshot] = [], now: Date = Date()) -> String {
        if let errors = MenuText.copyError(for: group) { return errors }
        return ServerReport.detailsText(ServerReport.entry(for: group, servers: servers), now: now)
    }

    // MARK: - Copy Details and Ask an Agent (1.5.3)

    /// "Copy Details" for a row, masked like the status file; nil when
    /// the row is gone.
    func serverDetailsText(_ name: String, now: Date = Date()) -> String? {
        guard let group = monitor.groups.first(where: { $0.name == name }) else { return nil }
        return ServerReport.detailsText(ServerReport.entry(for: group, servers: monitor.servers), now: now)
    }

    /// Copies the details; false when the row is gone.
    @discardableResult
    func copyServerDetails(_ name: String) -> Bool {
        guard let text = serverDetailsText(name) else { return false }
        Self.copyToPasteboard(text)
        return true
    }

    /// The "Ask an Agent" prompt for a row; nil when the row is gone or has nothing
    /// to ask about.
    func askAgentText(_ name: String, now: Date = Date()) -> String? {
        guard let group = monitor.groups.first(where: { $0.name == name }),
              ServerReport.canAskAgent(group) else { return nil }
        return ServerReport.askAgentPrompt(
            ServerReport.entry(for: group, servers: monitor.servers),
            mcpockAgents: ServerReport.mcpockAgents(in: monitor.servers),
            now: now
        )
    }

    /// Copies the "Ask an Agent" prompt; false when there was nothing to copy.
    @discardableResult
    func askAgent(_ name: String) -> Bool {
        guard let text = askAgentText(name) else { return false }
        Self.copyToPasteboard(text)
        return true
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Keyboard

    /// Arrow keys, Return, Escape, ⌘F, ⌘R and ⌘C for the panel. A local event monitor
    /// rather than SwiftUI focus: while the search field is open it holds the
    /// keyboard focus (so typing searches), and the monitor answers the navigation
    /// keys before the field sees them. Installed once; it only acts on events
    /// aimed at the panel window.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private enum KeyCode {
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    /// Escape peels one layer at a time: compare, card, search, then (in the
    /// Glass panel only) the panel itself. False lets it travel on, so the
    /// MenuBarExtra window closes itself. Not private: the tests drive it.
    func handleEscape() -> Bool {
        if isComparing {
            isComparing = false
            return true
        }
        if isCardOpen {
            closeCard()
            return true
        }
        if isSearchOpen || !query.isEmpty {
            closeSearch()
            return true
        }
        if let requestClose {
            requestClose()
            return true
        }
        return false
    }

    /// True when the event was handled and must not travel further.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === panelWindow || isCardWindow(window) else {
            return false
        }
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        let key = event.charactersIgnoringModifiers?.lowercased()

        if command && key == "f" {
            openSearch()
            return true
        }
        if command && key == "r" {
            // ⌘R (1.10): Check again on the selected row, right after a fix;
            // with nothing selected, the footer's Refresh (every server).
            if let name = selectedGroup?.name {
                checkAgain(name)
            } else if !monitor.isRefreshing {
                monitor.startRefreshAll()
            }
            return true
        }
        if command && key == "c" {
            // A text selection in the search field wins: that's an ordinary copy.
            if let editor = window.firstResponder as? NSTextView, editor.selectedRange().length > 0 {
                return false
            }
            guard let group = selectedGroup else { return false }
            Self.copyToPasteboard(Self.copyText(for: group, servers: monitor.servers))
            return true
        }
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            return false
        }

        switch event.keyCode {
        case KeyCode.escape:
            return handleEscape()
        case KeyCode.down, KeyCode.up:
            moveSelection(by: event.keyCode == KeyCode.down ? 1 : -1)
            return true
        case KeyCode.returnKey, KeyCode.enter:
            // With the search open, Return closes and clears it (1.4.1). A row she
            // arrowed to in the results keeps its selection and opens its card:
            // clearing the search only widens the list, so the row stays in it.
            if isSearchOpen {
                closeSearch()
                if selectedName != nil { openCard() }
                return true
            }
            if selectedName == nil { moveSelection(by: 1) }
            openCard()
            return true
        default:
            return false
        }
    }

    private func isCardWindow(_ window: NSWindow) -> Bool {
        window === card.window
    }
}
