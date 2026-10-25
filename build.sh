#!/bin/bash
# Builds Prune.app (release, ad-hoc signed). Pass --install to copy it into ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Prune"
APP="build/Prune.app"

[ -f Resources/AppIcon.icns ] || swift scripts/make_icon.swift Resources

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Prune"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  pkill -x Prune 2>/dev/null || true
  rm -rf "$HOME/Applications/Prune.app"
  cp -R "$APP" "$HOME/Applications/Prune.app"
  echo "Installed to ~/Applications/Prune.app"
fi
