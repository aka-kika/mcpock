import XCTest
@testable import mcpock

/// Pinned servers sit at the top of the panel. A server is pinned, shown or
/// hidden, one of the three: pinning a hidden server unhides it, hiding a pinned
/// one unpins it. Each test uses its own defaults suite, because the test host is
/// the app and `.standard` would be the real preferences.
@MainActor
final class PinnedServerTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "mcpock.tests.pinned.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.retireSuite(named: suite)
        super.tearDown()
    }

    func testPinnedServersRoundTrip() {
        AppPreferences.savePinnedServers(["reedmd", "wigolo"], to: defaults)
        XCTAssertEqual(AppPreferences.loadPinnedServers(from: defaults), ["reedmd", "wigolo"])
        XCTAssertEqual(defaults.stringArray(forKey: AppPreferences.pinnedServersKey), ["reedmd", "wigolo"],
                       "stored as a plain sorted string array, like hidden")
    }

    func testPinAndUnpinPersistOnTheNormalizedName() {
        let monitor = HealthMonitor(defaults: defaults)
        monitor.setPinned(true, name: "Chrome DevTools")
        XCTAssertTrue(monitor.isPinned("chrome-devtools"))
        XCTAssertEqual(monitor.pinnedNames, ["chromedevtools"])
        XCTAssertEqual(AppPreferences.loadPinnedServers(from: defaults), ["chromedevtools"])
        XCTAssertTrue(HealthMonitor(defaults: defaults).isPinned("Chrome DevTools"), "survives a relaunch")

        monitor.setPinned(false, name: "chrome-devtools")
        XCTAssertFalse(monitor.isPinned("Chrome DevTools"))
        XCTAssertTrue(AppPreferences.loadPinnedServers(from: defaults).isEmpty)
    }

    func testPinningAHiddenServerUnhidesIt() {
        let monitor = HealthMonitor(defaults: defaults)
        monitor.setHidden(true, name: "reed-md")
        XCTAssertTrue(monitor.isHidden("reed-md"))

        monitor.setPinned(true, name: "reed-md")
        XCTAssertTrue(monitor.isPinned("reed-md"))
        XCTAssertFalse(monitor.isHidden("reed-md"))
        XCTAssertFalse(AppPreferences.loadHiddenServers(from: defaults).contains("reedmd"))
    }

    func testHidingAPinnedServerUnpinsIt() {
        let monitor = HealthMonitor(defaults: defaults)
        monitor.setPinned(true, name: "reed-md")
        monitor.setHidden(true, name: "reed-md")
        XCTAssertFalse(monitor.isPinned("reed-md"))
        XCTAssertTrue(monitor.isHidden("reed-md"))
        XCTAssertTrue(AppPreferences.loadPinnedServers(from: defaults).isEmpty)
    }
}
