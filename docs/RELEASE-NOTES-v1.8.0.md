# mcpock v1.8.0

**2026-09-26** — Desktop widgets, a Glass theme, a new icon, and a round of fixes.

macOS 26+, Apple Silicon. The Glass theme's see-through panel needs macOS 27.

---

## New: desktop widgets

Right-click the desktop, choose **Edit Widgets…**, and search **mcpock**:

- **Status** (small): "All fine" or how many servers need you, and when
  mcpock last checked.
- **Problems** (medium): up to four servers that need you, in plain words
  ("needs sign-in", "not answering"), or "All 43 fine".
- **Agents** (medium): one row per agent with its logo, a small health bar
  and its server count, like the Agents tab.

The widgets update after every check mcpock runs, at most about once a
minute.

## New: the Glass theme

Settings > General > Appearance has a fourth choice, **Glass**: the panel,
the detail card and Settings use Apple's Liquid Glass. It follows light and
dark mode, and your own glass setting (System Settings > Appearance >
Liquid Glass: Clear or Tinted).

On macOS 27 the Glass panel is its own see-through window, so the glass
shows your real desktop instead of a white haze. It opens and closes like
the other menu bar menus: a click on the icon, a click anywhere else, or
Escape.

## New: the app icon

Server bars with a green check, in blue, with dark and tinted versions for
macOS's icon styles.

## Fixed

From a full review of the app before this release:

- A server sending a huge message size, binary noise, or a config with
  thousands of nested list levels could crash mcpock or keep a check busy
  until it timed out. These now fail cleanly.
- A server that exits at the wrong moment could end the whole app. Now its
  check just says broken.
- Cursor's usage counts stopped for good after Cursor's history was reset.
  They start over now.
- A named pipe with a `.json` name could stall the config scan forever.
- Legacy SSE servers left a connection open after each check.
- The Agents widget showed a plain dot for agent profiles ("Hermes · scribe")
  and project agents; they show their logo now.

## Faster

- The server list is built once per change instead of about ten times per
  screen update.
- Secret masking compiles its patterns once instead of on every use.

Everything else is v1.7.2 (see `docs/RELEASE-NOTES-v1.7.2.md`).
