import XCTest
import AppKit
@testable import mcpock

/// Round 7 Settings: the "Check servers" slider's stops, the Connect tab's
/// snippets and prompt, the About tab's texts and the config path menu.
final class Round7SettingsTests: XCTestCase {
    private let path = "/Applications/mcpock.app/Contents/Helpers/mcpock-mcp"

    // MARK: - Check servers slider

    func testSliderStopsLeftToRight() {
        XCTAssertEqual(ProbeInterval.allCases.map(\.title), ["1 min", "5 min", "15 min", "30 min", "1 h", "4 h", "Manual"])
        XCTAssertEqual(ProbeInterval.allCases.map(\.rawValue), [60, 300, 900, 1800, 3600, 14400, 0])
        XCTAssertEqual(ProbeInterval.manual.sliderIndex, 6)
        XCTAssertEqual(ProbeInterval.nearest(toSliderPosition: 2.4), .fifteenMinutes)
        XCTAssertEqual(ProbeInterval.nearest(toSliderPosition: 2.6), .thirtyMinutes)
        XCTAssertEqual(ProbeInterval.nearest(toSliderPosition: -3), .oneMinute)
        XCTAssertEqual(ProbeInterval.nearest(toSliderPosition: 99), .manual)
    }

    func testStoredValuesStayValid() {
        // What older versions saved still means the same.
        XCTAssertEqual(ProbeInterval.fromStored(60), .oneMinute)
        XCTAssertEqual(ProbeInterval.fromStored(300), .fiveMinutes)
        XCTAssertEqual(ProbeInterval.fromStored(900), .fifteenMinutes)
        XCTAssertEqual(ProbeInterval.fromStored(0), .manual)
        // A value no version offers snaps to the nearest automatic stop, never to Manual.
        XCTAssertEqual(ProbeInterval.fromStored(1200), .fifteenMinutes)
        XCTAssertEqual(ProbeInterval.fromStored(7200), .oneHour)
        XCTAssertEqual(ProbeInterval.fromStored(999_999), .fourHours)
        XCTAssertEqual(ProbeInterval.fromStored(-5), .default)
        XCTAssertEqual(ProbeInterval.fourHours.seconds, 14400)

        let suite = "round7.interval.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.retireSuite(named: suite) }
        AppPreferences.saveProbeInterval(.oneHour, to: defaults)
        XCTAssertEqual(defaults.integer(forKey: AppPreferences.probeIntervalKey), 3600, "stored as seconds")
        XCTAssertEqual(AppPreferences.loadProbeInterval(from: defaults), .oneHour)
        defaults.set(120, forKey: AppPreferences.probeIntervalKey)
        XCTAssertEqual(AppPreferences.loadProbeInterval(from: defaults), .oneMinute)
    }

    // MARK: - Connect

    func testHelperPathIsInsideTheBundle() {
        XCTAssertEqual(ConnectSnippets.helperPath(appBundle: URL(fileURLWithPath: "/Applications/mcpock.app")), path)
    }

    func testJSONSnippetParsesAndRunsTheHelper() throws {
        let text = ConnectSnippets.snippet(.json, path: path)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let entry = try XCTUnwrap((object["mcpServers"] as? [String: Any])?["mcpock"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, path)
        XCTAssertEqual((entry["args"] as? [Any])?.count, 0)
        XCTAssertNil(entry["env"], "no env: the helper needs nothing secret")
    }

    func testOtherFormats() {
        XCTAssertEqual(ConnectSnippets.snippet(.claudeCommand, path: path),
                       "claude mcp add --scope user mcpock -- \(path)")
        XCTAssertEqual(ConnectSnippets.snippet(.claudeCommand, path: "/Users/k/My Apps/mcpock.app/x"),
                       "claude mcp add --scope user mcpock -- '/Users/k/My Apps/mcpock.app/x'")
        XCTAssertEqual(ConnectSnippets.snippet(.toml, path: path),
                       "[mcp_servers.mcpock]\ncommand = \"\(path)\"\nargs = []")
        XCTAssertEqual(ConnectSnippets.snippet(.hermesYAML, path: path),
                       "mcp_servers:\n  mcpock:\n    command: \(path)\n    args: []")
        let goose = ConnectSnippets.snippet(.gooseYAML, path: path)
        XCTAssertTrue(goose.hasPrefix("extensions:\n  mcpock:\n    enabled: true\n    type: stdio\n"))
        XCTAssertTrue(goose.contains("    cmd: \(path)\n"))
        XCTAssertEqual(ConnectSnippets.snippet(.akaNote, path: path),
                       "In aka, open its MCP settings and add a server:\nName: mcpock\nType: stdio\nPath: \(path)")
        XCTAssertEqual(ConnectSnippets.yamlString("/a b/c"), "\"/a b/c\"")
        XCTAssertEqual(ConnectSnippets.jsonString("a\"b\\c"), #""a\"b\\c""#)
    }

    func testTargetsCoverTheAgents() {
        let names = ConnectSnippets.targets.map(\.name)
        for agent in ["Claude Code", "Claude Desktop", "Cursor", "Windsurf", "Cline", "Kimi Code", "MiniMax",
                      "Codex", "Grok", "Goose", "Hermes", "aka", "Other agents"] {
            XCTAssertTrue(names.contains(agent), agent)
        }
        XCTAssertEqual(names.last, "Other agents")
        let formats = Dictionary(uniqueKeysWithValues: ConnectSnippets.targets.map { ($0.name, $0.format) })
        XCTAssertEqual(formats["Claude Code"], .claudeCommand)
        XCTAssertEqual(formats["Grok"], .toml)
        XCTAssertEqual(formats["Codex"], .toml)
        XCTAssertEqual(formats["Goose"], .gooseYAML)
        XCTAssertEqual(formats["Hermes"], .hermesYAML)
        XCTAssertEqual(formats["aka"], .akaNote)
        XCTAssertEqual(formats["Cursor"], .json)
    }

    // MARK: - About

    func testAboutTexts() {
        XCTAssertEqual(SettingsAboutPane.links.map(\.url),
                       ["https://akakika.com", "https://x.com/akakikaaa", "https://github.com/aka-kika"])
        XCTAssertEqual(SettingsAboutPane.links.map(\.asset), ["social-globe", "social-x", "social-github"])
        XCTAssertEqual(SettingsAboutPane.madeBy, "Made by Kika")
        XCTAssertEqual(SettingsAboutPane.copyright, "\u{00A9} 2026 AKAKIKA.COM")
        XCTAssertEqual(SettingsAboutPane.versionLine(info: ["CFBundleShortVersionString": "1.5.0", "CFBundleVersion": "8"]),
                       "Version 1.5.0 (8)")
        let everything = [SettingsAboutPane.tagline, SettingsAboutPane.madeBy, SettingsAboutPane.copyright]
            + SettingsAboutPane.links.map(\.name)
        XCTAssertFalse(everything.joined().contains("Nica"))
        for link in SettingsAboutPane.links {
            XCTAssertNotNil(NSImage(named: link.asset), "\(link.asset) is in the asset catalog")
        }
    }

    func testTabsEndWithConnectThenAbout() {
        XCTAssertEqual(SettingsTab.allCases, [.general, .servers, .agents, .connect, .about])
    }

    // MARK: - Config path menu (round 8 order and wording: Round8SettingsTests)
}
