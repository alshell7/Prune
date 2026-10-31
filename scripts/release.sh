#!/bin/bash
# Builds, tests and publishes a GitHub release: Prune.zip plus its SHA-256 (the in-app updater requires both).
# Usage: scripts/release.sh [notes-file]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"

./build.sh
BIN="$(swift build -c release --show-bin-path)/Prune"
for suite in --selftest --selftest-features --selftest-security --selftest-offload; do "$BIN" "$suite" >/dev/null; done
echo "Self-tests passed"

rm -f build/Prune.zip build/Prune.zip.sha256
ditto -c -k --keepParent build/Prune.app build/Prune.zip
(cd build && shasum -a 256 Prune.zip > Prune.zip.sha256)

NOTES=(--generate-notes)
[ -n "${1:-}" ] && NOTES=(--notes-file "$1")
gh release create "$TAG" build/Prune.zip build/Prune.zip.sha256 --title "Prune $VERSION" "${NOTES[@]}"
echo "Released $TAG"
