#!/bin/bash
# Render README/blog screenshots into docs/images from the real SwiftUI views,
# once per language (the bundle makes Localizable.strings apply).
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
SHOTS=build/Screenshots.app/Contents
rm -rf build/Screenshots.app && mkdir -p "$SHOTS/MacOS" "$SHOTS/Resources" docs/images
cp Resources/Info.plist "$SHOTS/Info.plist"
cp -R Resources/en.lproj "$SHOTS/Resources/"
python3 scripts/i18n.py generate "$SHOTS/Resources"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Sources/MonitorLight/Core Sources/MonitorLight/UI Sources/MonitorLight/System -name '*.swift' | sort)
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 "${SOURCES[@]}" Tests/Screenshots.swift \
  -o "$SHOTS/MacOS/MonitorLight" -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement
"$SHOTS/MacOS/MonitorLight" -AppleLanguages '(en)'
"$SHOTS/MacOS/MonitorLight" -AppleLanguages '(zh-Hans)'
