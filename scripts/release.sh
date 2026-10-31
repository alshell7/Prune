#!/bin/bash
# Builds, tests and publishes a GitHub release: Prune.dmg to download, plus Prune.zip and its SHA-256 for the in-app updater.
# Usage: scripts/release.sh [notes-file]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"

./build.sh
BIN="$(swift build -c release --show-bin-path)/Prune"
for suite in --selftest --selftest-features --selftest-security --selftest-offload; do "$BIN" "$suite" >/dev/null; done
echo "Self-tests passed"

rm -f build/Prune.zip build/Prune.zip.sha256 build/Prune.dmg
ditto -c -k --keepParent build/Prune.app build/Prune.zip
(cd build && shasum -a 256 Prune.zip > Prune.zip.sha256)

# Drag-to-install disk image: the app plus an Applications shortcut.
STAGE="$(mktemp -d)"
cp -R build/Prune.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Prune $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov build/Prune.dmg >/dev/null
rm -rf "$STAGE"
hdiutil verify build/Prune.dmg >/dev/null
echo "Built build/Prune.dmg"

NOTES=(--generate-notes)
[ -n "${1:-}" ] && NOTES=(--notes-file "$1")
gh release create "$TAG" build/Prune.dmg build/Prune.zip build/Prune.zip.sha256 --title "Prune $VERSION" "${NOTES[@]}"
echo "Released $TAG"
