# MCPBAR v1.1.0

Quality-of-life release. You can now **hide** the MCP servers you don't care to
watch, and the errors you copy out of MCPBAR finally explain themselves when you
paste them into an AI assistant.

**Released:** 2026-07-11 · **Requires:** macOS 26+ · **Architecture:** Apple silicon (arm64)

## Highlights

<!-- SF Symbol: star -->
- **Hide a noisy server** — right-click any row → **"Hide this server"** and it drops out of the list. Hidden servers live in a collapsible **"Hidden (N)"** section at the bottom of the panel (and in Settings), each with an **Unhide** button, plus **Unhide all**. Your choices persist across restarts.
- **Honest menu-bar icon** — hiding is *display-only*: a hidden-but-broken server still counts in the "X/Y healthy" header and still turns the menu-bar icon red. So a hidden failure never silently disappears — and the "Hidden (N)" header carries its own status dot so a red icon over an all-green list has a visible reason.
- **Paste-ready errors** — "Copy error" (and the exported Markdown) now open with a one-line framing preamble that tells an AI assistant what MCPBAR is and that the server is failing its startup health check. No more "what is this app and why is it generating errors?"

## Added

<!-- SF Symbol: plus -->
- "Hide this server" in the row context menu; hidden servers are excluded from the list.
- Collapsible "Hidden (N)" section in the menu panel with per-row Unhide and a status dot reflecting the worst hidden state.
- Settings → "Hidden servers": list of hidden servers with per-row **Unhide** and **Unhide all**.
- Hidden-server set is persisted (UserDefaults), keyed by the normalized server name so it survives case/separator variants.

## Changed

<!-- SF Symbol: arrow.triangle.2.circlepath -->
- The copied error report (`Copy error`) is prefixed with an explanatory preamble so it's self-explanatory when pasted into Claude or another assistant.
- The exported error Markdown gains a matching one-line explainer (shown only when there are failing servers).

## Fixed

<!-- SF Symbol: wrench.and.screwdriver -->
- Nothing user-facing broken since v1.0.0; this release is purely additive.

## Install

<!-- SF Symbol: arrow.down.circle -->
Download **MCPBAR.dmg** (~1.8 MB), open it, and drag MCPBAR to Applications. It lives in the menu bar (no Dock icon); left-click the icon for the panel, right-click for Settings / Quit.

**Checksum (SHA-256):** `7e4734f870cc2973085e0c336f897f52f521aba261d8912b7153081d057bf035`

## Verify

<!-- SF Symbol: checkmark.seal -->
Signed with Developer ID (Veronica Loren, team P5RB3W3D58) and notarized by Apple. MCPBAR runs **outside** the App Store sandbox by design so it can spawn MCP servers and read your agent config files; it is distributed directly (notarized DMG), not via the Mac App Store.

## Full changelog

Since **v1.0.0**: adds hide/unhide for MCP servers (menu panel + Settings, persisted) and self-explanatory copied/exported error reports. No breaking changes.
