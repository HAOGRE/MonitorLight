#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p build
python3 scripts/i18n.py check
xcrun clang -Wall -Wextra -Werror -I Sources/DDCHelper Tests/DDCProtocolTests.c -o build/protocol-tests
build/protocol-tests
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
  Sources/MonitorLight/Core/*.swift Sources/MonitorLight/System/SoftwareDimming.swift \
  Tests/ModelTests.swift -o build/model-tests -framework AppKit -framework SwiftUI -framework ServiceManagement
build/model-tests
# Offscreen render of the panel (light + dark) for visual review.
UI_SOURCES=()
while IFS= read -r file; do UI_SOURCES+=("$file"); done < <(find Sources/MonitorLight/Core Sources/MonitorLight/UI Sources/MonitorLight/System -name '*.swift' | sort)
# Rendered from a real bundle so Localizable.strings apply, once per language.
PREVIEW=build/Preview.app/Contents
rm -rf build/Preview.app && mkdir -p "$PREVIEW/MacOS" "$PREVIEW/Resources"
cp Resources/Info.plist "$PREVIEW/Info.plist"
cp -R Resources/en.lproj "$PREVIEW/Resources/"
python3 scripts/i18n.py generate "$PREVIEW/Resources"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 "${UI_SOURCES[@]}" Tests/RenderPreview.swift \
  -o "$PREVIEW/MacOS/MonitorLight" -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement
"$PREVIEW/MacOS/MonitorLight" -AppleLanguages '(zh-Hans)'
"$PREVIEW/MacOS/MonitorLight" -AppleLanguages '(en)'
# Real NSEvents against the real slider and quick menu, inside this process.
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 "${UI_SOURCES[@]}" Tests/InteractionTests.swift \
  -o build/interaction-tests -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement
build/interaction-tests
