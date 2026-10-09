# MCPBAR v1.2.0

A field-testing release: every change in it came from running MCPBAR daily on a machine with ~85 configured MCP server instances across 11 agents.

**Released:** 2026-07-16 · **Requires:** macOS 26+ · **Architecture:** Apple silicon (arm64)

## New

<!-- SF Symbol: sparkles -->
- **Self-managed servers.** Entries marked `"builtin": true` in their config (e.g. MiniMax Code's `cu`/`trash`/`matrix`) run inside their host app's own runtime and can't be started from outside — so MCPBAR no longer probes them or shows them red. They get a neutral **gray dot**, are excluded from the menu-bar aggregate and the `N/M healthy` count, and the expanded row explains why.
- **Check servers (Settings).** Choose how often MCPBAR re-probes: **every 1 / 5 / 15 minutes, or manually** (no timer at all — the panel's "Refresh now" and per-server refresh always work).
- **MiniMax** joined the agent registry (`~/.minimax/mcp/mcp.json`), so its servers show a friendly label instead of a folder-derived one.

## Improved

<!-- SF Symbol: gauge.with.needle -->
- **Probes are roughly half the work.** Identical configs across agents (same command/args/env/cwd, or url/headers) are probed **once** per cycle and the result fanned out to every instance — on a real setup that's ~85 spawns down to ~45. Per-project working directories are never merged away.
- **Live results.** Each probe result lands in the panel the moment it completes, so the dots and the header count update during the cycle instead of freezing until the slowest server answers (a full cycle measured ~24s on 85 instances).

## Fixed

<!-- SF Symbol: wrench.and.screwdriver -->
- **The panel no longer clips.** `MenuBarExtra` sizes its window once at launch — while the list is still empty, i.e. at the minimum height — and never resizes it, so the panel rendered clipped at 420pt forever. The panel is now a fixed 560pt; expanding **Hidden** takes exactly its height back from the server list, and the hidden list shows up to 4 rows and scrolls beyond.
- **Settings fits.** The hidden-servers list is bounded and scrollable there too, and the window now grows when the list populates after launch instead of clipping the bottom controls.
- **Folder permissions finally stick.** Debug builds were ad-hoc signed, so macOS treated every rebuild as a new app and re-asked for folder access after each rebuild and restart; Open at Login registration went stale the same way. All builds now sign with a stable identity — grant once, keeps.

## Install

<!-- SF Symbol: arrow.down.circle -->
Download **MCPBAR.dmg** (~1.9 MB), open it, and drag MCPBAR to Applications. It lives in the menu bar (no Dock icon); left-click the icon for the panel, right-click for Settings / Quit.

**Checksum (SHA-256):** `b4d14cb3ba95cb53ae36a8f7f2698f0ce8d64e2e14dce869836a2d10f58dd32a`

## Verify

<!-- SF Symbol: checkmark.seal -->
Signed with Developer ID (Veronica Loren, team P5RB3W3D58) and notarized by Apple. MCPBAR runs **outside** the App Store sandbox by design so it can spawn MCP servers and read your agent config files; it is distributed directly (notarized DMG), not via the Mac App Store.

## Full changelog

Since **v1.1.1**: fixed panel height + hidden-section budget (`PanelLayoutTests`), self-managed `builtin` state (`SelfManagedTests`), probe-target dedup + live-streaming results (`ProbeDedupTests`), configurable probe interval, MiniMax registry entry, Settings hidden-list bounds + window content tracking, real Apple Development signing for Debug builds, release.sh identity-by-hash. A translucent panel material shipped and was reverted the same day (deferred — see TODO). **107 unit tests**, zero-warning build.
