import Foundation

/// Settings > Connect (1.10.7, the row list from Kartina, read-only on purpose): one row per agent
/// mcpock reads, saying whether its settings file already has an "mcpock" entry, with the line to
/// paste in by hand. mcpock never writes these files; adding the entry is the user's (or their
/// agent's) edit, the same as for any other server.
struct AgentHost: Identifiable, Sendable {
    enum Format: Sendable {
        /// `claude mcp add`, run in Terminal; the entry lands in `~/.claude.json`.
        case claudeCode
        /// `{"<top>": {"mcpock": {...}}}`
        case json(top: String, style: JSONStyle)
        /// `[mcp_servers.mcpock]`
        case toml(enabled: Bool)
        /// A YAML section (`extensions:` for Goose, `mcp_servers:` for Hermes).
        case yaml(section: String, style: YAMLStyle)
    }
    enum JSONStyle: Sendable { case standard, vscode, opencode }
    enum YAMLStyle: Sendable { case goose, hermes }

    var id: String
    /// The agent as the row shows it; also its badge (`AgentBadge.forLabel`).
    var name: String
    /// The settings file, from the home folder.
    var file: String
    var format: Format
    /// Where the agent lives when it is on this Mac (any one is enough), from the home folder or absolute.
    var detect: [String]
    /// What to do after adding the line.
    var after: String
    /// Other names the same file may have, read when `file` is not there
    /// (OpenCode's `opencode.jsonc`).
    var alternateFiles: [String] = []

    static let entry = ConnectSnippets.serverName

    static let all: [AgentHost] = [
        AgentHost(id: "claude-code", name: "Claude Code", file: ".claude.json", format: .claudeCode,
                  detect: [".claude", ".local/bin/claude", "/opt/homebrew/bin/claude"], after: "Start a new Claude Code session."),
        AgentHost(id: "claude-desktop", name: "Claude Desktop", file: "Library/Application Support/Claude/claude_desktop_config.json",
                  format: .json(top: "mcpServers", style: .standard), detect: ["/Applications/Claude.app", "Library/Application Support/Claude"],
                  after: "Quit and open Claude Desktop again."),
        AgentHost(id: "cursor", name: "Cursor", file: ".cursor/mcp.json", format: .json(top: "mcpServers", style: .standard),
                  detect: ["/Applications/Cursor.app", ".cursor"], after: "Cursor picks it up in its MCP settings."),
        AgentHost(id: "vscode", name: "VS Code", file: "Library/Application Support/Code/User/mcp.json", format: .json(top: "servers", style: .vscode),
                  detect: ["/Applications/Visual Studio Code.app", "Library/Application Support/Code"], after: "Start it in VS Code's MCP list (Copilot agent mode)."),
        AgentHost(id: "windsurf", name: "Windsurf", file: ".codeium/windsurf/mcp_config.json", format: .json(top: "mcpServers", style: .standard),
                  detect: ["/Applications/Windsurf.app", ".codeium/windsurf"], after: "Refresh Windsurf's MCP servers."),
        AgentHost(id: "antigravity", name: "Antigravity", file: ".gemini/config/mcp_config.json",
                  format: .json(top: "mcpServers", style: .standard),
                  detect: ["/Applications/Antigravity.app", ".gemini/antigravity-cli", ".gemini/config/mcp_config.json"],
                  after: "Refresh the MCP servers in Antigravity's Settings > Customizations."),
        AgentHost(id: "codex", name: "Codex", file: ".codex/config.toml", format: .toml(enabled: false),
                  detect: [".codex", "/opt/homebrew/bin/codex", ".local/bin/codex", "/Applications/Codex.app"], after: "Start a new Codex session."),
        AgentHost(id: "grok", name: "Grok", file: ".grok/config.toml", format: .toml(enabled: true),
                  detect: [".grok"], after: "Start a new Grok session."),
        AgentHost(id: "opencode", name: "OpenCode", file: ".config/opencode/opencode.json", format: .json(top: "mcp", style: .opencode),
                  detect: [".config/opencode", "/opt/homebrew/bin/opencode"], after: "Start a new OpenCode session.",
                  alternateFiles: [".config/opencode/opencode.jsonc"]),
        AgentHost(id: "goose", name: "Goose", file: ".config/goose/config.yaml", format: .yaml(section: "extensions", style: .goose),
                  detect: [".config/goose", "/Applications/Goose.app"], after: "Start a new Goose session."),
        AgentHost(id: "hermes", name: "Hermes", file: ".hermes/config.yaml", format: .yaml(section: "mcp_servers", style: .hermes),
                  detect: [".hermes"], after: "Restart Hermes."),
        AgentHost(id: "kimi-code", name: "Kimi Code", file: ".kimi-code/mcp.json", format: .json(top: "mcpServers", style: .standard),
                  detect: [".kimi-code"], after: "Start a new Kimi Code session."),
        AgentHost(id: "minimax", name: "MiniMax", file: ".minimax/mcp.json", format: .json(top: "mcpServers", style: .standard),
                  detect: [".minimax"], after: "Start a new MiniMax session."),
    ]

    /// `turnedOff`: the entry is there but switched off (`"enabled": false`,
    /// `"disabled": true`), so the agent does not start it (Argon 2026-10-17 #15).
    enum Status: Equatable, Sendable { case connected, turnedOff, notConnected, notInstalled }

    /// The settings file: `file`, or the first alternate name that exists.
    func fileURL(home: URL) -> URL {
        let fm = FileManager.default
        for name in [file] + alternateFiles {
            let url = home.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return home.appendingPathComponent(file)
    }

    /// Connected when the file has an "mcpock" entry that is on; otherwise whether the agent is on this Mac.
    func status(home: URL) -> Status {
        switch entry(home: home) {
        case .on: return .connected
        case .off: return .turnedOff
        case .none: break
        }
        let fm = FileManager.default
        let here = fm.fileExists(atPath: fileURL(home: home).path)
            || detect.contains { fm.fileExists(atPath: $0.hasPrefix("/") ? $0 : home.appendingPathComponent($0).path) }
        return here ? .notConnected : .notInstalled
    }

    enum Entry: Equatable { case none, on, off }

    /// The "mcpock" entry, read the way the scan reads each format (comments in
    /// JSON included), with the same on/off switches the scan honours.
    func entry(home: URL) -> Entry {
        guard let text = try? String(contentsOf: fileURL(home: home), encoding: .utf8) else { return .none }
        switch format {
        case .claudeCode, .json:
            let top: String
            if case .json(let t, _) = format { top = t } else { top = "mcpServers" }
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                ?? (try? JSONSerialization.jsonObject(with: Data(JSONC.plainJSON(text).utf8)))
            guard let root = object as? [String: Any] else { return .none }
            var value = (root[top] as? [String: Any])?[Self.entry]
            // Claude Code at local scope keeps it under projects.<folder>
            // (`claude mcp add` without --scope user): connected all the same (r3 7642).
            if value == nil, case .claudeCode = format, let projects = root["projects"] as? [String: Any] {
                value = projects.values.lazy
                    .compactMap { (($0 as? [String: Any])?["mcpServers"] as? [String: Any])?[Self.entry] }
                    .first
            }
            guard let value else { return .none }
            let fields = value as? [String: Any] ?? [:]
            let off = (fields["enabled"] as? Bool) == false || (fields["disabled"] as? Bool) == true
            return off ? .off : .on
        case .toml:
            // The TOML reader drops `enabled = false` servers: a table header
            // with no server behind it is one switched off.
            if MCPServersTOML.servers(fromTOML: text)[Self.entry] != nil { return .on }
            return text.contains("[mcp_servers.\(Self.entry)]") ? .off : .none
        case .yaml(let section, let style):
            guard let fields = YAMLBlock.entries(in: text, under: section)[Self.entry] else { return .none }
            let enabled = fields["enabled"]?.scalar
            switch style {
            case .goose: return enabled == nil || enabled?.lowercased() == "true" ? .on : .off
            case .hermes: return enabled.map(MCPServersYAML.isYAMLFalse) == true ? .off : .on
            }
        }
    }

    // MARK: The line to paste

    /// The entry for this agent, as its file writes it. `helper`: the path of `mcpock-mcp`.
    func setup(helper: String) -> String {
        let json = ConnectSnippets.jsonString(helper)
        switch format {
        case .claudeCode:
            return ConnectSnippets.snippet(.claudeCommand, path: helper)
        case .json(let top, let style):
            let body: String
            switch style {
            case .standard:
                body = "\"command\": \(json),\n      \"args\": []"
            case .vscode:
                body = "\"type\": \"stdio\",\n      \"command\": \(json),\n      \"args\": []"
            case .opencode:
                body = "\"type\": \"local\",\n      \"command\": [\(json)],\n      \"enabled\": true"
            }
            return "{\n  \"\(top)\": {\n    \"\(Self.entry)\": {\n      \(body)\n    }\n  }\n}"
        case .toml(let enabled):
            var lines = ["[mcp_servers.\(Self.entry)]", "command = \(json)", "args = []"]
            if enabled { lines.append("enabled = true") }
            return lines.joined(separator: "\n")
        case .yaml(_, .goose):
            return ConnectSnippets.snippet(.gooseYAML, path: helper)
        case .yaml(_, .hermes):
            return ConnectSnippets.snippet(.hermesYAML, path: helper)
        }
    }
}

extension AgentHost.Format {
    var isClaudeCode: Bool { if case .claudeCode = self { return true } else { return false } }
}
