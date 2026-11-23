#!/bin/bash
# Build, bundle and sign MacTranslate.app.  Usage: ./build.sh [install]
set -euo pipefail
cd "$(dirname "$0")"
APP=MacTranslate
BUNDLE_ID=local.mactranslate.app
# Signing identity: set IDENTITY in the environment or in the gitignored build.local.sh, e.g.
#   IDENTITY="Apple Development: Your Name (TEAMID)"
# A stable identity keeps the Input Monitoring permission across rebuilds. Default "-" = ad-hoc signing.
[ -f build.local.sh ] && source build.local.sh
IDENTITY="${IDENTITY:--}"
VERSION=${VERSION:-0.1.0}
BUILD=$(date +%Y%m%d%H%M)

swift build -c release --arch arm64 --product "$APP"
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP"
OUT="build/$APP.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    Resources/Info.plist > "$OUT/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$OUT/Contents/Resources/"
codesign --force --timestamp=none --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$OUT"
codesign --verify --strict "$OUT"
echo "Built $OUT"

if [ "${1:-}" = "install" ]; then
  pkill -x "$APP" || true
  sleep 0.5
  mkdir -p ~/Applications
  rm -rf ~/Applications/$APP.app
  ditto "$OUT" ~/Applications/$APP.app
  open ~/Applications/$APP.app
  echo "Installed to ~/Applications/$APP.app"
fi
