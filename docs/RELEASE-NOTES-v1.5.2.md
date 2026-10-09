# MCPBAR v1.5.2

**2026-09-24** — One new feature.

macOS 26+, Apple Silicon.

---

## New: Different on purpose

Some servers are set up differently in each agent on purpose. A `feed`
server, say: every agent has its own Feed key and its own small launcher script.
MCPBAR flagged it as "set up differently" all the time, and pausing it to
quiet the note also stopped the health checks.

- **Right-click a server that is set up differently and choose "Different on
  Purpose".** It works in the Servers tab, inside an agent on the Agents tab,
  and as a button in the card's yellow "Set up differently" box.
- **What changes:** the server leaves *Needs you*, loses its yellow note, and
  no longer counts in the summary line, the footer, the menu bar ring, the
  Agents tab or `mcpbar_problems`.
- **What doesn't:** MCPBAR still checks it. If it breaks, it shows as broken
  like any other server.
- **It notices changes.** MCPBAR saves a short fingerprint of each agent's
  command or address (never keys, env or header values). If an agent is added
  with a new setup, or one is removed or changed, the note comes back on its own.
- **Undo:** the card shows a quiet "Different on purpose" line with **Undo**,
  and the right-click item becomes **Flag Differences Again**. Settings >
  Servers shows a small check mark next to these servers.
- **For agents:** `mcpbar_server` says "Set up differently on purpose
  (acknowledged)" for such a server.

Everything else is v1.5.1 (see `docs/RELEASE-NOTES-v1.5.1.md`).
