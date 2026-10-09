import Foundation

/// A known agent: an exact config path and the shape that parses it.
struct KnownAgent {
    let label: String
    let path: String
    let shape: ConfigShape
}

/// Curated table of agents we cover exactly (fast, correct labels). The scanner
/// (`ConfigScanner`) catches everything else. Missing files are simply skipped.
/// An agent whose file the scan would find anyway still earns a row here when the
/// derived label would be ugly (`kimi-code`, `minimax`).
///
/// MiniMax reads only `~/.minimax/mcp.json`. `~/.minimax/mcp/mcp.json` is not a
/// config MiniMax loads (its `mcp-runtime-names.json` lists only the first file's
/// servers), so 1.5.1 dropped it here and `ConfigScanner` skips it: reading it
/// made servers look "set up differently" for MiniMax when they weren't.
enum AgentRegistry {
    private static func home(_ rel: String) -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(rel)
    }

    /// Claude Code's label. Short because it predates the other agents and is
    /// what stored choices were made under; people read it as "Claude Code"
    /// (`AgentBadge.displayNames`).
    static let claudeCodeLabel = "Code"

    static var known: [KnownAgent] {
        [
            KnownAgent(label: claudeCodeLabel, path: home(".claude.json"), shape: .json),
            KnownAgent(label: "Claude Desktop",
                       path: home("Library/Application Support/Claude/claude_desktop_config.json"),
                       shape: .json),
            KnownAgent(label: "Cursor", path: home(".cursor/mcp.json"), shape: .json),
            KnownAgent(label: "Windsurf", path: home(".codeium/windsurf/mcp_config.json"), shape: .json),
            KnownAgent(label: "Cline",
                       path: home("Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"),
                       shape: .json),
            KnownAgent(label: "Continue", path: home(".continue/config.json"), shape: .json),
            KnownAgent(label: "VS Code", path: home("Library/Application Support/Code/User/mcp.json"), shape: .json),
            KnownAgent(label: "Grok", path: home(".grok/config.toml"), shape: .mcpServersTOML),
            KnownAgent(label: "MiniMax", path: home(".minimax/mcp.json"), shape: .json),
            KnownAgent(label: "Codex", path: home(".codex/config.toml"), shape: .mcpServersTOML),
            KnownAgent(label: "Goose", path: home(".config/goose/config.yaml"), shape: .gooseYAML),
            KnownAgent(label: "Hermes", path: home(".hermes/config.yaml"), shape: .mcpServersYAML),
            KnownAgent(label: "Kimi Code", path: home(".kimi-code/mcp.json"), shape: .json),
            KnownAgent(label: "OpenCode", path: home(".config/opencode/opencode.json"), shape: .json),
        ]
    }
}

/// What an agent badge shows (round 3): the agent's real mono logo (`logoName`),
/// else its two-letter monogram. No colour app icons anywhere ("use
/// overall the symbols instead of the colour icons").
struct AgentBadge: Hashable, Sendable {
    /// The agent part of the label ("Hermes" for "Hermes · scribe").
    let agent: String
    let monogram: String
    /// The agent's real mono logo, an asset in `Assets.xcassets` (round 3), drawn
    /// in the secondary text colour: on its own in the server rows, in a neutral
    /// circle in the card, the Agents tab and Settings. nil falls back to the
    /// monogram. Claude Code's pixel mark already tells it apart from Claude
    /// Desktop's burst, so no corner mark is needed.
    var logoName: String? = nil

    /// Round 3: the real agent marks instead of made-up SF Symbols. Mono
    /// SVGs from LobeHub Icons (`@lobehub/icons-static-svg` 1.95.1, MIT) and,
    /// for Zed, Warp, JetBrains and Raycast, Simple Icons (CC0); see
    /// `docs/THIRD-PARTY.md`. Stored as vector template images named
    /// `agent-<source name>`. Round 4 ("so it loads smoothly with other
    /// users") added the MCP hosts other people run, not only hers. mcporter,
    /// Continue and anything unknown have no logo and keep their
    /// monogram. VS Code's MCP config belongs to Copilot's agent mode, so it
    /// shows the Copilot mark; ChatGPT shows OpenAI's.
    static let logoNames: [String: String] = [
        "Code": "agent-claudecode", "Claude Code": "agent-claudecode",
        "Claude Desktop": "agent-claude",
        "Cursor": "agent-cursor",
        "Goose": "agent-goose",
        "Grok": "agent-grok",
        "Hermes": "agent-hermesagent",
        "Kimi": "agent-kimi", "Kimi Code": "agent-kimi",
        "MiniMax": "agent-minimax",
        "OpenCode": "agent-opencode",
        "Windsurf": "agent-windsurf",
        // Round 4: hosts beyond the first few.
        "Codex": "agent-codex",
        "VS Code": "agent-githubcopilot", "GitHub Copilot": "agent-githubcopilot",
        "Cline": "agent-cline",
        "Gemini": "agent-geminicli", "Gemini CLI": "agent-geminicli",
        "Qwen": "agent-qwen", "Qwen Code": "agent-qwen",
        "Kiro": "agent-kiro",
        "Trae": "agent-trae",
        "Roo Code": "agent-roocode",
        "Kilo Code": "agent-kilocode",
        "Junie": "agent-junie",
        "Amp": "agent-amp",
        "LM Studio": "agent-lmstudio",
        "Cherry Studio": "agent-cherrystudio",
        "Perplexity": "agent-perplexity",
        "ChatGPT": "agent-openai",
        "Zed": "agent-zed",
        "Warp": "agent-warp",
        "JetBrains": "agent-jetbrains",
        "Raycast": "agent-raycast",
        "mcp": "agent-mcp",
        // Round 5: aka, a desktop agent app, its tray icon (a PNG template, not an SVG).
        "aka": "agent-aka",
    ]

    /// Spellings the scanner derives from folder names (`~/.gemini` gives
    /// "gemini", `~/.roo` gives "roo", `~/.codeium` is Windsurf's folder) and
    /// other ways people write an agent's name, keyed lowercase. Looked up after
    /// `logoNames`, and every `logoNames` key also matches case-insensitively,
    /// so "cursor", "CURSOR" and "Cursor" all get the same mark.
    static let logoAliases: [String: String] = [
        "claudecode": "agent-claudecode", "claude-code": "agent-claudecode",
        "claude": "agent-claude", "claude desktop": "agent-claude", "claude-desktop": "agent-claude",
        "codeium": "agent-windsurf",
        "kimi-code": "agent-kimi", "kimicode": "agent-kimi",
        "hermes agent": "agent-hermesagent", "hermes-agent": "agent-hermesagent",
        "opencode": "agent-opencode", "open code": "agent-opencode",
        "vscode": "agent-githubcopilot", "copilot": "agent-githubcopilot",
        "github-copilot": "agent-githubcopilot", "githubcopilot": "agent-githubcopilot",
        "geminicli": "agent-geminicli", "gemini-cli": "agent-geminicli",
        "qwencode": "agent-qwen", "qwen-code": "agent-qwen",
        "roo": "agent-roocode", "roocode": "agent-roocode", "roo-code": "agent-roocode",
        "roo-cline": "agent-roocode",
        "kilocode": "agent-kilocode", "kilo-code": "agent-kilocode", "kilo": "agent-kilocode",
        "lmstudio": "agent-lmstudio", "lm-studio": "agent-lmstudio",
        "cherrystudio": "agent-cherrystudio", "cherry-studio": "agent-cherrystudio",
        "chatgpt": "agent-openai", "openai": "agent-openai",
        "zed industries": "agent-zed", "zedindustries": "agent-zed",
        "warp terminal": "agent-warp", "warpdotdev": "agent-warp",
        "intellij": "agent-jetbrains", "jetbrains ai": "agent-jetbrains",
        "modelcontextprotocol": "agent-mcp",
    ]

    /// The logo asset for an agent name, or nil when it keeps its monogram.
    /// Exact label first, then the aliases, then a case-insensitive match on
    /// the labels themselves.
    static func logoName(forAgent agent: String) -> String? {
        if let exact = logoNames[agent] { return exact }
        let key = agent.lowercased()
        if let alias = logoAliases[key] { return alias }
        return logoNamesByLowercasedLabel[key]
    }

    private static let logoNamesByLowercasedLabel: [String: String] =
        Dictionary(logoNames.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })

    /// The table from the approved mockup. Keyed by `AgentRegistry` label, plus
    /// the long names so a scanned or future label spelled out in full still gets
    /// its proper monogram. Everything else takes the first two letters.
    static let monograms: [String: String] = [
        "Code": "CC", "Claude Code": "CC",
        "Claude Desktop": "CD",
        "Cursor": "Cu",
        "Grok": "Gk",
        "Goose": "Go",
        "Hermes": "He",
        "Kimi": "Ki", "Kimi Code": "Ki",
        "MiniMax": "Mm",
        "OpenCode": "OC",
        "Windsurf": "Ws",
        "VS Code": "VS",
    ]

    /// Badge for any source label: a registry label ("Cursor"), a scanned one
    /// ("Hermes · scribe") or a project-scoped display label ("Code (MyApp)").
    static func forLabel(_ label: String) -> AgentBadge {
        let agent = agentName(fromLabel: label)
        let monogram: String
        if let known = monograms[agent] {
            monogram = known
        } else {
            let letters = agent.filter { $0.isLetter || $0.isNumber }
            monogram = letters.prefix(1).uppercased() + letters.dropFirst().prefix(1).lowercased()
        }
        return AgentBadge(
            agent: agent,
            monogram: monogram,
            logoName: logoName(forAgent: agent)
        )
    }

    /// Long names for labels that are short in the registry. Claude Code's label is
    /// "Code" (it predates the other agents and is stored in pinned/hidden choices),
    /// but a detail card or an agent row reading "Code" says nothing.
    static let displayNames: [String: String] = [
        "Code": "Claude Code",
    ]

    /// A source label as people read it: "Code (MyApp)" becomes "Claude Code (MyApp)",
    /// "Hermes · scribe" and "Cursor" stay as they are.
    static func displayLabel(_ label: String) -> String {
        for (short, long) in displayNames {
            if label == short { return long }
            if label.hasPrefix(short + " (") || label.hasPrefix(short + " \u{00B7} ") {
                return long + label.dropFirst(short.count)
            }
        }
        return label
    }

    /// Strips the folder (" · scribe") and project ("(MyApp)") parts a label may carry.
    static func agentName(fromLabel label: String) -> String {
        var agent = label.components(separatedBy: " · ").first ?? label
        if let paren = agent.range(of: " (") {
            agent = String(agent[..<paren.lowerBound])
        }
        return agent.trimmingCharacters(in: .whitespaces)
    }
}
