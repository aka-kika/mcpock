# MCPBAR v1.0.0

The first public release. MCPBAR is a menu-bar macOS app that automatically
discovers every MCP server configured across your AI agents and health-checks
them on a timer — so a broken server is a glance away, not a surprise mid-task.

**Released:** 2026-07-11 · **Requires:** macOS 26+ · **Architecture:** Apple silicon (arm64)

## Highlights

<!-- SF Symbol: star -->
- **Automatic discovery** — no config to maintain. MCPBAR finds MCP servers across ~10 known agents (Claude Code, Claude Desktop, Cursor, Windsurf, Cline, Continue, VS Code, Grok, Codex, Goose) and, by recognizing the standard config *shapes*, any other agent on your Mac too. A new agent on the usual `mcpServers` JSON shows up with zero setup.
- **One row per tool, health at a glance** — the same server declared across several agents collapses to a single row (matched case- and separator-insensitively), with a green/amber/red dot and its available-tool count. Expand a broken row to see exactly which agent failed and why.
- **Fix-it affordances** — right-click a row to re-probe just that server, "Rescan for agents" after installing a new one, copy an error, or export every failing server to Markdown/JSON from Settings.

## Added

<!-- SF Symbol: plus -->
- Shape-based discovery: JSON `mcpServers` (+ Claude Code per-project), TOML `[mcp_servers.*]`, YAML `extensions:`; a bounded, TCC-safe filesystem scan for agents not in the built-in registry.
- Per-server "Refresh this server" and a "Rescan for agents" action.
- Settings → "Export errors…": save all failing servers as Markdown or JSON.
- Available-tool count badge on each server row.
- Health smoothing (a single transient timeout shows amber, not red) and stdio failure reasons that include exit code + stderr.

## Changed

<!-- SF Symbol: arrow.triangle.2.circlepath -->
- Discovery runs off the main thread and only at launch / "Rescan for agents" — the panel opens instantly and the 60-second timer only re-probes.
- The row badge now shows available tools rather than the number of agents (the sources still appear in the row's subtitle).

## Fixed

<!-- SF Symbol: wrench.and.screwdriver -->
- stdio message buffer no longer crashes on servers that print a large non-JSON banner before their first message (stack overflow), on leading whitespace before a message (index crash), or on a malformed negative `Content-Length`.
- Probes reap the whole process tree, so `npx` → `node` children don't leak.

## Known issues

<!-- SF Symbol: exclamationmark.triangle -->
- Agents that use a non-standard JSON key (Zed `context_servers`, VS Code `servers`) aren't auto-detected yet — a planned fast-follow.
- The `disabled` server flag isn't yet honored (a disabled server is simply probed like any other).

## Install

<!-- SF Symbol: arrow.down.circle -->
Download **MCPBAR.dmg** (~1.7 MB), open it, and drag MCPBAR to Applications. It lives in the menu bar (no Dock icon); left-click the icon for the panel, right-click for Settings / Quit.

**Checksum (SHA-256):** `32ee91e1c2092b8e0394c904bb85fb044c0cedc95fb40228e8418de776038731`

## Verify

<!-- SF Symbol: checkmark.seal -->
Signed with Developer ID (Veronica Loren, team P5RB3W3D58) and notarized by Apple. MCPBAR runs **outside** the App Store sandbox by design so it can spawn MCP servers and read your agent config files; it is distributed directly (notarized DMG), not via the Mac App Store.

## Full changelog

First public release — no prior tag.
