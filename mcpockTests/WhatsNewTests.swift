import XCTest
@testable import mcpock

/// The What's new sheet (1.10.7): shown once after an update, never on a first install.
final class WhatsNewTests: XCTestCase {
    func testParsesHeadingsAndBulletsAndSkipsTheInstallLine() {
        let notes = """
        mcpock 1.10.7, 2026-10-17. For macOS 26 or newer on Apple Silicon.

        New in 1.10.7
        - **Needs Wake open:** a calm grey dash.

        Fixes in 1.10.7
        - **Safer scan.**
        """
        let lines = WhatsNew.parse(notes)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.first, .heading("New in 1.10.7"))
        if case .bullet(let text) = lines[1] {
            XCTAssertEqual(String(text.characters), "Needs Wake open: a calm grey dash.")
        } else {
            XCTFail("expected a bullet")
        }
    }

    /// The tests run inside the app, so its own version and bundled notes are here.
    func testThisVersionShipsItsNotes() throws {
        let lines = try XCTUnwrap(WhatsNew.notes(for: WhatsNew.currentVersion), "docs/release-notes/<version>.md is bundled")
        XCTAssertTrue(lines.contains(.heading("New in \(WhatsNew.currentVersion)")) ||
                      lines.contains(.heading("Fixes in \(WhatsNew.currentVersion)")))
        XCTAssertFalse(lines.contains { if case .heading(let t) = $0 { return t.hasPrefix("mcpock ") } else { return false } },
                       "the install line on top is left out")
    }

    func testShownOnceAfterAnUpdateNeverOnFirstInstall() throws {
        let suite = "WhatsNewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.retireSuite(named: suite) }

        XCTAssertFalse(WhatsNew.shouldShow(defaults: defaults), "first install: nothing")
        XCTAssertFalse(WhatsNew.shouldShow(defaults: defaults), "same version again: nothing")
        defaults.set("1.10.6", forKey: WhatsNew.lastSeenKey)
        XCTAssertTrue(WhatsNew.shouldShow(defaults: defaults), "after an update")
        WhatsNew.markSeen(defaults: defaults)
        XCTAssertFalse(WhatsNew.shouldShow(defaults: defaults), "once")
    }

    @MainActor
    func testAnUpdateFromBeforeWhatsNewShowsIt() throws {
        let suite = "WhatsNewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.retireSuite(named: suite) }

        WhatsNewLauncher.markEarlierRun(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: WhatsNew.lastSeenKey), "a first install stays a first install")

        defaults.set(true, forKey: SettingsMigration.migratedFlagKey)  // mcpock 1.6.0+ ran here
        WhatsNewLauncher.markEarlierRun(defaults: defaults)
        XCTAssertTrue(WhatsNew.shouldShow(defaults: defaults), "1.10.6 -> 1.10.7 shows the notes")

        WhatsNew.markSeen(defaults: defaults)
        WhatsNewLauncher.markEarlierRun(defaults: defaults)
        XCTAssertFalse(WhatsNew.shouldShow(defaults: defaults), "a seen version is never reset")
    }
}
