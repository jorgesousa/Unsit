#!/usr/bin/env bash
# Notarizes build/Unsit.app so colleagues can open it without a Gatekeeper warning.
# Needs the paid Apple Developer Program (99 USD/year).
#
# One-time setup:
#   xcrun notarytool store-credentials unsit-notary \
#     --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
#
# Then:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
#   scripts/notarize.sh
#
# Result: build/Unsit.zip, notarized and stapled, ready to share.

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Unsit.app"
ZIP="build/Unsit.zip"
PROFILE="${NOTARY_PROFILE:-unsit-notary}"

[[ -d "$APP" ]] || { echo "Build first: scripts/build-app.sh" >&2; exit 1; }

echo "→ Zipping for upload…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "→ Submitting to Apple (this takes a few minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "→ Stapling the ticket…"
xcrun stapler staple "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ Ready to share: $ZIP"
