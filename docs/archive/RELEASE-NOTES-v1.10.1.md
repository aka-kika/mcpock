# mcpock v1.10.1

**2026-10-11** — Tinycast's servers.

macOS 26+, Apple Silicon.

- **Tinycast.** mcpock now reads the MCP servers you added in Tinycast, which
  keeps them in its own settings instead of a config file. They show under
  their own agent, Tinycast. A Tinycast server that needs a key, a header or a
  sign-in keeps that secret in Tinycast's own Keychain items, which mcpock
  never reads, so it shows as managed by its app instead of looking broken.
  Servers without a secret are checked like any other. Servers you switched
  off in Tinycast, or MCP switched off as a whole, are skipped.
- **The setup prompt** ("Copy for Claude" in Settings > Connect) tells the
  agent to add mcpock in Tinycast's own MCP settings, never to edit its
  preferences file.
- **Tests stay out of sight.** While the app hosts its unit tests it no longer
  puts a second mcpock icon in the menu bar.
