import Foundation
import Observation

@MainActor
@Observable
final class HealthMonitor {
    private(set) var servers: [ServerSnapshot] = [] {
        didSet {
            groupsCache = nil
            statusDidChange()
        }
    }
    /// A check is running: the footer glyph spins and the summary says Checking….
    /// Driven by `refreshHolds`, never assigned directly.
    private(set) var isRefreshing = false {
        didSet {
            guard isRefreshing != oldValue else { return }
            statusDidChange()
            if !isRefreshing { onCycleFinished?() }
        }
    }
    /// Called each time a full check cycle ends (the timer's own cycle or the
    /// footer's Refresh), never for a single row's Check again. Set by the app
    /// at launch so usage counts follow the checks without the panel being open.
    @ObservationIgnored var onCycleFinished: (() -> Void)?
    /// Work that keeps `isRefreshing` on: each probe cycle, and a user's Refresh
    /// from the tap until its discovery and forced pass are done. A count, not a
    /// flag, because the two overlap (the Refresh hold spans the cycle inside it).
    private var refreshHolds = 0 {
        didSet { isRefreshing = refreshHolds > 0 }
    }
    /// The Refresh the user started and that hasn't finished (see `startRefreshAll`).
    private var refreshAllTask: Task<Void, Never>?
    /// False from launch until the first probe pass has finished. The panel's
    /// summary line starts with "Checking…" until then (Phase 7): right after launch
    /// nearly every row is still unknown, and that is not news.
    private(set) var hasCompletedFirstPass = false {
        didSet { if hasCompletedFirstPass != oldValue { statusDidChange() } }
    }

    /// Writes `status.json` for agents (round 7) a moment after anything here
    /// changes. Set by the app at launch; nil in tests, so a test monitor never
    /// touches the real file.
    @ObservationIgnored var statusWriter: StatusWriter?
    /// Writes the widgets' snapshot into the App Group container (round 8).
    /// Set by the app at launch; nil in tests, same reason as `statusWriter`.
    @ObservationIgnored var widgetSnapshotWriter: WidgetSnapshotWriter?

    /// Schedule a status-file write (coalesced; see `StatusWriter`).
    private func statusDidChange() {
        statusWriter?.schedule { [weak self] in self?.statusSnapshot() }
        widgetSnapshotWriter?.schedule { [weak self] in
            self.map { MCPockWidgetSnapshot.build(from: $0.statusSnapshot(), logo: Self.widgetLogo) }
        }
    }

    /// What `status.json` holds right now.
    func statusSnapshot(now: Date = Date()) -> MCPockStatus {
        StatusSnapshot.build(
            servers: servers,
            isHidden: { [hiddenNames] in Self.isHidden($0, in: hiddenNames) },
            isPinned: { [pinnedNames] in pinnedNames.contains(Self.normalizedName($0)) },
            acknowledged: differsAcknowledged,
            checking: isRefreshing,
            firstCheckDone: hasCompletedFirstPass,
            interval: AppPreferences.loadProbeInterval(from: defaults),
            now: now
        )
    }
    private var hiddenNames: Set<String>
    private var pausedNames: Set<String>
    /// Normalized names the user pinned to the top of the panel (v1.5). Read by
    /// the views as `pinnedNames` and handed to `PanelSections.build`.
    private(set) var pinnedNames: Set<String>
    /// "Mark as intended" (1.5.2): normalized name -> the fingerprints of
    /// the launch targets she acknowledged. Never pruned: an entry whose setups
    /// changed simply stops matching (`Differs.acknowledgementMatches`).
    private(set) var differsAcknowledged: [String: [String]] {
        didSet { groupsCache = nil }
    }
    /// Where hidden/paused/pinned choices persist. `.standard` in the app; tests
    /// pass a throwaway suite, because the test host IS the app and would
    /// otherwise rewrite the user's real preferences.
    private let defaults: UserDefaults

    /// An Agents-widget row's logo, found like the Agents tab finds it:
    /// `forLabel` first strips a profile or project ("Hermes · scribe",
    /// "Claude Code (MyApp)"), which a plain name lookup missed.
    nonisolated static func widgetLogo(_ agentLabel: String) -> String? {
        AgentBadge.forLabel(agentLabel).logoName
    }

    /// Display rows: instances sharing a server name collapsed into one group.
    ///
    /// Built once per change, not per read: one panel render read this (and
    /// `visibleGroups` / `hiddenGroups`, which read it too) about ten times,
    /// and each read regrouped every server and ran "set up differently" on
    /// every group (review, 2026-09-26). Both inputs are still read on every
    /// call, so SwiftUI keeps tracking them; their `didSet` clears the cache.
    var groups: [ServerGroup] {
        let servers = self.servers
        let acknowledged = differsAcknowledged
        if let groupsCache { return groupsCache }
        let built = Self.groupByName(servers, acknowledged: acknowledged)
        groupsCache = built
        return built
    }
    /// `groups`' last result; nil means "rebuild on the next read".
    @ObservationIgnored private var groupsCache: [ServerGroup]?

    /// Display rows the user has NOT hidden.
    var visibleGroups: [ServerGroup] { Self.partition(groups, hidden: hiddenNames).visible }

    /// Display rows the user HAS hidden (the footer's count + Settings).
    var hiddenGroups: [ServerGroup] { Self.partition(groups, hidden: hiddenNames).hidden }

    /// Hide or unhide a display row by name; persists immediately. Hiding a pinned
    /// row unpins it: pinned, shown and hidden are one three-way choice.
    func setHidden(_ hidden: Bool, name: String) {
        let key = Self.normalizedName(name)
        if hidden {
            hiddenNames.insert(key)
            if pinnedNames.remove(key) != nil {
                AppPreferences.savePinnedServers(pinnedNames, to: defaults)
                statusDidChange()
            }
        } else {
            hiddenNames.remove(key)
        }
        AppPreferences.saveHiddenServers(hiddenNames, to: defaults)
        statusDidChange()
    }

    func isHidden(_ name: String) -> Bool {
        Self.isHidden(name, in: hiddenNames)
    }

    func isPinned(_ name: String) -> Bool {
        pinnedNames.contains(Self.normalizedName(name))
    }

    /// Pin or unpin a display row by name; persists immediately. A server is
    /// pinned, shown or hidden, never two at once, so pinning a hidden server
    /// also unhides it (the v1.5 Preferences "Show as" control has exactly those
    /// three positions). Unpinning leaves it shown.
    func setPinned(_ pinned: Bool, name: String) {
        let key = Self.normalizedName(name)
        if pinned {
            pinnedNames.insert(key)
            if hiddenNames.remove(key) != nil {
                AppPreferences.saveHiddenServers(hiddenNames, to: defaults)
                statusDidChange()
            }
        } else {
            pinnedNames.remove(key)
        }
        AppPreferences.savePinnedServers(pinnedNames, to: defaults)
        statusDidChange()
    }

    func isPaused(_ name: String) -> Bool {
        pausedNames.contains(Self.normalizedName(name))
    }

    /// Pause or resume probing for a display row by name; persists immediately.
    /// Pausing takes effect at once (state flips to `.paused`, no more launches);
    /// resuming re-probes the row right away so the user sees a fresh verdict.
    func setPaused(_ paused: Bool, name: String) {
        let key = Self.normalizedName(name)
        if paused { pausedNames.insert(key) } else { pausedNames.remove(key) }
        AppPreferences.savePausedServers(pausedNames, to: defaults)
        statusDidChange()
        for index in servers.indices where Self.normalizedName(servers[index].config.name) == key {
            if paused {
                servers[index].state = .paused
                servers[index].failureReason = nil
                servers[index].consecutiveFailures = 0
            } else {
                servers[index].state = .unknown
            }
        }
        if !paused {
            Task { await refresh(groupName: name) }
        }
    }

    /// True when the row is set up differently and she marked it as intended
    /// (and the setups still match what she acknowledged).
    func isDifferentOnPurpose(_ name: String) -> Bool {
        let key = Self.normalizedName(name)
        let configs = servers.filter { Self.normalizedName($0.config.name) == key }.map(\.config)
        let notes = Differs.detect(configs)
        guard !notes.isEmpty else { return false }
        return Differs.split(notes, configs: configs, saved: differsAcknowledged[key]).open.isEmpty
    }

    /// "Mark as Intended" / "Unmark as Intended" (1.5.2; per agent since
    /// 1.9.0). Marking saves each agent's launch target as it is now
    /// (fingerprint plus agent label, never env or header values), so the row
    /// stops counting as set up differently until an agent's setup is new or
    /// changed; an agent going away keeps the mark. Probing is not touched:
    /// the row's real errors still show. Unmarking forgets it. Both are
    /// idempotent, so a double click changes nothing.
    func setDifferentOnPurpose(_ onPurpose: Bool, name: String) {
        let key = Self.normalizedName(name)
        if onPurpose {
            let configs = servers.filter { Self.normalizedName($0.config.name) == key }.map(\.config)
            let marks = Differs.marking(configs, over: differsAcknowledged[key])
            guard !marks.isEmpty, marks != differsAcknowledged[key] else { return }
            differsAcknowledged[key] = marks
        } else {
            guard differsAcknowledged.removeValue(forKey: key) != nil else { return }
        }
        AppPreferences.saveDiffersAcknowledged(differsAcknowledged, to: defaults)
        statusDidChange()
    }

    /// Re-read the persisted probe interval and reschedule (or stop) the timer.
    /// Settings calls this when the user changes the "Check servers" preference.
    func probeIntervalChanged() {
        restartTimer()
        statusDidChange()
    }

    var aggregate: AggregateState {
        Self.iconState(servers.map(\.state), anyDiffers: groups.contains(where: \.differsNeedsAttention))
    }

    /// Menu-bar icon verdict across all servers. Pure — safe to unit-test.
    /// `anyDiffers` (some probed row is set up differently across its agents) only
    /// lifts an otherwise all-healthy verdict to `.attention`: a mismatch earns the
    /// quiet ring, never the broken diamond, and never masks a real failure.
    nonisolated static func iconState(_ states: [HealthState], anyDiffers: Bool = false) -> AggregateState {
        guard !states.isEmpty else { return .degradedOrUnknown }
        switch aggregateState(states) {
        case .broken: return .broken
        case .degraded, .unknown: return .degradedOrUnknown
        // Self-managed servers are their host app's business, and paused servers
        // aren't being probed at all — neither must ever color the menu-bar icon,
        // so an all-self-managed or all-paused set reads as healthy.
        case .healthy, .selfManaged, .paused: return anyDiffers ? .attention : .allHealthy
        }
    }

    private var timerTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?

    /// Discovery (registry + scan + aka). Replaceable so tests can run a full
    /// Refresh without scanning this Mac or launching its real servers.
    @ObservationIgnored var discover: @Sendable () async -> [ServerConfig] = {
        async let aka = AkaSource.discover()
        let configs = await Task.detached(priority: .utility) {
            ConfigDiscovery.discover()
        }.value
        return configs + (await aka)
    }

    /// One server's probe. Replaceable like `discover`, so demo mode
    /// (`DemoData`) and tests never spawn a process or open a network
    /// connection: a canned `ProbeResult` per server instead. Runs inside a
    /// concurrent `TaskGroup`, so it must be `@Sendable`; both call sites
    /// capture it into a local `let` before entering the group — reading an
    /// instance property needs the main actor, calling the captured closure
    /// doesn't.
    @ObservationIgnored var probe: @Sendable (ServerConfig, Bool) async -> ProbeResult = { config, fetchTools in
        await HealthMonitor.probeServer(config: config, fetchTools: fetchTools)
    }

    init(defaults: UserDefaults = .standard) {
        // No discovery here — it does filesystem I/O and would block whoever
        // constructs the monitor. `start()` kicks it off asynchronously.
        self.defaults = defaults
        hiddenNames = AppPreferences.loadHiddenServers(from: defaults)
        pausedNames = AppPreferences.loadPausedServers(from: defaults)
        pinnedNames = AppPreferences.loadPinnedServers(from: defaults)
        differsAcknowledged = AppPreferences.loadDiffersAcknowledged(from: defaults)
    }

    /// True once `start()` has run. The app calls `start()` at launch (1.7.1);
    /// before that it ran from the panel's `onAppear`, so after an install,
    /// restart or login nothing was checked until someone opened the panel.
    /// The latch still matters: with `menuBarExtraStyle(.window)` `onAppear`
    /// fired **every time the panel was opened**, and without this guard every
    /// open re-ran discovery and a full probe pass, including when "Check
    /// servers" was set to **Manually** (the 2026-08-03 report).
    private var hasStarted = false

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        restartTimer()
        Task {
            await reloadConfigs()
            await refreshNow()
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        probeTask?.cancel()
        probeTask = nil
        // Allow a later `start()` to take effect again.
        hasStarted = false
    }

    /// Run discovery (registry + filesystem scan) off the main actor, then merge the
    /// result into `servers` on the main actor. The scan touches hundreds of
    /// directories, so it must never run synchronously on the main thread.
    /// aka (round 5) has no config file: its sidecar is asked at the same time,
    /// with a 1.5 s timeout, and simply adds nothing when it isn't running.
    func reloadConfigs() async {
        let configs = await discover()
        servers = Self.merged(configs, into: servers, pausedNames: pausedNames)
    }

    /// Merge freshly-discovered configs into the current snapshots. A server that
    /// is still present keeps its health — unless its probe spec changed: a config
    /// the user just fixed must not inherit the hourly backoff its broken
    /// predecessor earned, so it restarts from `.unknown` and is probed next pass.
    /// Deduplicates defensively on id — downstream code (e.g.
    /// `Dictionary(uniqueKeysWithValues:)` over probe results) is entitled to
    /// assume ids are unique. Pure — safe to unit-test.
    ///
    /// Hidden/paused names are deliberately NOT pruned here: a config that is
    /// unreadable for one scan (an agent rewriting it mid-discovery) would have
    /// silently deleted the user's choices for every server in it.
    nonisolated static func merged(
        _ configs: [ServerConfig],
        into existing: [ServerSnapshot],
        pausedNames: Set<String>
    ) -> [ServerSnapshot] {
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seenIDs = Set<String>()
        return configs.compactMap { config in
            guard seenIDs.insert(config.id).inserted else { return nil }
            if let prev = byID[config.id], probeSpec(prev.config) == probeSpec(config) {
                var snap = prev
                snap.config = config
                return snap
            }
            let paused = pausedNames.contains(normalizedName(config.name))
            return ServerSnapshot(config: config, state: paused ? .paused : .unknown)
        }
    }

    /// One probe pass. `force: true` (the user's explicit ask) probes every
    /// non-paused server; `force: false` (the timer) honors per-server backoff.
    ///
    /// Single-flight: an unforced request rides the in-flight cycle rather than
    /// starting a second one. A forced request waits for the in-flight cycle and
    /// then runs its own — otherwise "Refresh now" during a timer tick silently
    /// degraded into that tick, backoff and all, and a server the user was staring
    /// at stayed red with nothing re-checked.
    func refreshNow(force: Bool = false) async {
        let waited = await awaitInFlightCycle()
        if waited && !force { return }
        let task = Task { await self.runProbeCycle(force: force) }
        probeTask = task
        await task.value
        if probeTask == task { probeTask = nil }
    }

    /// Wait for whichever cycle is in flight, then make sure `probeTask` no longer
    /// points at a finished task. Returns true when it actually waited for one.
    /// **Whoever wakes first must clear the finished task** — the original
    /// caller's own `probeTask = nil` runs only after *its* continuation gets a
    /// turn, and awaiting an already-completed task returns without suspending,
    /// so a plain `while let existing = probeTask { await existing.value }` loop
    /// spun the main actor at 100% forever (v1.4.0, "app stuck").
    @discardableResult
    private func awaitInFlightCycle() async -> Bool {
        var waited = false
        while let existing = probeTask {
            await existing.value
            waited = true
            if probeTask == existing { probeTask = nil }
            await Task.yield()
        }
        return waited
    }

    /// "Refresh now": re-run discovery, then a forced probe of every non-paused
    /// server. Discovery is included on purpose — the button answers "what is the
    /// state of my MCP setup *right now*", and a server added to a config a minute
    /// ago is part of that answer. The scan runs off the main actor and costs a
    /// fraction of the probe pass that follows it. Each timer round rediscovers
    /// too (`timerTick`).
    func refreshAll() async {
        refreshHolds += 1
        defer { refreshHolds -= 1 }
        await reloadConfigs()
        await refreshNow(force: true)
    }

    /// The footer's Refresh button. Synchronous on purpose: `isRefreshing` turns
    /// on in the tap's own turn, before the Task hop and before discovery (the
    /// scan plus aka's up-to-1.5 s answer), so the glyph spins and the summary
    /// says Checking… at once. In 1.5.0 the spin waited for discovery, about a
    /// second, and the pause read as "stuck". The hold ends with the forced
    /// pass. A tap while a Refresh is pending returns that one instead of queueing
    /// a second pass. No loop waits on a task here, so the v1.4.0 spin (see
    /// `awaitInFlightCycle`) can't come back through this path.
    @discardableResult
    func startRefreshAll() -> Task<Void, Never> {
        if let pending = refreshAllTask { return pending }
        refreshHolds += 1
        let task = Task {
            await self.refreshAll()
            self.refreshHolds -= 1
            self.refreshAllTask = nil
        }
        refreshAllTask = task
        return task
    }

    /// Re-probe only the instances behind one display row, leaving other servers'
    /// state untouched. Waits out an in-flight full cycle first (so the two never
    /// probe the same process at once) and then still runs — the user asked for
    /// this row specifically, and the cycle may have skipped it for backoff.
    func refresh(groupName: String) async {
        guard !isPaused(groupName) else { return }
        await awaitInFlightCycle()
        let ids = Set(Self.instanceIDs(forGroup: groupName, in: servers))
        guard !ids.isEmpty else { return }

        let targets = servers.filter { ids.contains($0.id) }
        let probe = self.probe
        let results = await withTaskGroup(of: (String, ProbeResult).self) { group in
            for s in targets {
                let config = s.config
                let fetchTools = s.state != .healthy
                group.addTask { (config.id, await probe(config, fetchTools)) }
            }
            var out: [String: ProbeResult] = [:]
            for await (id, r) in group { out[id] = r }
            return out
        }

        for index in servers.indices where ids.contains(servers[index].id) {
            guard let result = results[servers[index].id] else { continue }
            apply(result, at: index)
        }
    }

    /// Fold one probe result into the snapshot at `index`: smoothing, tools cache,
    /// and failure reason. Shared by the full cycle and per-group refresh so the two
    /// paths cannot drift.
    private func apply(_ result: ProbeResult, at index: Int) {
        // A pause issued while this probe was in flight wins: never overwrite
        // `.paused` with a stale result.
        guard !isPaused(servers[index].config.name) else { return }
        let smoothed = Self.smoothedState(
            probe: result.state,
            transientFailure: result.transientFailure,
            needsAttention: result.needsAttention,
            priorFailures: servers[index].consecutiveFailures
        )
        servers[index].state = smoothed.state
        servers[index].consecutiveFailures = smoothed.failures
        servers[index].lastChecked = Date()
        if smoothed.state == .healthy {
            // Update cached tools when this probe fetched them; otherwise keep the
            // last known set (probes only re-fetch on a transition to healthy).
            if let tools = result.tools { servers[index].tools = tools }
            servers[index].failureReason = nil
            servers[index].slowStartSeconds = result.slowStartSeconds
        } else {
            servers[index].slowStartSeconds = nil
            // Keep cached tools; the row shows failureReason when broken.
            servers[index].failureReason = result.failureReason
        }
    }

    /// Worst state across a set of instances: broken if any broken, else degraded,
    /// else unknown (still probing), else healthy. Empty → unknown.
    nonisolated static func aggregateState(_ states: [HealthState]) -> HealthState {
        states.min(by: { $0.sortRank < $1.sortRank }) ?? .unknown
    }

    /// Collapse snapshots into one group per server name, aggregating status and
    /// collecting the sources each name appears in. Broken variants (source + reason)
    /// are kept so the detail card can show which agent is broken.
    ///
    /// `acknowledged` (1.5.2, "Mark as intended"; per agent since 1.9.0): the
    /// notes of agents whose setup she marked move to `acknowledgedDiffers`, so
    /// they never count as set up differently; an agent that is new or changed
    /// stays in `differs`.
    nonisolated static func groupByName(
        _ snapshots: [ServerSnapshot],
        acknowledged: [String: [String]] = [:]
    ) -> [ServerGroup] {
        let grouped = Dictionary(grouping: snapshots, by: { Self.normalizedName($0.config.name) })
        let groups = grouped.map { key, variants -> ServerGroup in
            let name = Self.representativeName(variants)
            let state = aggregateState(variants.map(\.state))
            var labels: [String] = []
            for v in variants where !labels.contains(v.config.displaySource) {
                labels.append(v.config.displaySource)
            }
            let tools = variants.first(where: { $0.state == .healthy })?.tools
                ?? variants.max(by: { $0.tools.count < $1.tools.count })?.tools
                ?? []
            let issues = variants
                .filter { ($0.state == .broken || $0.state == .degraded) && $0.failureReason != nil }
                // Masked here, once, so every copy and export of an error (Copy Errors,
                // Cmd-C, the card, Copy All, Export) is safe to paste into a chat: a
                // command line can carry a bearer token (mcp-remote --header ...).
                .map { snapshot -> ServerIssue in
                    let known = SecretMask.knownSecrets(env: snapshot.config.env, headers: snapshot.config.headers)
                    let command = snapshot.config.transport == .stdio
                        ? SecretMask.commandLine(command: snapshot.config.command, args: snapshot.config.args, known: known)
                        : SecretMask.url(snapshot.config.url ?? "", known: known)
                    return ServerIssue(label: snapshot.config.displaySource,
                                       reason: SecretMask.scrub(snapshot.failureReason ?? "Unknown failure", known: known),
                                       command: command)
                }
            let sources = variants.map { v in
                GroupSource(
                    configID: v.config.id,
                    label: v.config.displaySource,
                    agent: v.config.source.label,
                    path: v.config.source.path,
                    transport: v.config.transport,
                    target: v.config.commandLine,
                    envKeys: v.config.env.keys.sorted(),
                    headerKeys: v.config.headers.keys.sorted(),
                    state: v.state,
                    failureReason: v.failureReason
                )
            }
            let configs = variants.map(\.config)
            let notes = Differs.split(Differs.detect(configs), configs: configs, saved: acknowledged[key])
            return ServerGroup(
                name: name,
                state: state,
                sourceLabels: labels,
                tools: tools,
                issues: issues,
                variantCount: variants.count,
                differs: notes.open,
                acknowledgedDiffers: notes.acknowledged,
                sources: sources,
                lastChecked: variants.compactMap(\.lastChecked).max(),
                slowStartSeconds: state == .healthy
                    ? variants.filter { $0.state == .healthy }.compactMap(\.slowStartSeconds).max()
                    : nil
            )
        }
        // Broken first, then by name — the only sort the display needs.
        return groups.sorted {
            if $0.state.sortRank != $1.state.sortRank {
                return $0.state.sortRank < $1.state.sortRank
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Grouping key that ignores case and separators, so the same MCP tool named
    /// `Chrome DevTools` (Goose) and `chrome-devtools` (Cursor) — or `Pieces`/`pieces`,
    /// `EventKit`/`eventkit` — collapses to a single row.
    nonisolated static func normalizedName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Whether `name` is in the hidden set, compared on the normalized grouping key.
    nonisolated static func isHidden(_ name: String, in hidden: Set<String>) -> Bool {
        hidden.contains(normalizedName(name))
    }

    /// Split groups into (visible, hidden) by the normalized hidden set.
    nonisolated static func partition(
        _ groups: [ServerGroup], hidden: Set<String>
    ) -> (visible: [ServerGroup], hidden: [ServerGroup]) {
        var visible: [ServerGroup] = []
        var hiddenGroups: [ServerGroup] = []
        for group in groups {
            if isHidden(group.name, in: hidden) { hiddenGroups.append(group) }
            else { visible.append(group) }
        }
        return (visible, hiddenGroups)
    }

    /// IDs of the snapshots that belong to a display group (matched by normalized name).
    nonisolated static func instanceIDs(forGroup groupName: String, in servers: [ServerSnapshot]) -> [String] {
        let key = normalizedName(groupName)
        return servers.filter { normalizedName($0.config.name) == key }.map(\.id)
    }

    /// The name to display for a merged group: the most common raw name across
    /// instances, preferring the canonical lowercase id (what Code/Cursor/Grok write)
    /// over a display-cased variant (what Goose writes). Depends only on the configs,
    /// not on health state, so a row's label (its selection and pin key) is stable.
    nonisolated static func representativeName(_ variants: [ServerSnapshot]) -> String {
        var counts: [String: Int] = [:]
        for v in variants { counts[v.config.name, default: 0] += 1 }
        let best = counts.keys.sorted { a, b in
            if counts[a] != counts[b] { return counts[a]! > counts[b]! }   // most frequent first
            let aLower = a == a.lowercased(), bLower = b == b.lowercased()
            if aLower != bLower { return aLower }                          // prefer lowercase id
            return a < b                                                   // stable tie-break
        }.first
        return best ?? variants.first?.config.name ?? ""
    }

    // MARK: - Private

    private func restartTimer() {
        timerTask?.cancel()
        timerTask = nil
        // Manual mode: no timer at all — probing happens only via "Refresh now"
        // and per-server refresh.
        guard let interval = AppPreferences.loadProbeInterval().seconds else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self?.timerTick()
            }
        }
    }

    /// One timer round: re-read the configs, then probe what is due. The timer
    /// used to skip discovery, so a server changed or removed in an agent's config
    /// kept its old row (old command, old failure, still in backoff) until Refresh
    /// or a relaunch (stress run, 2026-09-26: postiz moved from stdio to http in
    /// Claude Code and was deleted from aka; two rounds later both still showed the
    /// old entries). `merged` restarts a changed server from `.unknown`, so the
    /// probe below checks the new config at once instead of waiting out a backoff.
    func timerTick() async {
        await reloadConfigs()
        await refreshNow()
    }

    private func runProbeCycle(force: Bool) async {
        if Task.isCancelled { return }
        // Note: discovery (the filesystem scan) is NOT run here — the callers run
        // it first: launch, `refreshAll()` ("Refresh now") and `timerTick()`.
        refreshHolds += 1
        defer { refreshHolds -= 1 }

        // Paused servers are never launched. Persistently failing servers are
        // re-probed on an escalating backoff (5 min → 15 min → hourly) instead of
        // every cycle — spawning is side-effectful (an unauthenticated OAuth server
        // opens a browser login page on every launch), so full-cadence retries of a
        // known-bad server are actively harmful. `force` (Refresh now) skips the
        // backoff but never the pause.
        let now = Date()
        let due = servers.filter { Self.shouldProbe($0, pausedNames: pausedNames, force: force, now: now) }

        // Identical probe targets (same command/args/env/cwd or url/headers) are
        // probed ONCE and the result fanned out to every instance — the same server
        // declared in 5 agents used to spawn 5 subprocesses per cycle for the same
        // answer. Cuts a full cycle's spawn count roughly in half on real setups.
        let specGroups = Dictionary(grouping: due, by: { Self.probeSpec($0.config) })

        let probe = self.probe
        await withTaskGroup(of: ([String], ProbeResult).self) { group in
            for instances in specGroups.values {
                let config = instances[0].config
                // Fetch tools if ANY instance needs them (probes only re-fetch on a
                // transition to healthy).
                let fetchTools = instances.contains { $0.state != .healthy }
                let ids = instances.map(\.id)
                group.addTask {
                    (ids, await probe(config, fetchTools))
                }
            }
            // Apply each result the moment it arrives, so the header count and the
            // dots update live during the cycle instead of freezing until the
            // slowest probe (a full cycle takes ~10-25s on a large setup) finishes.
            for await (ids, result) in group {
                if Task.isCancelled { break }
                for id in ids {
                    guard let index = servers.firstIndex(where: { $0.id == id }) else { continue }
                    apply(result, at: index)
                }
            }
        }
        if !Task.isCancelled { hasCompletedFirstPass = true }
    }

    /// Identity of a probe target: two configs with the same spec launch the exact
    /// same process (or hit the same endpoint) the same way, so probing one answers
    /// for both. Deliberately excludes id/name/source — those are display identity.
    /// `projectPath` is included: it's the working directory the server runs in.
    nonisolated static func probeSpec(_ config: ServerConfig) -> ProbeSpec {
        ProbeSpec(
            transport: config.transport,
            command: config.command,
            args: config.args,
            env: config.env,
            projectPath: config.projectPath,
            url: config.url,
            headers: config.headers,
            builtin: config.builtin,
            headersHelper: config.headersHelper
        )
    }

    /// Consecutive transient failures required before a server is shown as `broken` (red).
    nonisolated static let failureThreshold = 2

    /// Seconds to wait before re-probing a server that has failed this many times
    /// in a row; `nil` = probe every cycle (still under the failure threshold).
    /// Escalates 5 min → 15 min → hourly, capped — a broken server keeps being
    /// re-checked, just not at a cadence that re-triggers its launch side effects.
    nonisolated static func backoffSeconds(consecutiveFailures: Int) -> TimeInterval? {
        switch consecutiveFailures {
        case ..<failureThreshold: return nil
        case failureThreshold: return 300
        case failureThreshold + 1: return 900
        default: return 3600
        }
    }

    /// Whether a snapshot's backoff window (if any) has elapsed at `now`.
    nonisolated static func isDue(_ snapshot: ServerSnapshot, now: Date) -> Bool {
        guard let backoff = backoffSeconds(consecutiveFailures: snapshot.consecutiveFailures),
              let last = snapshot.lastChecked else { return true }
        return now.timeIntervalSince(last) >= backoff
    }

    /// Whether a snapshot participates in a probe cycle: paused servers never do
    /// (even when `force`d — pause is the user's hard off-switch); everything else
    /// probes when due, or unconditionally on a user-initiated `force` refresh.
    nonisolated static func shouldProbe(
        _ snapshot: ServerSnapshot, pausedNames: Set<String>, force: Bool, now: Date
    ) -> Bool {
        if pausedNames.contains(normalizedName(snapshot.config.name)) { return false }
        return force || isDue(snapshot, now: now)
    }

    /// Failure smoothing. A single transient failure (e.g. a slow cold-start timeout) shows
    /// amber `degraded` rather than red, so a healthy/starting server doesn't blink red on one
    /// hiccup. A definitive failure (spawn error, non-zero exit) — or a 2nd consecutive
    /// transient failure — shows red `broken`. An **attention** failure (auth: HTTP 401/403)
    /// is stable amber `degraded` that never escalates — retrying won't help, but nothing is
    /// crashing, so it reads as "needs you," not "broken." Any success returns to `healthy`.
    nonisolated static func smoothedState(
        probe: HealthState,
        transientFailure: Bool,
        needsAttention: Bool = false,
        priorFailures: Int
    ) -> (state: HealthState, failures: Int) {
        if probe == .healthy {
            return (.healthy, 0)
        }
        // Self-managed (builtin) entries are never probed; the state passes
        // through untouched and never participates in failure smoothing.
        if probe == .selfManaged {
            return (.selfManaged, 0)
        }
        // Auth / "needs attention": stable amber, no escalation, counter held at 0.
        if needsAttention {
            return (.degraded, 0)
        }
        // Probes only return .healthy or .broken; this is a failure.
        // Definitive failures jump straight to the threshold AND keep counting up
        // on repeats, so probe backoff escalates for them too.
        guard transientFailure else {
            return (.broken, max(priorFailures + 1, failureThreshold))
        }
        let failures = priorFailures + 1
        return failures >= failureThreshold ? (.broken, failures) : (.degraded, failures)
    }

    nonisolated static func probeServer(config: ServerConfig, fetchTools: Bool) async -> ProbeResult {
        // Builtin entries run inside their host app's own runtime (e.g. MiniMax
        // Code's cu/trash/matrix behind its on-demand gateway, or asar-internal
        // paths) — probing the on-disk command from outside always fails, so
        // don't probe: report the dedicated neutral state instead.
        if config.builtin {
            return ProbeResult(state: .selfManaged, failureReason: nil, tools: nil)
        }
        switch config.transport {
        case .stdio:
            return await StdioProbe.probe(config: config, fetchTools: fetchTools)
        case .http, .sse:
            return await HTTPProbe.probe(config: config, fetchTools: fetchTools)
        }
    }
}
