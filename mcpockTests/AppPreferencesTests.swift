import XCTest
@testable import mcpock

final class AppPreferencesTests: XCTestCase {
    func testHiddenServersRoundTrip() {
        let suite = "AppPreferencesTests.hidden"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.retireSuite(named: suite) }

        XCTAssertEqual(AppPreferences.loadHiddenServers(from: defaults), [],
                       "empty when nothing saved")

        AppPreferences.saveHiddenServers(["pieces", "eventkit"], to: defaults)
        XCTAssertEqual(AppPreferences.loadHiddenServers(from: defaults), ["pieces", "eventkit"])

        AppPreferences.saveHiddenServers([], to: defaults)
        XCTAssertEqual(AppPreferences.loadHiddenServers(from: defaults), [],
                       "clearing removes all")
    }

    func testPausedServersRoundTrip() {
        let suite = "AppPreferencesTests.paused"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.retireSuite(named: suite) }

        XCTAssertEqual(AppPreferences.loadPausedServers(from: defaults), [],
                       "empty when nothing saved")

        AppPreferences.savePausedServers(["xmcp"], to: defaults)
        XCTAssertEqual(AppPreferences.loadPausedServers(from: defaults), ["xmcp"])

        AppPreferences.savePausedServers([], to: defaults)
        XCTAssertEqual(AppPreferences.loadPausedServers(from: defaults), [])
    }

    /// Round 6: "Hide scroll bars" is on until she turns it off.
    func testHideScrollBarsDefaultsToOn() {
        // The @AppStorage default every reader uses when nothing is saved.
        XCTAssertTrue(AppPreferences.defaultHideScrollBars, "on when nothing saved")
        XCTAssertEqual(PanelScrollIndicators.visibility(hide: true), .never,
                       ".hidden still shows bars with a mouse connected")
        XCTAssertEqual(PanelScrollIndicators.visibility(hide: false), .automatic)
    }

    func testTestCallLeftoversAreRemoved() throws {
        let suite = "AppPreferencesTests.testCallLeftovers"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.retireSuite(named: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestCallLeftovers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("test-requests", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("a.request.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("usage.json"))
        for key in TestCallLeftovers.keys { defaults.set("x", forKey: key) }
        defaults.set(["feed"], forKey: AppPreferences.hiddenServersKey)

        TestCallLeftovers.remove(from: defaults, directory: directory)

        for key in TestCallLeftovers.keys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "request folder gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("usage.json").path),
                      "the rest of the folder stays")
        XCTAssertEqual(AppPreferences.loadHiddenServers(from: defaults), ["feed"], "other settings stay")

        TestCallLeftovers.remove(from: defaults, directory: directory)  // nothing left: a no-op
    }

    /// The clean-up runs on the first launch only (review 2026-10-20, 2dc6):
    /// anything that shows up afterwards is left alone.
    func testTestCallLeftoversRunOnlyOnce() throws {
        let suite = "AppPreferencesTests.testCallLeftoversOnce"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.retireSuite(named: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestCallLeftoversOnce-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("test-requests", isDirectory: true)

        TestCallLeftovers.remove(from: defaults, directory: directory)  // nothing there: still marks done
        XCTAssertTrue(defaults.bool(forKey: TestCallLeftovers.doneFlagKey))

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for key in TestCallLeftovers.keys { defaults.set("x", forKey: key) }

        TestCallLeftovers.remove(from: defaults, directory: directory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "second launch leaves the folder")
        for key in TestCallLeftovers.keys { XCTAssertNotNil(defaults.object(forKey: key), key) }
    }
}

/// 1.6.0 rename: the one-time copy of every known preference from the old
/// `com.mcpbar.app` domain into the new one. Both domains are throwaway
/// suite names here, never the real bundle ids, and never `.standard`.
final class SettingsMigrationTests: XCTestCase {
    private var oldSuite: String!
    private var newSuite: String!
    private var oldDefaults: UserDefaults!
    private var newDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let id = UUID().uuidString
        oldSuite = "mcpock.tests.migration-old.\(id)"
        newSuite = "mcpock.tests.migration-new.\(id)"
        oldDefaults = UserDefaults(suiteName: oldSuite)
        newDefaults = UserDefaults(suiteName: newSuite)
    }

    override func tearDown() {
        oldDefaults.retireSuite(named: oldSuite)
        newDefaults.retireSuite(named: newSuite)
        super.tearDown()
    }

    /// A fresh new domain (no keys, no flag) copies every known key from the old one.
    func testCopiesWhenNewDomainIsEmpty() {
        AppPreferences.saveHiddenServers(["pieces"], to: oldDefaults)
        AppPreferences.savePinnedServers(["wigolo"], to: oldDefaults)
        oldDefaults.set(AppTheme.dark.rawValue, forKey: AppPreferences.themeKey)
        oldDefaults.set(false, forKey: AppPreferences.hideScrollBarsKey)

        SettingsMigration.migrateIfNeeded(oldDomain: oldSuite, newDefaults: newDefaults)

        XCTAssertEqual(AppPreferences.loadHiddenServers(from: newDefaults), ["pieces"])
        XCTAssertEqual(AppPreferences.loadPinnedServers(from: newDefaults), ["wigolo"])
        XCTAssertEqual(newDefaults.string(forKey: AppPreferences.themeKey), AppTheme.dark.rawValue)
        XCTAssertFalse(newDefaults.bool(forKey: AppPreferences.hideScrollBarsKey))
        XCTAssertTrue(newDefaults.bool(forKey: SettingsMigration.migratedFlagKey), "flag set once it has run")
        // The old domain is never touched.
        XCTAssertEqual(AppPreferences.loadHiddenServers(from: oldDefaults), ["pieces"])
    }

    /// Once the flag is set, a second call never copies again, even if the
    /// old domain changes in between (configs moving, a stale backup, etc.).
    func testSkipsWhenAlreadyMigrated() {
        newDefaults.set(true, forKey: SettingsMigration.migratedFlagKey)
        AppPreferences.saveHiddenServers(["pieces"], to: oldDefaults)

        SettingsMigration.migrateIfNeeded(oldDomain: oldSuite, newDefaults: newDefaults)

        XCTAssertEqual(AppPreferences.loadHiddenServers(from: newDefaults), [],
                       "already migrated: nothing new comes over")
    }

    /// A new domain that already has one of the app's keys (a user used the
    /// new app a little before the old one was gone) is left alone, and the
    /// flag is still set so future launches stop checking.
    func testSkipsWhenNewDomainAlreadyHasKeys() {
        AppPreferences.saveHiddenServers(["reedmd"], to: newDefaults)
        AppPreferences.saveHiddenServers(["pieces"], to: oldDefaults)

        SettingsMigration.migrateIfNeeded(oldDomain: oldSuite, newDefaults: newDefaults)

        XCTAssertEqual(AppPreferences.loadHiddenServers(from: newDefaults), ["reedmd"],
                       "the new app's own choice is never overwritten")
        XCTAssertTrue(newDefaults.bool(forKey: SettingsMigration.migratedFlagKey))
    }

    /// Runs once: calling it again after a successful copy changes nothing,
    /// even if the old domain gains new values afterward.
    func testRunsOnlyOnce() {
        AppPreferences.saveHiddenServers(["pieces"], to: oldDefaults)
        SettingsMigration.migrateIfNeeded(oldDomain: oldSuite, newDefaults: newDefaults)
        XCTAssertEqual(AppPreferences.loadHiddenServers(from: newDefaults), ["pieces"])

        AppPreferences.saveHiddenServers(["pieces", "eventkit"], to: oldDefaults)
        SettingsMigration.migrateIfNeeded(oldDomain: oldSuite, newDefaults: newDefaults)
        XCTAssertEqual(AppPreferences.loadHiddenServers(from: newDefaults), ["pieces"],
                       "a later call is a no-op; the flag already stopped it")
    }

    /// No old domain at all (a from-scratch install, never had MCPBAR): the
    /// migration is a harmless no-op and still sets the flag.
    func testNoOldDomainIsAHarmlessNoOp() {
        let missingSuite = "mcpock.tests.migration-missing.\(UUID().uuidString)"
        SettingsMigration.migrateIfNeeded(oldDomain: missingSuite, newDefaults: newDefaults)
        XCTAssertEqual(AppPreferences.loadHiddenServers(from: newDefaults), [])
        XCTAssertTrue(newDefaults.bool(forKey: SettingsMigration.migratedFlagKey))
    }
}
