# Contributing to mcpock

Thanks for helping. mcpock is small on purpose, so please read
[Out of scope](#out-of-scope) below before proposing a feature. Issues and pull
requests are welcome. The maintainer is one person and replies when she can.

## Setup

- macOS 26 or later, Apple Silicon
- Xcode 26 or later (it brings the macOS 26 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

`project.yml` is the source of truth; `mcpock.xcodeproj` is generated from it.
Run `xcodegen generate` after you add, move or remove a file. Editing an
existing file needs no regeneration.

Debug builds sign with an Apple Development identity (team set in
`project.yml`). Without that certificate, build ad-hoc like CI does:
add `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO` to the `xcodebuild` line.

## Build and test

```bash
./scripts/ci.sh            # generate + build + test, same as CI
```

or by hand:

```bash
xcodegen generate
xcodebuild -scheme mcpock -configuration Debug \
  -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' \
  build test
```

- The build must stay at **zero warnings**, and every test must pass.
- `xcodebuild` prints harmless system noise. To hide it:
  `./scripts/ci.sh 2>&1 | grep -Ev "linkd|synchronousRemoteObject|Process Instance Registry|autoShortcut"`
- The unit tests run inside the app (it is the test host). Use a throwaway
  `UserDefaults(suiteName:)` in tests, never `.standard`, so a test never
  changes your own mcpock settings.

## Screenshots (demo mode)

Never take a website or README screenshot from a real setup — it shows real
server names, config paths and, sometimes, a stray secret. Launch the Debug
build with the hidden demo flag instead: a curated, fully offline sample set
(`Services/DemoData.swift`) replaces discovery and probing, so nothing real is
scanned, spawned or written.

```bash
open -n build/Build/Products/Debug/mcpock.app --args --demo
# or, on the raw binary:
/path/to/mcpock.app/Contents/MacOS/mcpock --demo
```

`MCPOCK_DEMO=1` in the environment works the same way. Demo mode is off, and
invisible in the UI, unless one of those is set; it never touches your real
`status.json`, widget snapshot, `usage.json` or saved settings (its own
monitor and panel persist into a throwaway `UserDefaults` suite instead).

## How we work

1. **Test first.** A bug fix or behaviour change starts with a failing test.
   Probe changes also get a run against a real (or deliberately slow or silent)
   server: fast mocks never hit the timeout paths.
2. **Keep the rules** in [docs/ARCHITECTURE.md §6](docs/ARCHITECTURE.md#6-rules-that-must-not-regress):
   no orphan processes, NDJSON over stdio, session replay over HTTP, discovery
   off the main thread, the scan stays out of Documents/Desktop/Downloads,
   no secret leaves the app, mcpock never writes another app's config.
3. **No new dependencies without asking first.** JSON-RPC, TOML and YAML stay
   hand-rolled. Sparkle (round 10, in-app updates) is the one approved
   exception, added on purpose; see [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md).
4. **Ask first** before adding entitlements, a new settings surface, or
   anything on the Out of scope list.
5. **One change per pull request**, with a short plain-English description.

## Style

- Follow the code around you: 4-space indent, `enum` namespaces for stateless
  helpers, comments that say *why*, not *what*.
- Keep wording out of views: texts live in pure helpers (`PanelText`,
  `CardText`, `MenuText`, `ShortReason`) so tests can pin them.
- `HealthMonitor` is the single source of truth; views read from it.
- Plain English in docs and UI. No emojis.

## Docs to update with a change

| You changed… | Also update… |
|--------------|--------------|
| What the user sees | [README.md](README.md), the next `docs/RELEASE-NOTES-v*.md` |
| Architecture or a rule | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Agent logos | [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md) |

## Out of scope

These stay out unless there is a deliberate product decision first:

- Notifications or alerts
- Editing or writing any MCP config file (mcpock only reads)
- A heavy MCP SDK or more third-party dependencies (JSON-RPC stays
  hand-rolled; Sparkle, for updates, is the one dependency)
- Sandbox on with exceptions (it would break starting servers and reading
  configs)
- iOS or other platforms; Mac App Store distribution
