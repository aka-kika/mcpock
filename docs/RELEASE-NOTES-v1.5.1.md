# MCPBAR v1.5.1

**2026-09-24** — Bug fixes for v1.5.0, found by the first "check my mcpbar" run.

macOS 26+, Apple Silicon.

---

## Fixes

- **Hermes servers with long paths showed as broken.** Hermes wraps a long value
  onto the next line, like `command: /Applications/Safari Technology` followed by
  `Preview.app/Contents/MacOS/safaridriver`. That is valid YAML, but MCPBAR read
  only the first line, so safari-mcp-stp tried to start `/Applications/Safari
  Technology` and failed. MCPBAR now joins the lines the way YAML does. The same
  bug hid servers whose value starts on the line after `command:`
  (two such servers never showed for Hermes).
- **The YAML reader now handles the rest of YAML's multi-line text too:** quoted
  text over several lines, `|` and `>` blocks, `[ ]` / `{ }` lists over several
  lines, and comments. Still no YAML library: MCPBAR keeps zero dependencies.
  Goose and Hermes both use this reader.
- **MiniMax servers looked "set up differently" when they weren't.** MCPBAR read
  `~/.minimax/mcp/mcp.json` as a MiniMax config, but MiniMax only loads
  `~/.minimax/mcp.json`. The other file is now skipped, and Settings > Connect and
  Copy for Claude name only `~/.minimax/mcp.json`.
- **Refresh starts spinning right away.** The refresh button used to wait about a
  second (while MCPBAR looked for configs) before it spun, so it looked stuck.
  Now it spins and the footer says "Checking…" the moment you click, and keeps
  going until the whole check is done.

Everything else is v1.5.0 (see `docs/RELEASE-NOTES-v1.5.0.md`).
