# MCPBAR v1.5.3

**2026-09-24** — Feedback on 1.5.2, plus one fix found by Grok.

macOS 26+, Apple Silicon.

---

## Fixed: the Agents tab blamed the wrong agents

Claude Code said "2 need you" although all its servers worked. The two flags
came from servers set up differently in *other* agents (for a `notes` server,
Goose, Cursor and Grok launch something else; Claude Code is with the
majority).

- Now a server counts for an agent only when **that agent's own copy** is
  broken, slow or needs sign-in, or when the server is set up differently
  **and that agent is the odd one out**. When there is no majority, every
  agent involved counts.
- A server marked as intended never counts.
- The "n need you" text, the health bar, the order of the agents, the tint of
  the attention button and the footer all follow the same rule. An agent in
  the majority shows the server as a normal, fine row.

## Fixed: Grok's reed-md showed "needs sign-in" (found by Grok)

Grok keeps the reed-md key in a `[mcp_servers.reed-md.headers]` section of
its config. MCPBAR skipped that section, so its check went out without the
key and got "HTTP 401". MCPBAR now reads those headers. Grok found and fixed
this; Claude Code reviewed it.

## Changed: copy items in the server menu

Right-click a server (Servers tab, inside an agent, or on the card's title):

- **Copy Details**: name, status, every agent with its config file,
  transport and command or address, tool count and when it was last checked.
  Keys and tokens are hidden the same way as in MCPBAR's status file.
- **Copy Errors**: only when the server has errors; the same report as before,
  but keys and tokens in a command line (e.g. `--header Authorization: Bearer …`)
  are now hidden. The same goes for ⌘C, the card's error box, Copy All and
  Export.
- "Copy error", "Copy server name" and "Copy server details" are gone.

## New: Ask an Agent

**Ask an Agent** in the server menu, and an **Ask an agent** button in the
card's "Why it is broken / slow / needs sign-in" and "Set up differently"
boxes. It copies a prompt you paste into any agent.
The prompt asks the agent to **look into the problem and advise, not fix**:
what the problem is, the likely causes, your options with their trade-offs,
and what it recommends, and to ask you before changing anything. It includes
the server details and errors, with keys hidden. If MCPBAR's own MCP server is
set up in your agents, the prompt tells the agent it can call `mcpbar_server`
for more. The button turns orange with "Copied" for a moment.

Ask an Agent shows only for servers that need you (broken, slow, needs
sign-in, set up differently).

## Changed: the card's problem boxes, and clearer words

Every button in the card's problem boxes now has the same width and height,
and nothing wraps:

- **Set up differently:** two by two. **Compare** | **Ask an agent**, then
  **Copy details** | **Mark as intended**.
- **Why it is broken / slow / needs sign-in:** one row of two. **Ask an
  agent** | **Copy errors**.
- The copy and ask buttons still flash an orange "Copied", in place.

New words, the same everywhere (card, menus, Settings, the status file and
`mcpbar_server`):

- "Different on purpose" is now **Mark as intended**. A marked server shows a
  quiet **Marked as intended · Undo** line on the card instead of the yellow
  box, and its right-click item is **Unmark as Intended** (it replaced "Flag
  Differences Again"). "Mark as intended" is never offered for a server that
  is already marked.
- "Compare setups" (the button) is now **Compare**; the view it opens is still
  called "Compare setups".
- "Ask Agent" is now **Ask an Agent** in menus and **Ask an agent** on buttons.
- "Copy Server Details" is now **Copy Details** in menus and **Copy details**
  on the card's button (new in the "Set up differently" box).
- "Copy error" on the card is now **Copy errors**, like **Copy Errors** in the
  menu.
- Settings > Servers: the check mark's tooltip says "Marked as intended".
- For agents: `mcpbar_server`, `status.md` and Copy Details say "Set up
  differently, marked as intended: …" (was "Set up differently on purpose").
  The status file's JSON key `differsOnPurpose` is unchanged, so older helpers
  still read it.

## New: you can see a single server being checked

When you press **Check again** (on the card or in the menu), the server's
dot turns into a small spinning mark right away, in the same spot, in both
tabs and on the card. The card's Check again button spins until that
server's check is done.

## Changed: the card's tools list

The tool chips are gone. The card now lists tools like the old tools window
did: the name, and its short description underneath. It shows the first 5;
**Show more** lists the rest right there, **Show less** folds them again.

The separate "+N more" tools window is gone: the card now shows the same
list, in the same style, in place, and scrolls when it is long, so a second
window added nothing but another thing to open and close.

Everything else is v1.5.2 (see `docs/RELEASE-NOTES-v1.5.2.md`).
