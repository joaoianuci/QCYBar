#!/usr/bin/env bash
# Builds QCYBar.app (release by default) into ./build and ad-hoc signs it.
# Usage: scripts/build-app.sh [debug|release]
# Set INSTALL=1 to also copy it to ~/Applications and relaunch it.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/QCYBar.app"

cd "$ROOT"
swift build -c "$CONFIG" --product QCYBar
BIN="$(swift build -c "$CONFIG" --show-bin-path)/QCYBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QCYBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT"/Resources/*.lproj "$APP/Contents/Resources/"
# A stable identifier keeps the Bluetooth grant across rebuilds as long as the
# same identity signs it; ad-hoc ("-") is fine for local use.
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier io.github.joaoianuci.QCYBar "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${INSTALL:-0}" == "1" ]]; then
  pkill -x QCYBar 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/QCYBar.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/QCYBar.app
  echo "Installed ~/Applications/QCYBar.app"
fi
