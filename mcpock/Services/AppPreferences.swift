import Foundation

/// Persisted user preferences (UserDefaults via AppStorage keys).
enum AppPreferences {
    /// Where the app keeps its own settings: `.standard`, except in demo mode
    /// (`DemoData`), which gets a throwaway suite, so a demo run never reads
    /// or writes the user's real settings, theme included (review,
    /// 2026-10-14). Decided once, on first use, from the launch arguments.
    static let store: UserDefaults = DemoData.isActiveForApp() ? DemoData.makeThrowawayDefaults() : .standard

    static let themeKey = "appTheme"
    static let defaultTheme = AppTheme.system

    /// Server names the user has hidden from the menu list, keyed by
    /// `HealthMonitor.normalizedName` so a hidden name survives case/separator variants.
    static let hiddenServersKey = "hiddenServers"

    static func loadHiddenServers(from defaults: UserDefaults = store) -> Set<String> {
        Set(defaults.stringArray(forKey: hiddenServersKey) ?? [])
    }

    static func saveHiddenServers(_ names: Set<String>, to defaults: UserDefaults = store) {
        defaults.set(names.sorted(), forKey: hiddenServersKey)
    }

    /// Server names the user paused probing for (same normalized keying as
    /// `hiddenServers`). A paused server is never launched — the escape hatch for
    /// servers whose spawn has side effects (e.g. OAuth login pages).
    static let pausedServersKey = "pausedServers"

    static func loadPausedServers(from defaults: UserDefaults = store) -> Set<String> {
        Set(defaults.stringArray(forKey: pausedServersKey) ?? [])
    }

    static func savePausedServers(_ names: Set<String>, to defaults: UserDefaults = store) {
        defaults.set(names.sorted(), forKey: pausedServersKey)
    }

    /// Config files found only by the scan (no known agent reads them) whose
    /// servers she allowed mcpock to start, by canonical path (review
    /// 2026-10-20, 5ae6). `scanFilesSeeded`: set once; an update from an older
    /// version allows every such file already there, so nothing she had
    /// stops being checked.
    static let allowedScanFilesKey = "allowedScanFiles"
    static let scanFilesSeededKey = "allowedScanFilesSeeded"

    static func loadAllowedScanFiles(from defaults: UserDefaults = store) -> Set<String> {
        Set(defaults.stringArray(forKey: allowedScanFilesKey) ?? [])
    }

    static func saveAllowedScanFiles(_ paths: Set<String>, to defaults: UserDefaults = store) {
        defaults.set(paths.sorted(), forKey: allowedScanFilesKey)
    }

    /// What each allowed file starts, as she allowed it (a hash, path ->
    /// fingerprint): a later edit or git pull that changes a command pauses
    /// the file again (r3 e46f).
    static let allowedScanFingerprintsKey = "allowedScanFingerprints"
    /// Set once the prints saved before 1.13 were moved to the kind that also
    /// covers env values and header names (review 2026-10-30, 837b).
    static let scanFingerprintsUpgradedKey = "allowedScanFingerprintsUpgraded"

    static func loadAllowedScanFingerprints(from defaults: UserDefaults = store) -> [String: String] {
        defaults.dictionary(forKey: allowedScanFingerprintsKey) as? [String: String] ?? [:]
    }

    static func saveAllowedScanFingerprints(_ prints: [String: String], to defaults: UserDefaults = store) {
        defaults.set(prints, forKey: allowedScanFingerprintsKey)
    }

    /// Server names the user pinned to the top of the panel (v1.5), same
    /// normalized keying as `hiddenServers`. Pinned and hidden never overlap:
    /// `HealthMonitor.setPinned` unhides whatever it pins.
    static let pinnedServersKey = "pinnedServers"

    static func loadPinnedServers(from defaults: UserDefaults = store) -> Set<String> {
        Set(defaults.stringArray(forKey: pinnedServersKey) ?? [])
    }

    static func savePinnedServers(_ names: Set<String>, to defaults: UserDefaults = store) {
        defaults.set(names.sorted(), forKey: pinnedServersKey)
    }

    /// "Mark as intended" (1.5.2; "Different on purpose" before 1.5.3): servers
    /// whose agents are set up differently by design (a server like `feed`: each agent has its own key and
    /// launcher script). Normalized name -> what the user acknowledged, stored as one
    /// JSON object string. Since 1.9.0 each entry is "<fingerprint>:<agent label>"
    /// (`Differs.acknowledgement`), so only an agent whose own setup is new or
    /// changed brings the note back; a mark saved before 1.9.0 holds bare
    /// fingerprints and still reads (`Differs.split`).
    static let differsAcknowledgedKey = "differsAcknowledged"

    static func loadDiffersAcknowledged(from defaults: UserDefaults = store) -> [String: [String]] {
        switch defaults.object(forKey: differsAcknowledgedKey) {
        case let text as String:
            // The stored form, and what a `-differsAcknowledged '{"feed":[…]}'`
            // launch argument arrives as.
            guard let data = text.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
            else { return [:] }
            return decoded.mapValues { $0.sorted() }
        case let dictionary as [String: Any]:
            // A launch argument written as an old-style plist dictionary.
            return dictionary.compactMapValues { ($0 as? [String])?.sorted() }
        default:
            return [:]
        }
    }

    static func saveDiffersAcknowledged(_ acknowledged: [String: [String]], to defaults: UserDefaults = store) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(acknowledged.mapValues { $0.sorted() }),
              let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: differsAcknowledgedKey)
    }

    /// The panel's attention toggle (`PanelFilter.rawValue`), remembered between
    /// opens and launches (v1.5).
    static let panelFilterKey = "panelFilter"

    /// Local port -> the `.app` seen serving it (2026-10-16).
    static let hostAppPortsKey = "hostAppPorts"

    static func loadHostAppPorts(from defaults: UserDefaults = store) -> [Int: String] {
        let raw: [String: String] = decodeJSON(defaults.string(forKey: hostAppPortsKey)) ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    static func saveHostAppPorts(_ ports: [Int: String], to defaults: UserDefaults = store) {
        defaults.set(encodeJSON(Dictionary(uniqueKeysWithValues: ports.map { (String($0.key), $0.value) })),
                     forKey: hostAppPortsKey)
    }

    private static func decodeJSON<T: Decodable>(_ text: String?) -> T? {
        guard let data = text?.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Seconds between automatic probe cycles; `0` means manual only (no timer —
    /// probing happens via "Refresh now" / per-server refresh). Stored as seconds
    /// so future intervals need no migration.
    static let probeIntervalKey = "probeInterval"

    static func loadProbeInterval(from defaults: UserDefaults = store) -> ProbeInterval {
        guard defaults.object(forKey: probeIntervalKey) != nil else { return .default }
        return ProbeInterval.fromStored(defaults.integer(forKey: probeIntervalKey))
    }

    static func saveProbeInterval(_ interval: ProbeInterval, to defaults: UserDefaults = store) {
        defaults.set(interval.rawValue, forKey: probeIntervalKey)
    }

    /// Settings > General "Usage counts" (1.7; one switch since 1.13): how many
    /// days of MCP calls per server `UsageStore` counts, next to a server's name
    /// when its agent is open in the Agents tab. Off hides the numbers and stops
    /// reading entirely. New installs start off; 30 days is what the switch turns
    /// on, and an earlier install keeps the 7 days or All time it chose.
    static let usageWindowKey = "usageWindow"

    /// Settings > General "Open with ⌃⌥M" (1.10): the shortcut that opens
    /// and closes the panel from any app (`GlobalHotKey`). On by default.
    static let openPanelHotKeyKey = "openPanelHotKey"
    static let defaultOpenPanelHotKey = true

    static func loadOpenPanelHotKey(from defaults: UserDefaults = store) -> Bool {
        defaults.object(forKey: openPanelHotKeyKey) as? Bool ?? defaultOpenPanelHotKey
    }
    static let defaultUsageWindow = UsageWindow.default

    static func loadUsageWindow(from defaults: UserDefaults = store) -> UsageWindow {
        guard defaults.object(forKey: usageWindowKey) != nil else { return defaultUsageWindow }
        return UsageWindow(rawValue: defaults.integer(forKey: usageWindowKey)) ?? defaultUsageWindow
    }

    static func saveUsageWindow(_ window: UsageWindow, to defaults: UserDefaults = store) {
        defaults.set(window.rawValue, forKey: usageWindowKey)
    }

    /// The default changed from 30 days to off in 1.13, and an earlier install
    /// that never touched the choice has nothing saved: it keeps counting. Run
    /// once at launch, before anything reads it.
    static func keepUsageForEarlierInstall(ranBefore: Bool, defaults: UserDefaults = store) {
        guard ranBefore, defaults.object(forKey: usageWindowKey) == nil else { return }
        saveUsageWindow(.thirtyDays, to: defaults)
    }
}

/// How far back `UsageStore` counts. The switch in Settings is off or 30 days;
/// 7 days and All time remain for an install that chose them before 1.13.
enum UsageWindow: Int {
    case off = 0
    case sevenDays = 7
    case thirtyDays = 30
    case allTime = -1

    /// Off, so a first launch has no note about reading chat history (1.13).
    static let `default` = UsageWindow.off

    /// Days to count back, inclusive of today; nil = no limit (All time, and
    /// Off, which is never queried — the view hides the count entirely).
    var days: Int? {
        switch self {
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .off, .allTime: return nil
        }
    }
}

/// How often the health monitor re-probes on its own. Raw value = seconds
/// (0 = manual only), so the preference stays readable in `defaults read` and
/// the values saved before round 7 (60, 300, 900, 0) still mean the same.
///
/// Case order is the Settings slider's order, left to right: shortest
/// interval first, Manual last.
enum ProbeInterval: Int, CaseIterable, Identifiable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600
    case fourHours = 14400
    case manual = 0

    /// 15 minutes since 1.12 (9180; 1 min before): every round starts every
    /// server. Only a saved choice keeps its own interval.
    static let `default` = ProbeInterval.fifteenMinutes

    var id: Int { rawValue }

    /// Stop label, also the value shown beside the slider (round 9 dropped
    /// "Every …": one short word never wraps): "1 min", "1 h", "Manual".
    var title: String {
        switch self {
        case .oneMinute: return "1 min"
        case .fiveMinutes: return "5 min"
        case .fifteenMinutes: return "15 min"
        case .thirtyMinutes: return "30 min"
        case .oneHour: return "1 h"
        case .fourHours: return "4 h"
        case .manual: return "Manual"
        }
    }

    /// `nil` = no automatic timer.
    var seconds: TimeInterval? {
        rawValue == 0 ? nil : TimeInterval(rawValue)
    }

    /// Position on the slider (0 = 1 min … 6 = Manual).
    var sliderIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// The stop nearest a slider position; out-of-range positions clamp.
    static func nearest(toSliderPosition position: Double) -> ProbeInterval {
        let index = Int(position.rounded())
        return allCases[min(max(index, 0), allCases.count - 1)]
    }

    /// Keyboard / VoiceOver: a small step from `current` moves one whole stop
    /// that way; a jump of a stop or more (Home, End) lands on the nearest.
    static func stepped(from current: ProbeInterval, toward position: Double) -> ProbeInterval {
        let index = Double(current.sliderIndex)
        let delta = position - index
        if abs(delta) >= 1 { return nearest(toSliderPosition: position) }
        if delta > 0 { return nearest(toSliderPosition: index + 1) }
        if delta < 0 { return nearest(toSliderPosition: index - 1) }
        return current
    }

    /// Knob positions for the snap after a drag: an ease-out from `start` to
    /// `end` in `count` frames (~16 ms each), ending exactly on `end`.
    static func snapFrames(from start: Double, to end: Double, count: Int = 9) -> [Double] {
        guard count > 0, start != end else { return [end] }
        return (1...count).map { frame in
            let t = Double(frame) / Double(count)
            let eased = 1 - pow(1 - t, 3)
            return frame == count ? end : start + (end - start) * eased
        }
    }

    /// A stored value in seconds, as it may have been written by any version:
    /// a known stop as is, 0 as Manual, anything else snapped to the nearest
    /// automatic stop (never silently to Manual).
    static func fromStored(_ seconds: Int) -> ProbeInterval {
        if let exact = ProbeInterval(rawValue: seconds) { return exact }
        guard seconds > 0 else { return .default }
        return allCases.filter { $0 != .manual }
            .min { abs($0.rawValue - seconds) < abs($1.rawValue - seconds) } ?? .default
    }
}

/// The rename to mcpock (1.6.0): a one-time copy of every known preference
/// from the old app's persistent domain, so the user's pins, hidden/paused
/// servers, marked-as-intended notes, theme, check interval and panel filter
/// come over on their own. Never touches or deletes the
/// old domain — only the personal-ops-manual-style "read, never write" rule
/// applies here too.
enum SettingsMigration {
    /// Set once the copy has run (whether or not there was anything to copy),
    /// so a launch after the first never looks again.
    static let migratedFlagKey = "migratedFromMCPBAR"

    /// Every `AppPreferences` key worth carrying over. Kept as one list so a
    /// new preference is a one-line addition here, not a second migration path.
    static let knownKeys: [String] = [
        AppPreferences.themeKey,
        AppPreferences.hiddenServersKey,
        AppPreferences.pausedServersKey,
        AppPreferences.pinnedServersKey,
        AppPreferences.differsAcknowledgedKey,
        AppPreferences.panelFilterKey,
        AppPreferences.probeIntervalKey,
        AppPreferences.usageWindowKey,
    ]

    /// Copies `knownKeys` from `oldDomain` (the old app's bundle id) into
    /// `newDefaults`, but only the first time: if `newDefaults` already has
    /// the migrated flag, or already holds any of `knownKeys` (the new app
    /// has been used already), nothing is copied — the flag is still set so
    /// the next launch skips the check entirely. `oldDomain` and `newDefaults`
    /// are parameters so tests can point this at throwaway suite names
    /// instead of the real `com.mcpbar.app` / `com.mcpock.app` domains.
    static func migrateIfNeeded(
        oldDomain: String = "com.mcpbar.app",
        newDefaults: UserDefaults = .standard
    ) {
        guard newDefaults.object(forKey: migratedFlagKey) == nil else { return }
        defer { newDefaults.set(true, forKey: migratedFlagKey) }
        guard !knownKeys.contains(where: { newDefaults.object(forKey: $0) != nil }) else { return }
        guard let old = UserDefaults(suiteName: oldDomain) else { return }
        for key in knownKeys {
            guard let value = old.object(forKey: key) else { continue }
            newDefaults.set(value, forKey: key)
        }
    }
}

/// Test calls lived only in the 1.10.7 test builds (28-34) and were dropped
/// before the release (2026-10-17). Their saved rows (some switched on, with
/// write tools) and the folder agents left requests in must not outlive them:
/// the first launch removes whatever is still there, then sets a flag so no
/// later launch looks again (review 2026-10-20, 2dc6).
enum TestCallLeftovers {
    static let keys = ["testCallsEnabled", "testCallSettings", "testCallRecords", "testCallAgentLog"]
    static let folderName = "test-requests"
    /// Set once the clean-up has run (whether or not anything was there).
    static let doneFlagKey = "testCallLeftoversRemoved"

    static func remove(
        from defaults: UserDefaults = .standard,
        directory: URL = MCPockStatus.defaultDirectory()
    ) {
        guard defaults.object(forKey: doneFlagKey) == nil else { return }
        defer { defaults.set(true, forKey: doneFlagKey) }
        for key in keys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
        let folder = directory.appendingPathComponent(folderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
