# mcpock v1.9.0

**2026-10-10** — The first public release. In-app updates, fewer false alarms,
and a smarter "Mark as intended".

macOS 26+, Apple Silicon.

- **In-app updates.** mcpock now checks mcpock.com for new versions (Sparkle)
  and offers to install them. Settings > About has **Check for Updates** and a
  switch for automatic checks; the right-click menu has the same button. Every
  update is signed, and mcpock refuses one whose signature doesn't match.
- Servers that use Claude Code's `headersHelper` (a command that prints the auth headers) no longer show "needs sign-in" when they work fine. mcpock now runs the helper before each check, as Claude Code does, and sends the headers it prints. If the helper itself fails, the row says so ("Header helper failed: exit 1", "timed out after 10 s", "did not return JSON") instead of a misleading 401. What the helper prints is never saved, logged or copied.
- "Set up differently" no longer flags a server just because one agent runs `npx` or `node` from another folder (an agent's own `~/.agent/node/bin/npx` next to plain `npx`). Runtimes like node, npx, bun, uv and python count by name; the rest of the command still counts.
- **Mark as intended** now remembers each agent's setup separately. Removing an agent keeps the mark. A new agent with its own setup, or an agent whose setup changes, brings the note back for that agent only, and you can mark it again. Marks made before 1.9.0 still work.
- **Slow-starting servers no longer read as broken.** mcpock now waits up to 20 seconds (was 10) for a local server to answer. If it still hears nothing, it tries once more straight away. If the second try answers, the server is fine: its card just says "Slow to start (over 20 s)", and it does not count as a problem. If both tries are silent, nothing changes: amber "Slow" first, red if it happens again.
- **No leftover processes.** A server that quit on its own as soon as mcpock
  stopped talking to it could leave its child processes running. mcpock now
  notes the whole process tree first and stops all of it.
