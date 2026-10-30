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
    @ObservationIgnored var statusWriter: StatusWriter? {
        didSet { statusWriter?.onWrite = { [weak self] in self?.statusFileError = $0 } }
    }
    /// Why the last status-file write failed, or nil; Settings > General shows it.
    var statusFileError: String?
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
            sessionDrops: sessionDrops,
            checking: isRefreshing,
            firstCheckDone: hasCompletedFirstPass,
            interval: AppPreferences.loadProbeInterval(from: defaults),
            now: now
        )
    }
    private var hiddenNames: Set<String>
    private var pausedNames: Set<String>
    /// Scan-only config files she allowed (review 2026-10-20, 5ae6).
    private(set) var allowedScanFiles: Set<String>
    /// What each allowed file started when she allowed it (r3 e46f).
    private var allowedScanFingerprints: [String: String]
    /// Each scan-only file's fingerprint as last read.
    private var scanFingerprints: [String: String] = [:]
    /// An update from a version before 1.10.9: the first reload allows every
    /// scan-only file already there. A first install asks for each one.
    private var seedsScanFiles: Bool
    /// Normalized names the user pinned to the top of the panel (v1.5). Read by
    /// the views as `pinnedNames` and handed to `PanelSections.build`.
    private(set) var pinnedNames: Set<String>
    /// "Mark as intended" (1.5.2): normalized name -> the fingerprints of
    /// the launch targets she acknowledged. Never pruned: an entry whose setups
    /// changed simply stops matching (`Differs.acknowledgementMatches`).
    private(set) var differsAcknowledged: [String: [String]] {
        didSet { groupsCache = nil }
    }

    /// Servers open Claude Code sessions lost (1.12), by normalized name.
    private(set) var sessionDrops: [String: [SessionDrop]] = [:] {
        didSet {
            guard sessionDrops != oldValue else { return }
            groupsCache = nil
            statusDidChange()
        }
    }

    /// Reads which servers open sessions lost. Nil (tests, demo mode) reads nothing.
    @ObservationIgnored var readSessionDrops: (@Sendable () async -> [String: [SessionDrop]])?

    /// Read the open sessions' logs again: after each full check and when the
    /// panel opens, so a drop shows without waiting for the timer.
    func refreshSessionDrops() async {
        guard let readSessionDrops else { return }
        sessionDrops = await readSessionDrops()
    }
    /// Agents on this Mac that are listed with no servers (1.12.1, Grok Bot):
    /// `AgentRegistry.listedWhenEmpty`. Read with every config read.
    private(set) var installedEmptyAgents: [String] = []

    /// Those of them with no server at all, hidden ones included: the agents
    /// the Agents tab and Settings list with their "No servers yet" line.
    var serverlessAgents: [String] {
        guard !installedEmptyAgents.isEmpty else { return [] }
        let named = Set(groups.flatMap { $0.sources.map { AgentBadge.agentName(fromLabel: $0.agent) } })
        return installedEmptyAgents.filter { !named.contains($0) }
    }

    /// Finds those agents. Nil (tests, demo mode) finds none.
    @ObservationIgnored var findInstalledEmptyAgents: (@Sendable () async -> [String])?

    // MARK: - Servers that belong to a Mac app (2026-10-16)

    /// Local port -> the `.app` seen listening on it, kept across launches
    /// (re-checked once per session while its server works).
    private(set) var learnedHostPorts: [Int: String] = [:]
    /// Ports already looked up this session (a command-line listener stays unknown).
    @ObservationIgnored private var lookedUpPorts: Set<Int> = []

    /// The app a config belongs to, given the ports learned so far. Runs off
    /// the main thread, inside a probe. Swapped in tests.
    @ObservationIgnored var hostAppOf: @Sendable (ServerConfig, [Int: String]) -> HostApp? = {
        HostApps.app(for: $0, learnedPorts: $1)
    }
    /// Whether that app runs. Swapped in tests.
    @ObservationIgnored var appIsRunning: (HostApp) -> Bool = { HostApps.isRunning($0) }
    /// Which app listens on a local port (lsof). Runs off the main thread,
    /// inside a probe. Swapped in tests.
    @ObservationIgnored var listeningApp: @Sendable (Int) -> HostApp? = { HostApps.listeningApp(port: $0) }
    /// The app behind each probe target, as its last probe found it. The
    /// lookup reads files and runs lsof, so it happens in the probe, never on
    /// the main thread (Argon 2026-10-17 #7: the panel froze during a check).
    @ObservationIgnored private var hostAppBySpec: [ProbeSpec: HostApp] = [:]

    /// The closed app a healthy-or-failing server waits for, or nil when it
    /// has no app or the app runs.
    func closedHostApp(of config: ServerConfig) -> HostApp? {
        guard let app = hostAppBySpec[Self.probeSpec(config)], !appIsRunning(app) else { return nil }
        return app
    }

    /// `probe`, then the host-app lookup (`HostApps.lookUp`), both off the
    /// main thread.
    private func probeWithHostApp() -> @Sendable (ServerConfig, Bool) async -> (ProbeResult, HostLookup) {
        let probe = self.probe, hostAppOf = self.hostAppOf, listeningApp = self.listeningApp
        let learned = learnedHostPorts, skip = lookedUpPorts
        return { config, fetchTools in
            let result = await probe(config, fetchTools)
            let lookup = HostApps.lookUp(config, healthy: result.state == .healthy, learned: learned, skip: skip,
                                         hostAppOf: hostAppOf, listeningApp: listeningApp)
            return (result, lookup)
        }
    }

    /// Keep what a probe's lookup found: ports learned (each looked up once
    /// per session) and the config's app.
    private func record(_ lookup: HostLookup, for config: ServerConfig) {
        lookedUpPorts.formUnion(lookup.lookedUp)
        var ports = learnedHostPorts.merging(lookup.learned) { _, new in new }
        for port in lookup.forgotten { ports[port] = nil }
        if ports != learnedHostPorts {
            learnedHostPorts = ports
            AppPreferences.saveHostAppPorts(learnedHostPorts, to: defaults)
        }
        hostAppBySpec[Self.probeSpec(config)] = lookup.app
    }

    /// An app just opened: check at once the servers that waited for it, after
    /// a moment for it to start serving.
    func hostAppLaunched(bundlePath: String, bundleID: String?) {
        let names = groups.filter { group in
            group.state == .needsApp && servers.contains { snap in
                HealthMonitor.normalizedName(snap.config.name) == HealthMonitor.normalizedName(group.name)
                    && (snap.hostApp?.bundlePath == bundlePath || (bundleID != nil && snap.hostApp?.bundleID == bundleID))
            }
        }.map(\.name)
        guard !names.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            for name in names { await self.refresh(groupName: name) }
        }
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
        let drops = sessionDrops
        if let groupsCache { return groupsCache }
        let built = Self.groupByName(servers, acknowledged: acknowledged, sessionDrops: drops)
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
    /// Never gives a scan-only file its OK: that is `allowScanFiles` only (r3 f9f2).
    func setPaused(_ paused: Bool, name: String) {
        let key = Self.normalizedName(name)
        if paused { pausedNames.insert(key) } else { pausedNames.remove(key) }
        AppPreferences.savePausedServers(pausedNames, to: defaults)
        statusDidChange()
        for index in servers.indices where Self.normalizedName(servers[index].config.name) == key {
            if servers[index].awaitingFileOK { continue }
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

    /// The icon follows what the panel lists (Argon 2026-10-16 #5): a hidden
    /// server counts only while it is broken, and then the panel lists it too.
    var aggregate: AggregateState {
        let shown = visibleGroups
        if shown.isEmpty && !groups.isEmpty { return .allHealthy }
        return Self.iconState(shown.map(Self.iconInput), anyDiffers: shown.contains(where: \.attentionWhileHealthy))
    }

    /// A Not checked row (a `${VAR}` to fill) is calm, never the ring (r3 b964).
    nonisolated static func iconInput(_ group: ServerGroup) -> HealthState {
        group.notCheckedHere ? .healthy : group.state
    }

    /// Menu-bar icon verdict across all servers. Pure — safe to unit-test.
    /// `anyDiffers` (some probed row is set up differently across its agents) only
    /// lifts an otherwise all-healthy verdict to `.attention`: a mismatch earns the
    /// quiet ring, never the broken diamond, and never masks a real failure.
    nonisolated static func iconState(_ states: [HealthState], anyDiffers: Bool = false) -> AggregateState {
        // No servers, or rows only waiting for their first check: the plain
        // glyph (r3 8aa6). The ring is for a real slow, sign-in or differs.
        guard !states.isEmpty else { return .allHealthy }
        // A server waiting for its closed app never colors the icon (2026-10-16).
        switch aggregateState(states.map { $0 == .needsApp || $0 == .unknown ? .healthy : $0 }) {
        case .broken: return .broken
        case .degraded, .unknown: return .degradedOrUnknown
        // Self-managed servers are their host app's business, and paused servers
        // aren't being probed at all — neither must ever color the menu-bar icon,
        // so an all-self-managed or all-paused set reads as healthy.
        case .healthy, .selfManaged, .paused, .needsApp: return anyDiffers ? .attention : .allHealthy
        }
    }

    private var timerTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    /// True while `probeTask` is a full cycle, false for one row's Check again.
    /// An unforced cycle rides only a *full* cycle in flight: riding a single
    /// row's check made the timer skip every other server (Argon 2026-10-16 #7).
    private var probeTaskIsFullCycle = false

    /// Discovery (registry + scan + aka). Replaceable so tests can run a full
    /// Refresh without scanning this Mac or launching its real servers.
    @ObservationIgnored var discover: @Sendable () async -> [ServerConfig] = {
        async let aka = AkaSource.discover()
        let configs = await Task.detached(priority: .utility) {
            ConfigDiscovery.discover()
        }.value
        return configs + (await aka)
    }

    /// A timer round's read (9180): only the known agents' files and the
    /// files the last full scan found, no home-folder walk. Nil (tests, demo
    /// mode) reads with `discover`, as every round did before.
    @ObservationIgnored var discoverKnownFiles: (@Sendable ([String]) async -> [ServerConfig])?

    /// The scan-found files of the last full read, for `discoverKnownFiles`.
    private var knownScanFiles: [String] = []

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

    /// `isUpdate`: whether an older mcpock ran on this Mac before (nil: it
    /// left its status file).
    init(defaults: UserDefaults = .standard, isUpdate: Bool? = nil) {
        // No discovery here — it does filesystem I/O and would block whoever
        // constructs the monitor. `start()` kicks it off asynchronously.
        self.defaults = defaults
        hiddenNames = AppPreferences.loadHiddenServers(from: defaults)
        pausedNames = AppPreferences.loadPausedServers(from: defaults)
        allowedScanFiles = AppPreferences.loadAllowedScanFiles(from: defaults)
        allowedScanFingerprints = AppPreferences.loadAllowedScanFingerprints(from: defaults)
        seedsScanFiles = !defaults.bool(forKey: AppPreferences.scanFilesSeededKey)
            && (isUpdate ?? Self.ranBefore())
        pinnedNames = AppPreferences.loadPinnedServers(from: defaults)
        differsAcknowledged = AppPreferences.loadDiffersAcknowledged(from: defaults)
        learnedHostPorts = AppPreferences.loadHostAppPorts(from: defaults)
    }

    /// True once `start()` has run. The app calls `start()` at launch (1.7.1);
    /// before that it ran from the panel's `onAppear`, so after an install,
    /// restart or login nothing was checked until someone opened the panel.
    /// The latch still matters: with `menuBarExtraStyle(.window)` `onAppear`
    /// fired **every time the panel was opened**, and without this guard every
    /// open re-ran discovery and a full probe pass, including when "Check
    /// servers" was set to **Manually** (the 2026-08-03 report).
    private var hasStarted = false

    /// Runs once before the first check: the app reads the login shell's
    /// environment here (`ShellEnvironment`); tests and demo mode do nothing.
    @ObservationIgnored var prepareEnvironment: () async -> Void = {}

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        restartTimer()
        Task {
            await prepareEnvironment()
            await awaitInFlightCycle()
            await reloadThenProbe(force: false, fullScan: true)
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
    ///
    /// `fullScan: false` (a timer round) skips the folder walk when
    /// `discoverKnownFiles` is set: the full scan runs at launch, on Refresh
    /// and on Check again (9180).
    func reloadConfigs(fullScan: Bool = true) async {
        let found: [ServerConfig]
        if !fullScan, let discoverKnownFiles {
            found = await discoverKnownFiles(knownScanFiles)
        } else {
            found = await discover()
            knownScanFiles = ConfigDiscovery.scanFiles(in: found)
        }
        let configs = found + Self.midWriteSurvivors(previous: servers.map(\.config), found: found)
        if seedsScanFiles {
            allowedScanFiles.formUnion(configs.compactMap(Self.scanOnlyFile))
            AppPreferences.saveAllowedScanFiles(allowedScanFiles, to: defaults)
            seedsScanFiles = false
        }
        defaults.set(true, forKey: AppPreferences.scanFilesSeededKey)
        scanFingerprints = Self.scanFileFingerprints(configs)
        // A file allowed before fingerprints existed keeps what it starts now.
        var recorded = false
        for path in allowedScanFiles where allowedScanFingerprints[path] == nil {
            guard let fingerprint = scanFingerprints[path] else { continue }
            allowedScanFingerprints[path] = fingerprint
            recorded = true
        }
        if recorded { AppPreferences.saveAllowedScanFingerprints(allowedScanFingerprints, to: defaults) }
        if let findInstalledEmptyAgents {
            let installed = await findInstalledEmptyAgents()
            if installed != installedEmptyAgents { installedEmptyAgents = installed }
        }
        servers = Self.merged(configs, into: servers, pausedNames: pausedNames,
                              allowedScanFiles: Self.stillAllowed(allowedScanFiles, prints: allowedScanFingerprints,
                                                                  now: scanFingerprints))
    }

    /// The allowed files whose commands are still what she allowed.
    nonisolated static func stillAllowed(
        _ allowed: Set<String>, prints: [String: String], now: [String: String]
    ) -> Set<String> {
        allowed.filter { path in prints[path] == nil || prints[path] == now[path] }
    }

    /// A hash of what each scan-only file starts: every server's name,
    /// transport, command, args, url and headers helper (not env or header
    /// values), so a changed helper asks again too (r3 1c25).
    nonisolated static func scanFileFingerprints(_ configs: [ServerConfig]) -> [String: String] {
        var lines: [String: [String]] = [:]
        for config in configs {
            guard let path = scanOnlyFile(config) else { continue }
            let parts = [config.name, config.transport.rawValue, config.command ?? "", config.url ?? "",
                         config.headersHelper ?? ""] + config.args
            lines[path, default: []].append(parts.joined(separator: "\u{1F}"))
        }
        return lines.mapValues { UsageCursor.stableHash($0.sorted().joined(separator: "\n")) }
    }

    /// Servers whose config file is being written right now (changed in the
    /// last few seconds) and read as nothing this time: kept as they were
    /// until the next read, instead of vanishing from the panel (r3 801b).
    nonisolated static func midWriteSurvivors(
        previous: [ServerConfig],
        found: [ServerConfig],
        now: Date = Date(),
        modified: (String) -> Date? = { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
    ) -> [ServerConfig] {
        let foundPaths = Set(found.map(\.source.path))
        let foundIDs = Set(found.map(\.id))
        var recent: [String: Bool] = [:]
        return previous.filter { config in
            let path = config.source.path
            guard !path.isEmpty, !foundPaths.contains(path), !foundIDs.contains(config.id) else { return false }
            if let known = recent[path] { return known }
            let changed = modified(path).map { now.timeIntervalSince($0) < 10 } ?? false
            recent[path] = changed
            return changed
        }
    }

    /// The config file of a server found only by the scan, or nil for a known
    /// agent's file, aka, or a project `.mcp.json` (Claude Code's own approval
    /// decides those: `ClaudeProjectApproval`). The scan reads every MCP-shaped
    /// file in dot folders and Application Support, so an example, a copy or
    /// another app's file would otherwise have its command started every minute.
    nonisolated static func scanOnlyFile(_ config: ServerConfig) -> String? {
        guard config.id.hasPrefix("scan:"),
              ConfigDiscovery.claudeProjectFolder(forScannedPath: config.source.path) == nil
        else { return nil }
        return config.source.path
    }

    /// True when the server comes from a scan-only file she has not allowed.
    nonisolated static func awaitsFileOK(_ config: ServerConfig, allowed: Set<String>) -> Bool {
        scanOnlyFile(config).map { !allowed.contains($0) } ?? false
    }

    /// True when a server behind the row waits for its scan-only file's OK.
    func awaitsFileOK(_ name: String) -> Bool {
        let key = Self.normalizedName(name)
        return servers.contains { Self.normalizedName($0.config.name) == key && $0.awaitingFileOK }
    }

    /// Allow the scan-only files behind a row ("Allow this file" on the card
    /// and the right-click menu). Returns true when there was one to allow.
    @discardableResult
    func allowScanFiles(forGroup name: String) -> Bool {
        let key = Self.normalizedName(name)
        var allowedNow = false
        for index in servers.indices where Self.normalizedName(servers[index].config.name) == key
            && servers[index].awaitingFileOK {
            if let path = Self.scanOnlyFile(servers[index].config) {
                allowedScanFiles.insert(path)
                if let fingerprint = scanFingerprints[path] ?? Self.scanFileFingerprints(servers.map(\.config))[path] {
                    allowedScanFingerprints[path] = fingerprint
                }
            }
            servers[index].awaitingFileOK = false
            if !isPaused(name) { servers[index].state = .unknown }
            allowedNow = true
        }
        guard allowedNow else { return false }
        AppPreferences.saveAllowedScanFiles(allowedScanFiles, to: defaults)
        AppPreferences.saveAllowedScanFingerprints(allowedScanFingerprints, to: defaults)
        statusDidChange()
        return true
    }

    /// An older mcpock wrote its status file on this Mac.
    nonisolated static func ranBefore() -> Bool {
        FileManager.default.fileExists(
            atPath: MCPockStatus.defaultDirectory().appendingPathComponent(MCPockStatus.fileName).path)
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
        pausedNames: Set<String>,
        allowedScanFiles: Set<String>? = nil
    ) -> [ServerSnapshot] {
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seenIDs = Set<String>()
        return configs.compactMap { config in
            guard seenIDs.insert(config.id).inserted else { return nil }
            let awaiting = allowedScanFiles.map { awaitsFileOK(config, allowed: $0) } ?? false
            if let prev = byID[config.id], probeSpec(prev.config) == probeSpec(config), prev.awaitingFileOK == awaiting {
                var snap = prev
                snap.config = config
                return snap
            }
            let paused = awaiting || pausedNames.contains(normalizedName(config.name))
            var snap = ServerSnapshot(config: config, state: paused ? .paused : .unknown)
            snap.awaitingFileOK = awaiting
            return snap
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
        let waitedForFullCycle = await awaitInFlightCycle()
        if waitedForFullCycle && !force { return }
        let task = Task { await self.runProbeCycle(force: force) }
        probeTask = task
        probeTaskIsFullCycle = true
        await task.value
        if probeTask == task { probeTask = nil }
    }

    /// Read the configs, then probe, as ONE tracked cycle (Argon 2026-10-17 #6).
    /// The read used to run before `probeTask` was set, so a second caller in
    /// that window saw no cycle in flight, read the configs again and replaced
    /// `servers` while the first cycle probed, and both probed at once. Call it
    /// right after `awaitInFlightCycle()`, with no suspension in between.
    private func reloadThenProbe(force: Bool, fullScan: Bool) async {
        let task = Task {
            await self.reloadConfigs(fullScan: fullScan)
            await self.runProbeCycle(force: force)
        }
        probeTask = task
        probeTaskIsFullCycle = true
        await task.value
        if probeTask == task { probeTask = nil }
    }

    /// Wait for whichever cycle is in flight, then make sure `probeTask` no longer
    /// points at a finished task. Returns true when it waited for a full cycle
    /// (a single row's Check again doesn't count).
    /// **Whoever wakes first must clear the finished task** — the original
    /// caller's own `probeTask = nil` runs only after *its* continuation gets a
    /// turn, and awaiting an already-completed task returns without suspending,
    /// so a plain `while let existing = probeTask { await existing.value }` loop
    /// spun the main actor at 100% forever (v1.4.0, "app stuck").
    @discardableResult
    private func awaitInFlightCycle() async -> Bool {
        var waited = false
        while let existing = probeTask {
            let full = probeTaskIsFullCycle
            await existing.value
            if full { waited = true }
            if probeTask == existing { probeTask = nil }
            await Task.yield()
        }
        return waited
    }

    /// "Refresh now": re-run discovery, then a forced probe of every non-paused
    /// server. Discovery is included on purpose — the button answers "what is the
    /// state of my MCP setup *right now*", and a server added to a config a minute
    /// ago is part of that answer. The scan runs off the main actor and costs a
    /// fraction of the probe pass that follows it. A timer round re-reads only
    /// the files already known (`timerTick`, 9180).
    func refreshAll() async {
        refreshHolds += 1
        defer { refreshHolds -= 1 }
        // Read the configs only once no cycle is in flight: an old cycle that
        // finished after the reload wrote its result over a server just fixed
        // (Argon 2026-10-16 #8).
        await awaitInFlightCycle()
        await reloadThenProbe(force: true, fullScan: true)
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
    ///
    /// Reads the config files again first (1.10): Check again is what she
    /// presses right after fixing a server's config, and probing the command
    /// and keys from before the fix kept the row red until the next timer
    /// round. A config whose probe spec changed starts over from `.unknown`
    /// (`merged`), so the row spins and then shows the fixed server's answer.
    func refresh(groupName: String) async {
        guard !isPaused(groupName) else { return }
        await awaitInFlightCycle()
        let task = Task {
            await self.reloadConfigs()
            guard !self.isPaused(groupName) else { return }
            let ids = Set(Self.instanceIDs(forGroup: groupName, in: self.servers))
            guard !ids.isEmpty else { return }

            let targets = self.servers.filter { ids.contains($0.id) && !$0.awaitingFileOK }
            let specGroups = Dictionary(grouping: targets, by: { Self.probeSpec($0.config) })
            let probe = self.probeWithHostApp()
            let results = await withTaskGroup(of: ([String], (ProbeResult, HostLookup)).self) { group in
                for instances in specGroups.values {
                    let config = instances[0].config
                    // Check again always re-reads the tool list (review, 2026-10-14).
                    let ids = instances.map(\.id)
                    group.addTask { (ids, await probe(config, true)) }
                }
                var out: [String: (ProbeResult, HostLookup)] = [:]
                for await (ids, r) in group {
                    for id in ids { out[id] = r }
                }
                return out
            }

            for index in self.servers.indices where ids.contains(self.servers[index].id) {
                guard let (result, lookup) = results[self.servers[index].id] else { continue }
                self.apply(result, at: index, lookup: lookup)
            }
            // She pressed Check again, maybe right after /mcp: a lost row must
            // not linger until the next round (review 2026-10-30, 2a27).
            await self.refreshSessionDrops()
        }
        probeTask = task
        probeTaskIsFullCycle = false
        await task.value
        if probeTask == task { probeTask = nil }
    }

    /// Fold one probe result into the snapshot at `index`: smoothing, tools cache,
    /// and failure reason. Shared by the full cycle and per-group refresh so the two
    /// paths cannot drift.
    private func apply(_ result: ProbeResult, at index: Int, lookup: HostLookup) {
        record(lookup, for: servers[index].config)
        // A pause issued while this probe was in flight wins: never overwrite
        // `.paused` with a stale result.
        guard !isPaused(servers[index].config.name) else { return }
        // Failed while the app it belongs to is closed: waiting, not broken.
        // No backoff, so it turns fine at the next check once the app runs.
        if result.state != .healthy, result.state != .selfManaged,
           let app = closedHostApp(of: servers[index].config) {
            servers[index].state = .needsApp
            servers[index].hostApp = app
            servers[index].consecutiveFailures = 0
            servers[index].lastChecked = Date()
            servers[index].failureReason = "Needs \(app.name) open"
            servers[index].slowStartSeconds = nil
            return
        }
        servers[index].hostApp = nil
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
            // last known set (a timer round re-fetches only on a transition to
            // healthy; Refresh and Check again always do).
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
        acknowledged: [String: [String]] = [:],
        sessionDrops: [String: [SessionDrop]] = [:]
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
                    let known = SecretMask.knownSecrets(of: snapshot.config)
                    let command = snapshot.config.transport == .stdio
                        ? SecretMask.commandLine(command: snapshot.config.command, args: snapshot.config.args, known: known)
                        : SecretMask.url(snapshot.config.url ?? "", known: known)
                    return ServerIssue(label: snapshot.config.displaySource,
                                       reason: SecretMask.scrub(snapshot.failureReason ?? "Unknown failure", known: known),
                                       command: command)
                }
            let sources = variants.map { v -> GroupSource in
                let known = SecretMask.knownSecrets(of: v.config)
                let target = v.config.transport == .stdio
                    ? SecretMask.commandLine(command: v.config.command, args: v.config.args, known: known)
                    : SecretMask.url(v.config.url ?? "", known: known)
                return GroupSource(
                    configID: v.config.id,
                    label: v.config.displaySource,
                    agent: v.config.source.label,
                    path: v.config.source.path,
                    transport: v.config.transport,
                    target: target,
                    envKeys: v.config.env.keys.sorted(),
                    headerKeys: v.config.headers.keys.sorted(),
                    state: v.state,
                    failureReason: v.failureReason.map { SecretMask.scrub($0, known: known) },
                    compareKey: Differs.launchTarget(v.config).parts.joined(separator: "\u{1F}"),
                    awaitingFileOK: v.awaitingFileOK
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
                    : nil,
                needsAppName: state == .needsApp ? variants.compactMap(\.hostApp).first?.name : nil,
                sessionDrops: variants.contains { $0.config.source.label == AgentRegistry.claudeCodeLabel }
                    ? sessionDrops[key] ?? [] : []
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
            if staysHidden(group, isHidden: isHidden(group.name, in: hidden)) { hiddenGroups.append(group) }
            else { visible.append(group) }
        }
        return (visible, hiddenGroups)
    }

    /// A hidden server leaves the panel, except while it is broken: Settings
    /// promises mcpock "tells you if they break", and the red icon needs a row
    /// that explains it (Argon 2026-10-16 #5). Shared with the status file.
    nonisolated static func staysHidden(_ group: ServerGroup, isHidden: Bool) -> Bool {
        isHidden && group.state != .broken
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
        guard let interval = AppPreferences.loadProbeInterval(from: defaults).seconds else { return }
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
    /// Since 1.12 (9180) the round reads the known files only, no folder walk.
    func timerTick() async {
        // A full cycle that was in flight already covered this round; reading
        // the configs while it ran let its old result overwrite a fixed server
        // (Argon 2026-10-16 #8).
        if await awaitInFlightCycle() { return }
        await reloadThenProbe(force: false, fullScan: false)
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

        let probe = self.probeWithHostApp()
        await withTaskGroup(of: ([String], (ProbeResult, HostLookup)).self) { group in
            // At most `maxConcurrentProbes` at once, the next one starting as
            // each ends: a big setup used to start every server at login in
            // the same second (review 2026-10-20, 7d92).
            var waiting = Array(specGroups.values)
            func next() -> (@Sendable () async -> ([String], (ProbeResult, HostLookup)))? {
                guard !waiting.isEmpty else { return nil }
                let instances = waiting.removeFirst()
                let config = instances[0].config
                // Fetch tools if ANY instance needs them (a timer round re-fetches
                // only on a transition to healthy), and always on Refresh
                // (`force`), so a server's new tools show (review, 2026-10-14).
                let fetchTools = force || instances.contains { $0.state != .healthy }
                let ids = instances.map(\.id)
                return { (ids, await probe(config, fetchTools)) }
            }
            for _ in 0..<Self.maxConcurrentProbes {
                guard let task = next() else { break }
                group.addTask(operation: task)
            }
            let specs = Dictionary(due.map { ($0.id, Self.probeSpec($0.config)) }, uniquingKeysWith: { first, _ in first })
            // Apply each result the moment it arrives, so the header count and the
            // dots update live during the cycle instead of freezing until the
            // slowest probe (a full cycle takes ~10-25s on a large setup) finishes.
            for await (ids, (result, lookup)) in group {
                if Task.isCancelled { break }
                if let task = next() { group.addTask(operation: task) }
                for id in ids {
                    // A result for a config that changed meanwhile describes the
                    // old setup: never apply it (Argon 2026-10-16 #8).
                    guard let index = servers.firstIndex(where: { $0.id == id }),
                          Self.probeSpec(servers[index].config) == specs[id] else { continue }
                    apply(result, at: index, lookup: lookup)
                }
            }
        }
        if !Task.isCancelled { hasCompletedFirstPass = true }
        await refreshSessionDrops()
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
    /// How many servers a cycle checks at the same time.
    nonisolated static let maxConcurrentProbes = 6

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
        if snapshot.awaitingFileOK { return false }
        return force || isDue(snapshot, now: now)
    }

    /// Failure smoothing. A single transient failure (e.g. a slow cold-start timeout) shows
    /// amber `degraded` rather than red, so a healthy/starting server doesn't blink red on one
    /// hiccup. A definitive failure (spawn error, non-zero exit) — or a 2nd consecutive
    /// transient failure — shows red `broken`. An **attention** failure (auth: HTTP 401/403)
    /// is stable amber `degraded` that never turns red — retrying won't help, but nothing is
    /// crashing, so it reads as "needs you," not "broken"; it backs off like any repeated
    /// failure. Any success returns to `healthy`.
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
        // Auth / "needs attention": stable amber, never red. The counter still
        // climbs, so the probe backs off like any repeated failure: it used to
        // be held at 0 and the server (and its headersHelper) was hit every
        // minute forever (Argon 2026-10-17 #7).
        if needsAttention {
            return (.degraded, priorFailures + 1)
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
        if config.transport == .stdio && (config.command ?? "").isEmpty {
            return ProbeResult(state: .broken, failureReason: noEndpointReason, tools: nil, needsAttention: true)
        }
        // `${VAR}` and friends filled in as the agent would; one that can't be
        // is not started with the literal text (review 2026-10-20, 0d87). Amber
        // "not checked", never red, backs off like a sign-in.
        let expanded = ConfigVariables.expand(config)
        guard expanded.unresolved.isEmpty else {
            return ProbeResult(state: .broken, failureReason: ConfigVariables.reason(for: expanded.unresolved),
                               tools: nil, needsAttention: true)
        }
        let config = expanded.config
        switch config.transport {
        case .stdio:
            return await StdioProbe.probe(config: config, fetchTools: fetchTools)
        case .http, .sse:
            return agentSignIn(await HTTPProbe.probe(config: config, fetchTools: fetchTools), config: config)
        }
    }

    /// A config entry with neither a command nor a url (r3 e412).
    nonisolated static let noEndpointReason = "Not checked: no command or url in the config"

    /// Starts every reason for a server whose sign-in lives in its agent.
    nonisolated static let agentSignInPrefix = "Signed in by the agent"

    /// A 401 or 403 from a server whose config carries no headers and no
    /// helper: the agent signed in with OAuth and holds the token, so mcpock
    /// can't, and "Needs sign-in" was wrong forever (r3 5f42). Amber stays
    /// for a server with headers: then the token itself is wrong.
    nonisolated static func agentSignIn(_ result: ProbeResult, config: ServerConfig) -> ProbeResult {
        guard config.headers.isEmpty, config.headersHelper == nil,
              let reason = result.failureReason, reason.hasPrefix("Needs authentication") else { return result }
        let code = reason.replacingOccurrences(of: "Needs authentication (", with: "")
        var calm = ProbeResult(
            state: result.state,
            failureReason: agentSignInPrefix + ": the agent holds this server's sign-in, so mcpock can't check it (" + code,
            tools: result.tools, transientFailure: result.transientFailure, needsAttention: result.needsAttention)
        calm.slowStartSeconds = result.slowStartSeconds
        return calm
    }
}
