#!/usr/bin/env bash
#
# Build, sign, notarize, staple, and package mcpock for direct distribution
# (notarized DMG). NOT the Mac App Store — mcpock runs with the sandbox off so it
# can spawn MCP servers and read configs under ~/.
#
# One-time setup:
#
# 1. Store notary credentials in the keychain (interactive, app-specific
#    password from appleid.apple.com):
#
#      xcrun notarytool store-credentials <profile-name> \
#        --apple-id "you@example.com" --team-id <TEAMID> \
#        --password "<app-specific-password>"
#
# 2. cp scripts/release.env.example scripts/release.env (git-ignored) and fill
#    in your Developer ID identity and that profile name.
#
# Then just: ./scripts/release.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Signing identity and notary profile: scripts/release.env (git-ignored),
# or the same variables from the environment.
if [[ -f scripts/release.env ]]; then
  # shellcheck source=/dev/null
  source scripts/release.env
fi

SCHEME="mcpock"
APP_NAME="mcpock"
BUNDLE_ID="com.mcpock.app"
# Signing identity: the SHA-1 hash of a "Developer ID Application" identity
# (`security find-identity -v -p codesigning`). Prefer the hash to the name:
# a keychain holding two same-named certificates makes codesign fail with
# "ambiguous".
IDENTITY="${MCPOCK_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  echo "error: set MCPOCK_SIGN_IDENTITY in scripts/release.env (see release.env.example)" >&2
  exit 1
fi
NOTARY_PROFILE="${MCPOCK_NOTARY_PROFILE:-}"
if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "error: set MCPOCK_NOTARY_PROFILE in scripts/release.env (see release.env.example)" >&2
  exit 1
fi
BUILD_DIR="build"
DIST_DIR="dist"

echo "==> Generating project + building Release"
xcodegen generate
xcodebuild -scheme "$SCHEME" -configuration Release -derivedDataPath "$BUILD_DIR" \
  -destination 'platform=macOS,arch=arm64' clean build

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
rm -rf "$DIST_DIR"; mkdir -p "$DIST_DIR"

echo "==> Trimming and signing Sparkle (round 10: in-app updates)"
# mcpock is not sandboxed, so it never sets SUEnableInstallerLauncherService /
# SUEnableDownloaderService — those XPC services exist only to let a
# *sandboxed* app reach outside its sandbox to install updates or download
# without the network-client entitlement (Sparkle's own docs, "Sandboxing
# with Sparkle" > "Removing XPC Services": https://sparkle-project.org/documentation/sandboxing/#removing-xpc-services).
# Unused code that never runs is still an unsigned liability, so it is
# removed rather than carried and signed — Sparkle documents exactly this
# trim for a non-sandboxed app, with a sample script to do it.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE" ]] || { echo "error: $SPARKLE missing from the build" >&2; exit 1; }
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
# Xcode's build re-signs Sparkle.framework's own binary with the project's
# signing identity (Apple Development, here) as it embeds the framework, but
# — per the same Sparkle doc's "Code Signing" section — it does NOT re-sign
# what's nested inside: Autoupdate and Updater.app ship ad-hoc signed. Each
# needs Developer ID + hardened runtime before notarizing, innermost first,
# same as the helper and the widget below; never --deep (Sparkle's docs warn
# against it here too, for the same reason release.sh already avoids it: a
# blanket re-sign would stamp settings onto nested code that needs its own).
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/Versions/B/Autoupdate"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/Versions/B/Updater.app"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE"

echo "==> Codesigning with Developer ID + hardened runtime (inside out)"
# Never --deep: it would stamp the app's own (unsandboxed) entitlements onto
# every nested item it re-signs, including the widget's .appex — breaking its
# sandbox. Sign nested code first, each with its own entitlements file, then
# the app last, same order Xcode itself builds and embeds in.
HELPER="$APP/Contents/Helpers/mcpock-mcp"
WIDGET="$APP/Contents/PlugIns/mcpockWidgets.appex"
# Both ship in every release: a missing one means a broken build, not an
# optional part, so stop instead of shipping without it.
[[ -x "$HELPER" ]] || { echo "error: $HELPER missing from the build" >&2; exit 1; }
[[ -d "$WIDGET" ]] || { echo "error: $WIDGET missing from the build" >&2; exit 1; }
# No entitlements of its own (project.yml declares none for mcpock-mcp).
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$HELPER"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  --entitlements mcpockWidgets/mcpockWidgets.entitlements "$WIDGET"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  --entitlements mcpock/mcpock.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"
# A widget without its sandbox never loads: check the signature kept it.
codesign -d --entitlements - "$WIDGET" 2>/dev/null | grep -q "com.apple.security.app-sandbox" \
  || { echo "error: the widget lost its sandbox entitlement" >&2; exit 1; }
# Sparkle's Autoupdate and Updater.app must carry Developer ID, not the
# ad-hoc signature they shipped with, or notarization rejects the app.
codesign --verify --strict --verbose=2 "$SPARKLE/Versions/B/Autoupdate"
codesign --verify --strict --verbose=2 "$SPARKLE/Versions/B/Updater.app"
if [[ -e "$SPARKLE/Versions/B/XPCServices" ]]; then
  echo "error: Sparkle's XPC services are still in the build (mcpock isn't sandboxed and doesn't need them)" >&2
  exit 1
fi

echo "==> Notarizing the app"
ZIP="$DIST_DIR/$APP_NAME.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"           # staple the ticket into the .app
rm -f "$ZIP"

echo "==> Building + signing the DMG"
DMG="$DIST_DIR/$APP_NAME.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Notarizing + stapling the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Verifying Gatekeeper acceptance"
spctl --assess --type execute --verbose=4 "$APP" || true
xcrun stapler validate "$DMG"

echo "Shipped: $DMG (Developer ID signed, notarized, stapled)"
