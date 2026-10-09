import XCTest
@testable import mcpock

final class AppearanceTests: XCTestCase {
    /// Regression: stamping the status-item window with the user's theme froze the
    /// menu-bar icon in the wrong color (black icon on a dark menu bar with the
    /// Light theme, from the first panel open). The icon must follow the system,
    /// so the status-bar window is never stamped; mcpock's own windows are.
    func testStatusBarWindowIsNeverStamped() {
        XCTAssertFalse(AppearanceApplier.shouldStamp(windowClassName: "NSStatusBarWindow"))
        XCTAssertTrue(AppearanceApplier.shouldStamp(windowClassName: "NSWindow"))
        XCTAssertTrue(AppearanceApplier.shouldStamp(windowClassName: "NSPanel"))
        // SwiftUI's MenuBarExtra panel host — this one SHOULD get the theme.
        XCTAssertTrue(AppearanceApplier.shouldStamp(windowClassName: "NSMenuWindowManagerWindow"))
    }
}
