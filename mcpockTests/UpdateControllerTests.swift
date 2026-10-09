import XCTest
@testable import mcpock

/// In-app updates (round 10). `UpdateController` itself is deliberately not
/// exercised here: constructing one for real starts Sparkle's own updater —
/// exactly what `MCPockApp.init`'s `isHostingTests` guard exists to prevent a
/// test run from doing (see `ARCHITECTURE.md` §6, rule 26). What's testable
/// without touching the network or Sparkle's own state is the static
/// configuration it depends on: the Info.plist keys Sparkle reads, and the
/// wording the Settings and menu UI show.
final class UpdateControllerTests: XCTestCase {

    /// The test host is `mcpock.app` itself (`project.yml`'s `TEST_HOST`), so
    /// `Bundle.main` here is the real app bundle with the real Info.plist —
    /// the same file `mcpock/Info.plist` compiles into.
    private var info: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
    }

    func testFeedURLPointsAtMcpockDotCom() {
        XCTAssertEqual(info["SUFeedURL"] as? String, "https://mcpock.com/appcast.xml",
                       "the repo is private, so the feed can't live on a GitHub release — see HANDOFF.md")
    }

    /// An EdDSA public key is 32 raw bytes, base64-encoded: 44 characters,
    /// the last one padding ("="). This never asserts the key's *value* —
    /// that's public but still not something to pin in a test, since the
    /// maintainer could rotate it — only that Info.plist carries one in the right shape.
    func testPublicKeyIsPresentAndEdDSAShaped() {
        let key = info["SUPublicEDKey"] as? String
        XCTAssertNotNil(key, "Sparkle refuses to install any update without this")
        XCTAssertEqual(key?.count, 44, "EdDSA public keys are 32 bytes, base64-encoded")
        XCTAssertTrue(key?.hasSuffix("=") == true)
    }

    // MARK: - Wording (pinned, like ShortReason / CardText / MenuText)

    func testCheckForUpdatesWording() {
        XCTAssertEqual(SettingsAboutPane.checkForUpdatesTitle, "Check for Updates\u{2026}")
    }

    func testAutomaticUpdatesToggleWording() {
        XCTAssertEqual(SettingsAboutPane.automaticUpdatesTitle, "Automatically check for updates")
    }
}
