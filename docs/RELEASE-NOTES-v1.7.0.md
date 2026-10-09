# mcpock v1.7.0

**2026-09-26** — Usage counts, a shorter server list under each agent,
and a fix for the first launch after 1.6.0.

macOS 26+, Apple Silicon.

---

## New: usage counts

Open an agent in the Agents tab: next to each server is how many times that
agent called it. Settings > General > **Usage** picks the window: **7 days**,
**30 days** (the default), **All time**, or **Off**.

- Counted from the agent's own history on your Mac: **Claude Code**,
  **Grok**, **Cursor** and **Hermes** (each Hermes profile counts on its own).
- A dash means that agent keeps no record mcpock can read yet. Where the
  other agents keep theirs: `docs/USAGE-SOURCES.md`.
- mcpock only reads those files, and keeps only the agent, the server and
  the day. Never a message, an argument or a result.
- The first count reads everything once in the background (about 20 seconds
  on a busy Mac), then only what's new.

## Changed: a shorter list under each agent

An open agent shows its first 5 servers, then **Show more**. Servers that
need you always show, however many there are. The arrow keys unfold the list
when they reach a hidden server.

## Fixed

- **Your hidden, paused and marked servers on the first launch after
  MCPBAR:** 1.6.0 copied your settings only after it had read them, so that
  one launch showed marked servers as problems again. A relaunch fixed it;
  now the first launch is right too.
