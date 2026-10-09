# MCPBAR v1.5.0

**2026-09-24** — A new look for the panel: you
scan it instead of reading it.

macOS 26+, Apple Silicon.

---

## The panel

- **Problems come first.** The list has three parts: **Needs you** (broken, then
  slow or waiting for a sign-in, then set up differently), **Pinned**, and
  **Everything else**.
- **Each row shows its health as a shape**, not only a colour: a filled circle is
  fine, a ring is slow, a diamond is broken, a small dash is paused or runs inside
  its own app. Rows that need you get one short line saying why ("Could not start:
  command not found", "Needs sign-in").
- **Agent logos** show who uses each server: each agent's real logo, small and
  in one quiet grey. Thirty agents have one (Claude Code, Claude Desktop, Cursor,
  Codex, VS Code, Cline, Gemini CLI, Qwen Code, Kiro, Trae, Roo Code, Kilo Code,
  Junie, Amp, Zed, Warp, JetBrains, Raycast, LM Studio, Cherry Studio,
  Perplexity, ChatGPT, Goose, Grok, Hermes, Kimi, MiniMax, OpenCode, Windsurf
  and the shared `mcp` config). Agents without a logo show two letters.
  A number on the right shows how many tools it has.
- **The top is just two tabs:** Servers and Agents.
- **One thin footer**, like 1.4: a short summary on the left ("44 · 5 broken ·
  1 sign-in · 7 differ", or "44 servers, all fine"), then four small buttons:
  - **Needs you** (the exclamation mark): pressed shows only what needs you,
    unpressed shows everything. While it's off and something needs you, it takes
    that problem's colour. If something is broken when you open the panel, it
    turns on by itself, unless you pressed it yourself.
  - **Search** (the magnifier, or Cmd-F): opens a search field under the tabs. It
    finds servers, agents and tool names. Escape or Return closes and clears it.
  - **Refresh:** spins while any check runs, and the summary says "Checking…".
  - **Settings** (the gear).
- Hover the summary for the full sentence, when the last check ran and how many
  servers are hidden.
- Servers that are not checked yet stay in their normal place.

## The detail card

Click a row and a card opens next to the panel. It shows:

- the full error, with a **Copy error** button,
- which agent is set up differently, and a **Compare setups** view that puts each
  agent's command or address side by side (secret values stay hidden),
- which agents use the server, each with its logo and config file (4 shown, "+n more" for
  the rest); right-click a file to show it in Finder or copy its path,
- the server's tools; **"+n more"** opens a second window next to the card with
  every tool and its short description (click it again, or Escape, to close it),
- **Check again**, **Pin** and **Hide** as small icon buttons (hover for the
  words; Hide can be undone for 5 seconds).

Arrow keys move through the list, Return opens the card, Escape closes it.

**Right-click any server** (in Servers or inside an agent) for Check again,
Pause, Pin, Hide, **Copy error** (when there is one), **Copy server name** and
Copy server details. Right-click an agent (or any config path) for **Show in
Finder**, **Copy Path** and, last, **Open Config…**. Opening asks first: one
accidental save in a config can break an agent, so there is no open button and
no double-click anywhere.

## The Agents tab

One row per agent, the ones with problems first, each with its logo in a small
grey circle (the same logos as the list; two letters when there is no logo).
Every agent starts closed. The one you open stays open, also the next time you
open the panel (until MCPBAR quits).
Each has a small bar showing
broken, needs-you and fine servers. Open an agent to see **all** its servers,
problems first, each with its health and a short reason, plus its config file.
Click a server to open its card right there, like in Servers. The **Needs you**
button works here too (it is the same button, so it stays the same on both
tabs): pressed, only agents with problems show, and only their problem servers.

**aka** (a desktop agent app) shows up as an agent too: MCPBAR asks aka's
local helper for its servers and starts each one the way aka does (npm
packages through `bun x`). If aka isn't running, it simply isn't listed. aka
always sits at the bottom of the list. It starts servers its own way, so it
never counts toward "set up differently"; its real errors still show.

## Preferences

Five tabs, laid out like macOS System Settings (grouped sections), in a
narrower window (540 wide):

- **General:** Appearance (System, Dark, Light), **hide scroll bars** (on by
  default; lists still scroll), **Check servers** as a slider that snaps to
  1 min, 5 min, 15 min, 30 min, 1 h, 4 h or Manual (it drags smoothly and
  glides to the nearest stop when you let go; the value beside it never jumps
  or wraps; old choices keep working), Open at Login, and a **Status** section: when the
  last check ran, what was found (servers and agents), Copy All / Export for
  errors, and the status file agents read (right-click it for Show in Finder).
- **Servers:** set each server to Pinned, Shown or Hidden with three small
  icons (pin, eye, crossed eye; hover for the words). Pinned servers get their
  own section at the top of the list. Hidden servers are still checked, and
  MCPBAR still tells you if they break.
- **Agents:** every agent MCPBAR found, with its logo and config file.
  Right-click a file for **Show in Finder**, **Copy Path** and **Open Config…**.
- **Connect (new):** let your agents read what needs attention, so you can say
  "check my mcpbar" instead of copy-pasting errors. MCPBAR now ships a small
  read-only MCP server (`mcpbar-mcp`, inside the app). The main button is
  **Copy for Claude**: a prompt for Claude Code that finds every agent config
  on your Mac, backs each one up, adds MCPBAR where it's missing (in each
  file's own format), checks it works and ends with a short table. After a
  click it turns Claude orange and says "Copied" for a moment. Below, the
  helper's path and one copy icon per agent with the right setup: JSON for
  Claude Desktop, Cursor, Windsurf, Cline, Kimi Code, MiniMax and others, a
  Terminal command for Claude Code, TOML for Codex and Grok, YAML for Goose and
  Hermes, and what to enter in aka. A checkmark shows for a moment after a
  copy. MCPBAR itself still never edits another app's config.
- **About (new):** icon, version, what MCPBAR does, Made by Kika, and links to
  akakika.com, X and GitHub.

The gear in the panel's footer opens General.

## For agents: the mcpbar server

- Three read-only tools: `mcpbar_status` (counts), `mcpbar_problems` (every
  broken, slow, needs-sign-in or set-up-differently server with its reasons,
  config files and agents), `mcpbar_server` (everything about one server).
- It only reads a status file MCPBAR writes whenever its results change:
  `~/Library/Application Support/MCPBAR/status.json` (plus `status.md`, the same
  report as text for agents without MCP). It never starts a server itself.
- **No secrets in the file:** environment and header values are never written
  (names only), and API keys in command lines, URLs and error texts are masked.
- If MCPBAR isn't running, hasn't checked yet, or the results are old, the
  answer says so.

## Menu bar icon

Plain when everything is fine. A small **ring** when something is slow, needs a
sign-in or is set up differently. A small **diamond** when something is broken.
No numbers, no blinking.

## Themes

Light uses the frosted macOS menu look, and Dark keeps the soft dark grey. The
panel, the card and Preferences all match. No bright blue inside the panel.

## Credits

Agent logos come from LobeHub Icons (MIT) and Simple Icons (CC0); they are
trademarks of their owners. See `docs/THIRD-PARTY.md`.

## Smaller fixes

- Config paths everywhere (the card's **Used by**, the Agents tab, Settings)
  have one right-click menu in one order: Show in Finder, Copy Path, then Open
  Config… last, which asks before opening. The old open buttons and
  double-click-to-open are gone.
- "Set up differently in Code" now reads "... in Claude Code".

- Goose servers now go by their config name (`wake`), not Goose's display title
  ("Wake (agent session history)"), so they group with the same server in the
  other agents instead of showing as a second row.
- Neve is no longer a known agent (the tool is gone).
- A `.mcp.json` file found on disk is now shown as Claude Code (for example
  "Claude Code (.claude)"), not as an agent called "claude".
- Timeouts read the same everywhere ("no answer in 10 s").
- A Claude Code project whose folder no longer exists (an archived project) no
  longer shows its servers as broken ("The file ... doesn't exist"); those
  entries are skipped. The same server in other places is still checked.
