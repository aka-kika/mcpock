# mcpock — Architecture

How the app is put together (v1.5), how one health check flows end to end, and
the rules that must not regress. For what the app does from a user's point of
view, see the [README](../README.md); for build and test steps, see
[CONTRIBUTING.md](../CONTRIBUTING.md).

---

## 1. The big picture

mcpock is a menu-bar-only SwiftUI app (`LSUIElement`, no Dock icon) built on
Foundation, AppKit, SwiftUI, ServiceManagement, (1.5.2, for one hash)
CryptoKit, and its one third-party dependency, Sparkle 2, for
in-app updates (`docs/THIRD-PARTY.md`). It ships two executables: the app,
and a small read-only MCP server (`mcpock-mcp`) inside the app bundle that
lets agents read what the app found.

```
 MCPockApp (@main)
   MenuBarExtra(.window)
     label   = StatusIconView         plain glyph, ring or diamond
     content = MenuBarPanelView       Servers | Agents tabs, list, footer
                 │ reads                 │ opens
                 ▼                       ▼
        ┌──────────────────┐     DetailCardPresenter  (child NSPanel beside the panel)
        │  HealthMonitor   │
        │  @MainActor      │     SettingsLauncher     (NSWindow, five tabs)
        │  servers,        │
        │  groups, timer   │──── StatusWriter ──► ~/Library/Application Support/mcpock/
        └───────┬──────────┘                      status.json + status.md
                │                                        ▲ reads only
     1. discover│(launch, Refresh)          mcpock-mcp (Contents/Helpers/, stdio MCP)
                ▼
   ConfigDiscovery.discover()   AkaSource.discover()
   = AgentRegistry (known paths)   (aka's local sidecar,
   + ConfigScanner (bounded scan)   HTTP, 1.5 s timeout)
     → [ServerConfig]
                │
     2. probe   │ (timer, Refresh, Check again) TaskGroup, off the main actor
                ▼
   StdioProbe ── ProcessRunner + MCPMessageBuffer      (spawn, handshake, kill tree)
   HTTPProbe ─── URLSession (streamable HTTP), SSEProbe (legacy SSE)
                │
     3. results │ applied on the main actor, one at a time as they arrive
                ▼
   servers → groups (one row per server name) → views and the status file
```

`HealthMonitor` is the only stateful coordinator. Views are functions of its
`servers` / `groups` plus `PanelState` (tab, selection, search, filter, which
card is open).

---

## 2. Module map

### App and coordinator

| File | Role |
|------|------|
| `mcpock/MCPockApp.swift` | `@main`, the `MenuBarExtra`, owns `HealthMonitor` and `PanelState`, starts the monitor on the first panel open |
| `Services/HealthMonitor.swift` | Discovery reload, probe cycles (single-flight), smoothing, backoff, pause/pin/hide, grouping, menu-bar verdict, status file scheduling |
| `Services/AppPreferences.swift` | UserDefaults keys; `ProbeInterval` (the Check servers slider stops); `differsAcknowledged` (1.5.2, JSON string: name -> fingerprints) |
| `Services/LaunchAtLogin.swift` | `SMAppService` wrapper |
| `Services/UpdateController.swift` | Owns Sparkle's `SPUStandardUpdaterController` for the app's lifetime; never created while hosting tests |
| `Models/Models.swift` | `ServerConfig`, `ServerSnapshot`, `ServerGroup`, `HealthState`, `ProbeResult`, `ProbeError`, `ServerSource`, `DiffNote` |

### Discovery

| File | Role |
|------|------|
| `Services/AgentRegistry.swift` | `AgentRegistry.known`: exact config paths and labels of the agents mcpock knows. Also `AgentBadge` (logo lookup, monograms, display names) |
| `Services/ConfigScanner.swift` | Bounded, TCC-safe sweep of `~/.config/*`, `~/Library/Application Support/*` and home dot-folders. Never Documents, Desktop or Downloads; skips symlinks and files no agent loads (`excludedFileSuffixes`: `~/.minimax/mcp/mcp.json`, since MiniMax reads only `~/.minimax/mcp.json`) |
| `Services/ConfigShape.swift` | Recognises a config by its shape (JSON `mcpServers` / `servers` / `mcp`, TOML `[mcp_servers.*]`, YAML `extensions:` / `mcp_servers:`); a file counts only if one entry has a `command` or `url` |
| `Services/ConfigDiscovery.swift` | Merges registry and scan, dedupes by canonical path, drops `enabled: false` entries and projects whose folder is gone |
| `Services/MCPServersTOML.swift`, `GooseConfig.swift`, `MCPServersYAML.swift`, `YAMLBlock.swift` | Small parsers for the TOML/YAML shapes agents write (no third-party TOML/YAML). `YAMLBlock` builds a node tree and reads YAML's multi-line scalars: wrapped plain text (Hermes wraps long paths), multi-line quoted text, `|` / `>` blocks, flow `[]` / `{}` |
| `Services/AkaSource.swift` | aka keeps servers in a database, not a file: `GET http://127.0.0.1:6464/api/mcp/servers`, then launches each the way aka does (`bun x`, `python`, `bun run`) |

### Probing

| File | Role |
|------|------|
| `Services/StdioProbe.swift` | spawn → `initialize` → `notifications/initialized` → `tools/list` (only when needed) → terminate; builds the failure reason |
| `Services/ProcessRunner.swift` | Pipes, message reads with timeout, stderr capture, process-**tree** kill (SIGTERM, then SIGKILL) |
| `Services/MCPMessageBuffer.swift` | `[UInt8]`-backed reader: newline-delimited JSON, tolerates `Content-Length` frames and leading noise |
| `Services/MCPJSONRPC.swift` | Request builders, response matching by id, tool parsing |
| `Services/HTTPProbe.swift` | Streamable HTTP: POST JSON-RPC, replays `Mcp-Session-Id`, parses JSON or SSE frames, closes the session |
| `Services/SSEProbe.swift` | Legacy SSE: GET the stream, read the `endpoint` event, POST, read replies from the stream. Falls back to `HTTPProbe` when the URL isn't really SSE |
| `Services/PathResolver.swift` | `~` expansion, env merge, common bin folders on PATH, `ELECTRON_RUN_AS_NODE=1` for app-bundle commands |

### What the UI says (pure, unit-tested)

| File | Role |
|------|------|
| `Services/PanelSections.swift` | Needs you / Pinned / Everything else; the attention filter |
| `Services/AgentSections.swift` | The Agents tab: one section per agent, sorted by what needs you. 1.5.3: a server counts for an agent only when that agent's own declaration fails, or it differs and that agent is an odd one out. 1.5.4: with the attention filter, agents with nothing wrong stay listed after the others and `isDimmed` tells the view to fade them |
| `Services/Differs.swift` | "Set up differently": a source whose launch target differs from the majority (aka never counts). 1.5.2: `fingerprints` (SHA-256 of each launch target, deduped) for "Mark as intended" |
| `Services/ShortReason.swift`, `PanelText.swift`, `CardText.swift`, `MenuText.swift` | Every short line, footer summary, card sentence and menu text |
| `Services/ServerVisibility.swift` | Pinned / Shown / Hidden |
| `Services/ErrorExport.swift` | Markdown/JSON report of failing servers (Settings > General > Errors) |
| `Services/ServerReport.swift` | 1.5.3: the server menu's Copy Details and the Ask an Agent prompt, built on `StatusSnapshot.server` so they carry the status file's masking |
| `Services/StatusSnapshot.swift`, `SecretMask.swift` | Builds the status file; masks tokens, URL secrets and every env/header value |
| `Services/ConnectSnippets.swift` | What Settings > Connect copies: per-agent snippets and the Copy for Claude prompt |

### Views

| File | Role |
|------|------|
| `Views/MenuBarPanelView.swift`, `PanelState.swift`, `PanelChrome.swift`, `PanelBackdrop.swift` | The 380 x 560 panel, keyboard handling, tabs, footer, backdrop (menu material in Light, soft dark in Dark, Apple's `.glassEffect` in Glass) |
| `Views/GlassPanelController.swift` | Glass theme on macOS 27+ (1.8): its own `NSStatusItem` (expanded-interface session) and a clear borderless `GlassPanelWindow` hosting the same `MenuBarPanelView`; the MenuBarExtra item hides meanwhile (`GlassPanelStyle.usesGlassPanel`) |
| `Views/ServerRowView.swift`, `HealthMark.swift`, `AgentBadgeView.swift` | A row: health shape, name, agent logos, tool count; right-click menu |
| `Views/AgentsListView.swift` | The Agents tab (the panel opens on it, 1.5.4). Its `HealthBar` grows in on the tab's first real view each launch and after every full check (`PanelState.healthBarShouldGrow`, `agentsTabAppeared`) |
| `Views/DetailCardPresenter.swift`, `DetailCardView.swift` | Detail card as a child panel; its problem boxes (1.5.3 layout B: `CardText.problems` picks why / differs / marked; equal-width `CardButton(fillsWidth:)` rows, `CopyFlashButton` for the orange "Copied"); its tools list (first 5, Show more in place; 1.5.3 dropped the separate tools window) |
| `Views/ConfigPathMenu.swift` | One right-click menu for every config path (Show in Finder, Copy Path, Open Config… with a confirmation) |
| `Views/StatusIconView.swift`, `SpinnableIcon.swift` | Menu-bar icon; the refresh glyph's spin |
| `Views/Settings*.swift`, `Services/SettingsLauncher.swift` | Settings window: General, Servers, Agents, Connect, About |
| `Services/StatusItemRightClick.swift` | Right-click on the menu-bar icon: Settings, Quit |
| `Theme/Theme.swift` | Colour tokens (Light semantic, Dark soft dark), fonts, `AppearanceApplier` |

### Usage counts (1.7)

| File | Role |
|------|------|
| `Services/Usage/UsageReader.swift` | The contract: `UsageEvent` (agent, server, date; nothing else), `UsageCursor`, `UsageReader` |
| `Services/Usage/UsageStore.swift` | Runs the readers off the main thread, daily buckets per (agent, normalized server), windows 7 / 30 days / all time, persists counts and cursors to `usage.json`; refresh at most every 10 min after a full cycle |
| `Services/Usage/UsageReaders.swift` | `UsageReaders.all`: the readers in use |
| `Services/Usage/ClaudeCodeUsageReader.swift` | `~/.claude/projects/**/*.jsonl`, `mcp__<server>__<tool>`, byte offsets per file |
| `Services/Usage/GrokUsageReader.swift` | `~/.grok/sessions/*/*/events.jsonl`, `mcp_tool_call_started` (server and tool already split) |
| `Services/Usage/CursorUsageReader.swift` | Cursor's `state.vscdb` (SQLite, read-only), `cursorDiskKV` bubbles with `toolFormerData.name` `mcp-<server>-<tool>`, terminal statuses only, last rowid |
| `Services/Usage/HermesUsageReader.swift` | `~/.hermes/state.db` and each profile's own (`role = 'tool'` rows named `mcp_…`), profiles reported as "Hermes · <name>" |

Where every other agent keeps its calls: [USAGE-SOURCES.md](USAGE-SOURCES.md).

### Desktop widgets (1.8)

| File | Role |
|------|------|
| `Shared/AppGroup.swift` | The App Group id (`P5RB3W3D58.com.mcpock`) and its container URL |
| `Shared/WidgetSnapshot.swift` | `MCPockWidgetSnapshot`: the widgets' small shape of the data, `build(from: MCPockStatus)` |
| `Shared/WidgetSnapshotStore.swift` | Pure read/write of that snapshot as a file in a given directory |
| `mcpock/Services/Widgets/WidgetSnapshotWriter.swift` | App-only: coalesces writes into the App Group container, then asks `WidgetReloadPolicy` whether to call `WidgetCenter.reloadAllTimelines()` |
| `mcpock/Services/Widgets/WidgetReloadPolicy.swift` | Pure: reload only on a real display change, at most once a minute |
| `mcpockWidgets/` (target `mcpockWidgets`, `.appex`) | The three widgets (Status, Problems, Agents), a shared `TimelineProvider` that reads the App Group snapshot, `.after(15 min)` fallback refresh |

`MCPockStatus.perAgent` (optional field, `StatusSnapshot.build`) feeds the
per-agent widget; it's the same rows `AgentSections.build` gives the tab.

### The helper (`mcpock-mcp`) and shared code

| File | Role |
|------|------|
| `mcpock-mcp/main.swift` | stdin loop: one JSON-RPC line in, at most one out |
| `Shared/MCPockStatus.swift` | The status file's model (schema 1). Compiled into the app and the helper |
| `Shared/MCPStatusServer.swift` | `initialize`, `ping`, `tools/list`, `tools/call`, empty resources/prompts |
| `Shared/StatusReport.swift` | The text answers of `mcpock_status`, `mcpock_problems`, `mcpock_server`, including "isn't running" and "results are old" |

The helper also compiles `MCPJSONRPC.swift` and `Models.swift` from the app
(see `project.yml`). It is embedded at `mcpock.app/Contents/Helpers/mcpock-mcp`
and signed with the app.

---

## 3. One refresh, end to end

**Two cadences, kept apart on purpose.**

- **Discovery** (registry + scan + aka) runs when the monitor starts (the first
  time the panel opens) and on **Refresh** in the footer (`startRefreshAll()`
  → `refreshAll()`). It runs in `Task.detached(priority: .utility)` (the
  replaceable `HealthMonitor.discover` closure, stubbed in tests), then `HealthMonitor.merged`
  folds it into `servers` on the main actor: a server whose id and probe spec
  are unchanged keeps its health, tools and backoff; a changed spec starts over
  as `.unknown`. Hidden, pinned and paused choices are never pruned.
- **Probing** runs on the timer (Settings > General > Check servers: 1 min to
  4 h, or Manual = no timer), after a Refresh, and per server on **Check
  again**. Everything goes through `refreshNow(force:)` → `runProbeCycle`.

**Who gets launched.** Spawning has side effects (an OAuth server can open a
browser login), so `shouldProbe` filters first:

- **Paused** servers are never launched, not even by Refresh.
- **Backoff:** after repeated failures a server is re-checked after 5 min,
  then 15 min, then hourly. Refresh (`force: true`) skips backoff, never pause.
- **Self-managed** (`"builtin": true`: servers that run inside their host
  app) are never probed; they show a neutral dash.
- **Dedup:** identical probe specs (same command, args, env and folder, or
  same URL and headers) are probed once and the result is shared.

**One cycle.**

1. A `TaskGroup` probes every due target in parallel, off the main actor.
   Tools are fetched only when a server moves **into** healthy.
2. Each result is applied on the main actor as soon as it arrives
   (`apply(_:at:)`), so the list fills in live.
3. **Smoothing** (`smoothedState`): one transient failure (a timeout) shows
   slow (amber ring); a second one, or any definitive failure (spawn error,
   non-zero exit), shows broken (red diamond). HTTP 401/403 is a stable
   "needs sign-in" that never escalates. Any success resets to healthy.
4. `groupByName` collapses instances with the same normalised name into one
   `ServerGroup` (worst state wins) and attaches "set up differently" notes.
   A row marked as intended whose fingerprints still match gets them
   in `acknowledgedDiffers` instead, and an empty `differs` (1.5.2).
5. The panel, the Agents tab, the menu-bar icon (`iconState`) and the status
   file (coalesced write after 800 ms) all update from that.

**stdio probe.**

```
resolve command (PATH, ~, env; app-bundle binary → ELECTRON_RUN_AS_NODE=1)
  → spawn (ProcessRunner)
  → write initialize (one JSON object + "\n")    read reply by id, 10 s budget
  → write notifications/initialized
  → write tools/list (only if needed)           read reply by id
  → terminateAndReap(): SIGTERM the tree, wait, SIGKILL the tree
```

On failure the reason includes the exit code and the tail of stderr, for
example `Non-zero exit (1) — Error: MISSING_API_KEY`.

**HTTP probe.** `initialize` (POST) → keep `Mcp-Session-Id` → replay it and
`MCP-Protocol-Version` on the next POSTs → `DELETE` the session. Replies can
be JSON or SSE frames. A config typed `sse` is tried as legacy SSE first and
falls back to streamable HTTP, because many configs label streamable servers
`sse`.

---

## 4. The panel, the card and the helper

- **The panel is a fixed 380 x 560.** `MenuBarExtra` sizes its window once and
  never resizes it, so every block has a fixed height and the list gets what
  the chrome leaves (`listHeight(searchOpen:)`, `PanelLayoutTests`).
- **The detail card is a child `NSPanel`** beside the panel
  (`SidePanel` helpers). It can never become key: the MenuBarExtra window
  closes the moment it loses key, so a card that took focus would close its
  own parent. Keyboard input stays in the panel and `PanelState`'s key monitor
  drives both windows. Compare (titled "Compare setups") swaps the card's
  content instead of opening a sheet for the same reason.
- **The Glass panel (macOS 27+) is not the MenuBarExtra window.** That window
  blurs the desktop with its own material before the panel's glass sees it,
  so glass inside it only showed a white haze in Light. `GlassPanelController`
  shows the panel in a clear `NSPanel` instead, opened and closed by the menu
  bar's expanded-interface session; outside clicks, Escape (after card,
  compare and search, `PanelState.requestClose`) and another mcpock window
  taking key end it with `session.cancel()`. The content view is installed on
  open and removed on close, so its `onAppear`/`onDisappear` still run.
- **Settings is an `NSWindow` of fixed size** (`SettingsLauncher`), never sized
  from its content (that caused an AppKit constraint-loop crash in 2026-08).
- **The status file** is written by `StatusWriter` only from the running app
  (never from the unit-test host). `mcpock-mcp` reads it and nothing else. It
  says when the app isn't running (pid gone) or when results are old (older
  than 3 check intervals, at least 10 min; 1 h in Manual).

---

## 5. Threading

- `HealthMonitor` and `PanelState` are `@MainActor`; all state they publish
  changes on the main actor.
- Probes are `nonisolated` and run in a `TaskGroup`.
- `ProcessRunner` is `@unchecked Sendable` and guards its state with
  `OSAllocatedUnfairLock`. A read races a timeout in a child task group.
- **Single flight:** a timer tick rides an in-flight cycle; a forced refresh
  waits for it (`awaitInFlightCycle`) and then runs its own. Per-server
  refresh waits too.
- **`isRefreshing` comes from a hold count** (`refreshHolds`): each probe
  cycle holds it, and `startRefreshAll()` takes a hold synchronously on the
  tap, before the Task hop and discovery, so the footer spins at once (1.5.1).
  Never assign `isRefreshing` directly. The card's Check again spins from
  `PanelState.checkingNames`, also set synchronously; 1.5.3: the row's
  `HealthMark` turns into a spinning arc from the same set, in both tabs.

---

## 6. Rules that must not regress

1. **No orphan processes.** Probes end in `terminateAndReap`, which signals the
   whole process tree (`npx` → `node` is the classic leak). Both terminate paths
   claim termination once; a reaped pid is never signalled again (pid reuse).
   `ProcessCleanupTests`.
2. **Timeout-raced continuations resume on cancel** (`withTaskCancellationHandler`
   in `waitForMessage`), or a silent server deadlocks the probe and leaks. Fast
   mocks never hit this path: check probe changes against a slow or silent
   server. `testReadMessageTimesOutWithoutHanging`.
3. **stdio is newline-delimited JSON**, not `Content-Length` frames. Test mocks
   must speak NDJSON too.
4. **stderr is drained before waiters wake**, or failures regress to "No response".
5. **Streamable HTTP needs `Mcp-Session-Id` replayed** on every follow-up.
6. **Every probe trigger goes through `refreshNow()`**; never loop on
   `await task.value` for a task another continuation clears (the v1.4.1
   100% CPU bug).
7. **Discovery stays off the main thread** and out of `runProbeCycle()`.
8. **`start()` is idempotent** (`hasStarted`): `onAppear` fires on every panel
   open, and Manual mode must not re-probe on open.
9. **`MCPMessageBuffer` stays `[UInt8]`-backed** and its noise skip stays a loop
   (a `Data` index crash and a stack overflow both happened). A negative
   `Content-Length` throws. `MCPMessageBufferTests`.
10. **The scan stays TCC-safe**: no Documents/Desktop/Downloads roots, symlinks
    skipped, the one-endpoint gate kept, `excludedDirs` entries lowercase.
    `ConfigScannerTests`.
11. **Nothing secret leaves the app.** The status file carries env and header
    **names** only; `SecretMask` masks the rest. `StatusSnapshotTests`,
    `SecretMaskTests`.
12. **mcpock never writes another app's config.** Open Config… asks first,
    with Cancel as the default button.
13. **Sandbox off, entitlements empty.** Needed to spawn servers and read
    configs under `~`. Hardened runtime is added only when `scripts/release.sh`
    signs with Developer ID.
14. **Theme through `AppearanceApplier`**, only on mcpock's own windows: the
    menu-bar icon always follows the system bar. A `MenuBarExtra` label keeps
    only one image, so the badged icon is drawn as a single `NSImage`.
15. **The panel has a fixed height**, and child panels never become key.
16. **"Mark as intended" stores fingerprints, never targets** (a URL can hold
    a token), and only silences the differs note: an acknowledged row is still
    probed and its failures still count. `DifferentOnPurposeTests`.
17. **Copy Details and Ask an Agent go through `StatusSnapshot.server`**
    (1.5.3), so the clipboard gets the status file's masking. Ask an Agent
    asks the agent to investigate and advise, never to change anything first.
    `ServerReportTests`.
18. **Per-agent attribution** (1.5.3): an agent in the majority of a server
    set up differently sees it as fine; only the odd ones out count it.
    `AgentSectionsTests`.
19. **Servers-tab row ids include the section** (1.5.4,
    `MenuBarPanelView.rowID`): the sections' nested `ForEach`s flatten into
    one `LazyVStack`, so a bare-name id let a row that moved sections keep its
    old look. `scrollTo` goes through `rowID(forName:in:)`. `StaleRowTests`.
20. **Animations end.** The health bar grow is a one-shot `scaleEffect`,
    never a timer or `.repeatForever`, and Reduce Motion skips it.
21. **Usage readers only read, and keep three facts.** Agent, server, date:
    never arguments, results or chat text. SQLite stores open read-only
    (never a write, never a WAL checkpoint). `UsageTests` and each reader's tests.
22. **Usage starts after discovery.** Cursor and Hermes split call names
    against the known server names, and a cursor never goes back, so
    `MCPockApp` starts `UsageStore` only once `monitor.groups` has names.
23. **Settings copy before anything reads defaults** (`MCPockApp.init`,
    1.6.1): `HealthMonitor.init` loads hidden, paused and marked servers once.
24. **The glass panel's status item syncs only on a real theme change**, never
    re-entrantly: creating an `NSStatusItem` writes defaults, which posts
    `UserDefaults.didChangeNotification` (a re-entrant sync created items
    without end and crashed at launch, 1.8 development). It has its own
    `autosaveName`: AppKit saves visibility per creation slot, and the hidden
    MenuBarExtra item's "hidden" slot made the glass icon vanish.
25. **`HealthMonitor.groups` is cached per change** (`groupsCache`, cleared by
    `servers` and `differsAcknowledged`). Anything new it depends on must
    clear the cache too, or rows go stale. `testGroupsFollowTheServerList`.
26. **`UpdateController` never starts while hosting unit tests** (1.9.0,
    same `isHostingTests` guard as `StatusWriter` and
    `WidgetSnapshotWriter` in `MCPockApp.init`): a test run must never reach
    the network, touch Sparkle's real "last checked" defaults, or show its
    permission prompt. `scripts/release.sh` signs Sparkle's nested
    `Autoupdate` and `Updater.app` with Developer ID before the app, same as
    the helper and the widget, and removes the unused XPC services first
    (mcpock isn't sandboxed) — never `--deep` there either.

---

## 7. Adding an agent

- **It writes a standard shape** (`mcpServers` JSON, `[mcp_servers.*]` TOML,
  `extensions:` or `mcp_servers:` YAML) in `~/.config`, `~/Library/Application
  Support` or a home dot-folder: the scan already finds it. Add a row to
  `AgentRegistry.known` only for a clean label or a path the scan can't reach.
- **It has a new shape:** add a `ConfigShape` case and a parser that
  normalises into the JSON entry shape (`command`/`args`/`env`/`url`/`headers`),
  plus fixtures in `ConfigFormatTests` / `ConfigShapeTests`.
- **Logo:** add an `agent-<name>.imageset` (vector template, cleaned SVG) and a
  `logoNames` / `logoAliases` entry; `AgentBadgeTests` checks every mapped
  asset loads. Credit it in `docs/THIRD-PARTY.md`.
- **Connect snippet:** add a `ConnectSnippets.targets` row with its format.
