import AppKit
import XCTest
@testable import mcpock

/// Two-letter agent monograms from the approved mockup; anything unlisted takes
/// the first two letters of its label. Round 3: agents with a real mono logo
/// (LobeHub Icons) carry its asset name, and every badge draws that logo; the
/// monogram is only for agents without one. No colour app icons anywhere.
final class AgentBadgeTests: XCTestCase {
    func testKnownAgentsUseTheTable() {
        let expected = [
            "Code": "CC", "Claude Desktop": "CD", "Cursor": "Cu", "Grok": "Gk", "Goose": "Go",
            "Hermes": "He", "Kimi Code": "Ki", "MiniMax": "Mm", "OpenCode": "OC", "Windsurf": "Ws",
            "VS Code": "VS",
        ]
        for (label, monogram) in expected {
            XCTAssertEqual(AgentBadge.forLabel(label).monogram, monogram, label)
        }
    }

    func testFolderAndProjectSuffixesAreStripped() {
        XCTAssertEqual(AgentBadge.forLabel("Hermes · scribe").monogram, "He")
        XCTAssertEqual(AgentBadge.forLabel("Code (WeeklyContentCalendar)").monogram, "CC")
        XCTAssertEqual(AgentBadge.forLabel("Hermes · scribe").agent, "Hermes")
    }

    func testUnknownAgentsTakeTheirFirstTwoLetters() {
        XCTAssertEqual(AgentBadge.forLabel("Crush").monogram, "Cr")
        XCTAssertEqual(AgentBadge.forLabel("cline").monogram, "Cl")
        XCTAssertEqual(AgentBadge.forLabel("x").monogram, "X")
    }

    /// Every mapped asset ships in the catalog as a template image, so it takes
    /// the theme's secondary text colour.
    func testAgentLogos() {
        let expected = [
            "Code": "agent-claudecode", "Code (MyApp)": "agent-claudecode",
            "Claude Code": "agent-claudecode", "Claude Desktop": "agent-claude",
            "Cursor": "agent-cursor", "Goose": "agent-goose", "Grok": "agent-grok",
            "Hermes": "agent-hermesagent", "Hermes · scribe": "agent-hermesagent",
            "Kimi": "agent-kimi", "Kimi Code": "agent-kimi", "MiniMax": "agent-minimax",
            "OpenCode": "agent-opencode", "Windsurf": "agent-windsurf",
        ]
        for (label, asset) in expected {
            XCTAssertEqual(AgentBadge.forLabel(label).logoName, asset, label)
            let image = NSImage(named: asset)
            XCTAssertNotNil(image, "\(asset) is in the asset catalog")
            XCTAssertEqual(image?.isTemplate, true, "\(asset) renders as a template")
        }
    }

    /// Round 4: every logo in the table and the alias table (hosts other people
    /// run, not only one user's) is a real template image in the catalog.
    func testEveryMappedLogoAssetLoads() {
        let assets = Set(AgentBadge.logoNames.values).union(AgentBadge.logoAliases.values)
        XCTAssertGreaterThanOrEqual(assets.count, 30, "hers plus the new hosts")
        for asset in assets.sorted() {
            let image = NSImage(named: asset)
            XCTAssertNotNil(image, "\(asset) is in the asset catalog")
            XCTAssertEqual(image?.isTemplate, true, "\(asset) renders as a template")
            XCTAssertGreaterThan(image?.size.width ?? 0, 0, "\(asset) has a size")
        }
    }

    /// Round 4: the hosts other users run get their own marks.
    func testOtherHostsHaveLogos() {
        let expected = [
            "Codex": "agent-codex",
            "VS Code": "agent-githubcopilot",
            "Cline": "agent-cline",
            "Gemini": "agent-geminicli", "Gemini CLI": "agent-geminicli",
            "Qwen": "agent-qwen", "Qwen Code": "agent-qwen",
            "Kiro": "agent-kiro", "Trae": "agent-trae",
            "Roo Code": "agent-roocode", "Kilo Code": "agent-kilocode",
            "Junie": "agent-junie", "Amp": "agent-amp",
            "LM Studio": "agent-lmstudio", "Cherry Studio": "agent-cherrystudio",
            "Perplexity": "agent-perplexity", "ChatGPT": "agent-openai",
            "Zed": "agent-zed", "Warp": "agent-warp",
            "JetBrains": "agent-jetbrains", "Raycast": "agent-raycast",
            "mcp": "agent-mcp",
            "aka": "agent-aka",
        ]
        for (label, asset) in expected {
            XCTAssertEqual(AgentBadge.forLabel(label).logoName, asset, label)
        }
    }

    /// Labels the scanner derives from folder names (`~/.gemini` gives "gemini",
    /// `~/.roo` gives "roo", `~/.codeium` is Windsurf) and any spelling of the
    /// case resolve to the same mark as the registry label.
    func testScannedAndLowercaseLabelsResolve() {
        let expected = [
            "gemini": "agent-geminicli", "geminicli": "agent-geminicli", "gemini-cli": "agent-geminicli",
            "qwen": "agent-qwen", "qwen-code": "agent-qwen",
            "kiro": "agent-kiro", "trae": "agent-trae",
            "roo": "agent-roocode", "roo-code": "agent-roocode", "roocode": "agent-roocode",
            "kilocode": "agent-kilocode", "kilo-code": "agent-kilocode",
            "codeium": "agent-windsurf", "windsurf": "agent-windsurf",
            "codex": "agent-codex", "cline": "agent-cline",
            "vscode": "agent-githubcopilot", "copilot": "agent-githubcopilot",
            "claude-code": "agent-claudecode", "claude": "agent-claude",
            "kimi-code": "agent-kimi", "opencode": "agent-opencode",
            "cursor": "agent-cursor", "CURSOR": "agent-cursor", "grok": "agent-grok",
            "goose": "agent-goose", "hermes": "agent-hermesagent",
            "lmstudio": "agent-lmstudio", "cherrystudio": "agent-cherrystudio",
            "chatgpt": "agent-openai", "openai": "agent-openai",
            "zed": "agent-zed", "warp": "agent-warp", "raycast": "agent-raycast",
            "jetbrains": "agent-jetbrains", "junie": "agent-junie", "amp": "agent-amp",
            "perplexity": "agent-perplexity", "MCP": "agent-mcp",
            "gemini · work": "agent-geminicli", "roo (MyApp)": "agent-roocode",
        ]
        for (label, asset) in expected {
            XCTAssertEqual(AgentBadge.forLabel(label).logoName, asset, label)
        }
    }

    /// Claude Code and Claude Desktop have different marks, so the two never
    /// look the same without the round 2 corner mark.
    func testClaudeCodeAndClaudeDesktopDiffer() {
        XCTAssertNotEqual(AgentBadge.forLabel("Code").logoName, AgentBadge.forLabel("Claude Desktop").logoName)
        XCTAssertNotEqual(AgentBadge.forLabel("VS Code").logoName, AgentBadge.forLabel("Code").logoName,
                          "VS Code is not Claude Code")
    }

    /// No logo: the monogram stays as plain text. Continue has no mark in either
    /// icon set (round 4), so it keeps its letters too.
    func testAgentsWithoutALogoKeepTheirMonogram() {
        for label in ["mcporter", "Continue", "continue", "Augment", "Jan", "Msty", "SomethingNew"] {
            XCTAssertNil(AgentBadge.forLabel(label).logoName, label)
            XCTAssertFalse(AgentBadge.forLabel(label).monogram.isEmpty, label)
        }
        XCTAssertEqual(AgentBadge.forLabel("Continue").monogram, "Co")
    }
}
