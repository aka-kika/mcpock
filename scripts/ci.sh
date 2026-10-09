#!/usr/bin/env bash
# Local CI pipeline — mirrors .github/workflows/ci.yml
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED="${DERIVED_DATA_PATH:-$ROOT/build}"
DESTINATION="${DESTINATION:-platform=macOS,arch=arm64}"
CONFIGURATION="${CONFIGURATION:-Debug}"

echo "==> mcpock CI (configuration=$CONFIGURATION)"
echo "    root=$ROOT"
echo "    derivedData=$DERIVED"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Install Xcode command-line tools." >&2
  exit 1
fi

echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild build"
xcodebuild \
  -scheme mcpock \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED" \
  -destination "$DESTINATION" \
  build

echo "==> xcodebuild test"
xcodebuild \
  -scheme mcpock \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED" \
  -destination "$DESTINATION" \
  test

# The test host writes throwaway UserDefaults suites (mcpock.tests.*,
# mcpock-start-*, ...); removePersistentDomain empties them, but cfprefsd
# flushes the emptied domain back to a same-named .plist in
# ~/Library/Preferences on its own schedule — sometimes only once the test
# host process itself has fully exited, which is after any in-test tearDown
# could have caught it. By the time xcodebuild returns here, that process is
# long gone, so this sweep (run from outside it) reliably catches what
# tearDown couldn't.
echo "==> sweeping leftover throwaway prefs files"
find ~/Library/Preferences -maxdepth 1 \
  \( -name 'mcpock.tests.*.plist' -o -name 'mcpock-start-*.plist' \
     -o -name 'round7.interval.*.plist' -o -name 'status-tests.plist' \
     -o -name 'ProbeIntervalTests.plist' -o -name 'AppPreferencesTests.*.plist' \) \
  -delete 2>/dev/null || true

echo "==> CI OK"
