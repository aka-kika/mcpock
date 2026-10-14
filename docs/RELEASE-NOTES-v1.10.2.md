# mcpock v1.10.2

**2026-10-14** — Fixes from a full code review.

macOS 26+, Apple Silicon.

- **No crash on a broken address.** A server URL that is not a real URL (a
  space in the host, a stray `%`) used to send mcpock into a loop until it
  crashed. It now shows "Bad address in config" and keeps going.
- **Secrets stay hidden on every screen.** The Compare view and the notes on
  the Agents tab now mask tokens in command lines, URLs and error text, the
  same way the rest of the app already did.
- **headersHelper only where it belongs.** mcpock runs a `headersHelper`
  command only from Claude Code configs, the one agent that uses it. A
  helper line in another agent's config is ignored.
- **`~` in a project path works.** A server whose working folder starts with
  `~` now starts in that folder instead of failing.
- **Slow servers are called slow.** A stdio server that does not answer in
  time shows "Slow: no answer in 20 s" instead of "Quit on start".
- **Sign-in shows as sign-in.** An older SSE server that answers 401 or 403
  shows the amber "Needs sign-in" instead of red "Broken", and a network
  blip counts as a blip.
- **Check again is steadier.** It waits for a running check, respects a
  paused agent, and checks each distinct server once.
