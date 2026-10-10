# mcpock v1.10.0

**2026-10-10** — A keyboard shortcut for the panel, and Check again
that sees your fix.

macOS 26+, Apple Silicon.

- **Control-Option-M opens the panel from any app.** Press it again, or
  Escape, to close it. The panel opens under the menu bar of the screen your
  pointer is on, then the arrow keys, Return and Escape work as before. On by
  default; turn it off in Settings > General. If another app already uses
  Control-Option-M, Settings says so and mcpock leaves it alone.
- **Check again sees your fix.** Check again now reads the config files again
  before it checks the server. Before, it re-ran the server the way it was set
  up before your edit, so a server you had just fixed stayed red until the
  next timer round or a full Refresh.
- **Cmd-R in the panel** checks the selected server again. With nothing
  selected, it checks every server, like Refresh in the footer.
