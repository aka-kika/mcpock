# Building mcpock

How to build, test and release mcpock, and how it works inside. Setup and pull request rules: [CONTRIBUTING.md](../CONTRIBUTING.md). Back to the [README](../README.md).

## Build and run

You need macOS 26+, Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
git clone https://github.com/aka-kika/mcpock.git
cd mcpock
xcodegen generate
xcodebuild -scheme mcpock -configuration Debug \
  -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' build
open build/Build/Products/Debug/mcpock.app
```

Debug builds sign with an Apple Development identity (team in `project.yml`),
which keeps macOS folder permissions across rebuilds. Without that certificate,
add `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO` to the `xcodebuild` line
(that is what CI does).

## Test

```bash
./scripts/ci.sh      # xcodegen generate + build + test, same as GitHub Actions
```

901 unit tests at v1.14.0. They cover the
probes against real child processes and a real local HTTP server, process
cleanup, every config format, discovery and the scan's safety rules, grouping,
"set up differently", secret masking, the status file and the helper's
answers, and the panel's wording and layout.

## How it works

- **Discovery:** `AgentRegistry` (known paths) plus `ConfigScanner` (a shallow,
  size-capped scan of the usual config folders) plus `AkaSource`. A file counts
  only when it has at least one server with a `command` or a `url`, which keeps
  unrelated JSON out. TOML and YAML are read by small built-in parsers.
- **Probing:** `HealthMonitor` probes every server in parallel off the main
  thread. stdio servers get newline-delimited JSON-RPC (`initialize`,
  `tools/list`) and are then stopped along with their child processes. HTTP
  servers get the same over streamable HTTP (session id replayed) or legacy SSE.
  Identical setups are probed once. A single timeout shows as slow, a second one
  or a hard failure as broken, and failing servers back off to hourly checks.
- **Grouping:** instances with the same name (case and separators ignored)
  become one row; the worst state wins, and a launch target that differs from
  the majority becomes a "set up differently" note.
- **UI:** a `MenuBarExtra` panel of fixed size, with the detail card as a child
  panel beside it that never takes focus. The tools list is on the card.
- **Agents:** after each change the app writes `status.json` and `status.md`;
  the bundled `mcpock-mcp` (stdio) answers from that file; its `mcpock_ask`
  only leaves a request in `asks/` for you to answer.

The full module map, the flow of one refresh, and the rules that must not
regress are in [ARCHITECTURE.md](ARCHITECTURE.md).

## Project layout

```
mcpock/                 The app
  MCPockApp.swift       Entry point: the menu bar item and panel
  Models/               Server config, health, groups
  Services/             Discovery, probes, process runner, texts, status file
  Theme/                Colours, fonts, appearance
  Views/                Panel, rows, detail card, Agents tab, Settings
  Assets.xcassets/      App icon, agent logos, About links
mcpock-mcp/             The MCP helper (main.swift)
mcpockWidgets/          The desktop widgets (Status, Problems, Agents)
Shared/                 Code compiled into both app and helper
mcpockTests/            Unit tests
project.yml             XcodeGen spec (source of truth for the Xcode project)
scripts/ci.sh           Local CI: generate, build, test
scripts/release.sh      Release build, Developer ID signing, notarized DMG
scripts/appcast.sh      Sparkle's signed update feed (appcast.xml) from a folder of release DMGs
docs/                   Architecture, release notes, third-party credits
```

## Adding an agent

If it writes a standard format into a scanned folder, it already works. Add a
row to `AgentRegistry.known` for a clean name or a path outside the scan; add a
`ConfigShape` and a parser for a new format; add a logo as an
`agent-<name>.imageset` plus a `logoNames` entry. Details in
[ARCHITECTURE.md §7](ARCHITECTURE.md#7-adding-an-agent).

## Release

`scripts/release.sh` builds Release, signs with a Developer ID identity and
hardened runtime, notarizes and staples the app and the DMG, and writes
`dist/mcpock.dmg`. One-time setup, storing an app-specific password in your
keychain:

```bash
xcrun notarytool store-credentials my-notary \
  --apple-id "you@example.com" --team-id <TEAMID> \
  --password "<app-specific password from appleid.apple.com>"
MCPOCK_NOTARY_PROFILE=my-notary MCPOCK_SIGN_IDENTITY=<identity hash> ./scripts/release.sh
```

You can put the two variables in `scripts/release.env` (git-ignored, see
`scripts/release.env.example`) instead. Without them the script stops with an
error. It also stops if `docs/release-notes/<version>.md` is missing, if the
tests (`scripts/ci.sh`) fail, or if Gatekeeper rejects the app.
