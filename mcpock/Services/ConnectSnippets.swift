import Foundation

/// What Settings > Connect copies (round 7): the config snippet each agent
/// needs to run mcpock's `mcpock-mcp` helper, and the "Copy for Claude" setup
/// prompt (round 9 removed the one-agent prompt: Claude is the full setup, the
/// per-agent snippets are the manual way). mcpock still never writes another app's config;
/// these are only texts for the clipboard. Pure, pinned by the Settings tests.
enum ConnectSnippets {
    /// The server name every snippet registers.
    static let serverName = "mcpock"

    /// One line under the pane's title.
    static let intro = "Let your agents read what needs attention."

    /// Where the helper lives inside an app bundle.
    static func helperPath(appBundle: URL = Bundle.main.bundleURL) -> String {
        appBundle.appendingPathComponent("Contents/Helpers/mcpock-mcp").path
    }

    enum Format: Equatable {
        /// `{"mcpServers": {"mcpock": {"command": …}}}`.
        case json
        /// `claude mcp add …`, run in Terminal.
        case claudeCommand
        /// `[mcp_servers.mcpock]`, Grok and Codex.
        case toml
        /// Goose's `extensions:` entry.
        case gooseYAML
        /// Hermes' `mcp_servers:` entry.
        case hermesYAML
        /// aka has no file to paste into: a note for its MCP settings.
        case akaNote

        /// What the row's copy button copies, for its tooltip: "Copy JSON for
        /// Cursor" (round 8).
        var copyNoun: String {
            switch self {
            case .json: return "JSON"
            case .claudeCommand: return "Terminal command"
            case .toml: return "TOML"
            case .gooseYAML, .hermesYAML: return "YAML"
            case .akaNote: return "setup note"
            }
        }

        /// The row's second line.
        var caption: String {
            switch self {
            case .json: return "JSON"
            case .claudeCommand: return "Terminal command"
            case .toml: return "TOML"
            case .gooseYAML, .hermesYAML: return "YAML"
            case .akaNote: return "In aka's MCP settings"
            }
        }
    }

    struct Target: Identifiable, Equatable {
        /// The agent as the row shows it ("Claude Code").
        let name: String
        /// The label the badge is looked up by (`AgentBadge.forLabel`).
        let badgeLabel: String
        let format: Format
        /// Where the snippet goes, for the row's tooltip.
        let destination: String

        var id: String { name }
    }

    /// The Connect list: the agents mcpock knows how to read, aka next to
    /// last (as everywhere), and a generic JSON entry for anything else.
    static let targets: [Target] = [
        Target(name: "Claude Code", badgeLabel: "Code", format: .claudeCommand,
               destination: "Run in Terminal (adds it for every project)"),
        Target(name: "Claude Desktop", badgeLabel: "Claude Desktop", format: .json,
               destination: "~/Library/Application Support/Claude/claude_desktop_config.json"),
        Target(name: "Cursor", badgeLabel: "Cursor", format: .json, destination: "~/.cursor/mcp.json"),
        Target(name: "Codex", badgeLabel: "Codex", format: .toml, destination: "~/.codex/config.toml"),
        Target(name: "Grok", badgeLabel: "Grok", format: .toml, destination: "~/.grok/config.toml"),
        Target(name: "Goose", badgeLabel: "Goose", format: .gooseYAML,
               destination: "~/.config/goose/config.yaml, under extensions:"),
        Target(name: "Hermes", badgeLabel: "Hermes", format: .hermesYAML,
               destination: "~/.hermes/config.yaml, under mcp_servers:"),
        Target(name: "Kimi Code", badgeLabel: "Kimi Code", format: .json, destination: "~/.kimi-code/mcp.json"),
        Target(name: "MiniMax", badgeLabel: "MiniMax", format: .json, destination: "~/.minimax/mcp.json"),
        Target(name: "Windsurf", badgeLabel: "Windsurf", format: .json,
               destination: "~/.codeium/windsurf/mcp_config.json"),
        Target(name: "Cline", badgeLabel: "Cline", format: .json, destination: "Cline's MCP settings (cline_mcp_settings.json)"),
        Target(name: "aka", badgeLabel: "aka", format: .akaNote, destination: "aka's MCP settings"),
        Target(name: "Other agents", badgeLabel: "mcp", format: .json, destination: "The agent's MCP config, under mcpServers"),
    ]

    static func snippet(_ format: Format, path: String) -> String {
        switch format {
        case .json:
            return """
                {
                  "mcpServers": {
                    "\(serverName)": {
                      "command": \(jsonString(path)),
                      "args": []
                    }
                  }
                }
                """
        case .claudeCommand:
            return "claude mcp add --scope user \(serverName) -- \(shellQuoted(path))"
        case .toml:
            return """
                [mcp_servers.\(serverName)]
                command = \(jsonString(path))
                args = []
                """
        case .gooseYAML:
            return """
                extensions:
                  \(serverName):
                    enabled: true
                    type: stdio
                    name: \(serverName)
                    cmd: \(yamlString(path))
                    args: []
                    envs: {}
                    timeout: 60
                """
        case .hermesYAML:
            return """
                mcp_servers:
                  \(serverName):
                    command: \(yamlString(path))
                    args: []
                """
        case .akaNote:
            return """
                In aka, open its MCP settings and add a server:
                Name: \(serverName)
                Type: stdio
                Path: \(path)
                """
        }
    }

    /// The copy button's tooltip and accessibility label (round 8).
    static func copyHelp(_ target: Target) -> String {
        "Copy \(target.format.copyNoun) for \(target.name)"
    }

    // MARK: - Copy for Claude (round 8)

    /// "Copy for Claude": onboarding done BY Claude Code. Plain steps: find
    /// every agent config mcpock knows (paths from `AgentRegistry`), back each
    /// one up, add the mcpock entry where it's missing in that file's format,
    /// verify, report a table. mcpock still never writes a config itself; this
    /// is only text for the clipboard. `agents` and `home` are parameters so
    /// `ConnectSnippetsTests` gets the same text on any Mac.
    static func claudeSetupPrompt(
        path: String,
        agents: [KnownAgent] = AgentRegistry.known,
        home: String = NSHomeDirectory()
    ) -> String {
        let json = jsonString(path)
        let yaml = yamlString(path)
        let shell = shellQuoted(path)
        let test = "printf '%s\\n' "
            + #"'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}' "#
            + #"'{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | "#
            + shell
        return """
            Please connect mcpock to the AI agents on this Mac. mcpock is a menu bar app that checks MCP servers. \
            Its small read-only MCP server, "\(serverName)", lets an agent ask what needs attention. \
            mcpock never edits agent configs itself, so you make the edits. Go step by step and don't skip the backups.

            The server to add
            - name: \(serverName)
            - type: stdio
            - command: \(path)
            - no arguments, no environment variables

            Step 1. Find the agent configs
            Check each file below and skip any that doesn't exist.
            \(agentLines(agents, home: home).joined(separator: "\n"))
            Other MCP configs may exist too (for example a JSON file with an "mcpServers" block in a ~/.<agent> folder, \
            ~/.config or ~/Library/Application Support). List any you find and ask me before changing them.

            Step 2. Back up before editing
            Before you change a file, copy it next to itself as <file name>.mcpock-backup-<YYYYMMDD-HHMM>. \
            If the backup fails, don't touch that file.

            Step 3. Add \(serverName) where it's missing
            If a config already has an entry named \(serverName), leave it as it is ("already there"). \
            Otherwise add it and keep everything else in the file exactly as it was:
            - Claude Code: run  claude mcp add --scope user \(serverName) -- \(shell)
            - JSON with "mcpServers": inside "mcpServers" add
              "\(serverName)": { "command": \(json), "args": [] }
            - VS Code (mcp.json): inside "servers" add
              "\(serverName)": { "type": "stdio", "command": \(json), "args": [] }
            - OpenCode: inside "mcp" add
              "\(serverName)": { "type": "local", "command": [\(json)], "enabled": true }
            - TOML (Codex, Grok): add this table
              [mcp_servers.\(serverName)]
              command = \(json)
              args = []
            - Goose: under "extensions:" add
                \(serverName):
                  enabled: true
                  type: stdio
                  name: \(serverName)
                  cmd: \(yaml)
                  args: []
                  envs: {}
                  timeout: 60
            - Hermes: under "mcp_servers:" add
                \(serverName):
                  command: \(yaml)
                  args: []
            - Continue: only if its file already has an "mcpServers" block; otherwise skip it and say why.
            - aka: skip it and remind me to add it in aka's MCP settings (Name \(serverName), Type stdio, Path \(path)).
            After each edit, check the file still parses (JSON, TOML or YAML). If it doesn't, put the backup back \
            and mark that agent "skipped".

            Step 4. Check it works
            - Run  claude mcp get \(serverName)  and check that it says connected.
            - Test the helper itself: \(test)
              The second answer should list mcpock_status, mcpock_problems and mcpock_server.
            - If the \(serverName) tools are available to you in this session, call mcpock_status. Other agents \
            usually load a new server only after a restart; say so instead of guessing.

            Step 5. Report
            A short table: Agent | Config path | Result (added / already there / skipped: why) | \
            Verified (yes / after restart / no). Then list the backup files you made.

            From then on, when I say "check my mcpock", call mcpock_problems and help me fix what it reports.
            """
    }

    /// Step 1's list: one line per agent (files of the same agent joined with
    /// "or"), in registry order, then aka, which has no file.
    static func agentLines(_ agents: [KnownAgent], home: String) -> [String] {
        var order: [String] = []
        var paths: [String: [String]] = [:]
        var shapes: [String: ConfigShape] = [:]
        for agent in agents {
            if paths[agent.label] == nil { order.append(agent.label) }
            paths[agent.label, default: []].append(CardText.shortPath(agent.path, home: home))
            shapes[agent.label] = shapes[agent.label] ?? agent.shape
        }
        let lines = order.map { label -> String in
            let name = AgentBadge.displayLabel(label)
            let files = (paths[label] ?? []).joined(separator: " or ")
            return "- \(name): \(files) (\(formatNote(label: label, shape: shapes[label])))"
        }
        return lines + ["- aka: no file; it keeps its servers in its own settings"]
    }

    /// How step 3 treats an agent's file, in a few words.
    private static func formatNote(label: String, shape: ConfigShape?) -> String {
        switch label {
        case AgentRegistry.claudeCodeLabel: return "don't edit it by hand; use the claude command in step 3"
        case "VS Code": return "JSON, \"servers\""
        case "OpenCode": return "JSON, \"mcp\""
        case "Continue": return "JSON, only if it already has \"mcpServers\""
        default: break
        }
        switch shape?.id {
        case ConfigShape.mcpServersTOML.id: return "TOML"
        case ConfigShape.gooseYAML.id: return "YAML, Goose \"extensions\""
        case ConfigShape.mcpServersYAML.id: return "YAML, \"mcp_servers\""
        default: return "JSON, \"mcpServers\""
        }
    }

    // MARK: - Quoting

    /// A JSON string literal (also valid TOML basic-string syntax for a path).
    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// A path as a YAML scalar: plain when it is safe, double-quoted otherwise.
    static func yamlString(_ text: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-~+@"))
        return text.unicodeScalars.allSatisfy(safe.contains) ? text : jsonString(text)
    }

    /// A path for zsh: bare when it has nothing the shell would read, else in
    /// single quotes.
    static func shellQuoted(_ text: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+@%:,="))
        guard text.unicodeScalars.contains(where: { !safe.contains($0) }) else { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
