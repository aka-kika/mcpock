# MCPBAR v1.1.1

Small follow-up to v1.1.0's hide feature.

**Released:** 2026-07-11 · **Requires:** macOS 26+ · **Architecture:** Apple silicon (arm64)

## Fixed

<!-- SF Symbol: wrench.and.screwdriver -->
- **Stale hides are auto-cleaned.** If a server you'd hidden later disappears from discovery (its agent or config was removed), MCPBAR now drops the leftover hidden entry on the next scan instead of keeping an unreachable hide. A hidden key is retained only while a live server still backs it (matched on the normalized name); if that server ever returns, it shows normally.

## Install

<!-- SF Symbol: arrow.down.circle -->
Download **MCPBAR.dmg** (~1.8 MB), open it, and drag MCPBAR to Applications. It lives in the menu bar (no Dock icon); left-click the icon for the panel, right-click for Settings / Quit.

**Checksum (SHA-256):** `8508fd367b25d6d1fd26fb83dd3a9f32dbe9ba1d70df4a49ced3428c473e7978`

## Verify

<!-- SF Symbol: checkmark.seal -->
Signed with Developer ID (Veronica Loren, team P5RB3W3D58) and notarized by Apple. MCPBAR runs **outside** the App Store sandbox by design so it can spawn MCP servers and read your agent config files; it is distributed directly (notarized DMG), not via the Mac App Store.

## Full changelog

Since **v1.1.0**: auto-clean stale hidden-server keys on rescan. No other changes.
