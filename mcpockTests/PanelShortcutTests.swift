import XCTest
import Carbon.HIToolbox
@testable import mcpock

/// 1.12: she picks her own panel shortcut in Settings > General.
final class PanelShortcutTests: XCTestCase {
    func testTheDefaultIsControlOptionM() {
        XCTAssertEqual(PanelShortcut.standard.displayText, "\u{2303}\u{2325}M")
        XCTAssertEqual(PanelShortcut.standard.spokenText, "Control-Option-M")
    }

    func testAKeyPressBecomesAShortcut() throws {
        let picked = try XCTUnwrap(PanelShortcut.from(keyCode: UInt16(kVK_ANSI_K), flags: [.command, .shift], characters: "k"))
        XCTAssertEqual(picked.displayText, "\u{21E7}\u{2318}K")
        XCTAssertEqual(picked.spokenText, "Shift-Command-K")
        XCTAssertEqual(picked.modifiers, UInt32(cmdKey | shiftKey))
        XCTAssertEqual(PanelShortcut.from(keyCode: UInt16(kVK_Space), flags: [.option], characters: " ")?.displayText,
                       "\u{2325}Space")
        XCTAssertEqual(PanelShortcut.from(keyCode: UInt16(kVK_F5), flags: [.control], characters: "\u{F708}")?.key, "F5")
    }

    func testWhatCantBeAShortcut() {
        XCTAssertNil(PanelShortcut.from(keyCode: UInt16(kVK_ANSI_K), flags: [], characters: "k"), "a bare letter")
        XCTAssertNil(PanelShortcut.from(keyCode: UInt16(kVK_ANSI_K), flags: [.shift], characters: "k"), "Shift alone")
        XCTAssertNil(PanelShortcut.from(keyCode: UInt16(kVK_Escape), flags: [.command], characters: "\u{1B}"),
                     "Escape cancels")
    }

    func testSavedAndBackToTheDefault() throws {
        let suite = "mcpock.tests.shortcut.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        XCTAssertEqual(AppPreferences.loadPanelShortcut(from: defaults), .standard)
        let picked = try XCTUnwrap(PanelShortcut.from(keyCode: UInt16(kVK_ANSI_P), flags: [.control, .option], characters: "p"))
        AppPreferences.savePanelShortcut(picked, to: defaults)
        XCTAssertEqual(AppPreferences.loadPanelShortcut(from: defaults), picked)
        AppPreferences.savePanelShortcut(.standard, to: defaults)
        XCTAssertNil(defaults.object(forKey: AppPreferences.panelShortcutKey), "the default is not stored")
        defaults.set(Data("junk".utf8), forKey: AppPreferences.panelShortcutKey)
        XCTAssertEqual(AppPreferences.loadPanelShortcut(from: defaults), .standard)
    }

    func testSettingsTextFollowsTheShortcut() throws {
        let picked = try XCTUnwrap(PanelShortcut.from(keyCode: UInt16(kVK_ANSI_K), flags: [.command, .option], characters: "k"))
        XCTAssertEqual(SettingsGeneralPane.hotKeyTakenText(picked),
                       "Another app already uses \u{2325}\u{2318}K, so mcpock can't. Pick another one.")
        XCTAssertTrue(SettingsGeneralPane.hotKeyHelp(picked).hasPrefix("Option-Command-K opens"))
    }
}
