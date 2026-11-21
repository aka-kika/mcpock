# FAQ, troubleshooting and uninstalling

Back to the [README](../README.md).

## FAQ and troubleshooting

**macOS asks for permission to open a folder.**
One of your servers runs from Documents, Desktop or Downloads, and mcpock has
to start it there. Allow it once; it sticks. mcpock's own scan never looks in
those folders.

**A server shows broken. What now?**
Click it. The card shows the real error: "command not found" (the program isn't
installed, or isn't on the PATH mcpock uses: it adds `/opt/homebrew/bin`,
`/usr/local/bin` and `~/.local/bin`; use a full path in the config if needed),
"Quit on start (exit …)" when the process never answered initialize, or "Quit after starting (exit …)" when it dies after a good start (often a missing API key; the card shows the server's own error text), or
no answer in time (20 seconds for a local server, tried twice; 10 seconds for
a remote one). Copy the error, fix it in the agent's config, then
Check again.

**It says "Needs sign-in".**
The server answered with HTTP 401 or 403 although its config sends a token
header: the token is likely wrong or expired. Fix the header in the config.
mcpock never signs in for you, so this state doesn't turn red.

**It says "Signed in by the agent".**
The server answered with HTTP 401 or 403 and its config has no token header:
you signed in inside the agent (OAuth), and the agent keeps that sign-in to
itself. Nothing is wrong, mcpock just can't check this server. It shows a
calm dash and stays out of Needs you.

**What does "set up differently" mean?**
The same server name launches a different command, script or address in one
agent than in the others. Sometimes that's intended; often it is an old path.
**Compare** on the card shows each version (secret values hidden).

If it's intended (say each agent has its own key and its own small launcher
script), click **Mark as intended** in the card's yellow box, or right-click
the row and choose **Mark as Intended**. The row stops counting as a problem, but
mcpock keeps checking it and still shows real errors. mcpock remembers how the
agents were set up at that moment (a short fingerprint of each command or
address, never keys or env values), agent by agent. If an agent's setup
changes later, or a new agent sets it up another way, the note comes back on
its own for that agent; an agent you remove keeps the mark quiet. The card then shows a quiet "Marked as intended" line;
**Undo** there, or **Unmark as Intended** in the right-click menu, takes it
back.

**A login page or an app opens every time mcpock checks.**
Starting that server has a side effect. Right-click it and choose **Pause checks**:
mcpock won't start it again until you resume it.

**The grey dash?**
Either you paused the server, or it runs inside its own app (marked
`"builtin": true`) and can't be checked from outside, or the agent signed in to it,
or it is Not checked because a `${VAR}` in its config cannot be filled. None of these
counts as a problem.

**I added a server and it doesn't show.**
Click **Refresh** in the footer: it looks for configs again and checks
everything. A save in a config mcpock already knows (or a scan file it is allowed to read) is checked within seconds, unless checks are Manual. A file in a new place is found at launch or on Refresh; the timer re-reads only the files it already knows.

**My agent says mcpock isn't running or hasn't checked yet.**
Make sure mcpock is running (start it from Applications if its icon isn't in
the menu bar). It starts checking at launch and writes the status file once the
first check is done, then ask again.

**Hidden servers?**
Still checked, just not listed. A hidden server that breaks comes back to the
panel until it works again. Change it in Settings > Servers.

## Uninstalling

1. In each agent's MCP config, remove the `mcpock` entry you added in
   **Connect your agents** (in the README) (mcpock did not add it for you). If you turned a
   server off with mcpock, turn it back on first: one turned off for Claude
   Desktop or Cursor waits in `~/Library/Application Support/mcpock/parked/`.
2. In mcpock, open Settings > General and turn **Open at Login** off.
3. Quit mcpock from its menu bar icon.
4. Delete `mcpock.app` from Applications.
5. Optional, to remove what it left behind (open Finder, press Shift+Cmd+G, and
   paste each path):
   - `~/Library/Application Support/mcpock` (the status and usage files)
   - `~/Library/Preferences/com.mcpock.app.plist` (your settings)
   - `~/Library/Group Containers/P5RB3W3D58.com.mcpock` (shared with the widgets)
