#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$PROJECT_DIR/.build.noindex/MonitorLight.app"
DESTINATION="$HOME/Applications/MonitorLight.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ ! -d "$APP" ]; then bash "$PROJECT_DIR/scripts/build.sh"; fi
if [ -d "$DESTINATION" ]; then
  BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DESTINATION/Contents/Info.plist")
  if [ "$BUNDLE_ID" != "local.monitorlight.app" ]; then
    echo "Destination contains a different application; installation stopped." >&2
    exit 1
  fi
  mkdir -p "$PROJECT_DIR/build/backups"
  ditto -c -k --sequesterRsrc --keepParent "$DESTINATION" "$PROJECT_DIR/build/backups/MonitorLight-$(date +%Y%m%d-%H%M%S).zip"
fi
python3 - "$DESTINATION/Contents/MacOS/MonitorLight" "$PROJECT_DIR" <<'PY'
import os, signal, subprocess, sys, time
target = sys.argv[1]
project = sys.argv[2]
targets = {target, *(project + '/' + suffix + '/Contents/MacOS/MonitorLight' for suffix in
                    ('build/MonitorLight.app', 'build/MonitorLight.previous.app', '.build.noindex/MonitorLight.app'))}
for line in subprocess.check_output(['ps', '-ww', '-axo', 'pid=,comm='], text=True).splitlines():
    parts = line.strip().split(None, 1)
    if len(parts) == 2 and parts[1] in targets:
        pid = int(parts[0])
        try:
            os.kill(pid, signal.SIGTERM)
            for _ in range(40):
                time.sleep(.05)
                try: os.kill(pid, 0)
                except ProcessLookupError: break
            else: raise RuntimeError('MonitorLight did not exit; retry after quitting the app.')
        except ProcessLookupError:
            pass
PY
mkdir -p "$HOME/Applications"
ditto "$APP" "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
# Archive and unregister old development copies so Spotlight exposes one app.
for OLD_APP in "$PROJECT_DIR/build/MonitorLight.app" "$PROJECT_DIR/build/MonitorLight.previous.app"; do
  if [ -d "$OLD_APP" ]; then
    mkdir -p "$PROJECT_DIR/build/backups"
    ARCHIVE="$PROJECT_DIR/build/backups/$(basename "$OLD_APP")-$(date +%Y%m%d-%H%M%S).zip"
    ditto -c -k --sequesterRsrc --keepParent "$OLD_APP" "$ARCHIVE"
    unzip -tq "$ARCHIVE"
    "$LSREGISTER" -u "$OLD_APP" || true
    rm -rf -- "$OLD_APP"
  fi
done
"$LSREGISTER" -u "$APP" || true
"$LSREGISTER" -f "$DESTINATION"
open "$DESTINATION"
echo "Installed and started: $DESTINATION"
