import XCTest
@testable import mcpock

/// The server switch's writers (1.14), one client at a time, on files shaped
/// like the real ones. Every test works on text or on a file in a temporary
/// folder: never on a real config.
final class ServerSwitchTests: XCTestCase {
    private func edit(_ text: String?, _ mechanism: SwitchMechanism, _ server: String, on: Bool) throws -> String {
        try ServerSwitch.edited(text, mechanism: mechanism, server: server, turnOn: on)
    }

    // MARK: Claude Code (the blocked list in settings.json)

    private let claudeSettings = """
    {
      "cleanupPeriodDays": 30,
      "deniedMcpServers": [
        {
          "serverName": "claude.ai Canva"
        },
        {
          "serverName": "plugin:design:figma"
        }
      ],
      "theme": "dark"
    }

    """

    func testClaudeCodeOffAddsTheNameInTheFilesOwnStyle() throws {
        let off = try edit(claudeSettings, .claudeDeny, "openrouter", on: false)
        XCTAssertEqual(off, """
        {
          "cleanupPeriodDays": 30,
          "deniedMcpServers": [
            {
              "serverName": "claude.ai Canva"
            },
            {
              "serverName": "plugin:design:figma"
            },
            {
              "serverName": "openrouter"
            }
          ],
          "theme": "dark"
        }

        """)
        XCTAssertEqual(ServerSwitch.deniedNames(inClaudeSettings: off),
                       ["claude.ai Canva", "plugin:design:figma", "openrouter"])
    }

    func testClaudeCodeOnPutsTheFileBackByteForByte() throws {
        let off = try edit(claudeSettings, .claudeDeny, "openrouter", on: false)
        XCTAssertEqual(try edit(off, .claudeDeny, "openrouter", on: true), claudeSettings)
    }

    func testClaudeCodeOffTwiceChangesNothing() throws {
        let off = try edit(claudeSettings, .claudeDeny, "openrouter", on: false)
        XCTAssertEqual(try edit(off, .claudeDeny, "openrouter", on: false), off)
    }

    func testClaudeCodeFirstAndMiddleNamesComeOutCleanly() throws {
        let first = try edit(claudeSettings, .claudeDeny, "claude.ai Canva", on: true)
        XCTAssertEqual(ServerSwitch.deniedNames(inClaudeSettings: first), ["plugin:design:figma"])
        let both = try edit(first, .claudeDeny, "plugin:design:figma", on: true)
        XCTAssertEqual(ServerSwitch.deniedNames(inClaudeSettings: both), [])
        XCTAssertNotNil(ServerSwitch.jsonObject(both))
    }

    func testClaudeCodeWithNoListYetGetsOne() throws {
        let off = try edit("{\n  \"theme\": \"dark\"\n}\n", .claudeDeny, "open\"router", on: false)
        XCTAssertEqual(off, """
        {
          "theme": "dark",
          "deniedMcpServers": [
            {
              "serverName": "open\\"router"
            }
          ]
        }

        """)
    }

    func testClaudeCodeWithNoSettingsFileYet() throws {
        let off = try edit(nil, .claudeDeny, "openrouter", on: false)
        XCTAssertEqual(ServerSwitch.deniedNames(inClaudeSettings: off), ["openrouter"])
    }

    func testClaudeCodeKeepsCommentsAndOneLineStyle() throws {
        let text = "{\n  // mine\n  \"deniedMcpServers\": [{ \"serverName\": \"a\" }], /* keep */\n  \"x\": 1,\n}\n"
        let off = try edit(text, .claudeDeny, "b", on: false)
        XCTAssertEqual(off, "{\n  // mine\n  \"deniedMcpServers\": [{ \"serverName\": \"a\" }, { \"serverName\": \"b\" }], /* keep */\n  \"x\": 1,\n}\n")
        XCTAssertEqual(try edit(off, .claudeDeny, "b", on: true), text)
    }

    func testOtherAgentsNeedTheirFile() {
        XCTAssertThrowsError(try edit(nil, .toml, "x", on: false))
        XCTAssertThrowsError(try edit("not json", .claudeDeny, "x", on: false))
    }

    // MARK: Codex and Grok (TOML)

    private let codexTOML = """
    model = "gpt-5"   # default

    [mcp_servers.openrouter]
    command = "npx"
    args = [
      "-y",
      "[weird]",
    ]

    [mcp_servers.openrouter.env]
    OPENROUTER_API_KEY = "sk-or-123"

    [mcp_servers."the board"]
    url = "http://the-zen:4340/mcp"
    enabled = true  # keep

    """

    func testTOMLOffAddsOneLineUnderTheHeader() throws {
        let off = try edit(codexTOML, .toml, "openrouter", on: false)
        XCTAssertEqual(off, codexTOML.replacingOccurrences(
            of: "[mcp_servers.openrouter]\n", with: "[mcp_servers.openrouter]\nenabled = false\n"))
        XCTAssertNil(MCPServersTOML.servers(fromTOML: off)["openrouter"])
        XCTAssertEqual(MCPServersTOML.servers(fromTOML: off, includingOff: true)["openrouter"]?["command"] as? String, "npx")
    }

    func testTOMLOnFlipsTheLine() throws {
        let off = try edit(codexTOML, .toml, "openrouter", on: false)
        let on = try edit(off, .toml, "openrouter", on: true)
        XCTAssertTrue(on.contains("[mcp_servers.openrouter]\nenabled = true\n"))
        XCTAssertNotNil(MCPServersTOML.servers(fromTOML: on)["openrouter"])
    }

    func testTOMLExistingLineKeepsItsComment() throws {
        let off = try edit(codexTOML, .toml, "the board", on: false)
        XCTAssertTrue(off.contains("enabled = false  # keep"), off)
        XCTAssertEqual(try edit(off, .toml, "the board", on: true), codexTOML)
    }

    func testTOMLWindowsLineEndingsStay() throws {
        let crlf = codexTOML.replacingOccurrences(of: "\n", with: "\r\n")
        let off = try edit(crlf, .toml, "openrouter", on: false)
        XCTAssertTrue(off.contains("[mcp_servers.openrouter]\r\nenabled = false\r\ncommand"))
        XCTAssertFalse(off.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    func testTOMLUnknownServerIsRefused() {
        XCTAssertThrowsError(try edit(codexTOML, .toml, "nope", on: false))
    }

    // MARK: Goose and Hermes (YAML)

    private let gooseYAML = """
    extensions:
      mcpock:
        enabled: true
        type: stdio
        name: mcpock
        cmd: /Applications/mcpock.app/Contents/Helpers/mcpock-mcp
        args: []
        envs: {}
        timeout: 60
      developer:
        enabled: true   # built in
        type: builtin
    GOOSE_MODEL: sonnet

    """

    func testGooseOffAndOnAreTheSameFileButOneWord() throws {
        let off = try edit(gooseYAML, .yaml(section: "extensions"), "mcpock", on: false)
        XCTAssertEqual(off, gooseYAML.replacingOccurrences(of: "  mcpock:\n    enabled: true", with: "  mcpock:\n    enabled: false"))
        XCTAssertEqual(try edit(off, .yaml(section: "extensions"), "mcpock", on: true), gooseYAML)
        XCTAssertEqual(GooseConfig.servers(fromYAML: off)["mcpock"]?[ServerSwitch.offKey] as? Bool, true)
    }

    private let hermesYAML = """
    model: x
    mcp_servers:
      apple-notes:
        command: /usr/local/bin/notes
        args: []
      the-board:
        url: http://the-zen:4340/mcp
        headers:
          X-TB-Agent: hermes
          enabled: decoy
      firecrawl:
        args:
        - -y
        command: /Users/x/mcp.sh
    toolsets:
    - web

    """

    func testHermesOffAddsALineAtTheEntrysOwnIndent() throws {
        let off = try edit(hermesYAML, .yaml(section: "mcp_servers"), "the-board", on: false)
        XCTAssertEqual(off, hermesYAML.replacingOccurrences(
            of: "  the-board:\n", with: "  the-board:\n    enabled: false\n"))
        XCTAssertEqual(MCPServersYAML.servers(fromYAML: off)["the-board"]?[ServerSwitch.offKey] as? Bool, true)
        XCTAssertNil(MCPServersYAML.servers(fromYAML: off)["firecrawl"]?[ServerSwitch.offKey])
        let on = try edit(off, .yaml(section: "mcp_servers"), "the-board", on: true)
        XCTAssertTrue(on.contains("  the-board:\n    enabled: true\n"))
        XCTAssertNil(MCPServersYAML.servers(fromYAML: on)["the-board"]?[ServerSwitch.offKey])
    }

    func testYAMLOnWithNoLineChangesNothing() throws {
        XCTAssertEqual(try edit(hermesYAML, .yaml(section: "mcp_servers"), "firecrawl", on: true), hermesYAML)
    }

    func testYAMLWrittenOnOneLineIsRefused() {
        let flow = "mcp_servers:\n  a: {command: x}\n"
        XCTAssertThrowsError(try edit(flow, .yaml(section: "mcp_servers"), "a", on: false))
        XCTAssertThrowsError(try edit(hermesYAML, .yaml(section: "mcp_servers"), "nope", on: false))
    }

    // MARK: OpenCode (both shapes)

    private let openCodeOld = """
    {
      "$schema": "https://opencode.ai/config.json",
      "mcp": {
        "personal-ops-manual": {
          "enabled": true,
          "type": "local",
          "command": [
            "/usr/bin/node",
            "server.mjs"
          ]
        },
        "mcpock": {
          "type": "local",
          "command": [
            "/Applications/mcpock.app/Contents/Helpers/mcpock-mcp"
          ]
        }
      }
    }

    """

    func testOpenCodeOldShapeFlipsOrAddsEnabled() throws {
        let off = try edit(openCodeOld, .openCode, "personal-ops-manual", on: false)
        XCTAssertEqual(off, openCodeOld.replacingOccurrences(of: "\"enabled\": true", with: "\"enabled\": false"))
        XCTAssertEqual(try edit(off, .openCode, "personal-ops-manual", on: true), openCodeOld)

        let added = try edit(openCodeOld, .openCode, "mcpock", on: false)
        XCTAssertTrue(added.contains("      ],\n      \"enabled\": false\n    }\n  }"), added)
    }

    func testOpenCodeCurrentShapeUsesDisabledAndKeepsComments() throws {
        let text = """
        {
          // my servers
          "mcp": {
            "servers": {
              "context7": { "type": "remote", "url": "https://mcp.context7.com/mcp" }
            }
          }
        }
        """
        let off = try edit(text, .openCode, "context7", on: false)
        XCTAssertTrue(off.contains("\"url\": \"https://mcp.context7.com/mcp\", \"disabled\": true }"), off)
        XCTAssertTrue(off.contains("// my servers"))
        let on = try edit(off, .openCode, "context7", on: true)
        XCTAssertTrue(on.contains("\"disabled\": false"))
    }

    // MARK: Claude Desktop and Cursor (parking)

    private let desktop = """
    {
      "mcpServers": {
        "openrouter": {
          "command": "npx",
          "args": ["-y", "openrouter-mcp"],
          "env": {
            "OPENROUTER_API_KEY": "sk-or-123"
          }
        },
        "figma": {
          "url": "http://127.0.0.1:3845/mcp"
        }
      },
      "preferences": {
        "menuBarEnabled": false
      }
    }

    """

    func testParkingMovesTheEntryWholeAndKeepsEverythingElse() throws {
        let off = try edit(desktop, .park, "openrouter", on: false)
        XCTAssertEqual(off, """
        {
          "mcpServers": {
            "figma": {
              "url": "http://127.0.0.1:3845/mcp"
            }
          },
          "preferences": {
            "menuBarEnabled": false
          },
          "_mcpock_disabled": {
            "openrouter": {
              "command": "npx",
              "args": ["-y", "openrouter-mcp"],
              "env": {
                "OPENROUTER_API_KEY": "sk-or-123"
              }
            }
          }
        }

        """)
    }

    func testParkingBackRestoresTheEntryAndDropsTheEmptyKey() throws {
        let off = try edit(desktop, .park, "openrouter", on: false)
        let on = try edit(off, .park, "openrouter", on: true)
        XCTAssertFalse(on.contains(ServerSwitch.parkedKey))
        let before = try XCTUnwrap(ServerSwitch.jsonObject(desktop) as? NSDictionary)
        XCTAssertEqual(ServerSwitch.jsonObject(on) as? NSDictionary, before)
    }

    func testParkingTheLastServerLeavesAnEmptyMcpServers() throws {
        var text = try edit(desktop, .park, "openrouter", on: false)
        text = try edit(text, .park, "figma", on: false)
        let root = try XCTUnwrap(ServerSwitch.jsonObject(text) as? [String: Any])
        XCTAssertEqual((root["mcpServers"] as? [String: Any])?.count, 0)
        XCTAssertEqual((root[ServerSwitch.parkedKey] as? [String: Any])?.count, 2)
        text = try edit(text, .park, "figma", on: true)
        text = try edit(text, .park, "openrouter", on: true)
        XCTAssertEqual(ServerSwitch.jsonObject(text) as? NSDictionary, ServerSwitch.jsonObject(desktop) as? NSDictionary)
    }

    func testParkingAOneLineFile() throws {
        let cursor = #"{"mcpServers":{"a":{"command":"x"},"b":{"url":"http://h/mcp"}}}"#
        let off = try edit(cursor, .park, "b", on: false)
        XCTAssertEqual(off, #"{"mcpServers":{"a":{"command":"x"}}, "_mcpock_disabled": {"b": {"url":"http://h/mcp"}}}"#)
        XCTAssertEqual(ServerSwitch.jsonObject(try edit(off, .park, "b", on: true)) as? NSDictionary,
                       ServerSwitch.jsonObject(cursor) as? NSDictionary)
    }

    func testParkingRefusesWhenTheNameIsAlreadyOnTheOtherSide() throws {
        let off = try edit(desktop, .park, "openrouter", on: false)
        let clash = off.replacingOccurrences(of: "\"figma\": {", with: "\"openrouter\": {")
        XCTAssertThrowsError(try edit(clash, .park, "openrouter", on: true))
        XCTAssertThrowsError(try edit(desktop, .park, "nope", on: false))
    }

    // MARK: The check

    func testTheCheckCatchesAnEditThatTouchedSomethingElse() {
        let good = desktop.replacingOccurrences(of: "\"menuBarEnabled\": false", with: "\"menuBarEnabled\": true")
        XCTAssertFalse(ServerSwitch.verify(before: desktop, after: good, mechanism: .park, server: "openrouter", turnOn: false))
        XCTAssertFalse(ServerSwitch.verify(before: codexTOML, after: codexTOML + "x = 1\ny = 2\n", mechanism: .toml,
                                           server: "openrouter", turnOn: false))
        XCTAssertFalse(ServerSwitch.verify(before: gooseYAML, after: gooseYAML.replacingOccurrences(of: "timeout: 60", with: "timeout: 61"),
                                           mechanism: .yaml(section: "extensions"), server: "mcpock", turnOn: false))
    }

    // MARK: Which agents get a switch

    func testOnlyKnownFilesOfAgentsWithAWayGetASwitch() {
        XCTAssertEqual(ServerSwitch.mechanism(agent: "Code", configID: "scan:/x/.mcp.json:global:a", builtin: false), .claudeDeny)
        XCTAssertEqual(ServerSwitch.mechanism(agent: "Codex", configID: "reg:Codex:global:a", builtin: false), .toml)
        XCTAssertEqual(ServerSwitch.mechanism(agent: "Goose", configID: "reg:Goose:global:a", builtin: false), .yaml(section: "extensions"))
        XCTAssertEqual(ServerSwitch.mechanism(agent: "Cursor", configID: "reg:Cursor:global:a", builtin: false), .park)
        XCTAssertNil(ServerSwitch.mechanism(agent: "Cursor", configID: "scan:/x/mcp.json:global:a", builtin: false))
        XCTAssertNil(ServerSwitch.mechanism(agent: "VS Code", configID: "reg:VS Code:global:a", builtin: false))
        XCTAssertNil(ServerSwitch.mechanism(agent: "Codex", configID: "reg:Codex:global:a", builtin: true))
        XCTAssertNil(ServerSwitch.mechanism(agent: AkaSource.label, configID: "aka:1", builtin: false))
    }
}
