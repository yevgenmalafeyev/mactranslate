#!/bin/bash
# Build, bundle and sign mTranslate.app.  Usage: ./build.sh [install|dmg]
#   install  copy to ~/Applications and launch (signed with the local identity)
#   dmg      universal build signed with "Developer ID Application", packaged as
#            build/mTranslate-<version>.dmg, notarized by Apple and stapled (NOTARIZE=0 skips notarization)
set -euo pipefail
cd "$(dirname "$0")"
APP=mTranslate
BUNDLE_ID=local.mtranslate.app
# Local signing identity: set IDENTITY in the environment or in the gitignored build.local.sh, e.g.
#   IDENTITY="Apple Development: Your Name (TEAMID)"
# A stable identity keeps the Input Monitoring permission across rebuilds. Default "-" = ad-hoc signing.
# For the DMG: DIST_IDENTITY (default "Developer ID Application") and NOTARY_PROFILE, a keychain profile
# created with `xcrun notarytool store-credentials`.
[ -f build.local.sh ] && source build.local.sh
IDENTITY="${IDENTITY:--}"
DIST_IDENTITY="${DIST_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-mrecorder-notary}"
VERSION=${VERSION:-0.1.1}
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
# Hardened runtime always, and no entitlements: without it any program could load its own code into the app
# (DYLD_INSERT_LIBRARIES) and use its Input Monitoring permission.
if [ "${1:-}" = "dmg" ]; then
  codesign --force --options runtime --timestamp --identifier "$BUNDLE_ID" --sign "$DIST_IDENTITY" "$OUT"
else
  codesign --force --options runtime --timestamp=none --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$OUT"
fi
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

notarize() {  # <file to submit>
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait | tee build/notary.log
  grep -q "status: Accepted" build/notary.log || { echo "Notarization failed (see: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE)"; exit 1; }
}

if [ "${1:-}" = "dmg" ]; then
  DMG="build/$APP-$VERSION.dmg"
  if [ "${NOTARIZE:-1}" != "0" ]; then
    # The app gets its own ticket first, so the copy in /Applications opens without a network check.
    ditto -c -k --keepParent "$OUT" build/$APP.zip
    notarize build/$APP.zip
    rm -f build/$APP.zip
    xcrun stapler staple "$OUT"
  fi
  STAGE=$(mktemp -d)
  ditto "$OUT" "$STAGE/$APP.app"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -volname "$APP" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
  rm -rf "$STAGE"
  codesign --force --timestamp --sign "$DIST_IDENTITY" "$DMG"
  codesign --verify --strict "$DMG"
  echo "Packaged $DMG"
  if [ "${NOTARIZE:-1}" != "0" ]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    spctl --assess --type execute --verbose=2 "$OUT"
  fi
  echo "SHA-256: $(shasum -a 256 "$DMG")"
fi
