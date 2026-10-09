import SwiftUI
import XCTest
@testable import mcpock

/// 1.8: the fourth Appearance theme, Glass (Apple's own Liquid Glass). Its
/// raw value is what `AppPreferences` persists, so that stays pinned; the
/// rest of these check it behaves like System for light/dark (it isn't a
/// light/dark choice, glass is a surface layered on top) while its colors
/// still keep the chrome bars from painting an opaque fill over the glass.
final class ThemeTests: XCTestCase {
    /// The picker's order (`AppTheme.allCases`, read left to right in
    /// `SettingsGeneralPane`'s segmented control): Glass is added after the
    /// first three, not slotted between them, so an existing saved index
    /// keeps meaning what it meant before.
    func testPickerOrderAddsGlassLast() {
        XCTAssertEqual(AppTheme.allCases, [.system, .dark, .light, .glass])
    }

    /// The stored raw value is what travels through `AppPreferences` and the
    /// 1.6.0 settings migration — it must never change once saved.
    func testGlassRawValueIsStable() {
        XCTAssertEqual(AppTheme.glass.rawValue, "glass")
        XCTAssertEqual(AppTheme(rawValue: "glass"), .glass)
    }

    func testGlassTitleIsGlass() {
        XCTAssertEqual(AppTheme.glass.title, "Glass")
    }

    /// Glass isn't a light/dark choice — it's a surface treatment, and the
    /// system's own Liquid Glass already adapts to light/dark (and to
    /// Clear/Tinted) on its own. So, like System, Glass leaves both the
    /// SwiftUI color scheme and the AppKit window appearance on "follow
    /// system" rather than forcing one.
    func testGlassFollowsSystemLikeSystemTheme() {
        XCTAssertNil(AppTheme.glass.preferredColorScheme)
        XCTAssertNil(AppTheme.glass.nsAppearance)
        XCTAssertEqual(AppTheme.glass.resolvedScheme(systemFallback: .dark), .dark)
        XCTAssertEqual(AppTheme.glass.resolvedScheme(systemFallback: .light), .light)
    }

    /// Dark and Light keep painting the header/footer chrome exactly as
    /// before — `forGlass` defaults to false, so every existing
    /// `ThemeColors.resolve(.dark)` / `.resolve(.light)` call (including the
    /// ones other test files already pin) is untouched.
    func testNonGlassChromeFillUnchanged() {
        XCTAssertEqual(ThemeColors.resolve(.light).chromeFill, .clear)
        XCTAssertNotEqual(ThemeColors.resolve(.dark).chromeFill, .clear)
    }

    /// Glass paints its own surface (`PanelBackdrop`'s `.glassEffect`), so the
    /// chrome bars must stop laying a second, opaque fill on top of it — in
    /// both looks, not just Light.
    func testGlassChromeFillIsClearInBothSchemes() {
        XCTAssertEqual(ThemeColors.resolve(.light, forGlass: true).chromeFill, .clear)
        XCTAssertEqual(ThemeColors.resolve(.dark, forGlass: true).chromeFill, .clear)
    }

    /// Text, divider and status colors are untouched by `forGlass`: Glass
    /// reads exactly as strong as System/Dark/Light, per "readability
    /// over bright windows" rule — nothing here ever dims or tints them.
    func testGlassTextAndStatusColorsMatchTheSameScheme() {
        let plainDark = ThemeColors.resolve(.dark)
        let glassDark = ThemeColors.resolve(.dark, forGlass: true)
        XCTAssertEqual(plainDark.textPrimary, glassDark.textPrimary)
        XCTAssertEqual(plainDark.textSecondary, glassDark.textSecondary)
        XCTAssertEqual(plainDark.divider, glassDark.divider)
        XCTAssertEqual(plainDark.statusHealthy, glassDark.statusHealthy)
        XCTAssertEqual(plainDark.statusDegraded, glassDark.statusDegraded)
        XCTAssertEqual(plainDark.statusBroken, glassDark.statusBroken)

        let plainLight = ThemeColors.resolve(.light)
        let glassLight = ThemeColors.resolve(.light, forGlass: true)
        XCTAssertEqual(plainLight.textPrimary, glassLight.textPrimary)
        XCTAssertEqual(plainLight.statusHealthy, glassLight.statusHealthy)
    }

    /// `AppTheme.resolvedColors(systemFallback:)` is what the panel, card and
    /// Settings actually call — check it wires `forGlass` through on its own
    /// rather than each view site having to remember to.
    func testResolvedColorsPassesForGlassThrough() {
        XCTAssertEqual(
            AppTheme.glass.resolvedColors(systemFallback: .dark).chromeFill,
            ThemeColors.resolve(.dark, forGlass: true).chromeFill
        )
        XCTAssertEqual(
            AppTheme.system.resolvedColors(systemFallback: .dark).chromeFill,
            ThemeColors.resolve(.dark).chromeFill
        )
    }

    /// Dark Glass: the tab switch and search field are a faint tint, not the
    /// Dark theme's solid graphite, so the glass shows through (
    /// 2026-09-26). Plain Dark keeps its solid track.
    func testDarkGlassTrackIsTranslucent() {
        let glass = ThemeColors.resolve(.dark, forGlass: true)
        XCTAssertEqual(glass.fieldFill, Color.white.opacity(0.08))
        XCTAssertEqual(glass.selectedFill, Color.white.opacity(0.16))
        XCTAssertEqual(ThemeColors.resolve(.dark).fieldFill, Color(hex: 0x323238))
    }
}
