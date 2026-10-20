# mcpock v1.10.6

**2026-10-14** — Usage counts never count the same call twice.

macOS 26+, Apple Silicon.

- **No more doubled usage counts.** When an agent's history file or database
  was rewritten, replaced or reset, mcpock read it again from the start and
  added every old call a second time. Now each history file remembers the
  newest call it already counted, and a file that starts over adds only the
  calls made after that. Counts saved by earlier versions are kept as they
  are.
