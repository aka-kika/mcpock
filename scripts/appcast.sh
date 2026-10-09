#!/usr/bin/env bash
#
# Build mcpock's Sparkle update feed (appcast.xml) from a folder of notarized
# release DMGs. The DMGs and the appcast are hosted on mcpock.com; uploading
# them is a separate step. This script only builds the feed file locally.
#
# One-time (per release DMG): copy dist/mcpock.dmg into a folder that holds
# every version still worth offering as an update, under its own name, e.g.
#
#   mkdir -p ~/mcpock-appcast
#   cp dist/mcpock.dmg ~/mcpock-appcast/mcpock-1.9.0.dmg
#   ./scripts/appcast.sh ~/mcpock-appcast
#
# Then: ./scripts/appcast.sh <folder>
#
# generate_appcast (from Sparkle's resolved SPM package) EdDSA-signs each DMG
# using mcpock's own private key in the login Keychain (account "mcpock",
# made 2026-10-09 with `generate_keys --account mcpock`; override with
# SPARKLE_KEY_ACCOUNT). It never prints or exports that key; if the Keychain
# prompts for access, allow it.
#
# Re-running this script over the same folder after adding a new DMG updates
# appcast.xml in place (old versions beyond --maximum-versions move to
# old_updates/, kept off mcpock.com on purpose — only what the feed lists
# needs to be uploaded).
set -euo pipefail
cd "$(dirname "$0")/.."

FOLDER="${1:?usage: scripts/appcast.sh <folder-of-release-dmgs>}"
[[ -d "$FOLDER" ]] || { echo "error: $FOLDER is not a folder" >&2; exit 1; }

# mcpock.com/downloads/ is where the DMGs this appcast points at live.
# Override for a dry run against a different host.
DOWNLOAD_PREFIX="${MCPOCK_DOWNLOAD_URL_PREFIX:-https://mcpock.com/downloads/}"

# generate_appcast ships inside the same Sparkle SPM package generate_keys
# comes with; look wherever xcodebuild last resolved it —
# release.sh and ci.sh both point -derivedDataPath at "build/" in the repo,
# so that is checked first, then a plain Xcode.app build's DerivedData cache.
GENERATE_APPCAST="$(find "$PWD/build/SourcePackages/artifacts" \
  ~/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts \
  -maxdepth 4 -path '*/sparkle/Sparkle/bin/generate_appcast' -print -quit 2>/dev/null || true)"
if [[ -z "$GENERATE_APPCAST" ]]; then
  echo "error: generate_appcast not found under any SourcePackages/artifacts folder." >&2
  echo "  Resolve the package first: xcodegen generate && xcodebuild -resolvePackageDependencies -scheme mcpock -derivedDataPath build" >&2
  exit 1
fi

echo "==> Signing and building $FOLDER/appcast.xml"
"$GENERATE_APPCAST" --account "${SPARKLE_KEY_ACCOUNT:-mcpock}" \
  --download-url-prefix "$DOWNLOAD_PREFIX" "$FOLDER"

echo "Done: $FOLDER/appcast.xml is ready."
echo "   Upload it, and every DMG it references, to the download host."
