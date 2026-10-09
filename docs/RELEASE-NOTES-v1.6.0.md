# mcpock v1.6.0

**2026-09-26** — MCPBAR is now **mcpock**. Same app, same panel, new name
(it now lives at mcpock.com). Your settings come over on their own; your agents
need one small update.

macOS 26+, Apple Silicon.

---

## Changed: the app is now called mcpock

Menu bar, Finder, window titles, the DMG, the docs and the commands all say
**mcpock** now, lowercase everywhere. The app moves to
`/Applications/mcpock.app`.

## New: your settings come over on their own

The first time you launch mcpock, it copies your pins, hidden and paused
servers, marked-as-intended notes, theme, check interval, panel filter and
scroll-bar choice from the old MCPBAR straight over. It only ever reads the
old settings, never writes or deletes them, and it only does this once — so
the old app's settings are still there, untouched, if you ever need them.

## Changed: agents must use the new `mcpock` MCP server

The bundled read-only MCP server is now named **mcpock**, with tools
`mcpock_status`, `mcpock_problems` and `mcpock_server`, served by the helper
at its new path:

```
/Applications/mcpock.app/Contents/Helpers/mcpock-mcp
```

Say "check my mcpock" instead of "check my mcpbar". Settings > Connect >
**Copy for Claude** now hands Claude Code a prompt that adds the `mcpock`
server for you, the same easy way as before.

**The old `mcpbar` entry keeps working for now** — this app still recognises
it in "Ask an Agent" — but only while the old MCPBAR app is still on this
Mac. Once it's gone, an agent still pointed at the old entry or the old
helper path loses the connection, so re-add it as `mcpock` when you get the
chance; the Connect tab's prompt does the whole thing for you.

## Fixed: the real crash reason

When a server crashed, its reason showed only the last lines of the error.
For a Node crash, those are just `at ...` lines that don't say what went
wrong. Now the first line that names the error comes first, for example:

```
Non-zero exit (1) — Error: Could not locate the bindings file — at async main (…/index.js:146:7)
```

Python errors, whose cause is already at the bottom, show as before. Keys and
tokens stay hidden.

---

Everything else is v1.5.4 (see `docs/RELEASE-NOTES-v1.5.4.md`).
