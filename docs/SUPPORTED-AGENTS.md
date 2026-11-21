# Supported agents

Which agents' config files mcpock reads, in which format, and how it treats special cases. Back to the [README](../README.md).

mcpock reads these files directly. Anything else that writes one of the
standard formats (JSON `mcpServers`, `servers` or `mcp`; TOML
`[mcp_servers.*]`; YAML `extensions:` or `mcp_servers:`) in `~/.config`,
`~/Library/Application Support` or a hidden folder in your home folder is found
by the scan, with no code change. A server from a file only the scan found shows
**Waiting for your OK** until you choose **Allow this file** once (on its card, or
right-click the row): mcpock never starts a command from a file no agent it knows
reads without your OK. An update from a version before 1.10.9 keeps the files
that version already checked, once; after that, a file whose commands or env
change asks again.

| Agent | Config file | Format |
|-------|-------------|--------|
| Claude Code | `~/.claude.json` (global and per-project servers), and `.mcp.json` files the scan finds, but only inside `~/.config`, `~/Library/Application Support` or a hidden folder in your home folder, not in ordinary project folders (only the servers you approved in Claude Code) | JSON |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | JSON |
| Cursor | `~/.cursor/mcp.json` | JSON |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` | JSON |
| Antigravity | `~/.gemini/config/mcp_config.json` | JSON |
| Cline | `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json` | JSON |
| Continue | `~/.continue/config.json` | JSON |
| VS Code | `~/Library/Application Support/Code/User/mcp.json` (`servers`) | JSON |
| Codex / ChatGPT desktop | `~/.codex/config.toml` | TOML |
| Grok | `~/.grok/config.toml` | TOML |
| Grok Bot | `~/.grokbot/settings.json` (`mcpBoxServers`, names only) | Settings |
| Goose | `~/.config/goose/config.yaml` (`extensions:`) | YAML |
| Hermes | `~/.hermes/config.yaml` (`mcp_servers:`) | YAML |
| Kimi Code | `~/.kimi-code/mcp.json` | JSON |
| MiniMax | `~/.minimax/mcp.json` | JSON |
| OpenCode | `~/.config/opencode/opencode.json` (`mcp`) | JSON |
| aka | Asked from aka's local helper (`127.0.0.1:6464`) while aka runs | API |
| Tinycast | `~/Library/Preferences/com.tinycast.app.plist` (`mcpServers`) | Settings |

Notes: servers turned off with `enabled: false` are skipped. `${VAR}`,
`${env:VAR}` and `${workspaceFolder}` are filled in before a check, from
mcpock's own environment and the project folder. A server whose command, args,
URL or headers use one mcpock can't fill (like `${input:...}`) reads **Not
checked**; in an env value it stays as written and the server still starts,
because most servers start without their key and ask for it only when a tool
runs. Servers marked
`"builtin": true` (they run inside their own app) are shown
but never started. **aka** keeps its servers in its own database, so mcpock
asks aka's local helper for the list (only when aka itself is the program on
that port) and starts each server the way aka does;
because aka launches servers its own way, it never counts toward "set up
differently". If aka asks for access before listing its servers (a newer aka
wants a token mcpock does not have yet), aka shows as **Needs access**. **Tinycast** keeps its servers in its own settings and their
keys and sign-ins in its own Keychain items, which mcpock never reads: a
Tinycast server that needs one shows as managed by its app, the others are
checked like any other. **Grok Bot** keeps its connectors in your Grok account and runs them on its
own computers; its settings file holds at most their names, so mcpock lists
those under Grok Bot and never starts them. Nothing on this Mac lists the rest,
so Grok Bot is listed in Settings > Agents once installed (its app or
`~/.grokbot`), and with an empty list it reads **Not visible here**: check its
connectors in Grok Bot's own settings. It joins the panel's Agents tab only
when it has names to list. A remote server
written as `serverUrl` (Antigravity, Windsurf) is read like `url`. Thirty-one agents have their real logo in the app (Grok Bot since 1.12.2); others show two
letters.
