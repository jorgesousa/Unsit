#!/usr/bin/env bash
# Builds Unsit.app from source.
#
#   scripts/build-app.sh              build into build/Unsit.app
#   scripts/build-app.sh --install    build, then copy to /Applications
#   scripts/build-app.sh --open       build, install and launch
#
# Signing: ad-hoc by default (fine for your own Mac).
# Set SIGN_IDENTITY to sign with a certificate, for example:
#   SIGN_IDENTITY="Unsit Local" scripts/build-app.sh          (self-signed, keeps calendar permission between builds)
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh   (for notarized sharing)

set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
OPEN=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --open) INSTALL=1; OPEN=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

APP_NAME="Unsit"
APP="build/${APP_NAME}.app"

echo "→ Compiling (release)…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "→ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "→ Signing…"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  echo "  Signed with: $SIGN_IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "  Ad-hoc signed (macOS may ask for calendar access again after each rebuild)."
fi

if [[ $INSTALL -eq 1 ]]; then
  echo "→ Installing to /Applications…"
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$APP" /Applications/
  APP="/Applications/${APP_NAME}.app"
fi

echo "✓ Built $APP"

if [[ $OPEN -eq 1 ]]; then
  open "$APP"
fi
