# mcpock v1.7.1

**2026-09-26** — mcpock checks your servers from the moment it starts.

macOS 26+, Apple Silicon.

---

## Fixed: nothing was checked until you opened the panel

After an install, a restart or a login, mcpock sat idle until the first
time you opened its panel. Until then:

- no server was checked,
- agents asking mcpock (`mcpock_problems`, `mcpock_status`) got an old
  answer, or none, and
- usage counts were not read.

mcpock now starts its first check when it launches, then follows your
"Check servers" setting as before. Usage counts update after every full
check, panel open or not.

Everything else is v1.7.0 (see `docs/RELEASE-NOTES-v1.7.0.md`).
