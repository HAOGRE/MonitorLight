#!/bin/bash
# Package the built app into a drag-to-install DMG: build/MonitorLight-<version>.dmg
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
APP=.build.noindex/MonitorLight.app
[ -d "$APP" ] || bash scripts/build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
STAGE=build/dmg
OUT="build/MonitorLight-$VERSION.dmg"
rm -rf "$STAGE" "$OUT" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/MonitorLight.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MonitorLight $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
rm -rf "$STAGE"
hdiutil verify "$OUT" >/dev/null
shasum -a 256 "$OUT"
echo "Created: $OUT"
