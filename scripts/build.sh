#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
APP="$PROJECT_DIR/.build.noindex/MonitorLight.app"
SIGNING_IDENTITY="${MONITORLIGHT_SIGNING_IDENTITY:-}"
SIGNING_OPTIONS=()
if [ -z "$SIGNING_IDENTITY" ]; then
  SIGNING_KEYCHAIN=$(python3 scripts/local-signing.py)
  SIGNING_IDENTITY='MonitorLight Local Development'
  SIGNING_OPTIONS=(--keychain "$SIGNING_KEYCHAIN")
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
xcrun clang -O2 -Wall -Wextra -Werror -fmodules -arch arm64 -mmacosx-version-min=14.0 \
  -I Vendor/m1ddc -I Sources/DDCHelper -framework CoreDisplay \
  Vendor/m1ddc/ioregistry.m Sources/DDCHelper/main.m -o "$APP/Contents/Helpers/monitor-ddc"
SWIFT_SOURCES=()
while IFS= read -r file; do SWIFT_SOURCES+=("$file"); done < <(find Sources/MonitorLight -name '*.swift' | sort)
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
  "${SWIFT_SOURCES[@]}" -o "$APP/Contents/MacOS/MonitorLight" \
  -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Localizations: English table + generated Chinese identity tables; app name per language.
python3 scripts/i18n.py check
cp -R Resources/en.lproj "$APP/Contents/Resources/"
python3 scripts/i18n.py generate "$APP/Contents/Resources"
printf '"CFBundleDisplayName" = "MonitorLight";\n"CFBundleName" = "MonitorLight";\n' > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
for LANGUAGE in zh-Hans zh-Hant; do
  printf '"CFBundleDisplayName" = "光控";\n"CFBundleName" = "光控";\n' > "$APP/Contents/Resources/$LANGUAGE.lproj/InfoPlist.strings"
done
cp Vendor/m1ddc/LICENSE "$APP/Contents/Resources/m1ddc-LICENSE.txt"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
codesign --force --sign "$SIGNING_IDENTITY" "${SIGNING_OPTIONS[@]}" --timestamp=none --identifier local.monitorlight.ddc "$APP/Contents/Helpers/monitor-ddc"
codesign --force --sign "$SIGNING_IDENTITY" "${SIGNING_OPTIONS[@]}" --timestamp=none --identifier local.monitorlight.app "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
