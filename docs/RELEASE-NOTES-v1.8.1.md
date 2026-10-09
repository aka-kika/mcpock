# mcpock v1.8.1

**2026-10-04** — Two fixes and one small addition.

macOS 26+, Apple Silicon.

---

## New: Copy All Problems on an agent

Right-click an agent in the Agents tab and choose **Copy All Problems**.
Every server that needs that agent's attention lands on the clipboard as
one block: the agent, its config file, then each server with that agent's
own error and command (secrets masked, like Copy Errors) or, for a server
set up differently, what differs. The item shows only when the agent has
a problem.

## Fixed

- **Rows stayed stale after a config change.** mcpock re-read the agents'
  config files only at launch and on Refresh, so a server you changed or
  removed kept its old row, old error and old backoff until then. Every
  timer round now re-reads the configs first: a changed server is checked
  again with its new setup right away, and a removed one disappears.
- **Some HTTP servers showed "No JSON in SSE stream" although they worked.**
  Servers that end their event-stream lines with CRLF (`\r\n`, for example
  Python servers built on sse-starlette) were read as one long line. mcpock
  now splits on any line ending.

## Also

- Signed with the new Developer ID certificate (valid to 2031).
- A hidden `--demo` mode for screenshots (fake servers, nothing of this Mac).
