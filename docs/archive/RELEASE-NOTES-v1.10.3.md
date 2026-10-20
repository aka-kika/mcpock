# mcpock v1.10.3

**2026-10-14** — The rest of the fixes from the code review.

macOS 26+, Apple Silicon.

- **Control-Option-M takes the keyboard in Glass.** The shortcut now brings
  mcpock forward, so the arrow keys and Return work in the Glass panel right
  away. Closing it hands the keyboard back to the app you were in.
- **Codex and Grok configs read in full.** A `]` inside an argument no longer
  cuts the argument list short, escaped characters in strings are read,
  `type` is read, and `env` / `headers` written on one line
  (`env = { KEY = "value" }`, the way Codex documents it) are read too.
- **Built-in servers never count as set up differently.** A server marked
  `"builtin": true` runs inside its own app, so it is no longer compared with
  other agents' setups.
- **Refresh and Check again ask for tools again.** A server that was already
  fine now shows tools it gained since. Timer rounds stay light.
- **A broken reply fails fast.** A server that sends a malformed message
  right away is reported at once, not after 40 seconds.
- **Hermes usage never skips calls.** When Hermes is busy writing its
  database, mcpock reads the missed calls next time instead of skipping them.
- **Demo mode keeps to itself.** `--demo` keeps every setting, the theme
  included, apart from your real settings, and does not check for updates.
- **Docs match the app.** mcpock checks from launch, each timer round reads
  the configs again, and a local server gets 20 seconds, tried twice.
