# Usage sources — where each agent keeps its own MCP call history

Research for the "usage counts" feature: how many times each agent called each MCP
server. mcpock would read this straight from the agent's own on-disk records —
read-only, and only ever the server name + tool name + timestamp of a call. Never
chat content, arguments, results, keys or tokens.

Covers every agent mcpock can discover a config for or show a logo for (from
`AgentRegistry.swift`, `ConfigScanner.swift`, `AkaSource.swift`, and the
`agent-*.imageset` names), not just the ones on this Mac — public users run other
agents.

Checked 2026-09-26.

## In one minute

- **30 agents/apps covered.** Countable today: **13**. Partly countable (opt-in,
  format still shaky, or needs a non-trivial reader): **8**. Not countable
  (cloud-only or no local record): **4**. Unknown (too little public information,
  or needs hands-on install to confirm): **5**.
- **Countable (13):** Claude Code, Grok, Cursor, Hermes — already built. Plus
  Goose, OpenCode, MiniMax, aka (all installed here and now checked), and Cline,
  Codex, Kimi Code, Roo Code, LM Studio (confirmed from their own source/docs,
  not installed here).
- **Not countable (4):** Claude Desktop, ChatGPT, Amp, Perplexity — all keep the
  call history server-side, not on the Mac.
- **Top next candidates, in order:** Goose → OpenCode → MiniMax → Cline → Roo
  Code → LM Studio. All five are either already verified on this Mac or
  confirmed from the project's own source code, and none need an unstable or
  compressed format to read. See "Build order suggestion" below for the reasoning.

## The table

"Checked on this Mac" = read the real file/db directly (read-only) on
2026-09-26. "From source" = read the agent's own open-source code. "From docs" =
official documentation. "Guess" = one blog post / issue thread / inference, not
confirmed.

| Agent | Countable | Where (macOS) | Format | MCP call name pattern | Timestamp? | How sure | Notes |
|---|---|---|---|---|---|---|---|
| Claude Code | yes | `~/.claude/projects/**/*.jsonl` | JSONL, one line per event | `mcp__<server>__<tool>` | yes, per line | checked on this Mac | Already built. Files go back to at least June 2026 with no sign of rotation. |
| Grok | yes | `~/.grok/sessions/<url-encoded-project-path>/<session-uuid>/chat_history.jsonl` and `events.jsonl` | JSONL | wrapped in a `use_tool` call; its `tool_name` argument is `<server>__<tool>` | yes | checked on this Mac | Already built. Session folders are keyed by URL-encoded project path, one level deeper than it looks at first glance. |
| Cursor | yes | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, table `cursorDiskKV` | SQLite key-value store; each `bubbleId:*` row's value is a JSON blob | `toolFormerData.name` = `mcp-<server>-<tool>` | conversation-level yes (`composerData:*` rows carry `createdAt`/`lastUpdatedAt` epoch-ms); a timestamp on the individual bubble/call itself was not found | checked on this Mac | Already built. 66k+ bubble rows on this Mac alone — no visible pruning. |
| Hermes | yes | `~/.hermes/sessions/*.jsonl` and `~/.hermes/state.db` | JSONL + SQLite | `mcp_<server>_<tool>` | yes | checked on this Mac | Already built. Sessions go back to April 2026, no rotation seen. |
| Goose | yes | `~/.local/share/goose/sessions/sessions.db`, table `messages`, column `content_json` | SQLite, JSON blob per message | `<extension>__<tool>` | yes | checked on this Mac | Not yet built — next in line. Calls made *inside* `execute_typescript` are invisible (Goose doesn't log what runs inside that sandboxed script). |
| OpenCode | yes | `~/.local/share/opencode/opencode.db`, table `part`, columns `data` (JSON), `time_created`/`time_updated` | SQLite, JSON blob per part | tool name sits in the `data` blob's `tool` key; on this Mac's data the only calls logged so far are OpenCode's own built-ins (`bash`, `read`, `write`, …) — no MCP call has actually gone through yet to confirm the exact server-prefixed spelling. Sibling entries like `complete-task_complete_task` suggest a single-underscore `<server>_<tool>` shape, but that's inference, not a confirmed MCP example | yes, per row | checked on this Mac (structure); call-name pattern for an actual MCP call is unconfirmed — needs one real MCP call from OpenCode to nail down | Not yet built. Table/column structure is solid; just needs a live example to lock the regex. |
| Claude Desktop | no | — | — | — | — | checked on this Mac | Chats live in Anthropic's cloud, not on disk. Nothing to count locally. |
| MiniMax | yes | `~/.minimax/v2/sqlite/runtime-state.sqlite`, table `local_runtime_message_rows`, columns `data_json` (JSON blob), `created_at_ms`. Older sessions may also sit in the legacy `~/.minimax/sqlite.db` table `session_messages` (`data`, `timestamp`), but MCP-prefixed calls were only found in the v2 store on this Mac | SQLite, JSON blob per row | `mcp__<server>__<tool>` (confirmed real examples on this Mac: `mcp__feed__publish_report`, `mcp__minimax__gen_images`) | yes, per row | checked on this Mac | Not yet built, but fully verified this session — same `mcp__server__tool` shape as Claude Code, just a different database. `AgentRegistry` already special-cases MiniMax's config path (`~/.minimax/mcp.json` only); this uses a different file for usage. |
| aka (a desktop agent app) | yes, from source (not directly queried — see note) | Postgres data directory `~/Library/Application Support/pipali/db` (an embedded Postgres cluster, not a flat file); table `conversation_step`, jsonb column `step` (an `ATIFStep`, whose `tool_calls[].function_name` is the call), plus a `timestamp` column per step | Postgres table, jsonb | `<server>__<tool>` (double underscore, no "mcp" prefix) — confirmed from aka's own `src/server/processor/mcp/manager.ts` (`parseNamespacedToolName`, format `server_name__tool_name`) | yes, per step | from aka's source; not read from a live query since `psql` isn't installed on this Mac and aka's local sidecar API (`127.0.0.1:6464`) only exposes `/api/mcp/servers` (config), not call history | Not yet built and the odd one out: it's a real Postgres database, not a file mcpock can just open. Would need either a bundled Postgres client, or (cleaner) a small read-only endpoint added to aka's own sidecar that returns counts. |
| Cline | yes | `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/<taskId>/api_conversation_history.json` and `ui_messages.json` (one folder per task; Cline's own enterprise docs also mention an alternate `~/.cline/data/tasks/<taskId>/...` — check both) | JSON, one file per task | MCP calls go through Cline's own `use_mcp_tool` action; the server and tool are separate `server_name`/`tool_name` arguments inside that call, not a single fused string | task folder is timestamp-named; per-message timestamp likely (unconfirmed against a real file) | from source/docs (Cline's own blog + enterprise docs); not installed here to verify | Very popular VS Code extension — good build candidate. [Cline enterprise prompt-storage docs](https://docs.cline.bot/enterprise-solutions/monitoring/prompt-storage), [community writeup](https://prismmd.app/blog/read-cline-chat-history). Local-first by default; an optional enterprise add-on can sync history to S3/R2. |
| Continue | partly | `~/.continue/sessions/<sessionId>.json` (chat), separately `~/.continue/dev_data/<schemaVersion>/<eventName>.jsonl` (telemetry, e.g. `chatFeedback`, `tokensGenerated`) plus a rollup `~/.continue/dev_data/devdata.sqlite` | JSON / JSONL / SQLite | not confirmed — no public doc describes a dedicated MCP-call event type; if present it's inside a session's message array in an unverified shape | dev_data events are per-event (JSONL); per-message timestamp in session files unconfirmed | from source (`continuedev/continue`, `core/util/paths.ts`) | [Source](https://github.com/continuedev/continue/blob/main/core/util/paths.ts). Needs a real installed Continue + an actual MCP call to confirm the shape before building. |
| VS Code / GitHub Copilot | yes, likely | `~/Library/Application Support/Code/User/globalStorage/emptyWindowChatSessions/`, `.../transferredChatSessions/`, and per-workspace `.../workspaceStorage/<hash>/chatSessions/*.jsonl` | JSONL, one line-delimited turn log per chat session | reported as `mcp_{server}_{tool}` (single underscore) — from a GitHub issue thread, **not** official docs; VS Code's MCP docs don't specify a file format at all | yes, each session write carries timing metadata | mixed: storage path from a real (third-party) session-indexing extension; call-name format from a bug report, not primary source | Storage: [digitarald/vscode-session-trace](https://github.com/digitarald/vscode-session-trace). Call-name report: [GitHub issue #225](https://github.com/JohnnyZ93/oai-compatible-copilot/issues/225). Official (no file-format detail): [MCP in Copilot docs](https://docs.github.com/en/copilot/how-tos/provide-context/use-mcp-in-your-ide/extend-copilot-chat-with-mcp). Verify the single-underscore claim against a real file before hardcoding a regex. |
| Windsurf | unknown | `~/.codeium/windsurf/cascade` (one blog's claim) | unknown | unknown | unknown | guess (single blog, closed source) | [Source](https://ptkd.com/journal/does-windsurf-cascade-leak-api-keys-in-the-prompt-history) — thin, unverified. Needs a real install to say anything solid. |
| Codex (OpenAI) | yes | `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl` (some newer builds also backfill a local SQLite index) | JSONL, one file per session | present in the file (tool calls incl. MCP ones are recorded) but the exact string shape wasn't confirmed from source in this pass | yes, per event | from docs + third-party source analysis; format itself is explicitly called "undocumented/unstable" by third parties | On by default, no opt-in. Persistence code: [`codex-rs/rollout/src/recorder.rs`](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/recorder.rs). MCP config: `~/.codex/config.toml` under `[mcp_servers.<name>]`. ChatGPT desktop itself has no local record — Codex CLI is the only local surface for OpenAI's stack. |
| Kimi Code | yes | `~/.kimi-code/sessions/<workDirKey>/<sessionId>/agents/main/wire.jsonl`; session index at `~/.kimi-code/session_index.jsonl` | JSONL | present (`wire.jsonl` carries the tool schemas and request/response trace, including MCP tool listings) but the literal naming convention wasn't verified against source in this pass | likely yes (append-only event stream; `state.json` has session creation time) | from official docs; open source (MIT) so a source read can pin the exact format down | Open source: [MoonshotAI/kimi-code](https://github.com/MoonshotAI/kimi-code). Docs: [sessions](https://moonshotai.github.io/kimi-code/en/guides/sessions.html), [MCP integration](https://deepwiki.com/moonshotai/kimi-code/2.5-mcp-integration). |
| Gemini CLI (Google) | partly, opt-in only | (1) `~/.gemini/tmp/<project_hash>/checkpoints/*.json` — only with `--checkpointing` enabled, and only for tool calls that modify files; (2) an OTel telemetry log/endpoint — only if enabled in `settings.json` | (1) JSON per checkpoint; (2) OpenTelemetry log/metric records | `function_name` attribute on the `gemini_cli.tool_call` event, with a `tool_type` attribute of `"mcp"` or `"native"` | yes on telemetry events | from official docs | [Telemetry docs](https://google-gemini.github.io/gemini-cli/docs/cli/telemetry.html), [checkpointing docs](https://google-gemini.github.io/gemini-cli/docs/cli/checkpointing.html). Nothing is written by default — both features are off out of the box. |
| Qwen Code (Alibaba) | partly/unknown | `~/.qwen/tmp/<project_hash>/` (checkpoint-style temp data); an optional `.qwen/chat-history/<session_id>.json` only via explicit `qwen chat export` or an experimental setting | JSON | likely inherits Gemini CLI's `function_name` shape (it's a fork) but not verified against Qwen's own telemetry doc in this pass | unknown for the default store; export files likely timestamped | from GitHub docs/issues | [Settings docs](https://github.com/QwenLM/qwen-code/blob/main/docs/users/configuration/settings.md); an open issue ([#2373](https://github.com/QwenLM/qwen-code/issues/2373)) is literally requesting persistent local history, implying today's default isn't solid. |
| Kiro (AWS) | unknown | MCP config confirmed at `~/.kiro/settings/mcp.json`; no local call-history location found anywhere public | unknown | unknown | unknown | guess (closed source; docs cover config, not logging) | [MCP config docs](https://kiro.dev/docs/mcp/configuration/). Kiro is a VS Code-derived Electron app, so a Cursor-style `state.vscdb` is plausible but unconfirmed. |
| Trae (ByteDance) | unknown | not found | unknown | unknown | unknown | guess | No documentation, source, or credible community writeup surfaced. Needs a fresh look or a hands-on install. |
| Roo Code | yes, likely | `~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks/<taskId>/ui_messages.json` and `api_conversation_history.json` | JSON, one file per task (same shape family as Cline — it's a Cline fork) | tool-use entries for `use_mcp_tool` carry `serverName`/`toolName` fields (file layout confirmed from source; exact JSON key spelling not independently verified against a live file) | yes — Cline-family messages carry a `ts` (ms epoch) per message | from source | [`globalFileNames.ts`](https://github.com/RooCodeInc/Roo-Code/blob/main/src/shared/globalFileNames.ts). MIT, VS Code extension. Kept until the user deletes a task in-app; no known auto-rotation. |
| Kilo Code | unknown / in flux | extension id `kilocode.kilo-code` → `~/Library/Application Support/Code/User/globalStorage/kilocode.kilo-code/` (directory confirmed; internal format not confirmed) | unknown | unknown | unknown | from source (partial) | v7.8.1 was re-architected on top of `@opencode-ai/core`/`@opencode-ai/ui` ([source](https://github.com/Kilo-Org/kilocode/blob/main/packages/kilo-vscode/package.json)) — the older Cline-style file docs floating around are likely stale. Probably closer to OpenCode's SQLite shape now. Needs a hands-on check after install. |
| JetBrains AI Assistant / Junie | partly/unknown | Chat text in per-workspace XML under `~/Library/Application Support/JetBrains/<IDE><version>/workspace/*.xml` (`<component name="ChatSessionStateTemp">`); a separate `aia-task-history` event log for agent/tool actions, path not pinned down | Chat: XML with `timestamp` attributes. Tool-event log: newline-delimited base64-JSON under an `AUI_EVENTS_V1` header | not documented; unconfirmed | yes for chat messages (epoch-ms `timestamp` attrs); tool-event log timestamps unconfirmed | low — from an unofficial reverse-engineering project, not JetBrains | [Third-party notes](https://github.com/vshulcz/deja-vu/issues/3104). [Official Junie docs](https://www.jetbrains.com/help/ai-assistant/junie-agent.html) don't document a local log format at all. Treat as a lead, not a fact. |
| Amp (Sourcegraph) | no | Local files found are config/keys only: `~/.config/amp/settings.json`, `~/.local/share/amp/secrets.json`, `~/.local/state/amp-acp/sessions/` (just an ACP-session-id ↔ Amp-thread-id map, explicitly "no prompts, responses, credentials") | JSON | n/a locally | n/a | from docs | Amp stores full agent threads server-side on Sourcegraph's own servers (`ampcode.com/threads`). [Amp manual](https://ampcode.com/manual). |
| LM Studio | yes, likely | `~/.lmstudio/conversations/` | JSON, one file per conversation | message entries look like `{"type":"tool_call","tool":"<name>","arguments":{...},"provider_info":{...}}` — `provider_info` carries which MCP server it came from | not confirmed at tool-call level; conversations are chat logs so message-level timestamps are typical | from official docs | [Manage chats](https://lmstudio.ai/docs/app/basics/chat) confirms the path and format ("structure may change, don't hand-edit"). [MCP via API](https://lmstudio.ai/docs/developer/core/mcp) documents the `tool_call` shape. |
| Cherry Studio | partly | `~/Library/Application Support/CherryStudio/` (or `CherryStudioDev` for dev builds) | Electron's IndexedDB + LevelDB, plus Redux-persist state — not a plain SQLite file or JSON file | unknown | likely present in-app, unconfirmed on disk | from docs/source (partial) | MCP config itself lives in Redux state via redux-persist, not a JSON file ([discussion #7190](https://github.com/CherryHQ/cherry-studio/discussions/7190)). Would need a LevelDB reader to get anything out — a harder build than it looks, not a quick win. |
| Perplexity (app / Comet browser) | no, not yet | — | — | — | — | from docs/news | Comet's local MCP support hasn't shipped — seen in dev builds only ([report](https://geekflare.com/news/local-mcp-support-coming-soon-to-perplexity-comet-browser)). Today it's cloud-only. Worth a watch-item, not a build target now. |
| ChatGPT | no | — | — | — | — | from official docs | ChatGPT's MCP ("connectors"/"apps") is remote-only — HTTPS endpoints, no local stdio servers, and it's an org/Enterprise cloud feature. Nothing local to read. |
| Zed | partly | `~/Library/Application Support/Zed/threads/threads.db` | SQLite; the `data` column is a Zstd-compressed JSON blob per thread | tool name sits inside a `ToolUse`/`raw_input` object per thread; no confirmed MCP-server-prefix convention | likely per-message, unconfirmed at tool-call granularity | from source (open source) | [Storage discussion](https://github.com/zed-industries/zed/discussions/32335), [schema/deserialize issue](https://github.com/zed-industries/zed/issues/64578). Needs `unzstd` + JSON parsing, not a plain grep — a real build would need that decompression step first. |
| Warp | partly/unknown | Warp's own docs say a `warp.sqlite`-style store under `~/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/` holds "MCP logs", but the schema itself isn't documented | SQLite (schema unconfirmed) | unknown | unknown | from docs (partial) + one community project | [File locations](https://docs.warp.dev/terminal/settings/file-locations/) names "MCP logs" living here. A community MCP server, [8agana/warp-sqlite-mcp](https://github.com/8agana/warp-sqlite-mcp), exists specifically to query `warp.sqlite`, which implies it's queryable — worth a hands-on look once Warp's installed somewhere. Warp also has an opt-in cloud-sync mode for conversations, separate from this. |
| Raycast | unknown | not documented anywhere found | unknown | unknown | unknown | guess | [Raycast's own MCP page](https://manual.raycast.com/ai/model-context-protocol) covers installing/using MCP servers, says nothing about logging calls. Likely somewhere under `~/Library/Application Support/com.raycast.macos/` (Raycast's known app-support folder) but unconfirmed for MCP specifically. |

Not its own row: the generic "mcp" logo (`AgentBadge.logoNames["mcp"]`, alias
`modelcontextprotocol`) is a fallback icon for an unrecognized MCP-related
source, not a real agent — nothing to research there.

## Build order suggestion (after the current four)

Ranked by a mix of "how sure are we this works" and "how many people run it."
Claude Code, Grok, Cursor and Hermes are already built.

1. **Goose** — fully verified on this Mac already, clean SQLite/JSON shape, no
   surprises. Cheapest next win.
2. **OpenCode** — same: verified structure, just needs one live MCP call from
   OpenCode itself to lock the exact tool-name spelling before shipping.
3. **MiniMax** — verified this session, same `mcp__server__tool` pattern as
   Claude Code (just a different SQLite file/table). Straightforward.
4. **Cline** — very large install base (one of the most-used VS Code AI
   extensions), well-documented per-task JSON on GitHub/enterprise docs, local by
   default. Needs one real installed Cline + an MCP call to pin the exact JSON
   shape, but the path is solid.
5. **Roo Code** — a Cline fork, same file family, source-confirmed paths.
   Slightly less certain than Cline on the exact key names, but close.
6. **LM Studio** — official docs confirm both the path and the `tool_call` shape.
   Smaller install base than the above but very low risk.
7. **aka** — a desktop agent app, and the call shape is fully understood from source
   (`<server>__<tool>`, per-step timestamp), but it's the only one sitting in a
   real Postgres cluster rather than a flat file/SQLite db mcpock can just open.
   Worth doing, but it's an engineering decision (bundle a Postgres client, or
   ask aka's own sidecar for a small read-only "call counts" endpoint) before
   it's a quick win.
8. **Codex** — big install base since it's OpenAI's own CLI, on-by-default
   logging, but the rollout JSONL format is explicitly called
   "undocumented/unstable" by people who've tried to parse it. Build it, but
   expect to revisit the parser when Codex changes its own format.
9. **Kimi Code** — open source so the exact tool-name string is confirmable by
   reading the code, but a smaller install base than the above; do this after
   the others land.
10. **Everyone else in the table** — needs either a hands-on install to verify
    (VS Code/Copilot, Kilo Code, Windsurf, Kiro, Trae, Warp, JetBrains/Junie,
    Raycast), an opt-in the user has to flip on first (Gemini CLI, Qwen Code), or
    a non-trivial reader (Cherry Studio's LevelDB, Zed's Zstd-compressed
    SQLite blobs) — none of these are "next," they're "later, and only once
    verified for real."

## Privacy notes

What a reader (mcpock, or anyone building on this doc) must never do:

- **Never keep, log, or print full chat content, tool arguments, or tool
  results.** Every format above mixes the tool-call name in with the rest of the
  message — the parser must pull out only the server name, tool name, and
  timestamp, and throw the rest away immediately. Do not hold the full JSON blob
  in memory longer than it takes to extract those three fields.
- **Never keep API keys, OAuth tokens, or auth headers.** Several of these
  files/tables sit right next to secrets (MiniMax's `~/.minimax/mcp.json` has
  bearer tokens in it; aka's sidecar payload carries `apiKey`/OAuth fields).
  mcpock's existing config-discovery code already follows this rule — the
  usage-counter must too.
- **Open everything read-only.** `sqlite3 -readonly`, never write to another
  agent's own database or log file. For a Postgres-backed one (aka), that means
  a read-only connection/role, never a write-capable one.
- **Don't guess a format from a blog post and ship it.** Several rows above are
  marked "guess" or "unconfirmed" on purpose — those need a real install and a
  real MCP call to verify before mcpock parses them for real users, not just a
  best-effort regex.
- **Binary/compressed blobs (Zed's Zstd SQLite column, Cherry Studio's LevelDB)
  are not a job for naive text scanning.** Either write a real decoder or leave
  that agent unsupported until one exists — don't half-parse and silently
  undercount.
