#!/bin/bash
# /bin/bash on purpose: Homebrew bash 5.3 deadlocks on heredocs over ~512 bytes when macOS hands out small pipe buffers.
# Build Roost.app — a signed, menu-bar-only bundle.
#
#   ./scripts/build-app.sh              build into build/Roost.app
#   ./scripts/build-app.sh --install    …and copy it to /Applications
#   ./scripts/build-app.sh --install --run
#
# Signing matters here: macOS ties Accessibility permission (needed to press ⌘V
# for you) to the code signature. An ad-hoc signature changes on every rebuild,
# so the grant would be lost each time. We sign with your Apple Development
# identity when there is one, which keeps the grant across rebuilds.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="Roost"
BUNDLE_ID="io.hammant.roost"
VERSION="0.1.0"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

INSTALL=0
RUN=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --run)     RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "==> building release binary"
swift build -c release --product Roost

echo "==> assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Roost" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>             <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>      <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>       <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>       <string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key>      <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>          <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>   <string>13.0</string>
  <key>LSUIElement</key>              <true/>
  <key>NSHumanReadableCopyright</key> <string>MIT — Roost</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Roost brings the terminal tab of the agent you click to the front, in iTerm2 or Terminal.</string>
</dict>
</plist>
PLIST

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')

if [ -n "$IDENTITY" ]; then
  echo "==> signing as: $IDENTITY"
  codesign --force --options runtime --timestamp=none \
    --entitlements "$ROOT/scripts/Roost.entitlements" \
    --sign "$IDENTITY" "$APP" >/dev/null
else
  echo "!   no Developer identity found — signing ad-hoc."
  echo "!   Accessibility permission will need re-granting after every rebuild."
  codesign --force --entitlements "$ROOT/scripts/Roost.entitlements" --sign - "$APP" >/dev/null
fi
codesign --verify --strict "$APP"

if [ "$INSTALL" -eq 1 ]; then
  DEST="/Applications/$APP_NAME.app"
  if ! touch /Applications/.roost-write-test 2>/dev/null; then
    DEST="$HOME/Applications/$APP_NAME.app"
    mkdir -p "$HOME/Applications"
  else
    rm -f /Applications/.roost-write-test
  fi
  echo "==> installing to $DEST"
  # Replace in place so the signature (and its permission grants) stay matched.
  osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  APP="$DEST"
fi

echo "==> built: $APP"
if [ "$RUN" -eq 1 ]; then
  open "$APP"
  echo "==> running — look for the bird in the menu bar"
fi
