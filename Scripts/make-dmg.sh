#!/bin/bash
# Packs build/Porthole.app (from Scripts/build-app.sh) for download:
#   build/Porthole-<version>.dmg  opens to the app and an Applications shortcut to drag it onto
#   build/Porthole-<version>.zip  just the app
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Porthole.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Porthole-$VERSION.dmg"
ZIP="build/Porthole-$VERSION.zip"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Porthole.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG" "$ZIP"
# hdiutil now and then fails with "Resource busy" on build machines; a retry gets past it.
for attempt in 1 2 3; do
    if hdiutil create -volname Porthole -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null; then break; fi
    if [[ $attempt == 3 ]]; then exit 1; fi
    sleep 5
done
ditto -c -k --keepParent "$APP" "$ZIP"
echo "$DMG"
echo "$ZIP"
