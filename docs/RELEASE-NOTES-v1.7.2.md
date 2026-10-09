# mcpock v1.7.2

**2026-09-26** — Folded lists say how much is folded.

macOS 26+, Apple Silicon.

---

## Changed: "+N more" instead of "Show more"

Under an open agent in the Agents tab, and under a server card's tools,
the folded rest now reads **+23 more** (the real count), like **+1 more**
under "Used by". Opened, it still says **Show less**.

## Fixed: the fold lines up with the server names

Under an open agent, **+N more** now starts on the same line as the server
names above it. It sat a little to the left.

## Behind the scenes

- The HTTP tests that once hung CI for 14 minutes now fail within seconds
  when something gets stuck.
- Debug and test builds use their own app id (`com.mcpock.app.debug`), so
  running the tests no longer moves Open at Login off `/Applications`.

Everything else is v1.7.1 (see `docs/RELEASE-NOTES-v1.7.1.md`).
