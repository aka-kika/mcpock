# mcpock — Observability: what fits, what doesn't

A decision record for the recurring question: *"Which tools are actually used,
which are slow, which hallucinate, which leak tokens — the Datadog for MCP. Should
that be part of mcpock?"* Companion to the out-of-scope list in
[CONTRIBUTING.md](../CONTRIBUTING.md#out-of-scope) and
[docs/ARCHITECTURE.md](ARCHITECTURE.md) (how it fits together).

**Status (still true in v1.5):** decision recorded, not built. Anything here needs a deliberate product
decision before implementation — the app is intentionally small.

---

## The constraint that decides everything

mcpock is **not in the MCP data path.** On each check it spawns each server *itself*
(`StdioProbe` / `HTTPProbe`), runs its own `initialize` + `tools/list` handshake,
then tears the process down (see [ARCHITECTURE.md §3](ARCHITECTURE.md)). It never
forwards or observes the real Claude Code / Cursor / Claude Desktop → server
traffic. So real tool **invocations**, their latency, and their token usage are
invisible from where it sits today.

That single fact separates what is honestly buildable *inside* mcpock from what
would be a different product.

## The four asks vs. what mcpock can actually see

| Ask | Feasible in mcpock? | Why |
|-----|---------------------|-----|
| **Which leak tokens** | ✅ now | mcpock already fetches `tools/list` and **discards the schemas** (`MCPJSONRPC.parseTools` keeps only name + description). The serialized size of names + descriptions + `inputSchema` is the *fixed context cost* each server injects into every request — the dominant real-world token leak (a many-tool server with fat schemas silently eats the context budget on every call). |
| **Which are slow** | ⚠️ partial | It can time its own handshake (responsiveness / cold-start), but not real per-call latency under real payloads. Probes currently record no duration. |
| **Which are actually used** | ❌ needs read-path | Requires parsing Claude Code on-disk session transcripts (`~/.claude/projects/**/*.jsonl` — they carry `tool_use` / `tool_result` blocks plus per-message token usage), a read-only extension in the same idiom as reading `~/.claude.json`; or a proxy. |
| **Which hallucinate** | ❌ never | Hallucination is an LLM-output property, not an MCP-server signal. MCP carries nothing to measure it. Claiming it would be dishonest. |

## Recommendation

**Do not fold a full "Datadog for MCP" into mcpock.** A proxy/gateway that captures
real calls contradicts three explicit product constraints — read-only; never write
MCP configs ([out of scope](../CONTRIBUTING.md#out-of-scope)); "only build what
was specified, no drive-by features" — and turns a passive widget into an active
middleman. That is a separate product.

A high-signal, honest subset *does* fit what mcpock already is (a read-only observer
of the same `~/` surfaces). Ranked by fit:

1. **Fits now (zero pivot) — context weight + responsiveness.** Measure each
   server's tool-catalog context cost (estimated tokens from the names +
   descriptions + schemas it already fetches and currently throws away), record
   handshake latency, persist a small rolling history, surface it in the panel.
   Answers **"which leak tokens"** (the schema-bloat sense — the one that actually
   matters) and **"which are slow"** (responsiveness). Reuses `MCPJSONRPC.parseTools`,
   `MCPToolInfo`, `ServerSnapshot`, `HealthMonitor.runProbeCycle`, `ServerRowView`,
   and the `AppPreferences` / UserDefaults idiom — no new dependency.
2. **Fits with effort (still read-only) — usage from transcripts.** A reader
   alongside `ConfigDiscovery` parses Claude Code session `.jsonl` for real
   invocation counts, error rates, result sizes, and real latency / tokens per MCP
   tool. This is where **"which tools are actually used"** truly comes from. Claude
   Code first (Cursor / Claude Desktop formats are less documented).
3. **Never fits — hallucination detection.** Belongs to a prompt / agent-eval tool,
   not a server monitor.

**Full-fidelity capture** (real args / results / tokens via a proxy the client
talks *through*) should be a **separate companion product** if wanted — it requires
rewriting the user's MCP configs (out of scope) and long-lived processes (vs. the
current spawn-probe-kill model).

## Bottom line

- **Is "the Datadog for MCP" a good idea?** Yes — but most of it lives *outside*
  mcpock's read-only, out-of-band vantage point.
- **Should it be part of *this* tool?** Only the honest slice: **context / token
  weight + probe latency** (fits today) and, if we go further, **usage from Claude
  Code transcripts** (fits the read-only ethos with more work). Drop hallucination.
  Keep the proxy as a separate product.
