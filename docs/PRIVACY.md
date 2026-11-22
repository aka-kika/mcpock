# Privacy and safety

What mcpock runs, reads, writes and sends. Back to the [README](../README.md).

- **It changes a config only when you flip a switch.** The switch beside an
  agent on a server's card turns that server on or off there. mcpock shows you
  the change first, saves a copy of the file in
  `~/Library/Application Support/mcpock/backups/` (the newest 60; they hold
  what the config holds, keys included, readable only by you), then replaces
  the file in one step. It uses the agent's own way: Claude Code's blocked
  list, the `enabled` line in Codex, Grok, Goose, Hermes (its profiles too)
  and OpenCode, the `disabled` line in Cline. Claude Desktop, Cursor, VS Code
  and Windsurf have none, and an app that rewrites its own file can drop
  what it does not know (Claude Desktop does), so for these four the entry
  waits in `~/Library/Application Support/mcpock/parked/` (readable only by
  you) and moves back when you turn it on. The switch beside a tool hides
  that tool the same way, in the agent's own setting: Claude Code's deny list,
  `disabled_tools` in Codex, Grok's `disabled_mcp_tools`, `tools: exclude` in
  Hermes, `available_tools` in Goose, a deny rule in OpenCode. Nothing is
  deleted, and agents can't flip a switch: they can only ask, and your Yes
  goes through the same sheet.
- **The tool filter, for agents that can't hide single tools.** Cursor, Claude
  Desktop, VS Code, Cline and Windsurf have no setting for that. If you press
  **Set up** on a server's card, mcpock changes that server's entry in the
  agent's file, through the same sheet and backup: the entry then starts
  mcpock's helper (`mcpock.app/Contents/Helpers/mcpock-mcp filter`), with the
  server's own command and arguments inside it, word for word; its keys stay
  where they are. The helper starts the server, passes every message both ways
  unchanged, leaves the tools you turned off out of the server's tool list,
  and refuses a call to one of them. It keeps no log and opens no connection
  of its own. The list of hidden tools is a small file in
  `~/Library/Application Support/mcpock/filter/`; tool switches for a
  filtered server write only that file. **Remove** on the card puts the entry
  back as it was. Only for servers that run as a command. The entry holds the
  path of mcpock.app, so remove the filter before you move or delete mcpock:
  until then the agent can't start that server, and mcpock shows it as broken
  and says why.
- **Your own server icons are read, never sent.** Pictures you put in
  `~/Library/Application Support/mcpock/ServerIcons/` are only drawn in the
  panel. mcpock never writes there.
- **Everything else only reads.** "Open Config…" asks first, with Cancel as
  the default.
- **What it runs.** To check a local server, mcpock starts the exact command
  from your config, with its arguments and environment, in its project folder
  when it has one: the same thing your agent runs. It does the handshake, asks
  for the tool list, then stops the process and all its child processes.
  Remote servers get the same few requests over HTTP. Paused servers are never
  started.
- **Claude account connectors are off until you turn them on.** With "Include
  claude.ai connectors" on (Settings > Agents), mcpock runs `claude mcp list`
  to ask Claude Code which connectors your account has and what state they
  are in. Claude Code starts its own servers to answer and talks to
  claude.ai as it always does, so mcpock asks at most every 30 minutes, and
  when you press Refresh. mcpock keeps each connector's name, host and state
  (never the rest of its address, which can hold a key) and reads which
  projects switched one off from `~/.claude.json`. It never changes a
  connector.
- **Agents managed online are links.** The rows for Grok web, ChatGPT, Cursor
  cloud and Gemini open the vendor's page in your browser. mcpock does not
  sign in to them, read them or check them; the server names shown there are
  the ones you typed in Settings.
- **Secrets are masked.** The status file for agents holds env and header
  **names**, never their values. Anything that looks like an API key in
  command lines, URLs, server replies and error texts is masked wherever
  mcpock shows or stores it.
- **Network stays narrow.** mcpock's own connections are to the remote MCP
  servers in your configs, to aka on your own Mac if you use it, and
  to mcpock.com to check for app updates (Settings > About). With connectors
  turned on, the `claude` command it runs talks to claude.ai itself. No
  accounts, no analytics, nothing else phones home.
  mcpock calls a remote server the way your config says, `http://` too. A
  server whose config sends keys over plain `http://` to another machine
  gets a warning on its card: anyone on that network can read those keys.
- **Updates are signed, and you're asked before the first automatic check.**
  mcpock checks mcpock.com for a newer version (Sparkle, its one dependency —
  see [THIRD-PARTY.md](THIRD-PARTY.md)); every update is verified
  against a key only the maintainer holds before it installs. Turn automatic checks off
  any time in Settings > About; "Check for Updates…" there always works.
- **Usage counts read, never keep, your chats.** To count calls, mcpock reads
  the agents' own history files and databases (read-only) and keeps only the
  agent, the server name and the day, in `~/Library/Application
  Support/mcpock/usage.json`, plus what it needs to never count a call twice:
  for each history file a hashed key, how far it has read and the time of the
  newest call it counted, and for Cursor the record keys of recent calls with
  their times. Never a message, an argument, a result or a file path.
  They are off until you turn on **Usage counts** in Settings > General, and
  turning them off stops the reading.
- **Session logs, read only.** To spot a server lost in an open Claude Code
  session, mcpock reads `~/.claude/sessions/*.json` (which sessions run, and
  in which folder) and those sessions' lines in Claude Code's own MCP logs
  (`~/Library/Caches/claude-cli-nodejs`), looking only at connect and failure
  lines. Nothing is kept or sent.
- **Where it looks.** Only known config paths and the usual config folders.
  The scan never looks inside Documents, Desktop or Downloads, and it skips
  symbolic links so it can't be led anywhere else.
- **Why no App Store.** The App Store sandbox would stop mcpock from starting
  servers and reading configs in your home folder, so it ships as a signed,
  notarized download instead.
