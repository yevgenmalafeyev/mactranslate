#!/bin/bash
# Build, bundle and sign mTranslate.app.  Usage: ./build.sh [install|dmg]
#   install  copy to ~/Applications and launch
#   dmg      also package build/mTranslate-<version>.dmg (universal binary) for distribution
set -euo pipefail
cd "$(dirname "$0")"
APP=mTranslate
BUNDLE_ID=local.mtranslate.app
# Signing identity: set IDENTITY in the environment or in the gitignored build.local.sh, e.g.
#   IDENTITY="Apple Development: Your Name (TEAMID)"
# A stable identity keeps the Input Monitoring permission across rebuilds. Default "-" = ad-hoc signing.
[ -f build.local.sh ] && source build.local.sh
IDENTITY="${IDENTITY:--}"
VERSION=${VERSION:-0.1.0}
BUILD=$(date +%Y%m%d%H%M)

# The distributable DMG gets a universal (Apple silicon + Intel) binary; local builds stay arm64-only.
ARCHS=(--arch arm64)
[ "${1:-}" = "dmg" ] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" --product "$APP"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/$APP"
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

if [ "${1:-}" = "dmg" ]; then
  DMG="build/$APP-$VERSION.dmg"
  STAGE=$(mktemp -d)
  ditto "$OUT" "$STAGE/$APP.app"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -volname "$APP" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "Packaged $DMG"
fi
