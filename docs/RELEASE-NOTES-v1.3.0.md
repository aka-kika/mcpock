# MCPBAR v1.3.0

**2026-08-03** — four real bugs (three of them MCPBAR's own, found by MCPBAR), and a
panel that finally looks like a menu-bar app.

Notarized, stapled, Developer ID-signed DMG. macOS 26+, Apple Silicon.

---

## Fixes

**Goose HTTP auth headers were dropped.** `GooseConfig.parseExtension` never parsed
`headers:` — the key fell into the catch-all `default:` branch, which skips a field
*and* every nested line under it. Any authenticated Goose `sse`/`streamable_http`
extension was probed anonymously and reported a **false 401**. Found because `reed-md`
showed healthy under Claude Code, Claude Desktop, Grok and kimi-code but 401 under
Goose alone; the token was identical in all five.

**Cache directories were scanned for configs.** `ConfigScanner.excludedDirs` was matched
case-sensitively and held `Caches`/`Cache` but not lowercase **`cache`** — the Unix/XDG
spelling. A three-month-old Langflow artifact at `~/.langflow/cache/<uuid>/` was
discovered as a live server and reported broken forever. Exclusion is now
case-insensitive, which fixes the whole class (`Build`, `Logs`, `Node_Modules` too).

**Settings crashed on open.** With `sizingOptions = [.intrinsicContentSize,
.preferredContentSize]`, every content-size change resized the window, which re-laid out
the content, which resized the window — until AppKit's loop guard threw
`-[NSWindow _postWindowNeedsUpdateConstraints]` and the process aborted. Settings now
uses a fixed-size window with its content in a `ScrollView`, so there's no feedback path.

**Manual mode still re-analyzed.** `HealthMonitor.start()` runs from the panel's
`onAppear`, and with `menuBarExtraStyle(.window)` that fires **every time the panel
opens** — and `start()` unconditionally ran discovery plus a full probe pass. Opening the
panel forced a re-analyze regardless of the "Check servers" setting. `start()` is now
idempotent.

## Interface

The panel was reworked to read as a menu, not a popover:

- **Header removed.** The app titling its own popover was the main tell; the healthy
  count moved to the footer.
- **300×420** (was 340×560), with tighter rows.
- **No bold.** System menus set item titles in regular weight.
- **Native menu font** (`NSFont.menuFont`) instead of the generic system font.
- **Rounded hover highlight**, neutral rather than accent-tinted — an accent block
  behind a two-line row reads as a selection slab.
- **Charcoal dark mode.** `windowBackgroundColor` in Dark is near-black, which read as a
  harsh void; surfaces are now a lifted ramp with semantic text on top.
- **Muted in-panel accent** for tool names — full `controlAccentColor` at monospace
  weight over charcoal was hard on the eyes.
- **Icon-only footer**: filter, refresh, settings, plus the hidden-servers toggle merged
  in from what used to be its own row.

## Added

- **Filter servers** — the footer magnifying glass now opens a real filter, matching
  server name **or** any source label (typing `cursor` surfaces everything Cursor
  declares). It previously meant "rescan", which promised a search that didn't exist.
- **Refresh progress** — the refresh glyph spins and the footer reads "Checking…" while
  a pass runs. Previously the buttons only dimmed, which reads as *disabled*, not *busy*.
- **Icons in Settings**, including an icon-based Appearance picker, and a
  **hidden-servers section that starts collapsed** so Settings fits without scrolling.

## Moved

- **Rescan for agents** is now in the status-item right-click menu (**⌘R**). It only
  matters after adding or removing an agent, and its magnifying glass was misleading.

## Reverted

- **Agent icons** in server rows. Brand marks existed for only 5 of ~16 agents, so every
  version of it mixed real logos with invented letter chips. Needs a different design.

---

**141 unit tests, zero failures, zero warnings.**
