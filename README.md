# mcpock

<p align="center">
  <a href="#install"><img src="https://img.shields.io/badge/macOS-26%2B-555?logo=apple" alt="macOS 26 or later"></a>
  <a href="docs/DEVELOPING.md"><img src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white" alt="Swift and SwiftUI"></a>
  <a href="#install"><img src="https://img.shields.io/badge/signed%20%26%20notarized-Developer%20ID-6b8e6b" alt="Signed and notarized by Apple"></a>
  <a href="#connect-an-agent"><img src="https://img.shields.io/badge/MCP-5%20tools-7a8fb0" alt="MCP server with 5 tools"></a>
  <a href="docs/THIRD-PARTY.md"><img src="https://img.shields.io/badge/dependencies-1%20(Sparkle)-6b8e6b" alt="One dependency: Sparkle"></a>
  <a href="docs/release-notes/1.18.0.md"><img src="https://img.shields.io/badge/version-1.18.0-7a8fb0" alt="Version 1.18.0"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-888" alt="MIT License"></a>
</p>

<p align="center"><a href="https://mcpock.com">mcpock.com</a> · <a href="https://github.com/aka-kika/mcpock/releases/latest">latest release</a></p>

A native macOS menu bar app that checks every MCP server your AI agents use and tells you which ones are broken, slow, waiting for a sign-in, or set up differently from one agent to the next. MCP (Model Context Protocol) servers are the small programs that give agents like Claude Code, Cursor or Codex their extra tools. mcpock knows where 18 agents keep their servers, finds them, starts each one the way the agent would, and checks that it answers. It changes a config only when you flip a switch, and shows you the change first.

![mcpock's panel on the Servers tab (made-up demo servers): the ones that need you come first, one broken, one slow, one waiting for a sign-in, one set up differently, each with a health shape, the logos of the agents that use it and its tool count. Beside it, the card of the server that needs a sign-in, with why, Ask an agent and Copy errors, and below the card the Problems desktop widget listing the same four servers.](docs/images/mcpock-servers.png)

- macOS 26 or later, Apple Silicon. Lives in the menu bar only: no Dock icon, no window.
- Swift and SwiftUI, one dependency (Sparkle, for signed updates).
- Reads Claude Code, Claude Desktop, Cursor, Windsurf, Codex, Grok, Goose, Hermes, OpenCode, VS Code and more, plus any standard MCP config it finds.
- Ships its own small MCP server, so you can say "check my mcpock" to an agent.

## Problems first, in plain words

When you use more than one agent, the same MCP server ends up in several config files, each written a little differently. One day a tool quietly stops working in one agent and not the others, and the agent rarely says why. mcpock gives you one place to look.

It starts each local server (or calls a remote one), does the MCP handshake, asks for its tool list, then stops it. It does this every 15 minutes by default (1 minute to 4 hours, or only when you click Refresh), and checks a server again within seconds when you save its config. Health shows as a shape, not only a colour:

| Shape | Means |
|-------|-------|
| Filled dot (green) | Fine: it started and listed its tools |
| Ring (amber) | Slow (no answer in 20 s, tried twice; 10 s for a remote server) or needs sign-in (HTTP 401/403) |
| Ring (grey) | Still checking |
| Diamond (red) | Broken: could not start, quit on start, or refused the handshake |
| Dash (grey) | Paused by you, runs inside its own app, signed in by the agent, a `${VAR}` it cannot fill, or its Mac app is closed |

The list starts with *Needs you*, then your pinned servers, then everything else. Click a row for its card: the full error with **Copy errors** and **Ask an agent**, which agents use the server and where their configs live, its tools, and **Check again**, **Pin** and **Hide**. The menu bar icon stays plain while all is fine; no numbers, no blinking, no notifications. Control-Option-M opens the panel from any app, and the arrow keys, Return, Cmd-F and Cmd-R work as you would expect.

## One row per agent

![mcpock's Agents tab (made-up demo servers): one row per agent with a small health bar and how many of its servers need you; agents with nothing wrong are listed below, faded. On the left, the Status desktop widget (4 need you, 14 servers) and the Agents widget with a health bar per agent.](docs/images/mcpock-agents.png)

The panel opens on the **Agents** tab: one row per agent with a small health bar, the agents that need you first. Open one to see its servers and its config file. Turn on **Usage counts** in Settings > General to see how many times each agent called each server in the last 30 days, and each tool's calls on a server's card (read from Claude Code, Grok, Cursor and Hermes history on your Mac; off until you turn it on).

Desktop widgets show the same at a glance: **Status** (small), **Problems** and **Agents** (medium). Right-click the desktop, **Edit Widgets…**, and search for mcpock.

## Set up differently, side by side

When one agent launches a different command or address for the same server than the others (often an old path), the row says so, and **Compare** on the card shows each agent's version side by side, with secret values hidden. The same runtime in another folder is not a difference. If the agents are meant to differ, choose **Mark as intended**; the note comes back by itself if an agent's setup changes later.

When a server drops inside a Claude Code session that is still open, its row says "Lost in 1 open Claude Code session: run /mcp there", even while mcpock's own check reaches it.

## You flip the switches

A switch beside each agent on a server's card turns that server on or off there, and a switch beside each tool hides that tool from your agents. mcpock uses each agent's own setting for this (Claude Code's blocked and deny lists, `enabled` and `disabled_tools` lines in Codex, Grok, Goose, Hermes and OpenCode), shows you the change first and saves a backup of the file. Nothing is deleted, and one click turns it back.

Agents can't flip a switch. They can only ask: an ask shows on the server's card with its reason and Yes and No, and only your Yes changes anything, through the same sheet. Everything else mcpock does only reads.

## Connect an agent

mcpock includes `mcpock-mcp`, a small MCP server that only reads the status file mcpock writes after each check. It never starts a server and never changes a config.

**The easy way:** Settings > **Connect** > **Copy for Claude**, then paste into Claude Code. **By hand:** Settings > Connect shows which agents already have mcpock, with the right line for each. For Claude Code:

```bash
claude mcp add --scope user mcpock -- /Applications/mcpock.app/Contents/Helpers/mcpock-mcp
```

For agents that use `mcpServers` JSON (Claude Desktop, Cursor, Windsurf, Cline and most others):

```json
{
  "mcpServers": {
    "mcpock": {
      "command": "/Applications/mcpock.app/Contents/Helpers/mcpock-mcp",
      "args": []
    }
  }
}
```

Then ask your agent to "check my mcpock". The tools it gets:

| Tool | Answers |
|------|---------|
| `mcpock_status` | Counts: how many servers are fine, broken, slow, need a sign-in or are set up differently, and when mcpock last checked |
| `mcpock_problems` | Every server that needs attention, with the reason, the agents and the config files involved |
| `mcpock_server` | Everything about one server, by name, with each tool's calls and last use (when Usage counts are on) |
| `mcpock_switches` | Which servers are turned off, and in which agents, which tools are hidden, and what became of each ask |
| `mcpock_ask` | Asks you to hide or show a tool, or turn a server off or on, with a reason. Changes nothing by itself |

The first four only read. Secrets are masked. If mcpock isn't running, hasn't checked yet, or its results are old, the answer says so.

## Privacy

- To check a local server, mcpock runs the exact command from your config, the same thing your agent runs, then stops it and its child processes. Paused servers are never started.
- The only network connections are to the remote MCP servers in your configs and to mcpock.com to check for updates. No accounts, no analytics.
- Anything that looks like an API key is masked wherever mcpock shows or stores it. The status file for agents holds env and header names, never their values.
- Usage counts keep only the agent, the server name and the day: never a message, an argument, a result or a file path.
- Why no App Store: its sandbox would stop mcpock from starting servers and reading configs in your home folder.

Every detail: [docs/PRIVACY.md](docs/PRIVACY.md).

## Install

```bash
brew install --cask aka-kika/tap/mcpock
```

Or download `mcpock.dmg` from [mcpock.com](https://mcpock.com) or the [Releases](https://github.com/aka-kika/mcpock/releases) page, open it and drag **mcpock** to Applications. It is signed and notarized by Apple and updates itself (Sparkle; you are asked before the first automatic check).

Needs macOS 26 or later on Apple Silicon. Launch it and look for its icon in the menu bar. If one of your servers lives in Documents, Desktop or Downloads, macOS asks whether mcpock may open that folder: click **Allow**, since mcpock has to start the server from there. Turn on **Open at Login** in Settings > General if you want it always there.

## Docs

- [docs/SUPPORTED-AGENTS.md](docs/SUPPORTED-AGENTS.md): every agent mcpock reads, its config file and format, and the special cases.
- [docs/PRIVACY.md](docs/PRIVACY.md): what mcpock runs, reads, writes and sends.
- [docs/FAQ.md](docs/FAQ.md): what each state means, what to do about it, and how to uninstall.
- [docs/DEVELOPING.md](docs/DEVELOPING.md): build, test, how it works, adding an agent, release.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): the module map, one refresh step by step, the rules that must not regress.
- [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md): Sparkle and the agent logos, with their licenses.
- [docs/release-notes/](docs/release-notes/): what changed in each version.

## Release

Each version's notes are in [docs/release-notes/](docs/release-notes/); the newest is [1.18.0](docs/release-notes/1.18.0.md). Signed and notarized DMGs are on the [Releases](https://github.com/aka-kika/mcpock/releases) page and mcpock.com. How a release is built: [docs/DEVELOPING.md](docs/DEVELOPING.md#release).

## Thanks

mcpock's interface was shaped by studying these open-source Mac apps, found and kept with [reshelf](https://github.com/aka-kika/reshelf), the author's app for collecting repos. Thank you to their authors:

- [RepoBar](https://github.com/steipete/RepoBar) by @steipete: dashboard rows, detail on demand, pinned and hidden in Preferences.
- [Skills Manager](https://github.com/yibie/skills-manager) by @yibie: the "which agent uses what" view and showing set-up-differently states.
- [mectrics](https://github.com/farukkamcici/mectrics) by @farukkamcici: a quiet menu bar icon that only speaks up when something's wrong.
- [cctop](https://github.com/st0012/cctop) by @st0012: sorted by what needs you, keyboard first.
- [AgentBar](https://github.com/michalstrnadel/AgentBar) by @michalstrnadel: real agent marks instead of text.
- [Hop](https://github.com/antonyshakirov/hop) by @antonyshakirov: tabs in a menu bar panel.
- [TokenMon](https://github.com/faulknerpearce/token_monitor) by @faulknerpearce: a section per agent with a small bar.

In-app updates run on [Sparkle](https://sparkle-project.org) (MIT). Agent logos come from [LobeHub Icons](https://github.com/lobehub/lobe-icons) (MIT) and [Simple Icons](https://github.com/simple-icons/simple-icons) (CC0); they are trademarks of their owners, and mcpock is not affiliated with or endorsed by any of them. Details: [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md).

## Contributing

Issues and pull requests are welcome. mcpock is small on purpose: read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## License

MIT. See [LICENSE](LICENSE).

---

Made by **Kika** ([aka-kika](https://github.com/aka-kika), [akakika.com](https://akakika.com)).
