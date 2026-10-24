#!/bin/bash
# Quit MonitorLight, remove its login item and move the app to the Trash.
# Preferences and the local signing keychain are kept unless --purge is given.
set -euo pipefail
APP="$HOME/Applications/MonitorLight.app"
osascript -e 'tell application id "local.monitorlight.app" to quit' >/dev/null 2>&1 || true
pkill -x MonitorLight >/dev/null 2>&1 || true
if [ -d "$APP" ]; then
  osascript -e "tell application \"Finder\" to delete POSIX file \"$APP\"" >/dev/null
  echo "Moved to Trash: $APP"
fi
if [ "${1:-}" = "--purge" ]; then
  defaults delete local.monitorlight.app >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Caches/MonitorLight"
  echo "Removed preferences and caches."
fi
