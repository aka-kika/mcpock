# MCPBAR v1.4.0

**2026-09-12** — refresh that actually refreshes, five more agents, a soft dark
mode, and a code audit.

macOS 26+, Apple Silicon. Build with `scripts/release.sh` for the signed DMG.

---

## Fixes

**"Refresh now" did not rediscover.** The footer button only re-probed the servers
found at launch. A server added to any config after launch never appeared until the
app was relaunched or the separate right-click "Rescan for agents" was found. Refresh
now runs discovery (off the main thread) and then a forced probe pass; the separate
rescan action is gone.

**A forced refresh degraded into the timer's pass.** `refreshNow(force: true)`
coalesced onto an in-flight unforced cycle and returned — so a click during a timer
tick re-checked nothing on backoff, and a broken server stayed red. A forced refresh
now waits the in-flight pass out and then runs its own. Per-server "Refresh this
server" had the same no-op; it now waits and then probes.

**A fixed config kept its predecessor's backoff.** On rescan a server whose probe
spec changed (new args, new command) inherited the old snapshot's hourly backoff, so
the fix went unverified for up to an hour. A changed spec restarts from unknown and
is probed on the next pass (`HealthMonitor.merged`).

**Hidden/paused choices could be wiped by a rescan.** The merge pruned any hidden
or paused name not backed by a discovered server. A config that was unreadable for
one scan (an agent rewriting it) deleted the user's choices for every server in it.
Nothing is pruned any more; a stale key is a few bytes.

**Agents were missing from rows.** A server declared in eight agents rendered as
"Code · Claude Desktop · Cur…" — the other five were invisible. Collapsed rows show
three labels and "+N"; the expanded row lists every agent, wrapping.

**MiniMax showed as two agents.** `~/.minimax/mcp.json` was scanned and labelled
"minimax" next to the registry's "MiniMax". Both files are now registry entries.

**VS Code was never parsed.** Its `mcp.json` uses `servers`, not `mcpServers`.

**Legacy SSE servers always reported broken.** An `sse` entry was POSTed to like a
streamable-HTTP server. `SSEProbe` now opens the event stream, reads the announced
endpoint, and completes the handshake over the stream; a URL labelled `sse` that
does not serve an event stream falls back to the streamable probe.

**A rare "No response from server" on a healthy server.** Pipe data was read by
`readabilityHandler`, whose queue cannot be joined, so a chunk already taken off the
pipe could still be in flight when the exit handler failed every waiting reader.
Both pipes are now drained by dedicated blocking-read threads; EOF is only observed
after the last byte has been parsed.

## Added

- **Hermes** (`~/.hermes/config.yaml`, YAML `mcp_servers:`), **Kimi Code**,
  **OpenCode** (`mcp` map with argv-array `command`), **Neve** (Goose fork), and
  VS Code `settings.json` `mcp.servers`. `enabled: false` is honoured in JSON too.
- Scanned configs inside a known agent's directory carry that agent's label
  ("Hermes · scribe" for a Hermes profile).
- `YAMLBlock`: one indent-based block reader behind both YAML shapes.
- Scanner skips `snapshots`, `archive`, `history` and similar copy folders.

## Interface

- **Settings fits its window again.** "Check servers" segments are now 1 min / 5 min /
  15 min / Manual; the long labels clipped "Manually" at 420pt.
- **Copy all errors.** Next to Export: puts the same report on the clipboard.
- **About** row: app icon, version, links to GitHub, akakika.com and X.
- **Soft dark.** The dark ramp is a lifted warm graphite (#2B2B30 / #323238 /
  #3D3D45) with fainter dividers and pastel status dots, instead of the previous
  near-black charcoal.
- Project-scoped sources read "Code (project)" instead of "Code · project".

## Removed

Docs: `docs/superpowers/` (plans and specs from July), `docs/store/appstore-prep.md`
(App Store is out of scope), `docs/TEST-PLAN-2026-07-14.md`, `docs/NAMING-DECISION.md`.

`lastRefresh`, `ServerSource.origin`, `ThemeColors.border`, `SettingsLauncher.close`,
`StatusItemRightClick.uninstall`, the `parseServersForTesting` seam, `retainHidden`,
the redundant end-of-cycle `servers.sort`, and duplicate appearance wiring in
Settings. 161 tests (was 141).
